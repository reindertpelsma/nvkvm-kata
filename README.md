# nvkvm-kata

**Give a container a real NVIDIA GPU, behind a real VM boundary, without taking
the GPU away from the host.**

Today you pick two of three. Plain containers share the GPU but put your
workload one kernel bug away from the host. [Kata
Containers](https://katacontainers.io) gives each container its own VM, but its
GPU story is PCIe passthrough — the card goes to `vfio-pci`, to one sandbox, and
is gone from the host and from every other sandbox. vGPU gets you sharing and
isolation, and a licence bill.

`nvkvm-kata` is the third option: it runs
[**nvkvm**](https://github.com/reindertpelsma/nvkvm-pv) — a **sibling project,
not a replacement** — inside Kata. nvkvm gives a KVM guest driver-level NVIDIA
access with no passthrough, forwarding the driver's own ioctl interface over
virtio to unprivileged per-guest-process helpers on the host while the host
keeps using the card. **All of the GPU virtualization lives in nvkvm-pv.** What
lives here is the integration: a second Kata runtime, the scripts that build and
register it, and the evidence that an OCI workload lands on it.

## What it buys you

- **a GPU inside a Kata VM with no passthrough** — the host keeps the card,
  `vfio-pci` is never involved
- **several Kata sandboxes on one GPU, concurrently** — which Kata's existing
  VFIO path cannot do at all
- **no vGPU licence** and no datacenter SKU — consumer GeForce throughout
- **`docker run --runtime=nvkvm-kata --gpus all`, and nothing else** — no
  `volumes:`, no `LD_LIBRARY_PATH`, no `VISIBLE_CDI_DEVICES`
- **one line of change upstream** — `build-kernel.sh`'s `-g` vendor validation.
  No patch to the Kata runtime, shim, agent or rustjail.

## What it is not

- **Compute and headless graphics only.** No display path, no display broker, no
  audio, no clipboard, no input. For a desktop, that is
  [nvkvm-steamos](https://github.com/reindertpelsma/nvkvm-steamos).
- **Not a multi-tenant boundary.** On cgroup v2 the container's device cgroup is
  not enforced inside the guest, and the VMM itself is unconfined. Do not put
  untrusted tenants behind this — [known issues](#known-issues).
- **Not a fast-start sandbox.** Bringing up NVIDIA userspace costs more than
  Kata's sub-second start, ruling out FaaS. Intrinsic, and **not yet measured** —
  [05 §1](docs/design/05-caveats-and-scope.md).
- **Not vGPU.** No SR-IOV, no partitioning, no MIG; sharing is cooperative, at
  the driver interface.

## Requirements

| | |
|---|---|
| Host | Linux **x86-64**, working `/dev/kvm`, an NVIDIA GPU with the driver loaded, cgroup v2 |
| Engine | **containerd** is the baseline; Docker is optional and additionally gets a named runtime in `daemon.json` |
| Toolkit | **nvidia-container-toolkit ≥ 1.14.6**, required and deliberately [not installed for you](docs/install.md#the-toolkit-dependency-required-not-installed-not-pinned) |
| Kata | 4.1.0, installed for you if absent; a stock install is left untouched |
| Distro | Debian/Ubuntu and RHEL/Fedora verified end to end; Arch [partially](docs/install.md#which-distributions-this-works-on) |

## Quickstart

One script, source to installed, on a **fresh host**:

```bash
sudo scripts/nvkvm-kata-install.sh --install-kata --install-deps
```

It builds nvkvm's QEMU and a guest kernel, fetches Kata, registers a second
runtime, and **ends by running a CUDA workload on the runtime it just
registered** — installed-but-broken is never reported as success.
`nvkvm-kata-uninstall.sh` reverts from a manifest the install wrote.

The manual path stays first-class: [`docs/install.md`](docs/install.md) is the
same recipe by hand, in nine numbered sections that the script's stages map onto
one for one. Where the two disagree, the document is right.

## First result

```bash
docker run --runtime=nvkvm-kata --gpus all --rm \
    nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 nvidia-smi
```

That is the whole user-facing surface. The host driver's userspace arrives on
its own, `libcuda.so.1` resolves on its own, and `ldconfig` has already run
inside the container before your process starts. `--gpus 1`,
`--gpus '"device=0"'` and `--gpus '"device=GPU-<uuid>"'` select devices as under
`nvidia-container-toolkit` — including Docker's newer daemon-side CDI path,
which is recognised and undone rather than refused
([09 §8c](docs/design/09-gpu-libraries-automatically.md#8c-docker-has-a-second---gpus-path-and-it-is-now-the-default-one)).

Compose: [`examples/docker-compose.yml`](examples/docker-compose.yml). Without
Docker, the `ctr` form:
[install §6a](docs/install.md#6a-containerd-bare--one-flag-no-configuration).

## How it fits together

```
  CONTAINER (stock NVIDIA userspace)     HOST
  ─────────────────────────────          ──────────────────────────
  CUDA / PyTorch                         driver libraries
    │  ioctl(/dev/nvidia*)               ─── CDI mounts ───┐
    ▼                                                      │
  nvkvm-guest.ko ── virtio ────────►  QEMU (Kata's VMM,  ◄─┘
  ─────────────────────────────        nvkvm build)
  KATA GUEST VM                           │
                                          ▼
                                        one unprivileged isolate
                                        per guest process
                                          └─► driver ─► GPU
                                              (host still using it)
```

The rule the design turns on: **libraries traverse nothing, device nodes
traverse everything** — so a host-generated CDI spec has to be *split*. One
benefit falls out: the container gets the **host's own** driver libraries and
the host driver services every forwarded ioctl, so container userspace matches
the servicing kernel driver by construction.

[The architecture](docs/design/00-overview.md) ·
[what the research changed](docs/design/findings.md) ·
[the run that proved it](docs/design/07-end-to-end.md)

## Tested platforms

Every row is a fresh host, installed from nothing, finishing with a CUDA
vector-add that checks its own arithmetic.

| host | driver | toolkit | engine | result |
|---|---|---|---|---|
| Ubuntu 22.04, RTX 4070 Ti SUPER | 580.173.02 (open) | 1.20.0 | Docker 29.0.3 + containerd 2.1.5 | **PASS** |
| Ubuntu 22.04, same host, Docker ignored | 580.173.02 | 1.20.0 | `ctr` only | **PASS** |
| RHEL 9.5 (SELinux enforcing), RTX 3090 | 560.35.03 | 1.17.1 | Docker 27.3.1 + containerd 1.7.23 | **PASS** |
| Arch Linux | 580.173.02 | 1.20.0 | — | **partial** — builds and dependencies only |

Two GPU architectures (Ada AD103, Ampere GA102) across three machines. Arch is
partial because no Arch KVM host with a GPU was obtainable, not because anything
failed — [which stages ran](docs/install.md#which-distributions-this-works-on),
[raw logs](docs/design/evidence/10/README.md).

**Not tested at all:** multi-GPU selection, Kubernetes/CRI, cgroup v1, the
`--graphics 1` build, any non-x86-64 host.

## Known issues

- **`--gpus` is not an access boundary on cgroup v2.** A container that asks for
  no GPU can still use one — `cgroups-rs 0.5.1` builds no devices subsystem on
  v2, so kata-agent's allowlist is silently discarded. A plain upstream bug with
  a two-line reproducer:
  [findings](docs/design/findings.md#1-the-containers-device-cgroup-is-not-enforced-inside-the-guest).
- **The VMM is not confined.** Kata jails Firecracker and enables Cloud
  Hypervisor's seccomp by default; its QEMU driver gets neither and ships
  `seccompsandbox = ""` — and nvkvm is QEMU-only
  ([01 §3](docs/design/01-vmm-confinement.md),
  [06](docs/design/06-vmm-confinement-design.md)).
- **Kata's shipped generic rootfs cannot load a kernel module.**
  `kernel_modules = [...]` execs `/sbin/modprobe`, and `kata-containers.img`
  4.1.0 ships no modprobe, kmod or busybox — so we build our own
  ([install §4](docs/install.md#4-the-guest-rootfs)).
- **One host configuration enumerates zero CUDA devices.** `cuInit` returns 0,
  then `cuDeviceGetCount` returns 0. **Open**, several candidate causes
  eliminated by measurement: [cuda-zero-devices](docs/cuda-zero-devices.md).

All of them, plus `NVIDIA_DRIVER_CAPABILITIES`, `docker run -i`, prebuilt
artifacts and the rest of what this does *not* do:
[install](docs/install.md#what-this-installer-does-not-do).

## Documentation

| | |
|---|---|
| [Installing](docs/install.md) | the installer and the manual path; what it touches, runtime selection, uninstall, troubleshooting |
| [What the research changed](docs/design/findings.md) | the inversion, the two findings, the withdrawn claim, the organising rule |
| [07 — End to end](docs/design/07-end-to-end.md) | **the run** — what worked, and the commands that reproduce it |
| [09 — `--gpus all`](docs/design/09-gpu-libraries-automatically.md) | how the driver libraries get in with no help from the user |
| [`scripts/`](scripts/README.md) | every script, its `--self-test`, and the document it implements |

Everything else, and the evidence standard it is all held to:
[`docs/README.md`](docs/README.md).

## Status

Experimental — a research artifact, not a supported product.

On 2026-08-27 a CUDA vector-add executed inside an OCI container, inside a Kata
VM, on an RTX 4070 Ti SUPER, with every ioctl forwarded by nvkvm to the host
driver and the host keeping the card throughout. Two Kata sandboxes then shared
that one GPU. Since reproduced on a second architecture (Ampere) and on a third
machine from a cold host.

That is the extent of it: one GPU, one architecture and one driver at a time,
never under Kubernetes, and with one open compute defect. Reports from
configurations this repository has not exercised are wanted — a **failure** is
worth more than a success.

## Credits

The GPU virtualization is [**nvkvm**](https://github.com/reindertpelsma/nvkvm-pv),
packaged here rather than reimplemented — its `ARCHITECTURE.md` has the
forwarding path, its `CREDITS` the upstream work it derives from. The sandbox is
[Kata Containers](https://katacontainers.io), used as shipped apart from that
one-line build change; the libraries arrive through NVIDIA's own
`nvidia-container-toolkit` and CDI.

## Licence

The design documents are the bulk of this repository; `scripts/` carries the
installer, the uninstaller, the QEMU shim and the CUDA proof program. See
[nvkvm-pv](https://github.com/reindertpelsma/nvkvm-pv) for the licence covering
the components packaged here.
