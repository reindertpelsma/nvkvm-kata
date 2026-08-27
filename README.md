# nvkvm-kata

**Status: IT RUNS.** On 2026-08-27 a CUDA vector-add executed inside an OCI
container, inside a Kata Containers VM, on an NVIDIA RTX 4070 Ti SUPER, with
every ioctl forwarded by nvkvm to the host driver — and the host keeping the
card the whole time. Two Kata sandboxes then shared that one GPU concurrently,
which is the thing Kata's existing VFIO passthrough path cannot do at all.
**Read [07 — End to end](docs/design/07-end-to-end.md)**: it has the commands
that reproduce it, and two measured findings that change what the earlier
design docs claim.

Upstream changes required for any of it: **one line** — widening
`build-kernel.sh`'s `-g` vendor validation to accept a third value.

**The two findings, because they are the important part:**

1. **The container's device cgroup is not enforced inside the guest** on
   cgroup v2. Measured with the *identical* OCI spec under two runtimes: `runc`
   returns EPERM, Kata does not. [03](docs/design/03-guest-side-devices.md)
   calls that cgroup "the one that decides"; here it decides nothing, and
   `nvidia-smi` works in a container that was never given a GPU.
2. **Kata's shipped generic rootfs cannot load a kernel module.**
   `kernel_modules = [...]` execs `/sbin/modprobe`, and `kata-containers.img`
   4.1.0 ships no modprobe, no kmod and no busybox. The shipped mechanism
   cannot run on the shipped image.

**The earlier gating unknown was also measured.** See
[01 §1.4](docs/design/01-vmm-confinement.md) — on cgroup v2 the Kata hypervisor
can open `/dev/nvidiactl` and every other NVIDIA node, unconfigured, for both
`sandbox_cgroup_only` values, on both Kata runtimes, verified against a real GPU
and driver. Not because Kata permits it, but because Kata's device policy is
silently discarded on cgroup v2 before it is ever attached.

## The pitch, in one paragraph

