# 11 — three defects, and the two Docker `--gpus` paths

Everything here was produced on **one rented host**, 2026-08-28, plus two
parser checks that need no hardware at all. The injector under test is
byte-identical to the one committed (`md5 523b7e29…`, recorded in
[`host-and-selftest.log`](host-and-selftest.log) next to the repo copy).

## The host

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 4070 Ti |
| driver | **575.51.03**, proprietary kernel module |
| OS | Ubuntu 22.04.5, kernel 6.8.0-59-generic, inside a KVM guest |
| Docker | 29.7.2 |
| containerd | v2.3.3 |
| nvidia-container-toolkit | 1.20.0 |
| guest kernel built | 6.18.35-nvkvm |

Not the desktop the defects were reported from — deliberately. It matches that
desktop on the three versions that matter (Docker 29.7.2, containerd 2.3.3,
toolkit 1.20.0) and differs on the two that should not (driver 575.51.03
proprietary vs 595.84 open; Ubuntu 22.04 vs 26.04).

**`nvidia-cdi-refresh.service` and `.path` came up `enabled` from nothing more
than `apt-get install nvidia-container-toolkit`.** Nothing enabled them by
hand. `/var/run/cdi/nvidia.yaml` existed before the installer was ever run, and
`docker info` reported `Discovered Devices: cdi: nvidia.com/gpu=0`. That is the
whole premise of defect 3, reproduced on a second, independent host.

## Defect 1 — the driver version was the COMPILER's version

[`defect1-driver-version.log`](defect1-driver-version.log). No GPU needed.

```
FORMAT         EXPECTED     OLD(main)    NEW(bash)    NEW(python)
proprietary    575.51.03    575.51.03    575.51.03    575.51.03
open-3comp     580.95.05    580.95.05    580.95.05    580.95.05
open-2comp     595.84       15.2.0       595.84       595.84   <-- OLD RULE WRONG
```

`15.2.0` is the GCC version on the file's second line. Pinned by
`scripts/lib/gpu-cdi.py self-test`, which also asserts the shell and Python
rules **agree** — they must, or the injector refuses every container.

Verified in situ: preflight printed `ok NVIDIA host driver 575.51.03`
([`install-full.log`](install-full.log)).

## Defect 2 — `--qemu` ignored unless the `qemu` stage ran

[`defect2-ab.log`](defect2-ab.log). `--only runtime --qemu <path>` on a host
that already has an unrelated `/opt/qemu-nvkvm`:

```
RESULT[OLD-main]:  --qemu was IGNORED   (the defect)   shim.env = /opt/qemu-nvkvm/...
RESULT[NEW-fixed]: --qemu WAS honoured  (correct)      shim.env = /opt/qemu-right/...
```

Both installers exited **0**. That is the point: the old one wrote the wrong
hypervisor into `shim.env` and said nothing.

## Defect 3 — Docker's daemon resolves `--gpus` through CDI

[`defect3-ab.log`](defect3-ab.log), against a real daemon-CDI spec really
carrying `/run/nvidia-persistenced/socket` (persistenced was started so the
socket existed, then the spec regenerated exactly as
`nvidia-cdi-refresh.service` does).

*Old injector:*

```
docker: Error response from daemon: failed to create task for container:
Internal: failed to create shim task: Input/output error (os error 5)
Stack backtrace:
   0: <unknown>
   ...
```

…and its log is **empty** — `NVIDIA_VISIBLE_DEVICES=void` read as "not a GPU
container", so it did nothing at all. *New injector:* `GPU 0: NVIDIA GeForce
RTX 4070 Ti`.

## Both configurations of the acceptance test

The gate: `docker run --runtime=nvkvm-kata --gpus all --rm
nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 "nvidia-smi"` verbatim, **plus** a
real compute proof in the same container — `scripts/e2e/vecadd.c`, built with
`gcc` inside the container and checked for arithmetic, not just exit status.

| | daemon CDI | acceptance | compute | injector saw |
|---|---|---|---|---|
| [A](acceptance-A-with-daemon-cdi.log) | **present** | PASS | `VECADD OK`, 0/1048576 mismatches | `+32 mounts, -7 host hooks, 7 host device nodes dropped, -1 untraversable mounts (socket)` |
| [B](acceptance-B-without-daemon-cdi.log) | **absent** | PASS | `VECADD OK`, 0/1048576 mismatches | `+82 mounts, -1 host hooks` — nothing dropped |

B is the configuration that already worked, and its log shows the *unchanged*
legacy path: all 82 mounts from our own manifest, the one legacy prestart hook
removed, no device nodes and no mounts stripped. That is the regression check
for hosts that were never broken.

## Install, uninstall, reinstall, and a third run

* [`install-full.log`](install-full.log) — cold install, all five rungs PASS,
  ending in the CUDA proof.
* [`uninstall-reinstall.log`](uninstall-reinstall.log) — uninstall reverts from
  the manifest, `runc` still works, reinstall PASSES.
* [`idempotence-third-run.log`](idempotence-third-run.log) — a third run:
  **zero `CHANGED` lines**, all checks PASS.

## What this does NOT establish

* **The open kernel module was not exercised here.** This host is proprietary
  575.51.03. The two-component *open* format (595.84) is covered only by the
  fixture test, not by a live preflight on such a host.
* **Multi-GPU device selection under daemon CDI.** One GPU. The index-mapping
  branch (`--gpus '"device=1"'` reaching a daemon-CDI spec) is unit-tested only.
* **`/var/run/nvidia-fabricmanager/socket` and `/tmp/nvidia-mps`** were never
  present. They are handled by the same `st_mode` classifier as the
  persistenced socket, and covered by the self-test against real sockets and
  FIFOs, but no host has emitted them into a spec here.
* **Kubernetes / CRI**, as ever, untested.
