# 07 — End to end: a CUDA workload in a Kata pod, through nvkvm

**Status: RUN. All five rungs reached, on real hardware, 2026-08-27.**
A vector-add executed on an NVIDIA RTX 4070 Ti SUPER from inside an OCI
container, inside a Kata Containers VM, with every NVIDIA ioctl forwarded by
nvkvm to the host driver, and the host keeping the card the whole time. No
VFIO, no passthrough, no unbind.

This document is the record: what worked, the commands that reproduce it, the
things that did not work and why, and — the part that matters most — **the two
measured findings that are worse than the design docs assumed.**

Everything marked MEASURED was run on the host in [§9](#9-the-test-host).
Everything else is marked UNVERIFIED with the experiment that settles it.

---

## 0. Result, in one table

| rung | claim | verdict | evidence |
|---|---|---|---|
| 1 | Kata pod boots with nvkvm's QEMU at `hypervisor.path` | **PASS** | [§3](#3-rung-1--the-pod-boots-on-nvkvms-qemu) |
| 2 | the virtio-nvgpu device appears in the guest and the module loads | **PASS** | [§4](#4-rung-2--the-device-appears-and-the-module-loads) |
| 3 | `/dev/nvidia*` exist inside the pod's container | **PASS** | [§5](#5-rung-3--dev-nvidia-inside-the-container) |
| 4 | `nvidia-smi` runs inside the container | **PASS** | [§6](#6-rung-4--nvidia-smi) |
| 5 | a real CUDA workload runs | **PASS** — 1,048,576 elements, 0 mismatches | [§7](#7-rung-5--a-real-cuda-workload) |

Two Kata sandboxes ran CUDA on the same card concurrently, ten successful
workloads between them, with the host's `nvidia` driver still bound to
`0000:00:07.0` throughout — the claim [00](00-overview.md) leads with, and the
thing Kata's VFIO path cannot do. [§7](#two-sandboxes-one-gpu-host-keeps-the-card)

Sandbox start-to-exit for a trivial container on this configuration: **3.75 s,
3.90 s, 3.82 s** (MEASURED, three runs). [05 §"boot time turns out to be tens of
seconds"](05-caveats-and-scope.md) does not bite here.

**Two findings that should change how the earlier docs read:**

1. **The container's device cgroup is not enforced in the guest, on cgroup v2.**
   [03](03-guest-side-devices.md) calls that cgroup "the one that decides, and
   the one that fails silently". Measured against the *identical* OCI spec under
   two runtimes: `runc` denies, Kata does not. So CDI's `linux.resources.devices`
   allow rule — the thing [03](03-guest-side-devices.md) says comes "for free"
   and does the gating — is decorative on this path. What CDI actually delivers
   is the *nodes*. [§8.1](#81-finding-the-containers-device-cgroup-is-not-enforced-in-the-guest)
2. **Kata's shipped generic rootfs cannot load a kernel module at all.**
   `kernel_modules = [...]` shells out to `/sbin/modprobe`
   (`src/agent/src/rpc.rs:124`), and `kata-containers.img` (4.1.0) ships no
   modprobe, no kmod and no busybox. The shipped mechanism cannot run on the
   shipped image. [§8.2](#82-finding-there-is-no-modprobe-in-the-shipped-rootfs)

And one correction *in Kata's favour*: [04](04-guest-kernel.md)'s headline trap
("**neither `build-kernel.sh` nor `rootfs.sh` runs `depmod`**") is true of the
generic path, but upstream **already solved it on the NVIDIA path** —
`tools/osbuilder/rootfs-builder/nvidia/nvidia_rootfs.sh:709-716` runs `depmod -b`
per kernel version, and `:837-843` installs kmod plus absolute-target applet
symlinks. That file is the precedent to copy, not a gap to fill.
[§8.3](#83-correction-to-04-upstreams-nvidia-rootfs-already-runs-depmod)

---

## 1. What had to be built

Four artifacts, all in this repository, all exercised end to end:

| artifact | what it does |
|---|---|
| [`kata/fragments/gpu/nvkvm.x86_64.conf.in`](../../kata/fragments/gpu/nvkvm.x86_64.conf.in) | guest-kernel config fragment: `CONFIG_MODULES`, `CONFIG_MODULE_UNLOAD`, `CONFIG_LOCALVERSION`. Three lines. |
| [`scripts/build-guest-kernel.sh`](../../scripts/build-guest-kernel.sh) | drives Kata's `build-kernel.sh` with `-g nvkvm`, builds `nvkvm-guest.ko` out-of-tree against it, **runs `depmod -b`**, and asserts `modules.dep` names the module. |
| [`scripts/prepare-guest-rootfs.sh`](../../scripts/prepare-guest-rootfs.sh) | installs kmod (there is none) and the guest-side CDI generator into a shipped Kata rootfs image. |
| [`scripts/inject-guest-modules.sh`](../../scripts/inject-guest-modules.sh) | puts the `.ko` + a valid `modules.dep` into that image (or an initrd) without running osbuilder. |
| [`scripts/nvkvm-qemu-shim.sh`](../../scripts/nvkvm-qemu-shim.sh) | what goes at `hypervisor.path`; appends `-device virtio-nvgpu-pci` and `exec()`s the real QEMU. |
| [`scripts/e2e/vecadd.c`](../../scripts/e2e/vecadd.c) | the rung-5 proof: driver-API + embedded-PTX vector add, no CUDA toolkit needed. |

**Upstream changes required to make it work: one line.** `build-kernel.sh`
validates `-g` against `{intel, nvidia}` at
`tools/packaging/kernel/build-kernel.sh:652`; accepting `nvkvm` as a third
vendor is the entire delta, and `build-guest-kernel.sh` applies it with a
guarded `sed` (which is also a check that upstream's text has not moved). No
patch to the runtime, the shim, the agent or rustjail was needed for any rung.

---

## 2. The shape of the working configuration

```
/etc/kata-containers/configuration.toml
  [hypervisor.qemu]
  path   = "/usr/local/bin/nvkvm-qemu-shim"        # <- the shim, not QEMU
  kernel = "/root/gk/vmlinuz-6.18.35-nvkvm"        # <- built by build-guest-kernel.sh
  image  = "/opt/kata/share/kata-containers/kata-nvkvm.image"
  kernel_params = "... agent.visible_cdi_devices=true"
  [agent.kata]
  kernel_modules = ["nvkvm-guest"]

containerd environment (systemd drop-in):
  NVKVM_EXTRA_ARGS=-device virtio-nvgpu-pci-non-transitional,id=nvkvm0

per container:
  VISIBLE_CDI_DEVICES=nvidia.com/gpu=0
  LD_LIBRARY_PATH=/usr/local/nvidia/lib      (host driver libs, bind-mounted)
```

Two of those deserve a note.

**`path` is not checked against `valid_hypervisor_paths`.** That list is
consulted only for the `io.katacontainers.config.hypervisor.path` *annotation*
— `HypervisorPathList` is documented as "the list of hypervisor paths names
allowed in annotations" (`src/runtime/virtcontainers/hypervisor.go:590`), parsed
at `src/runtime/pkg/katautils/config.go:114`. Setting `path` directly in
`configuration.toml` needs no allowlist entry. We add the shim to the list
anyway, so per-pod selection works later.

**`NVKVM_EXTRA_ARGS` is passed through containerd's environment**, because the
shim is exec'd by `containerd-shim-kata-v2`, which inherits containerd's
environment. A systemd drop-in on `containerd.service` is the whole mechanism.

### Why a shim at all, and why `exec` is safe

Kata generates the entire QEMU command line in govmm and exposes no key for an
arbitrary `-device`. The shim appends one and `exec()`s. That is safe for three
specific reasons, all of which were verified rather than assumed:

- **pid is preserved**, so Kata's cgroup placement, its wait, and its SIGKILL
  all still land on the right process. MEASURED: with the shim at
  `hypervisor.path`, `readlink /proc/<vmm-pid>/exe` is
  `/opt/qemu-nvkvm/bin/qemu-system-x86_64` and `/proc/<pid>/cgroup` is
  `0::/default/kata_<sandbox-id>` — the sandbox cgroup, exactly as without the
  shim.
- **fds are preserved.** Kata passes the QMP socket as `-qmp unix:fd=3` via
  `cmd.ExtraFiles`; a shim that closed it would kill the VM instantly. It does
  not.
- **QEMU's data directory still resolves**, because QEMU finds it from
  `/proc/self/exe`, which after `exec` is the real binary.

The one place Kata runs the hypervisor binary for something other than booting a
VM is `q.config.HypervisorPath --version` in `dumpGuestMemory`
(`src/runtime/virtcontainers/qemu.go:2151`), which is a debug path and is
harmless here.

This is the same shape [06 §0](06-vmm-confinement-design.md) recommends for
confinement. **One shim can serve both**: put the `unshare`/`setpriv` in front
of the `exec` in [`nvkvm-qemu-shim.sh`](../../scripts/nvkvm-qemu-shim.sh).
UNVERIFIED: not combined in this run.

---

## 3. Rung 1 — the pod boots on nvkvm's QEMU

Three runs, differing in one variable each, so the result is attributable.

| run | `hypervisor.path` | extra args | guest PCI devices | boots |
|---|---|---|---|---|
| **A** control | `/opt/kata/bin/qemu-system-x86_64` (QEMU **11.0.1**, kata-static) | — | 10 | yes |
| **B** | shim → `/opt/qemu-nvkvm/bin/qemu-system-x86_64` (QEMU **11.1.1**) | `-msg timestamp=off` | 10, **identical set** | yes |
| **C** | same | `-device virtio-nvgpu-pci-non-transitional,id=nvkvm0` | **11** | yes |

B is the run that matters: swapping Kata's QEMU for nvkvm's, with no nvkvm
device attached, changes nothing at all. The binary swap is not where any risk
lives. Kata 4.1.0 pins QEMU `v11.0.1` (`versions.yaml`), nvkvm is on 11.1.1 —
one stable point apart, which is why the ~40-argument Kata command line needed
no adjustment.

The delta in C, from the guest's own `/sys/bus/pci/devices`:

```
  0000:00:07.0 0x1af4:0x1072       <- virtio vendor 1af4, device 0x1072 = 0x1040+50
```

Full evidence: [`evidence/07/rung1-controls.log`](evidence/07/rung1-controls.log).

---

## 4. Rung 2 — the device appears and the module loads

Guest kernel built by [`build-guest-kernel.sh`](../../scripts/build-guest-kernel.sh):

```bash
scripts/build-guest-kernel.sh \
    --kata-src /root/kata-containers \
    --nvkvm-src /root/nvkvm-pv \
    --out /root/gk --graphics 0
```

**2 minutes 10 seconds** on 42 cores, from an unpacked kernel tarball to a
`vmlinuz`, a depmod'd module tree and a verified `modules.dep`. Result:
`6.18.35-nvkvm`, `nvkvm-guest.ko` with `vermagic: 6.18.35-nvkvm SMP mod_unload`.

`--graphics 0` (compute-only, `NVKVM_GRAPHICS=0`) is what makes the config
fragment three lines instead of a `CONFIG_DRM` dependency hunt — the choice
[04](04-guest-kernel.md) recommends for a first milestone, and it was the right
one. **UNVERIFIED: the graphics build.** `kata/fragments/gpu/nvkvm-graphics.x86_64.conf`
exists but was never built or booted; settle it by rebuilding with
`--graphics 1` and checking `/dev/dri/renderD128` appears.

Loaded with the shipped mechanism — `kernel_modules = ["nvkvm-guest"]`, which
kata-agent turns into `/sbin/modprobe -v nvkvm-guest` at `create_sandbox`
(`src/agent/src/rpc.rs:1549-1550`, `:2566-2582`). Inside a container in that
sandbox:

```
uname: 6.18.35-nvkvm
--- /proc/devices ---
195 nvidia
195 nvidiactl
243 nvidia-uvm
```

Three char-device majors registered by `nvkvm-guest.ko`: 195 for `nvidia`/
`nvidiactl` (the number NVIDIA's userspace hardcodes, `nvkvm_main.c:91-98`), and
**243** — dynamically allocated — for UVM. Hold on to 243; §5 is about it.

Full evidence: [`evidence/07/rung2.log`](evidence/07/rung2.log).

---

## 5. Rung 3 — `/dev/nvidia*` inside the container

Requested with **one environment variable and no upstream change**, exactly as
[03 §(a)](03-guest-side-devices.md) predicted:

```bash
ctr run --rm --runtime io.containerd.kata.v2 \
    --mount type=bind,src=$LIBS,dst=/usr/local/nvidia/lib,options=rbind:ro \
    --env VISIBLE_CDI_DEVICES=nvidia.com/gpu=0 \
    --env LD_LIBRARY_PATH=/usr/local/nvidia/lib \
    docker.io/library/ubuntu:24.04 gpu0 /bin/sh -c 'ls -l /dev/nvidia*'
```
```
crw-rw-rw- 1 root root 243,   0  /dev/nvidia-uvm
crw-rw-rw- 1 root root 243,   1  /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195,   0  /dev/nvidia0
crw-rw-rw- 1 root root 195, 255  /dev/nvidiactl
```

Mode 0666 — nvkvm's `struct class` devnode callback, arriving intact through
CDI and rustjail's mknod.

### The number that proves the guest-side generation was necessary

```
host      /dev/nvidia-uvm : major 236
container /dev/nvidia-uvm : major 243
```

MEASURED, same machine, same moment. This is precisely the case
[02](02-libraries-via-cdi.md) and [03](03-guest-side-devices.md) argue about: a
host-generated CDI spec would have injected 236, and the container would have
got a device node pointing at nothing. Because the spec is generated **in the
guest**, against the guest's own nodes, the CDI library's `Lstat()`-based
major/minor fill-in produces 243 and the node works. The layering rule earns its
keep here and nowhere more clearly.

### Where the guest spec comes from — and the trap that shapes it

kata-agent reads `/var/run/cdi` **in the guest**
(`src/agent/src/device/mod.rs:431`). Anything baked into the rootfs image at
that path is invisible, because the agent mounts a fresh tmpfs on `/run` during
init (`src/agent/src/mount.rs:62`). The spec must therefore be *generated after
boot*. Upstream's answer is NVRC; ours is a `modprobe.d` `install` directive:

```
install nvkvm-guest /sbin/modprobe --ignore-install nvkvm-guest $CMDLINE_OPTS && /usr/local/bin/nvkvm-guest-cdi-gen
```

kmod runs that instead of a plain load, so the generator fires exactly when the
agent modprobes — at `create_sandbox`, before the first `create_container` calls
`handle_cdi_devices`, and `handle_cdi_devices` retries for `cdi_timeout` (100 s
default) anyway. The ordering [04](04-guest-kernel.md) wanted, obtained from a
standard kmod feature rather than a new init system.

The generator writes `deviceNodes` **with no major/minor**, deliberately, and no
`mounts` at all. That sidesteps [03](03-guest-side-devices.md)'s open question
about what `nvidia-ctk cdi generate` does in a guest with device nodes but no
driver libraries: we never run it there. **That question is still UNVERIFIED**
and now optional — a production build wanting the toolkit's discovery logic
would still have to answer it.

Full evidence: [`evidence/07/rung345.log`](evidence/07/rung345.log).

---

## 6. Rung 4 — `nvidia-smi`

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 575.51.03              Driver Version: 575.51.03      CUDA Version: 12.9     |
|   0  NVIDIA GeForce RTX 4070 ...    Off |   00000000:00:07.0 Off |                  N/A |
|  0%   31C    P8             17W /  285W |       2MiB /  16376MiB |      0%      Default |
| Processes:                                                                              |
|    0   N/A  N/A               1  M+C+G   /usr/local/nvidia/bin/nvidia-smi          0MiB |
+-----------------------------------------------------------------------------------------+
```

Note the process list: **PID 1**, the container's own pid-namespace view. The
namespace-correct enumeration nvkvm documents (`pid_vnr()` over the guest
module's session table) survives the extra Kata layer.

The libraries reached the container as an ordinary OCI bind mount over
virtio-fs, with `LD_LIBRARY_PATH` from the container's env — the substitution
[02 §D](02-libraries-via-cdi.md) prescribes for the `update-ldcache` hook Kata
drops (kata#11169). **The versioned symlink chain survives virtio-fs**:
`libcuda.so.1 -> libcuda.so.575.51.03` resolved and `dlopen`ed inside the guest.
That was flagged UNVERIFIED in [02 §C.1](02-libraries-via-cdi.md); it is now
**VERIFIED** — with the caveat that the links were created in the bind-mounted
directory on the host, not generated in the container.

---

## 7. Rung 5 — a real CUDA workload

[`scripts/e2e/vecadd.c`](../../scripts/e2e/vecadd.c), driver API via
`dlopen`, kernel supplied as embedded PTX so no CUDA toolkit is needed anywhere:

```
devices: 1
device 0: NVIDIA GeForce RTX 4070 Ti SUPER
elements: 1048576  mismatches: 0  sample: c[7]=21.0 (want 21.0)
VECADD OK
```

It checks the arithmetic, because "it ran" and "it computed" are different
claims. The path exercised: `cuInit` → `cuDeviceGet` → `cuCtxCreate` →
`cuMemAlloc` → `cuMemcpyHtoD` → `cuModuleLoadData` (**the PTX JIT, running in
the container against the host's `libnvidia-ptxjitcompiler`**) →
`cuLaunchKernel` → `cuCtxSynchronize` → `cuMemcpyDtoH`.

Controls, in order, all MEASURED:

1. same binary on the bare-metal host → `VECADD OK`
2. same binary on the host with **only** the bundle on `LD_LIBRARY_PATH` → `VECADD OK`
3. same binary in the Kata container through nvkvm → `VECADD OK`

so a failure at (3) would have been attributable, and a pass is not an artifact
of the host's system libraries.

### A trap worth recording, because it costs an hour

`dlsym("cuMemAlloc")` returns the **pre-CUDA-3.2** entry point. Called after a
`cuCtxCreate_v2` context it fails with `CUDA_ERROR_INVALID_CONTEXT` (201) and
nothing suggests the symbol is the problem. Anything resolving driver-API
symbols by name rather than through `cuda.h`'s `#define` shims must ask for
`cuMemAlloc_v2`, `cuMemFree_v2`, `cuMemcpyHtoD_v2`, `cuMemcpyDtoH_v2`,
`cuCtxCreate_v2` explicitly. Found on bare metal before nvkvm was in the
picture, which is the only reason it did not get blamed on the forwarder.

### Two sandboxes, one GPU, host keeps the card

The headline claim in [00](00-overview.md) — *"the GPU is never unbound from the
host driver… several sandboxes can share it"* — run rather than asserted.
MEASURED: two Kata sandboxes started concurrently, each running `vecadd` five
times:

```
-- shrA: VECADD OK count = 5 --   elements: 1048576  mismatches: 0
-- shrB: VECADD OK count = 5 --   elements: 1048576  mismatches: 0
  host GPU 0000:00:07.0 driver: nvidia   <- never unbound, no vfio-pci
```

Ten successful CUDA workloads across two independent VMs on one card, with the
host's `nvidia` driver still bound to the device throughout and `nvidia-smi`
answering on the host. This is the thing Kata's existing VFIO cold-plug path
cannot do at all. Raw output:
[`evidence/07/two-sandboxes-one-gpu.log`](evidence/07/two-sandboxes-one-gpu.log).

Two is not many. **UNVERIFIED: where it stops** — memory, isolate count, host
driver client limits. Settle by walking the sandbox count up until something
fails and recording what.

### nvkvm's own isolation, under Kata

From the QEMU stderr Kata forwards to the journal, MEASURED:

```
nvkvm: host driver 575.51.03 → ABI profile 570
nvkvm: isolate sandbox: namespace
nvkvm: isolate mode auto -> namespace (strongest rung; clone(CLONE_NEWUSER|...),
       the uid/gid map write and the in-namespace mount all succeeded)
nvkvm: GPA width: host MAXPHYADDR 46 bits, guest MAXPHYADDR 46 bits
```

**nvkvm reaches its strongest isolation rung under Kata.** [06](06-vmm-confinement-design.md)
treated that as the thing to check; it holds, unmodified, with QEMU at host root
in Kata's sandbox cgroup.

**An observation that does not match `isolate-model.md` and is left open.**
While a CUDA loop ran, the QEMU process itself held ~30 open fds on
`/dev/nvidiactl` and `/dev/nvidia0` as well as `/dev/nvidia-uvm`. nvkvm's
`docs/internal/isolate-model.md` ("Who opens what") says ctl and GPU nodes are
opened **inside the isolate**, and QEMU holds only `/dev/nvidia-uvm`. A scan of
every process on the host holding an `/dev/nvidia*` fd found only QEMU and
virtiofsd — no isolate process. **UNVERIFIED which of three things this is:**
(a) isolates live in a pid namespace and were missed by a `/proc` ppid scan,
(b) the fds are inherited pre-`clone` and the doc describes post-`clone` state,
(c) the model genuinely differs under Kata. Settle it by running the same probe
on a non-Kata nvkvm host and comparing; if the fd set differs, it is (c) and it
is a real regression in the VMM's blast radius.

---

## 8. The findings that matter more than the rungs

### 8.1 FINDING: the container's device cgroup is **not** enforced in the guest

[03](03-guest-side-devices.md) is built on this sentence: *"the container's
device cgroup allows it — fails EPERM, with no log line… **This is the one that
decides, and the one that fails silently.**"*

It does not decide here. MEASURED, with the **identical OCI spec** produced by
the same `ctr run` invocation, differing only in `--runtime`:

| runtime | `mknod c 195 255` then `open()` | `mknod c 1 1` (`/dev/mem`) then `open()` |
|---|---|---|
| `io.containerd.runc.v2` | **`Operation not permitted`** (EPERM) | **`Operation not permitted`** (EPERM) |
| `io.containerd.kata.v2` | `Invalid argument` — **the open SUCCEEDED**, the driver rejected the `read()` | `No such device or address` (ENXIO — no such driver in the guest) |

Raw output: [`evidence/07/device-cgroup-runtimes.log`](evidence/07/device-cgroup-runtimes.log).

Neither Kata result is EPERM. The container has `CAP_MKNOD`
(`CapEff: 00000000a80425fb`), fabricates the node itself, and opens it. The
consequence is direct and was measured separately: **`nvidia-smi` works in a
container that was never given a GPU** — libnvidia-ml `mknod`s 195:255 itself
before opening `nvidiactl` (`nvkvm-pv/src/guest/nvkvm_main.c:91-98` documents
that behaviour), and nothing stops it.

So on this path, `VISIBLE_CDI_DEVICES` controls whether the *nodes are created
for you*. It does not control *access*. The negative control in
[`evidence/07/evidence.log`](evidence/07/evidence.log) shows exactly that: no
`/dev/nvidia*` without the variable, and `nvidia-smi` working anyway.

**Why this is not just a `ctr` artifact:** `runc`, given the same spec by the
same tool, denies. The allowlist is in the spec; something between the spec and
the guest's cgroup is not applying it.

**ROOT CAUSE — found, and it is a library bug, not a Kata design choice.**
Followed all the way down, with a guest shell (`kata-runtime exec`, needs
`debug_console_enabled = true` and a pty):

1. The guest kernel supports it. `CONFIG_CGROUP_DEVICE=y`, `CONFIG_BPF_SYSCALL=y`,
   `CONFIG_CGROUP_BPF=y` in both our kernel and the shipped
   `config-6.18.35-202` — they come from
   `tools/packaging/kernel/configs/fragments/common/cgroup.conf:13,26-27`. Not
   the kernel.
2. The container's cgroup exists. `/sys/fs/cgroup/default/dbgcon`, created by
   the agent. Not a missing cgroup.
3. The agent computes the rules. `set_devices_resources`
   (`src/agent/rustjail/src/cgroups/fs/mod.rs:340-360`) fills
   `res.devices.devices` from the OCI spec. Not a missing computation.
   (It does drop the `allow: false` catch-all via `rule_for_all_devices`, but
   that is not what breaks here.)
4. **`cgroups-rs` has no devices subsystem on cgroup v2.** Kata pins
   `cgroups-rs 0.5.1` (`Cargo.toml:160`). Its **v1** hierarchy constructs one —
   `hierarchies.rs:145-146`, `Subsystem::Devices(DevicesController::new(...))`.
   Its **v2** hierarchy (`hierarchies.rs:203-208`) builds the subsystem list by
   *reading `/sys/fs/cgroup/cgroup.controllers` and matching controller names* —
   and `devices` is never in that file, because on cgroup v2 device control is
   not a controller, it is a `BPF_CGROUP_DEVICE` program attachment. So
   `Subsystem::Devices` can never be constructed on v2, and `res.devices.devices`
   is silently discarded.

MEASURED, from the guest shell, closing the loop on step 4:

```
# cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma
```

No `devices`. There is nothing for the library to find, and it does not fall
back to attaching a BPF program. Full transcript:
[`evidence/07/guest-shell.log`](evidence/07/guest-shell.log) — which also shows
`/proc/modules` = `nvkvm_guest ... Live`, the guest's `/dev/nvidia*`, and the
`/var/run/cdi/nvkvm.yaml` the `modprobe.d` `install` directive wrote.

**This is the same bug as [01 §1.6](01-vmm-confinement.md), one layer down and
in a different language.** On the host, `containerd/cgroups` `v2.ToResources()`
never assigns `Resources.Devices`, so Kata's sandbox device allowlist is
dropped. In the guest, `cgroups-rs` `V2::subsystems()` never yields a devices
subsystem, so the container's device allowlist is dropped. Two independent
libraries, the same silent failure, and between them **no device cgroup is
enforced anywhere on a cgroup v2 Kata host** — not around the VMM, not around
the container.

**Why it matters.** [03](03-guest-side-devices.md) placed the entire gate here,
and [00](00-overview.md)'s table repeats it. Any claim that CDI "provides the
cgroup rule for free" now needs this attached: the rule is produced, and then
thrown away. On this configuration, a container that asks for no GPU can still
use one — `nvidia-smi` proves it in one command.

**This is the fourth upstream item, and the strongest one yet**, because unlike
[00 §Phase 4](00-overview.md) items 13-17 it is a plain bug with a two-line
reproducer and no nvkvm content at all:

> `kata-agent` computes a container device allowlist and, on every cgroup v2
> host, discards it, because `cgroups-rs 0.5.1`'s v2 hierarchy has no devices
> subsystem. Reproducer: `ctr run --runtime io.containerd.kata.v2 ubuntu:24.04
> x sh -c 'mknod /tmp/m c 1 1; cat /tmp/m'` returns ENXIO where the same
> command under `io.containerd.runc.v2` returns EPERM.

It should be reported **whether or not nvkvm-kata ever ships**, exactly as
[00 §Phase 4 item 16](00-overview.md) says of the host-side twin. The fix
belongs in `cgroups-rs` (attach a `BPF_CGROUP_DEVICE` program on v2, as
`containerd/cgroups` and runc both do) or in rustjail (do it directly, as runc
does). **UNVERIFIED: whether newer `cgroups-rs` fixes it** — settle by reading
`hierarchies.rs` in the current release before filing.

### 8.2 FINDING: there is no `modprobe` in the shipped rootfs

`kernel_modules = [...]` is Kata's shipped, documented way to load a guest
kernel module. kata-agent implements it by exec'ing `/sbin/modprobe`
(`MODPROBE_PATH`, `src/agent/src/rpc.rs:124`).

MEASURED on `kata-static-4.1.0-amd64`, loop-mounting
`/opt/kata/share/kata-containers/kata-containers.img` (Ubuntu 24.04 noble):

```
/sbin/modprobe      : absent
/bin/modprobe       : absent
/usr/bin/kmod       : absent
/usr/bin/busybox    : absent
/lib/modules        : absent
```

The agent binary itself has every string (`kernel_modules`, `/sbin/modprobe`,
`visible_cdi_devices`, `/var/run/cdi`, `cdi_timeout` — all PRESENT), so the
mechanism is compiled in and simply has nothing to call. The failure is
`ctr: failed to create shim task: No such file or directory (os error 2)` with
a 21-frame backtrace of `<unknown>` and no mention of modprobe, modules, or the
module name.

[`prepare-guest-rootfs.sh`](../../scripts/prepare-guest-rootfs.sh) fixes it by
harvesting kmod from the guest's own distro release (so glibc and libcrypto
symbol versions match by construction) — 174 KB plus four libraries.

#### And the second-order trap: usrmerge

Ubuntu noble is usr-merged: `/sbin` is itself a symlink to `usr/sbin`. So
`ln -s ../usr/bin/kmod $rootfs/sbin/modprobe` lands in `$rootfs/usr/sbin` and
resolves to `$rootfs/usr/usr/bin/kmod` — dangling. The symptom is *byte
identical* to having no modprobe at all: `No such file or directory (os error 2)`.
Cost: one build cycle. Upstream hit this too and says so —
`nvidia_rootfs.sh:838-841`, *"Absolute targets so they resolve regardless of
whether /sbin is a real dir or a usr-merge symlink."* Our script now uses
absolute targets for the same reason.

### 8.3 Correction to [04](04-guest-kernel.md): upstream's NVIDIA rootfs already runs depmod

[04](04-guest-kernel.md) leads with "**Neither `build-kernel.sh` nor `rootfs.sh`
runs `depmod`.** That is a real gap and a classic silent failure." That is
accurate for those two files, and `rootfs.sh:349-361`'s `copy_kernel_modules`
really does just `cp -a`. But the conclusion "so nobody upstream does it" is
wrong:

- `tools/osbuilder/rootfs-builder/nvidia/nvidia_rootfs.sh:709-716` runs
  `depmod -b "${extension}" "${kver}"` for every kernel version present;
- `:837-843` copies `usr/bin/kmod` and creates `modprobe insmod rmmod depmod
  lsmod` symlinks with absolute targets.

So Kata's GPU path already carries the complete recipe — kmod, applet symlinks,
`depmod -b` — and the nvkvm work should be framed as *reusing* it, not
*supplying* it. The gap is that none of it is in the generic path, so anything
that is not the NVIDIA rootfs starts from zero. That is a smaller and more
accurate complaint, and a much easier upstream conversation.

[`build-guest-kernel.sh`](../../scripts/build-guest-kernel.sh) still runs
`depmod` itself and still asserts the result, because the assertion is the
valuable half: `depmod` exits 0 on a tree it indexed to nothing.

---

## 9. The test host

| | |
|---|---|
| machine | vast.ai KVM instance, RTX 4070 Ti SUPER, 42 vCPU, 198 GB RAM |
| host OS | Ubuntu 22.04.5, kernel 6.8.0-59-generic, `systemd-detect-virt` = `kvm` |
| host driver | 575.51.03 (`/proc/driver/nvidia/version`) |
| cgroup | v2 (`cgroup2fs`) |
| containerd | `containerd.io 1.7.27` (`05044ec0a9a75232cad458027ca83437aae3f4da`) |
| Kata | 4.1.0, `kata-runtime` commit `ddcb1ad8d23cbb4323f86c209f132b89592902df`, Go runtime (`kata-go-static-4.1.0-amd64`) |
| Kata's QEMU | 11.0.1 (kata-static) |
| nvkvm QEMU | 11.1.1 (`v11.1.1-dirty`), built by `nvkvm-pv/scripts/build_qemu.sh` |
| nvkvm-pv | `7f875d186b7a7baba36c85fcc516f4c2d6ffc863` ("Merge branch 'qemu-bump': QEMU 9.2.0 -> v11.1.1") |
| kata-containers source | `f6205cf` (main, shallow-cloned 2026-08-27); design docs cite `f62ecce` |
| guest kernel | 6.18.35-nvkvm (Kata's 6.18.35 + `gpu/nvkvm.x86_64.conf.in`) |
| guest rootfs | `kata-ubuntu-noble.image`, 268 MB, + kmod + `nvkvm-guest.ko` |

**SELinux: not installed.** As on the [01](01-vmm-confinement.md) host. Nothing
here says anything about a SELinux-enforcing node.

**One GPU, one architecture, one driver.** Ada (AD103), 575.51.03. Nothing here
generalises to Blackwell, to multi-GPU, or to a driver outside nvkvm's 570 ABI
profile without being run again.

---

## 10. Reproducing it

> **There is now a script for all of this**, and a document that keeps the
> manual path first-class: [`docs/install.md`](../install.md) and
> `scripts/nvkvm-kata-install.sh`. Its nine stages are the nine numbered
> sections of that document, which are the steps below plus the two things this
> section leaves to the reader: registering a **second** runtime so the choice
> is per container, and reverting it. Two corrections to what follows, both
> MEASURED on 2026-08-27/28 and both recorded in
> [`evidence/08/`](evidence/08/):
>
> 1. **`KATA_CONF_FILE` can no longer select a second configuration.** Kata's
>    `isShippedKataConfigPath` (`containerd-shim-v2/create.go:325`) accepts only
>    the two hardcoded default paths. The `ConfigPath` *runtime option* — the
>    one containerd's CRI plugin and Docker's `daemon.json` pass — is read first
>    and is not validated, and it is what works.
> 2. **The `NVKVM_EXTRA_ARGS` systemd drop-in on `containerd.service` is not
>    needed**, and the installer does not create one. It is global and awkward
>    to revert; the shim already defaults to the device, and an override belongs
>    in `/etc/nvkvm-kata/shim.env`, which only the shim reads.
>
> The steps below are still the honest bring-up sequence and are left as they
> were run.


Assumes a host with `/dev/kvm`, an NVIDIA driver, docker and containerd. Check
`/dev/kvm` and `systemd-detect-virt` **first**; most GPU rentals are containers
and cannot provide it, and CPU `vmx`/`svm` flags prove nothing because a
container inherits its host's.

```bash
# 0. nvkvm's QEMU  (~2.5 min on 42 cores)
git clone https://github.com/reindertpelsma/nvkvm-pv /root/nvkvm-pv
bash /root/nvkvm-pv/scripts/build_qemu.sh --install-deps --force
/opt/qemu-nvkvm/bin/qemu-system-x86_64 -device help | grep nvgpu   # expect 4 lines

# 1. Kata 4.1.0.  BOTH tarballs: kata-static has the guest assets and the VMMs,
#    kata-go-static has containerd-shim-kata-v2 and the configs.  Installing only
#    the first leaves configuration.toml a DANGLING SYMLINK and no shim.
for a in kata-static kata-go-static; do
  curl -sL -o /root/$a.tar.zst \
    https://github.com/kata-containers/kata-containers/releases/download/4.1.0/$a-4.1.0-amd64.tar.zst
  tar -I zstd -xf /root/$a.tar.zst -C /
done
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/bin/containerd-shim-kata-v2
mkdir -p /etc/kata-containers
cp /opt/kata/share/defaults/kata-containers/configuration.toml /etc/kata-containers/

# 2. guest kernel + module + depmod  (~2 min)
curl -sL -o /root/gk/linux-6.18.35.tar.xz \
  https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x/linux-6.18.35.tar.xz
git clone --depth 1 https://github.com/kata-containers/kata-containers /root/kata-containers
scripts/build-guest-kernel.sh --kata-src /root/kata-containers \
    --nvkvm-src /root/nvkvm-pv --out /root/gk --graphics 0

# 3. rootfs: kmod + the CDI generator + the module
cp /opt/kata/share/kata-containers/kata-ubuntu-noble.image \
   /opt/kata/share/kata-containers/kata-nvkvm.image
scripts/prepare-guest-rootfs.sh  --image /opt/kata/share/kata-containers/kata-nvkvm.image
scripts/inject-guest-modules.sh  --image /opt/kata/share/kata-containers/kata-nvkvm.image \
    --modules /root/gk/modules --release "$(cat /root/gk/release)"

# 4. the shim, and Kata's configuration
install -m0755 scripts/nvkvm-qemu-shim.sh /usr/local/bin/nvkvm-qemu-shim
#   configuration.toml: path=/usr/local/bin/nvkvm-qemu-shim
#                       kernel=/root/gk/vmlinuz-<release>
#                       image=/opt/kata/share/kata-containers/kata-nvkvm.image
#                       kernel_params += " agent.visible_cdi_devices=true"
#                       kernel_modules=["nvkvm-guest"]
mkdir -p /etc/systemd/system/containerd.service.d
printf '[Service]\nEnvironment="NVKVM_EXTRA_ARGS=-device virtio-nvgpu-pci-non-transitional,id=nvkvm0"\n' \
    > /etc/systemd/system/containerd.service.d/nvkvm.conf
systemctl daemon-reload && systemctl restart containerd

# 5. host driver userspace for the container, with SONAME links
#    (Kata drops CDI hooks -- kata#11169 -- so nothing runs ldconfig in there)
bash /root/nvkvm-pv/scripts/make_host_bundle.sh /root
cd /root/host-libs-*/ && for f in *.so.*; do
    so=$(objdump -p "$f" | awk '/SONAME/{print $2}'); [ -n "$so" ] && ln -sf "$f" "$so"; done
gcc -O2 -o /root/nvidia-bin/vecadd scripts/e2e/vecadd.c -ldl

# 6. run it
ctr run --rm --runtime io.containerd.kata.v2 \
  --mount type=bind,src=/root/host-libs-575.51.03,dst=/usr/local/nvidia/lib,options=rbind:ro \
  --mount type=bind,src=/root/nvidia-bin,dst=/usr/local/nvidia/bin,options=rbind:ro \
  --env VISIBLE_CDI_DEVICES=nvidia.com/gpu=0 \
  --env LD_LIBRARY_PATH=/usr/local/nvidia/lib \
  docker.io/library/ubuntu:24.04 gpu0 /usr/local/nvidia/bin/vecadd
```

Run from a clean `kata-ubuntu-noble.image` with the committed scripts as the
final act of this session; output in
[`evidence/07/rung345.log`](evidence/07/rung345.log).

---

## 11. What is still not done

Ordered by how much it would change the picture.

1. **Settle §8.1.** Until it is known why the container's device cgroup is not
   enforced, this configuration has no device boundary inside the guest, and
   [03](03-guest-side-devices.md)'s central claim is unsupported. Experiment
   named in §8.1.
2. **Settle the isolate fd question in §7.** If nvkvm's VMM genuinely holds
   ctl/GPU fds under Kata that it does not hold elsewhere, that is a widening of
   the blast radius of a QEMU RCE and belongs in
   [06](06-vmm-confinement-design.md). Experiment named in §7.
3. **Kubernetes.** Everything here is `ctr`. No kubelet, no CRI, no device
   plugin, no scheduler. `VISIBLE_CDI_DEVICES` is a container-driven request, as
   [03 §(a)](03-guest-side-devices.md) is honest about; the orchestrator-grade
   version is [03 §(b)](03-guest-side-devices.md) and is untouched.
4. **The host CDI spec (`nvkvm.io/vmm`).** Not needed on this host, because
   [01 §1.4](01-vmm-confinement.md)'s gap left the VMM able to open the nodes
   unconfigured. [`split-cdi-spec.sh`](../../scripts/split-cdi-spec.sh) exists
   and is tested; it was never wired in, because there was nothing to fix.
   **It is still the only answer that is correct on cgroup v1 and survives the
   eventual fix**, and it remains Phase-0 step 2.
5. **cgroup v1.** Not tested at all.
6. **The graphics build** (`--graphics 1`, `CONFIG_DRM`, `/dev/dri/renderD128`).
7. **Combining the shim with [06](06-vmm-confinement-design.md)'s user
   namespace.** Both want the same file; neither has met the other.
8. **Multi-sandbox at scale.** Two concurrent sandboxes sharing one GPU is
   MEASURED (§7). Where it stops — memory, isolate count, host driver client
   limits — is not.
9. **The osbuilder path.** `prepare-guest-rootfs.sh` and
   `inject-guest-modules.sh` edit a shipped image, which is right for bring-up
   and wrong for release. The release form is `KERNEL_MODULES_DIR` +
   `rootfs.sh`, following `nvidia_rootfs.sh`.
10. **`nvidia-ctk cdi generate` in the guest** — still UNVERIFIED
    ([03](03-guest-side-devices.md)), now optional rather than blocking.