[`nvkvm`](../nvkvm-pv) gives a KVM guest driver-level NVIDIA GPU access without
PCIe passthrough: a guest kernel module forwards the NVIDIA driver's own ioctl
interface over virtio to unprivileged per-guest-process isolate processes on the
host, which run the real ioctls against the real driver, while the host keeps
using the card. Guest userspace is stock NVIDIA. Measured at roughly host parity
for CUDA, PyTorch, LLM inference and Vulkan compute. **`nvkvm-kata` is the
proposal to run that stack inside [Kata Containers](https://katacontainers.io),
so that an OCI/Kubernetes workload gets a GPU behind a real VM boundary with no
passthrough, no vGPU licence, and no loss of the GPU to the host.**

The original pitch added "…and so that the VMM is confined by the container
platform's own machinery rather than by nvkvm's own tooling". **Measurement
removed most of that clause** — Kata jails Firecracker but not QEMU, and nvkvm
is QEMU-only. What survives, and is a better reason, is below.

Scope is deliberately narrow: **compute and headless graphics only.** No display
path, no display broker, no audio, no clipboard, no input.

## What the research changed

The design was started expecting the guest half to be the hard, unprecedented
part. **That was wrong, and the inversion is the main result.**

| piece | status |
|---|---|
| VMM opening the **host** GPU device nodes | **MEASURED, and it works today by accident.** Kata builds the sandbox device cgroup itself as an allowlist that excludes `/dev/nvidia*` — and then, on cgroup v2, never installs it, so the VMM opens every NVIDIA node read-write with no configuration. Confirmed on a real RTX 3060. Treat as temporary — [01](docs/design/01-vmm-confinement.md) |
| confinement of the **VMM process itself** | **MEASURED, and it is the weak point.** Kata jails Firecracker and enables Cloud Hypervisor's seccomp by default; its QEMU driver gets neither, and ships with `seccompsandbox = ""`. Since nvkvm is QEMU-only, this project is pinned to the least-confined VMM — [01 §3](docs/design/01-vmm-confinement.md), [05 §2a](docs/design/05-caveats-and-scope.md) |
| host NVIDIA **libraries** into the container | works via CDI mounts → virtio-fs; CDI **hooks** are dropped by Kata's shim — [02](docs/design/02-libraries-via-cdi.md) |
| **guest-resident device nodes** into the container | expected to be novel; **it is not.** kata-agent already applies CDI specs found inside the guest — [03](docs/design/03-guest-side-devices.md) |
| shipping an out-of-tree module in Kata's guest kernel | **DONE AND RUN.** `-g nvkvm`, module built out-of-tree, `depmod`'d, loaded via `kernel_modules` — [04](docs/design/04-guest-kernel.md), [07](docs/design/07-end-to-end.md) |
| the whole thing, end to end | **DONE AND RUN.** `nvidia-smi` and a CUDA vector-add in a container in a Kata VM; two sandboxes sharing one GPU — [07](docs/design/07-end-to-end.md) |

And one thing the research turned around completely: the project was pitched
partly on **"the VMM gets confined by the platform"**. It largely does not — for
the QEMU path Kata contributes a network namespace and a cgroup hierarchy, no
seccomp, no chroot, no uid drop, and (on cgroup v2) no device policy either.
Since most QEMU exploits give code execution in the VMM's *host userspace*, that
is the difference between "a VM boundary" and "a full host compromise". The
honest version is the reverse of the original claim: **nvkvm's architecture
already assumes an untrusted VMM — unprivileged per-guest-process isolates, and
a display broker built so the VMM never holds a display-server connection — so
on that axis nvkvm is ahead of Kata's QEMU path and is positioned to contribute
to it rather than consume it.** See
[00](docs/design/00-overview.md#what-nvkvm-brings-that-katas-qemu-path-lacks).

The organising rule: **libraries traverse nothing, device nodes traverse
everything.** CUDA userspace only ever needs to exist in the container and goes
host → container in one hop, so the Kata guest image carries none of it. Device
files must exist at every layer, because each layer's existence depends on the
one below. A host-generated CDI spec therefore has to be *split*: its `mounts`
are portable and wanted, its `deviceNodes` are host-flavoured and belong on the
host side only.

A benefit falls out of that: because CDI supplies the **host's own** driver
libraries into the container, and the host driver services every forwarded
ioctl, the container's driver userspace matches the servicing kernel driver by
construction — removing nvkvm's usual version-matching machinery entirely.

## Documents

| | |
|---|---|
| [00 — Overview and build plan](docs/design/00-overview.md) | the whole architecture, the layering model, and an ordered plan with the riskiest unknown first |
| [01 — VMM confinement](docs/design/01-vmm-confinement.md) | what Kata puts QEMU in, and what it takes to open `/dev/nvidia*` from there |
| [02 — Libraries via CDI](docs/design/02-libraries-via-cdi.md) | host driver userspace into the container; why the CDI spec must be **split** |
| [03 — Guest-side device nodes](docs/design/03-guest-side-devices.md) | the novel part; the smallest viable change and where it lands |
| [04 — The guest kernel](docs/design/04-guest-kernel.md) | how `nvkvm-guest.ko` gets into Kata's guest |
| [05 — Caveats and scope](docs/design/05-caveats-and-scope.md) | boot time, QEMU-only, and the multi-tenancy problem |
| [07 — End to end](docs/design/07-end-to-end.md) | **the run.** What worked, how to reproduce it, and the two findings that contradict 03 |

## Evidence standard

Every factual claim about Kata's or CDI's behaviour carries a URL or a repository
path. Claims that could not be verified from documentation or source are marked
**UNVERIFIED** and are accompanied by the experiment that would settle them. This
was enforced deliberately: the design turns on a handful of specifics (does the
hypervisor land in a device-restricted cgroup; does the agent have a bind-mount
fallback for devices), and a confident guess on any of them would invalidate the
plan without anyone noticing.

## Licence

Documentation only; no code is distributed here. See `nvkvm` for the licence
covering the components this design proposes to package.
