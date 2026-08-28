# 09 — `--gpus all`, and nothing else

**Status: RUN, 2026-08-28.** The command this document exists to make work:

```bash
docker run --runtime=nvkvm-kata --gpus all --rm \
    nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 "nvidia-smi"
```

No `volumes:`. No `LD_LIBRARY_PATH`. No `VISIBLE_CDI_DEVICES`. Transcript:
[`evidence/09/acceptance.log`](evidence/09/acceptance.log).

Before this change that exact command did not merely fail to get a GPU — **it
failed to start the container at all** ([§2](#2-what-docker-actually-hands-us)).
[`docs/install.md`](../install.md) §7 used to tell people to bind-mount
`/opt/nvkvm-kata/nvidia/lib` and set `LD_LIBRARY_PATH` by hand. That is gone.

Upstream changes required: still **one line**, the same one
([07](07-end-to-end.md)). No patch to the Kata runtime, shim, agent or rustjail.

---

## 0. The result, in one table

| claim | verdict | evidence |
|---|---|---|
| **kata-agent executes `createContainer` hooks from a GUEST-side CDI spec** | **YES** — the pivotal unknown of [02 §D](02-libraries-via-cdi.md), settled positively | [§3](#3-the-pivotal-measurement), [`evidence/09/guest-cdi-hooks.log`](evidence/09/guest-cdi-hooks.log) |
| `update-ldcache` **alone** suffices — `ldconfig` makes the SONAME links itself | **YES** | [§5](#5-ablation-which-half-does-what), [`evidence/09/ldcache-ablation.log`](evidence/09/ldcache-ablation.log) |
| `docker run --gpus all` works with a stock CUDA image | **PASS** | [`evidence/09/acceptance.log`](evidence/09/acceptance.log) |
| CUDA **compute** in that container | **PASS** — 1,048,576 elements, 0 mismatches | [§6](#6-what-was-proved-and-what-was-not) |
| `--gpus 1`, `--gpus '"device=0"'`, `--gpus '"device=<uuid>"'` | **PASS** | [`evidence/09/docker-gpus-forms.log`](evidence/09/docker-gpus-forms.log) |
| `NVIDIA_DRIVER_CAPABILITIES` selects a library subset | **NO, and it cannot** — NVIDIA's own CDI mode is capability-complete | [§7](#7-capabilities-the-one-thing-that-does-not-transfer) |
| the same image under stock `runc` + nvidia-container-toolkit | **REFUSES TO START** on this host | [§6](#6-what-was-proved-and-what-was-not) |

---

## 1. The four things, and which two the VM breaks

`nvidia-container-toolkit` does four things for a GPU container. Confirmed by
running one against a plain image on the test host and reading the result —
[`evidence/09/toolkit-under-runc.log`](evidence/09/toolkit-under-runc.log):

```
$ docker run --gpus all --rm ubuntu sh -c "mount; ls -la /usr/lib/x86_64-linux-gnu"

/dev/root on /usr/bin/nvidia-smi type ext4 (ro,nosuid,nodev,...)                  <- 2
/dev/root on /usr/lib/x86_64-linux-gnu/libcuda.so.575.51.03 type ext4 (ro,...)    <- 2
devtmpfs on /dev/nvidiactl type devtmpfs (ro,nosuid,noexec,...)                   <- 1
...
lrwxrwxrwx 1 root root       12 Aug 28 02:21 libcuda.so -> libcuda.so.1           <- 4
lrwxrwxrwx 1 root root       20 Aug 28 02:21 libcuda.so.1 -> libcuda.so.575.51.03 <- 4
-rw-r--r-- 1 root root 92316728 Apr 16  2025 libcuda.so.575.51.03                 <- 2
```

Note the dates. The versioned file is the host's, from April 2025, arriving as a
**bind mount**. The two symlinks are dated *now* — they were created in the
container's **writable overlay** by a hook, seconds ago. So:

| | what | under Kata |
|---|---|---|
| 1 | bind-mount the device nodes | **already solved** — guest-side CDI spec, [03](03-guest-side-devices.md), [07](07-end-to-end.md) |
| 2 | bind-mount the host CUDA libraries, **version-postfixed** | mounts traverse virtio-fs fine — but nothing was putting them in the spec |
| 3 | allow the nodes in the container's device cgroup | **already solved** (and, on cgroup v2, discarded by a Kata bug — [07 §8.1](07-end-to-end.md#81-finding-the-containers-device-cgroup-is-not-enforced-in-the-guest)) |
| 4 | create SONAME symlinks, config files and ldcache entries **in the container's writable layer** | a `createContainer` hook, and **Kata deletes host-injected hooks** |

(4) is the whole problem. `grpcSpec.Hooks = nil`, with a comment explaining
why, at `src/runtime/virtcontainers/kata_agent.go:1055`.

---

## 2. What Docker actually hands us

`--gpus` is not magic. Docker's nvidia device driver registers only when
`nvidia-container-runtime-hook` is on `PATH` — so **the toolkit is already a
hard dependency of the acceptance test**, whatever we do — and all it then does
is edit the OCI spec. MEASURED, from the bundle's own `config.json`
([`evidence/09/shim-bundle-probe.log`](evidence/09/shim-bundle-probe.log)):

```
ENV:     NVIDIA_VISIBLE_DEVICES=all
HOOKS:   prestart: /usr/bin/nvidia-container-runtime-hook prestart
MOUNTS:  10          (none of them NVIDIA)
DEVICES: None
RESDEV:  ... no NVIDIA entries ...
```

One environment variable, and one hook that does all the real work.

**And Kata runs that hook, on the host, where it cannot work.**
`PreStartHooks` is called from `src/runtime/pkg/katautils/create.go:194`, in the
host's namespaces, against an overlay directory the guest will only later see
over virtio-fs. So:

```
$ docker run --runtime=nvkvm-kata --gpus all --rm ubuntu:24.04 /bin/true
docker: Error response from daemon: failed to create task for container:
failed to create shim task: exit status 1: stdout: , stderr:
Auto-detected mode as 'legacy'
nvidia-container-cli: mount error: mount operation failed:
/var/lib/docker/overlay2/0786abb7.../merged/proc/driver/nvidia: no such file or directory
```

That is kata issue **#10672** reproduced from a clean install. It is the
starting point, not a regression: `--gpus` was *broken*, not merely unsupported.

---

## 3. The pivotal measurement

[02 §D](02-libraries-via-cdi.md) named the unknown that decides the whole
design:

> **UNVERIFIED:** whether kata-agent actually executes hooks arriving via the
> guest CDI path.

**It does.** A `createContainer` hook was added to the guest-generated
`/var/run/cdi/nvkvm.yaml`; the hook touched a file in the container's rootfs;
the file was there inside the container:

```
$ docker run --runtime=nvkvm-kata -e VISIBLE_CDI_DEVICES=nvidia.com/gpu=0 \
      --rm ubuntu:24.04 sh -c "ls -l /NVKVM_HOOK_RAN"
-rw-r--r-- 1 root root 0 Aug 28 02:33 /NVKVM_HOOK_RAN
```

The path it takes: `handle_cdi_devices` (`src/agent/src/device/mod.rs`) applies
the guest spec's `containerEdits` to the container's OCI spec, and rustjail runs
what lands in `hooks.createContainer` at
`src/agent/rustjail/src/container.rs:621-632`, **in the container's mount
namespace, after the rootfs is assembled and before `pivot_root`** — which is
exactly the contract `nvidia-cdi-hook update-ldcache` is written against.

Upstream evidently knows this path is live and awkward to debug; there is a
dedicated `/dev/kmsg` mirror for hook failures in
`src/libs/kata-sys-util/src/hooks.rs`, whose comment says createContainer hooks
run in the forked container child where the agent's log drain does not exist,
"so without this a failed hook (e.g. a CDI hook that can't be found or exits
non-zero) leaves no trace at all."

**So no kata-agent patch is needed, and none was written.** Full transcript:
[`evidence/09/guest-cdi-hooks.log`](evidence/09/guest-cdi-hooks.log).

---

## 4. The design

Three pieces, none of them a daemon.

```
INSTALL TIME, host        scripts/lib/gpu-cdi.py discover
  `nvidia-ctk cdi generate --format=json`   <- NVIDIA answers "which files"
      containerEdits.mounts        -> taken verbatim
      hooks[create-symlinks] --link-> resolved against the host, taken as mounts
      containerEdits.deviceNodes   -> DISCARDED (host majors; the guest's differ)
      hooks[everything else]       -> DISCARDED (they cannot run on the host)
  + DT_SONAME of each library      -> a SECOND mount at the SONAME path
  = /var/lib/nvkvm-kata/gpu-mounts.json

PER CONTAINER, host       scripts/lib/gpu-cdi.py inject, from the shim wrapper
  cwd is the bundle; config.json is already written (MEASURED, sec 2)
  NVIDIA_VISIBLE_DEVICES set and not void?
      + the mounts from the manifest
      + VISIBLE_CDI_DEVICES=nvidia.com/gpu=<mapped>
      - Docker's nvidia prestart hook, which cannot work here (sec 2)

GUEST, at modprobe time   scripts/prepare-guest-rootfs.sh
  nvkvm-guest-cdi-gen writes /var/run/cdi/nvkvm.yaml:
      devices "0".."N" and "all", deviceNodes only, no major/minor
      hooks: createContainer -> nvkvm-cdi-hook-ldcache

CONTAINER CREATE, guest   rustjail
  nvkvm-cdi-hook-ldcache  chroot <container-root> /sbin/ldconfig
```

### Why the discovery is a subprocess and not a Go import

The brief's preference was to link `nvidia-container-toolkit`'s own Go packages.
This calls `nvidia-ctk cdi generate` instead, and the reasons are worth stating
because the goal — *"keeps working when NVIDIA ships a new library"* — is better
served this way, not worse:

- **`nvidia-ctk cdi generate` IS the toolkit's highest-level API**, and it
  returns mounts and hooks as data (a CDI spec). Consuming it is reuse, not
  reimplementation. The public Go entry point, `nvcdi.New(...).GetSpec("all")`,
  computes the same object; `internal/discover`, where the file lists actually
  live, is an `internal/` package and not importable from outside the module at
  all.
- **The toolkit is already installed.** Docker will not accept `--gpus` without
  `nvidia-container-runtime-hook`, which ships in the same package as
  `nvidia-ctk`. Requiring it costs nothing that was not already required.
- **A linked copy would be a snapshot.** Compiled in, the discovery is whatever
  toolkit version we built against, on a host whose driver and toolkit will move
  independently. Shelled out, the list is whatever NVIDIA shipped *on this host*
  — which is the version that also has to service the ioctls.
- It also removes a Go 1.26 + cgo toolchain from the target's requirements.

The one thing computed here rather than asked for is `DT_SONAME`, read out of
the ELF (`scripts/lib/gpu-cdi.py`, ~40 lines). That is glibc semantics, not
NVIDIA's, so it cannot rot when a new library appears — and a new library
appears in the mount list automatically, because it appears in
`nvidia-ctk`'s output.

### What the manifest looks like

76 mounts on the test host: 48 straight from `nvidia-ctk`, 23 SONAME names, 5
from NVIDIA's own `create-symlinks` list. Full file:
[`evidence/09/gpu-mounts.json`](evidence/09/gpu-mounts.json), and the
`nvidia-ctk` output it is distilled from:
[`evidence/09/nvidia-ctk-cdi-generate.json`](evidence/09/nvidia-ctk-cdi-generate.json)
— which also settles [02 §A](02-libraries-via-cdi.md)'s **UNVERIFIED** request
for a literal generated spec as a committed fixture.

### Device selection

`NVIDIA_VISIBLE_DEVICES` → `VISIBLE_CDI_DEVICES`, which kata-agent resolves
against the guest spec (`src/agent/src/device/mod.rs`,
`cdi_devices_from_visible_devices`):

| the user types | Docker sets | the injector emits |
|---|---|---|
| `--gpus all` | `NVIDIA_VISIBLE_DEVICES=all` | `nvidia.com/gpu=all` |
| `--gpus 2` | `NVIDIA_VISIBLE_DEVICES=0,1` | `nvidia.com/gpu=0,1` |
| `--gpus '"device=0"'` | `NVIDIA_VISIBLE_DEVICES=0` | `nvidia.com/gpu=0` |
| `--gpus '"device=GPU-f758…"'` | the UUID | the UUID's **index** — the guest has no NVML to resolve a UUID with, so the mapping is recorded on the host at `discover` time |

The guest generator therefore enumerates `/dev/nvidia[0-9]*` and emits a device
per GPU **plus** an `all` device, mirroring what `nvidia-ctk` emits, because
`nvidia.com/gpu=all` is a lookup for a device literally named `all`.

Asking for a GPU the host does not have fails cleanly:

```
$ docker run --runtime=nvkvm-kata --gpus 2 --rm ubuntu:24.04 /bin/true
docker: ... CDI device(s) ["nvidia.com/gpu=1"] do not exist; their CDI kind(s)
are present in /var/run/cdi but do not provide them
```

**UNVERIFIED: multi-GPU.** The test host has one card. Index selection is
plumbed end to end and the failure path above is measured, but "give container A
GPU 0 and container B GPU 1" has never been run, and nvkvm's own device
enumeration in the guest is a separate question from CDI's.

---

## 5. Ablation: which half does what

The brief asked whether `updateLdCache` alone suffices, on the theory that
`ldconfig` creates SONAME symlinks by itself and `createSymlinks` is therefore
redundant. **It does, and it is.** Both mechanisms were run alone —
[`evidence/09/ldcache-ablation.log`](evidence/09/ldcache-ablation.log):

| | `libcuda.so.1` resolves | `ldconfig -p` lists it | CUDA runs |
|---|---|---|---|
| SONAME mounts only, no hook | yes (a real file at the SONAME path) | **no** | yes |
| ldconfig hook only, mounts stripped 76 → 53 | yes (**ldconfig made the symlink itself**) | yes | yes |
| both — what ships | yes | yes | yes |

The middle row is the interesting one, and it confirms the theory exactly:
`nvidia-ctk`'s `create-symlinks` hook does **not** emit the SONAME links at all.
It emits four odd ones out — `libcuda.so`, `libGLX_indirect.so.0`, the gbm and
xorg links — and leaves `libcuda.so.1` to `ldconfig`. Read
[`evidence/09/nvidia-ctk-cdi-generate.json`](evidence/09/nvidia-ctk-cdi-generate.json)
and see for yourself.

### Why both ship anyway

Not belt-and-braces for its own sake: they fail differently.

**The cache is not cosmetic.** NVIDIA's own images gate on it —
`/opt/nvidia/entrypoint.d/50-gpu-driver-check.sh` runs
`ldconfig -p | grep libcuda.so.1` and, finding nothing, prints *"The NVIDIA
Driver was not detected"* and exports **`NVIDIA_CPU_ONLY=1`**, with a perfectly
working GPU attached. Mounts alone produce a container that works but tells
every framework in it to use the CPU. So the hook is required.

**And the hook needs `ldconfig` in the image.** A distroless or Alpine image has
none. Without the SONAME mounts, such a container would get a GPU, no
`libcuda.so.1`, and no error — a silent failure of exactly the kind the rest of
this repository is written to avoid. The mounts cost 23 entries in a list that
is already computed, and about **0.7 s** of sandbox start (4.5 s → 5.2 s for
`ubuntu:24.04`, three runs each, MEASURED).

---

## 6. What was proved, and what was not

**CUDA compute, in the acceptance image, compiled inside it:**

```
$ docker run --runtime=nvkvm-kata --gpus all --rm -v /tmp/vecadd.c:/tmp/vecadd.c:ro \
    nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 bash -c 'gcc -O2 -o /tmp/v /tmp/vecadd.c -ldl && /tmp/v'
devices: 1
device 0: NVIDIA GeForce RTX 4070 Ti SUPER
elements: 1048576  mismatches: 0  sample: c[7]=21.0 (want 21.0)
VECADD OK
```

**`nvcc`, in a CUDA image matched to the host driver:**

```
$ docker run --runtime=nvkvm-kata --gpus all --rm -v /tmp/vadd.cu:/tmp/vadd.cu:ro \
    nvidia/cuda:12.9.1-cudnn-devel-ubuntu24.04 bash -c 'nvcc -arch=native -o /tmp/v /tmp/vadd.cu && /tmp/v'
Cuda compilation tools, release 12.9, V12.9.86
device: NVIDIA GeForce RTX 4070 Ti SUPER  sm_89
elements: 1048576  mismatches: 0  sample: c[7]=21.0 (want 21.0)
NVCC VECADD OK
```

### The one thing that does not work, and why it is not ours

`nvcc` from the **CUDA 13.3** image produces a binary whose CUDA *runtime*
requires a driver newer than this host's **575.51.03** (a CUDA 12.9 driver):

```
CUDA ERROR: CUDA driver version is insufficient for CUDA runtime version
```

That is the ordinary CUDA runtime/driver rule, and the control settles whose
fault it is. Under **stock `runc` + nvidia-container-toolkit** on the same host,
the same image does not get as far as running anything:

```
$ docker run --gpus all --rm nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 nvidia-smi
nvidia-container-cli: requirement error: unsatisfied condition: cuda>=13.3,
please update your driver to a newer version, or use an earlier cuda container
```

So on this host nvkvm-kata is **strictly more permissive than the toolkit's own
runtime**: the container starts, `nvidia-smi` works, and driver-API CUDA
computes. It is a driver-version fact, not a VM-boundary fact.

**Not implemented: `enable-cuda-compat`.** The image ships forward-compatibility
libraries (`/usr/local/cuda/compat/libcuda.so.610.43.02`) and NVIDIA has a CDI
hook that activates them. It is deliberately not wired up: a 610 userspace
speaking to a 575 kernel driver through nvkvm's **570 ABI profile** is exactly
the mismatch [02](02-libraries-via-cdi.md) says this architecture removes *by
construction*, and CUDA forward compatibility is in any case only supported on
datacenter GPUs. **UNVERIFIED** whether it would work; not attempted.

---

## 7. Capabilities: the one thing that does not transfer

The goal was for `--gpus 'all,"capabilities=compute,utility"'` to select the
same **library set** the toolkit would. It selects the same **devices**, and the
variable is read and recorded, but the library set is not filtered — and it
cannot be, through this route or any other public one.

**NVIDIA's own CDI mode does not filter by capability either.** Capability
filtering lives in the *legacy* path, where `nvidia-container-runtime-hook`
turns `NVIDIA_DRIVER_CAPABILITIES` into `--compute --utility --graphics …` flags
for `nvidia-container-cli`
(`cmd/nvidia-container-runtime-hook/container_config.go:155`). The CDI generator
has no such input: `newCommonNVMLDiscoverer`
(`pkg/nvcdi/common-nvml.go:27-50`) merges the graphics discoverer, the driver
files and the meta devices **unconditionally**, and `GetCommonEdits()` takes no
capability argument. A spec generated by `nvidia-ctk` and requested as
`--device nvidia.com/gpu=all` is capability-complete too.

So the honest statement is: **nvkvm-kata is capability-compatible with
nvidia-container-toolkit's CDI mode, which ignores capabilities, and is not
compatible with its legacy mode, which honours them.** The variable passes
through to the container untouched, so anything in the image that reads it still
sees what the user asked for. Measured, both syntaxes:

```
$ docker run --runtime=nvkvm-kata --gpus 'all,"capabilities=compute,utility"' --rm ubuntu:24.04 \
      sh -c 'echo CAPS=$NVIDIA_DRIVER_CAPABILITIES; nvidia-smi -L'
CAPS=compute,utility
GPU 0: NVIDIA GeForce RTX 4070 Ti SUPER (UUID: GPU-f758d3b3-...)
```

(Note the quoting: bare `--gpus all,capabilities=compute,utility` is rejected by
Docker's own flag parser, which reads `utility` as a device count. That is a
Docker CLI quirk, present with every runtime.)

Filtering *could* be added — the discoverers are separable inside the toolkit —
but only by reimplementing `newCommonNVMLDiscoverer` against an `internal/`
package, which is precisely the copy-NVIDIA's-logic-forever outcome this design
avoids.

---

## 8. Two traps, recorded because each cost real time

**`set -e` in the guest CDI generator lies about what failed.** kmod runs the
generator from a `modprobe.d install` directive, so a non-zero exit fails the
module load, and kmod reports it as:

```
modprobe: ERROR: could not insert 'nvkvm_guest': Invalid argument
```

— which names neither the script nor the problem, and sends you off debugging
`nvkvm-guest.ko`, which loaded perfectly. (Proved by `insmod`-ing it by hand
from a guest shell: it loads, registers majors 195 and 243, and says so.) The
actual cause was an `[ -e "$n" ] && echo …` in tail position: `/dev/dri/renderD128`
does not exist on a compute-only build, so the last statement returned 1. The
generator now has no bare `&&` in tail position, every helper ends in
`return 0`, and it reports its own failures to `/dev/kmsg`.

**YAML indentation in the generated CDI spec fails the same way.** A 6-space
`deviceNodes:` next to a 2-space `hooks:` under the same mapping gets:

```
failed to create shim task: error refreshing cache:
SpecError { message: "spec error message parse spec file failed" }
```

with no file and no line. The emitter now takes the indent as a parameter.

**And one latent bug in this repository, fixed in passing.**
`losetup -f --show -P` returns before udev has created the `p1` node, so
`PART="${LOOP}p1"; [ -b "$PART" ] || PART="$LOOP"` loses a race on a busy host
and silently mounts the whole disk instead of the partition —
`mount: wrong fs type, bad option, bad superblock`. Both
`prepare-guest-rootfs.sh` and `inject-guest-modules.sh` now wait for the node.

---

## 9. The test host

Same shape as [07 §9](07-end-to-end.md#9-the-test-host), different rental.

| | |
|---|---|
| machine | vast.ai KVM instance, **NVIDIA RTX 4070 Ti SUPER**, 42 vCPU, 198 GB RAM |
| host OS | Ubuntu 22.04.5, `systemd-detect-virt` = `kvm`, cgroup v2 |
| host driver | 575.51.03 |
| nvidia-container-toolkit | preinstalled on the image (`nvidia-ctk`, `nvidia-container-cli`, `nvidia-container-runtime-hook` all present) |
| containerd / docker | `containerd.io 1.7.27` / `28.1.1` |
| Kata | 4.1.0, both tarballs, installed by the script |
| guest kernel | `6.18.35-nvkvm` |
| images | `nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04`, `nvidia/cuda:12.9.1-cudnn-devel-ubuntu24.04`, `ubuntu:24.04` |

**One GPU, one architecture, one driver, one container engine.** Ada (AD103),
575.51.03, Docker. Nothing here says anything about multi-GPU, about
Kubernetes/CRI (which passes the same OCI spec through the same shim wrapper and
*should* work identically — **UNVERIFIED**), or about a SELinux-enforcing node.

---

## 10. What is still not done

1. **Multi-GPU.** [§4](#device-selection).
2. **Kubernetes.** The injector sits in the containerd shim wrapper, below the
   engine, so the CRI path gets it for free in principle. No kubelet has run.
3. **`enable-cuda-compat`.** [§6](#6-what-was-proved-and-what-was-not).
4. **Capability filtering.** [§7](#7-capabilities-the-one-thing-that-does-not-transfer) —
   possible, but only by copying NVIDIA's internals.
5. **A driver upgrade under a live installation.** `inject` compares
   `/proc/driver/nvidia/version` against the manifest and refuses loudly if they
   differ, telling you to re-run `discover`; that refusal path is coded and
   reviewed but has not been exercised against a real driver upgrade.
