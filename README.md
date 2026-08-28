# nvkvm-kata

**Give a container a real NVIDIA GPU, behind a real VM boundary, without taking
the GPU away from the host.**

Today you get to pick two of three. Plain containers share the GPU but put your
workload one kernel bug away from the host. [Kata
Containers](https://katacontainers.io) puts each container in its own VM, but its
GPU story is PCIe passthrough — the card is bound to `vfio-pci`, handed to one
sandbox, and gone from the host and from every other sandbox. vGPU gets you
sharing and isolation, and a licence bill.

`nvkvm-kata` is the third option.
[nvkvm](https://github.com/reindertpelsma/nvkvm-pv) gives a KVM guest
driver-level NVIDIA access with no passthrough: a guest kernel module forwards
the NVIDIA driver's own ioctl interface over virtio to unprivileged
per-guest-process helper processes on the host, which run the real ioctls against
the real driver — while the host keeps using the card. Guest userspace is stock
NVIDIA, and it measures at roughly host parity for CUDA, PyTorch, LLM inference
and Vulkan compute. This repository runs that stack **inside Kata**, so an
OCI or Kubernetes workload gets a GPU behind a VM boundary, with no passthrough,
no vGPU licence, and no loss of the card to the host.

**Scope is deliberately narrow: compute and headless graphics only.** No display
path, no display broker, no audio, no clipboard, no input. If you want a desktop,
that is [nvkvm-steamos](https://github.com/reindertpelsma/nvkvm-steamos).

## Status: it runs

On 2026-08-27 a CUDA vector-add executed inside an OCI container, inside a Kata
Containers VM, on an NVIDIA RTX 4070 Ti SUPER, with every ioctl forwarded by
nvkvm to the host driver — and the host keeping the card the whole time. Two Kata
sandboxes then shared that one GPU concurrently, which is the thing Kata's
existing VFIO path cannot do at all. It has since been reproduced on a second
architecture (Ampere) and on a third machine from a cold host.

**Upstream changes required for any of it: one line** — widening
`build-kernel.sh`'s `-g` vendor validation to accept a third value. No patch to
the Kata runtime, shim, agent or rustjail.

**Read [07 — End to end](docs/design/07-end-to-end.md)**: it has the commands
that reproduce it, and two measured findings that change what the earlier design
docs claim.

## Install it

One script, source to installed, on a **fresh host**:

```bash
sudo scripts/nvkvm-kata-install.sh --install-kata --install-deps
```

It builds nvkvm's QEMU and a guest kernel, fetches Kata, registers a second
runtime, and **ends by running a CUDA workload on the runtime it just
registered** — installed-but-broken is never reported as success.
`scripts/nvkvm-kata-uninstall.sh` puts the host back from a manifest written
during the install.

**Requirements.** A GPU host with `/dev/kvm`, the NVIDIA driver loaded,
**containerd**, and **nvidia-container-toolkit** (≥ 1.14.6). The toolkit is
required and deliberately *not* installed for you — setting up NVIDIA's package
repository on your host is your decision, and preflight names the exact command
for your distribution if it is missing. Everything else `--install-deps` handles,
per distribution.

**Docker is not required.** containerd is the baseline, because a Kubernetes
node or a podman host has containerd and no Docker — the install and its proof
both run through `ctr` when Docker is absent. Docker, when present, additionally
gets a named runtime in `daemon.json`, which is what makes the one-liner below
work.

## Use it

```bash
docker run --runtime=nvkvm-kata --gpus all --rm \
    nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 nvidia-smi
```

That is the whole user-facing surface. **No `volumes:`, no `LD_LIBRARY_PATH`, no
`VISIBLE_CDI_DEVICES`.** The host driver's userspace arrives on its own,
`libcuda.so.1` resolves on its own, and `ldconfig` has already run inside the
container before your process starts. `--gpus 1`, `--gpus '"device=0"'` and
`--gpus '"device=GPU-<uuid>"'` select devices exactly as they do under
`nvidia-container-toolkit`.

Docker has **two** ways of answering `--gpus`, and both end up here. On a
current host, `nvidia-container-toolkit` enables `nvidia-cdi-refresh` by
default, and the *daemon* resolves `--gpus all` through CDI before a runtime is
chosen — handing the shim host device nodes and a bind mount of a UNIX socket
that cannot cross virtio-fs. That is the default configuration of a stock
Ubuntu + NVIDIA box, and it is recognised and undone rather than refused:
[09 §8c](docs/design/09-gpu-libraries-automatically.md#8c-docker-has-a-second---gpus-path-and-it-is-now-the-default-one),
tested in both configurations in
[evidence/11](docs/design/evidence/11/README.md).

Compose says the same thing:

```yaml
services:
  cuda:
    image: nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04
    runtime: nvkvm-kata          # <- the only nvkvm-specific line
    command: nvidia-smi
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

Without Docker, the same thing through containerd:

```bash
ctr run --rm --runtime io.containerd.nvkvm-kata.v2 \
    --runtime-config-path /etc/kata-containers/configuration-nvkvm.toml \
    --env NVIDIA_VISIBLE_DEVICES=all \
    docker.io/library/ubuntu:24.04 gpu0 nvidia-smi
```

How that works — and the measurement it turns on, that kata-agent executes CDI
hooks arriving from *inside* the guest — is
[09](docs/design/09-gpu-libraries-automatically.md).

### Where it has actually been installed

Every row below is a fresh rented host, installed from nothing and finishing
with a CUDA vector-add that checks its own arithmetic.

| host | driver | toolkit | engine | result |
|---|---|---|---|---|
| Ubuntu 22.04, RTX 4070 Ti SUPER | 580.173.02 (open) | 1.20.0 | Docker 29.0.3 + containerd 2.1.5 | **PASS** |
| Ubuntu 22.04, same host, Docker ignored | 580.173.02 | 1.20.0 | `ctr` only | **PASS** |
| RHEL 9.5 (SELinux enforcing), RTX 3090 | 560.35.03 | 1.17.1 | Docker 27.3.1 + containerd 1.7.23 | **PASS** |
| Arch Linux | 580.173.02 | 1.20.0 | — | **partial**: builds and dependencies only, see below |

**Arch is only partly tested, and the reason is not a defect.** vast.ai
publishes no Arch KVM image, so there was no Arch *host* with a GPU and
`/dev/kvm` to install on. What was run, in an Arch container on a GPU host:
distro detection, the whole `pacman` dependency path, the Kata install, the
nvkvm QEMU build and the guest kernel + `nvkvm-guest.ko` build — all pass. The
guest-rootfs, runtime-registration and verify stages were **not** run on Arch;
they are the distro-neutral stages, but that is an argument, not a measurement.
Details in [install §0](docs/install.md#0-preflight).

**Not tested at all:** multi-GPU selection, Kubernetes/CRI, cgroup v1, and any
non-x86-64 host.

### How the runtime is selected, and how to undo it

A **second Kata `configuration.toml` plus a `ConfigPath` runtime option** — a
separate containerd runtime type `io.containerd.nvkvm-kata.v2`, and (if Docker
is present) a named runtime in `daemon.json`. The stock Kata configuration, the
stock shim and `runc` are untouched and keep working; a container that does not
name `nvkvm-kata` cannot reach any of this. Note that `KATA_CONF_FILE` — the
mechanism kata-deploy uses and the one you will reach for first — **no longer
works** for a second configuration on Kata 4.1.0; see
[install §5d](docs/install.md#5d-the-containerd-shim-wrapper--half-one-of-the-selection-mechanism).

**The manual path stays first-class.** [`docs/install.md`](docs/install.md) is
the recipe by hand, in nine numbered sections; the script's stages *are* those
sections and name them in their own output. If the two ever disagree, the
document is right.

## Limits worth knowing

Named here rather than discovered later. None of them are new to this release;
all are measured.

1. **`--gpus` is not an access boundary on cgroup v2.** A container that asks
   for no GPU can still use one. See finding 1 below.
2. **`NVIDIA_DRIVER_CAPABILITIES` does not filter the library set.** Device
   selection transfers; capabilities do not — because NVIDIA's own CDI mode is
   capability-complete and exposes no capability input
   ([09 §7](docs/design/09-gpu-libraries-automatically.md#7-capabilities-the-one-thing-that-does-not-transfer)).
3. **The VMM is not confined.** Kata's QEMU driver gets no seccomp and no
   jail, and nvkvm is QEMU-only —
   [01 §3](docs/design/01-vmm-confinement.md), [06](docs/design/06-vmm-confinement-design.md).

**The two findings, because they are the important part:**

1. **The container's device cgroup is not enforced inside the guest** on
   cgroup v2, and the **root cause is found**: `cgroups-rs 0.5.1`, which
   kata-agent uses, builds no devices subsystem on v2 (its v2 hierarchy matches
   controller names out of `cgroup.controllers`, and `devices` is never one —
   on v2 it is a BPF attachment). kata-agent computes the allowlist and it is
   silently thrown away. Measured with the *identical* OCI spec under two
   runtimes: `runc` returns EPERM, Kata does not, and `nvidia-smi` works in a
   container that was never given a GPU. **This is the exact twin of the
   host-side bug in [01 §1.6](docs/design/01-vmm-confinement.md)** — so on a
   cgroup v2 Kata host, no device cgroup is enforced anywhere, around the VMM
   or around the container. It is a plain upstream bug with a two-line
   reproducer and should be reported regardless of this project.
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

## A claim this project had to withdraw

It was pitched partly on "…and the VMM gets confined by the container platform's
own machinery rather than by nvkvm's own tooling". **Measurement removed most of
that clause.** Kata jails Firecracker and enables Cloud Hypervisor's seccomp by
default; its QEMU driver gets neither and ships with `seccompsandbox = ""`. nvkvm
is QEMU-only, so this project is pinned to Kata's least-confined VMM.

The honest version is the reverse of the original claim: **nvkvm's architecture
already assumes an untrusted VMM** — unprivileged per-guest-process isolates, and
a display broker built so the VMM never holds a display-server connection — so on
that axis nvkvm is ahead of Kata's QEMU path and is positioned to contribute to
it rather than consume it. See
[00](docs/design/00-overview.md#what-nvkvm-brings-that-katas-qemu-path-lacks) and
[06 — Confining the QEMU VMM](docs/design/06-vmm-confinement-design.md), which
works out what confinement is actually available and recommends one.

## What the research changed

The design was started expecting the guest half to be the hard, unprecedented
part. **That was wrong, and the inversion is the main result.**

| piece | status |
|---|---|
| VMM opening the **host** GPU device nodes | **MEASURED, and it works today by accident.** Kata builds the sandbox device cgroup itself as an allowlist that excludes `/dev/nvidia*` — and then, on cgroup v2, never installs it, so the VMM opens every NVIDIA node read-write with no configuration. Confirmed on a real RTX 3060. Treat as temporary — [01](docs/design/01-vmm-confinement.md) |
| confinement of the **VMM process itself** | **MEASURED, and it is the weak point.** Kata jails Firecracker and enables Cloud Hypervisor's seccomp by default; its QEMU driver gets neither, and ships with `seccompsandbox = ""`. Since nvkvm is QEMU-only, this project is pinned to the least-confined VMM — [01 §3](docs/design/01-vmm-confinement.md), [05 §2a](docs/design/05-caveats-and-scope.md) |
| host NVIDIA **libraries** into the container | **DONE AND AUTOMATIC.** `docker run --gpus all` is the whole user surface. Host-injected CDI **hooks** are dropped by Kata (`kata_agent.go:1055`) — but hooks on a **guest-resident** CDI spec are executed by rustjail, which was the pivotal unknown and is now measured — [09](docs/design/09-gpu-libraries-automatically.md), [02](docs/design/02-libraries-via-cdi.md) |
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
| [06 — Confining the QEMU VMM](docs/design/06-vmm-confinement-design.md) | the options for confining the VMM, the capability analysis, and a staged recommendation |
| [07 — End to end](docs/design/07-end-to-end.md) | **the run.** What worked, how to reproduce it, and the two findings that contradict 03 |
| [09 — `--gpus all`, and nothing else](docs/design/09-gpu-libraries-automatically.md) | how the driver libraries get in with no help from the user; **kata-agent does run guest-side CDI hooks**; what `--gpus` transfers and what it cannot |
| [Installing](docs/install.md) | **the installer, and the manual path it is a convenience over.** Nine numbered steps, the per-container selection mechanism, uninstall, and what it does *not* do |

## Evidence standard

Every factual claim about Kata's or CDI's behaviour carries a URL or a repository
path. Claims that could not be verified from documentation or source are marked
**UNVERIFIED** and are accompanied by the experiment that would settle them. This
was enforced deliberately: the design turns on a handful of specifics (does the
hypervisor land in a device-restricted cgroup; does the agent have a bind-mount
fallback for devices), and a confident guess on any of them would invalidate the
plan without anyone noticing.

## Licence

The design documents are the bulk of this repository; `scripts/` also carries the
installer, the uninstaller, the QEMU shim and the CUDA proof program. See
[nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv) for the licence covering
the components this repository packages.
