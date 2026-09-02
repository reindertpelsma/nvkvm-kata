# nvkvm-kata documentation

Start at [`README.md`](../README.md) in the repository root for what this is and
how to install it. Everything here is either a procedure, a design document
carrying the reasoning and the measurements behind one decision, or raw
evidence.

The GPU virtualization itself is **not** documented here — it lives in
[nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv), whose `ARCHITECTURE.md`
explains the forwarding path, the isolate model and the guest kernel module.
This repository documents only what it takes to run that stack inside Kata
Containers.

## How to

| | |
|---|---|
| [Installing](install.md) | **the installer, and the manual path it is a convenience over.** Nine numbered steps, what it does to your host, the per-container selection mechanism, uninstall, troubleshooting, and what it does *not* do |
| [`scripts/`](../scripts/README.md) | every script, what it does, its `--self-test`, and the design document it implements |
| [`examples/docker-compose.yml`](../examples/docker-compose.yml) | the compose spelling, plus the two control services you want when something breaks |

## Design

Read [00](design/00-overview.md) first for the architecture, then
[findings](design/findings.md) for what the research changed about it.

| | |
|---|---|
| [What the research changed](design/findings.md) | the inversion, the two findings from the end-to-end run, the claim that had to be withdrawn, and the organising rule |
| [00 — Overview and build plan](design/00-overview.md) | the whole architecture, the layering model, and an ordered plan with the riskiest unknown first |
| [01 — VMM confinement](design/01-vmm-confinement.md) | what Kata puts QEMU in, and what it takes to open `/dev/nvidia*` from there |
| [02 — Libraries via CDI](design/02-libraries-via-cdi.md) | host driver userspace into the container; why the CDI spec must be **split** |
| [03 — Guest-side device nodes](design/03-guest-side-devices.md) | the part expected to be novel; the smallest viable change and where it lands |
| [04 — The guest kernel](design/04-guest-kernel.md) | how `nvkvm-guest.ko` gets into Kata's guest |
| [05 — Caveats and scope](design/05-caveats-and-scope.md) | boot time, QEMU-only, and the multi-tenancy problem |
| [06 — Confining the QEMU VMM](design/06-vmm-confinement-design.md) | the options for confining the VMM, the capability analysis, and a staged recommendation |
| [07 — End to end](design/07-end-to-end.md) | **the run.** What worked, how to reproduce it, and the two findings that contradict 03 |
| [09 — `--gpus all`, and nothing else](design/09-gpu-libraries-automatically.md) | how the driver libraries get in with no help from the user; **kata-agent does run guest-side CDI hooks**; what `--gpus` transfers and what it cannot |

## Open defects

| | |
|---|---|
| [CUDA enumerates zero devices](cuda-zero-devices.md) | **OPEN.** NVML sees the GPU, `cuInit` succeeds, `cuDeviceGetCount` returns 0. Several causes ruled out with measurements, including the one that looked most likely |

## Evidence

Raw logs, kept because the claims above are only as good as them.

| | |
|---|---|
| [`evidence/07/`](design/evidence/07/) | the end-to-end run: the five rungs, the two-sandboxes-one-GPU log, the device-cgroup comparison against `runc` |
| [`evidence/08/`](design/evidence/08/README.md) | the installer: cold host → installed → uninstall → reinstall → a third run with zero changes, plus the physical-PC install log |
| [`evidence/09/`](design/evidence/09/README.md) | `--gpus all` and nothing else: the guest-side CDI hook measurement, the ldcache ablation, the injector |
| [`evidence/10/`](design/evidence/10/README.md) | fresh hosts across three distro families, the minimum-toolkit determination, and every README command executed verbatim |
| [`evidence/11/`](design/evidence/11/README.md) | both of Docker's `--gpus` paths, the three defects a second host found, idempotence and uninstall/reinstall |

## Evidence standard

Every factual claim about Kata's or CDI's behaviour carries a URL or a
repository path. Claims that could not be verified from documentation or source
are marked **UNVERIFIED** and are accompanied by the experiment that would
settle them. This was enforced deliberately: the design turns on a handful of
specifics (does the hypervisor land in a device-restricted cgroup; does the
agent have a bind-mount fallback for devices), and a confident guess on any of
them would invalidate the plan without anyone noticing.
