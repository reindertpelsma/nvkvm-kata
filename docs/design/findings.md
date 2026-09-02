# What the research changed

The design was started expecting the guest half to be the hard, unprecedented
part. **That was wrong, and the inversion is the main result.** This page
collects the results that changed the plan, the claim the project had to
withdraw, and the organising rule everything else follows from. It is the
narrative companion to the numbered design documents; each row points at the
document that carries the measurement.

---

## The inversion

| piece | status |
|---|---|
| VMM opening the **host** GPU device nodes | **MEASURED, and it works today by accident.** Kata builds the sandbox device cgroup itself as an allowlist that excludes `/dev/nvidia*` — and then, on cgroup v2, never installs it, so the VMM opens every NVIDIA node read-write with no configuration. Confirmed on a real RTX 3060. Treat as temporary — [01](01-vmm-confinement.md) |
| confinement of the **VMM process itself** | **MEASURED, and it is the weak point.** Kata jails Firecracker and enables Cloud Hypervisor's seccomp by default; its QEMU driver gets neither, and ships with `seccompsandbox = ""`. Since nvkvm is QEMU-only, this project is pinned to the least-confined VMM — [01 §3](01-vmm-confinement.md), [05 §2a](05-caveats-and-scope.md) |
| host NVIDIA **libraries** into the container | **DONE AND AUTOMATIC.** `docker run --gpus all` is the whole user surface. Host-injected CDI **hooks** are dropped by Kata (`kata_agent.go:1055`) — but hooks on a **guest-resident** CDI spec are executed by rustjail, which was the pivotal unknown and is now measured — [09](09-gpu-libraries-automatically.md), [02](02-libraries-via-cdi.md) |
| **guest-resident device nodes** into the container | expected to be novel; **it is not.** kata-agent already applies CDI specs found inside the guest — [03](03-guest-side-devices.md) |
| shipping an out-of-tree module in Kata's guest kernel | **DONE AND RUN.** `-g nvkvm`, module built out-of-tree, `depmod`'d, loaded via `kernel_modules` — [04](04-guest-kernel.md), [07](07-end-to-end.md) |
| the whole thing, end to end | **DONE AND RUN.** `nvidia-smi` and a CUDA vector-add in a container in a Kata VM; two sandboxes sharing one GPU — [07](07-end-to-end.md) |

**Upstream changes required for any of it: one line** — widening
`build-kernel.sh`'s `-g` vendor validation to accept a third value. No patch to
the Kata runtime, shim, agent or rustjail.

---

## The two findings from the end-to-end run

These contradict what the earlier design documents (notably
[03](03-guest-side-devices.md)) assumed, and they are the important part of
[07](07-end-to-end.md).

### 1. The container's device cgroup is not enforced inside the guest

On cgroup v2, and the **root cause is found**: `cgroups-rs 0.5.1`, which
kata-agent uses, builds no devices subsystem on v2 — its v2 hierarchy matches
controller names out of `cgroup.controllers`, and `devices` is never one of
them, because on v2 it is a BPF attachment rather than a controller.
kata-agent computes the allowlist and it is silently thrown away.

Measured with the *identical* OCI spec under two runtimes: `runc` returns
EPERM, Kata does not, and `nvidia-smi` works in a container that was never
given a GPU.

**This is the exact twin of the host-side bug in
[01 §1.6](01-vmm-confinement.md)** — so on a cgroup v2 Kata host, no device
cgroup is enforced anywhere, around the VMM or around the container. It is a
plain upstream bug with a two-line reproducer and should be reported regardless
of this project. Detail:
[07 §8.1](07-end-to-end.md#81-finding-the-containers-device-cgroup-is-not-enforced-in-the-guest).

### 2. Kata's shipped generic rootfs cannot load a kernel module

`kernel_modules = [...]` execs `/sbin/modprobe`, and `kata-containers.img`
4.1.0 ships no modprobe, no kmod and no busybox. The shipped mechanism cannot
run on the shipped image. The workaround is to prepare our own guest rootfs —
[install §4](../install.md#4-the-guest-rootfs).

### The earlier gating unknown was also measured

See [01 §1.4](01-vmm-confinement.md) — on cgroup v2 the Kata hypervisor can
open `/dev/nvidiactl` and every other NVIDIA node, unconfigured, for both
`sandbox_cgroup_only` values, on both Kata runtimes, verified against a real
GPU and driver. Not because Kata permits it, but because Kata's device policy
is silently discarded on cgroup v2 before it is ever attached.

---

## A claim this project had to withdraw

It was pitched partly on "…and the VMM gets confined by the container
platform's own machinery rather than by nvkvm's own tooling". **Measurement
removed most of that clause.** Kata jails Firecracker and enables Cloud
Hypervisor's seccomp by default; its QEMU driver gets neither and ships with
`seccompsandbox = ""`. nvkvm is QEMU-only, so this project is pinned to Kata's
least-confined VMM.

For the QEMU path Kata contributes a network namespace and a cgroup hierarchy —
no seccomp, no chroot, no uid drop, and (on cgroup v2) no device policy either.
Since most QEMU exploits give code execution in the VMM's *host userspace*,
that is the difference between "a VM boundary" and "a full host compromise".

The honest version is the reverse of the original claim: **nvkvm's architecture
already assumes an untrusted VMM** — unprivileged per-guest-process isolates,
and a display broker built so the VMM never holds a display-server connection —
so on that axis nvkvm is ahead of Kata's QEMU path and is positioned to
contribute to it rather than consume it. See
[00](00-overview.md#what-nvkvm-brings-that-katas-qemu-path-lacks) and
[06 — Confining the QEMU VMM](06-vmm-confinement-design.md), which works out
what confinement is actually available and recommends one.

---

## The organising rule

**Libraries traverse nothing, device nodes traverse everything.**

CUDA userspace only ever needs to exist in the container and goes
host → container in one hop, so the Kata guest image carries none of it. Device
files must exist at every layer, because each layer's existence depends on the
one below. A host-generated CDI spec therefore has to be *split*: its `mounts`
are portable and wanted, its `deviceNodes` are host-flavoured and belong on the
host side only. That is what
[`scripts/split-cdi-spec.sh`](../../scripts/split-cdi-spec.sh) implements, and
[02](02-libraries-via-cdi.md) derives.

A benefit falls out of that: because CDI supplies the **host's own** driver
libraries into the container, and the host driver services every forwarded
ioctl, the container's driver userspace matches the servicing kernel driver by
construction — removing nvkvm's usual version-matching machinery entirely.
