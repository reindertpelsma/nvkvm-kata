# CUDA initialises but enumerates zero devices under nvkvm-kata

**Status: OPEN.** Measured on the physical PC (RTX 4070, host driver 580.173.02
proprietary, nvkvm-pv `1dc47d4`) on 2026-08-30.

## What happens

```
docker run --runtime=nvkvm-kata --gpus all --rm nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 ...

nvidia-smi -L        -> GPU 0: NVIDIA GeForce RTX 4070 (UUID: GPU-66e52545-...)
cuInit(0)            -> 0        (success)
cuDriverGetVersion   -> 13000
cuDeviceGetCount     -> rc 0, devices = 0     <-- nothing to run a kernel on
```

So NVML sees the GPU and the CUDA driver loads and initialises, and then CUDA
enumerates no devices. Compute is unusable.

## What has been RULED OUT, each with a measurement

- **The mounted libraries.** `libcuda.so.580.173.02`, `.so.1` and `.so` are all
  present in the container at the host driver's version. `cuInit` would not
  succeed otherwise.
- **`NVIDIA_DRIVER_CAPABILITIES`.** Already `compute,utility` -- the usual cause
  of "nvidia-smi works but CUDA does not" -- and forcing it changes nothing.
- **`NVIDIA_VISIBLE_DEVICES` / `CUDA_VISIBLE_DEVICES`.** The container inherits
  `NVIDIA_VISIBLE_DEVICES=void` and an empty `CUDA_VISIBLE_DEVICES`, but forcing
  `NVIDIA_VISIBLE_DEVICES=all CUDA_VISIBLE_DEVICES=0` still gives `devices = 0`.
- **Device nodes.** `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm` and
  `/dev/nvidia-uvm-tools` are all present; `/dev/nvidia-uvm` opens successfully.
- **The guest module.** `/proc/modules` shows `nvkvm_guest` loaded, and the guest
  dmesg shows it registering all four nodes and mapping transport rings
  ("session 1 RING MAPPED ... 3-way OK").
- **A stale CDI manifest.** Rebuilt for 580.173.02 before these runs (88 mounts).

**UVM was my first guess and it is not supported by evidence** -- the node opens
and the module is live. Do not start there.

## What this is NOT

It is **not** the `cuInit rc=999` seen on rented vast boxes. Here `cuInit`
returns 0. That failure looks environmental to nested virtualisation rather than
a defect in the forwarding path, which matters because a sweep full of
`cuInit rc=999` would otherwise read as a driver-matrix catastrophe.

## Where to look next

The split is NVML-yes / CUDA-no with a correct userspace. That points at what
the CUDA driver does BEYOND what NVML does when it enumerates -- device
probing through `/dev/nvidia0` ioctls that NVML never issues. Instrument the
forwarded ioctl stream during `cuDeviceGetCount` and compare against a
bare-metal container on the same host; the first divergence is the bug.

## Two unrelated defects found while testing this

1. **`--privileged` fails outright**: `QMP command failed: Parameter 'aio' does
   not accept value 'io_uring'`. Our QEMU build does not accept the aio mode
   kata requests for privileged containers.
2. **The driver-mismatch error names a path that does not exist on an installed
   system.** It says `-> re-run: scripts/lib/gpu-cdi.py discover --force`, but
   the installer places it at `$PREFIX/bin/nvkvm-kata-gpu-cdi`
   (`nvkvm-kata-install.sh:944`). On a box installed from the tarball there is no
   `scripts/` directory, so the suggested remedy cannot be run. It should name
   the installed binary.

Related: the mismatch check itself is GOOD behaviour -- it failed closed, loudly,
with the versions named. That is the opposite of the silent staleness that cost a
day on the nvkvm-steamos side. The open question is only whether it should
self-heal (rebuild under a lock, atomically, logging loudly) rather than require
a human step after every unattended host driver upgrade.
