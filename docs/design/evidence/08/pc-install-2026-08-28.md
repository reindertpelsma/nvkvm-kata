# nvkvm-kata install on this PC — change log & undo list

Installed 2026-08-28 (~01:07–01:35 CEST) by an agent, at the owner's request.
Recipe followed verbatim: `nvkvm-kata/docs/install.md` §0–§8 (= `docs/design/07-end-to-end.md`).

**RESULT: all five rungs PASS.** `VECADD OK` — a CUDA vector-add ran on the
RTX 4070, inside a container, inside a Kata VM, through nvkvm — *while the
SteamOS VM stayed up and kept rendering frames.*

---

## Baseline recorded BEFORE any change

- Ubuntu 26.04 LTS, kernel 7.0.0-30-generic, 24 cores
- NVIDIA RTX 4070, driver **595.84 (open kernel module)**, `/dev/kvm` present
- containerd v2.3.3 (`disabled_plugins = ["cri"]`), docker 29.7.2, cgroup v2
- **`/etc/docker/daemon.json` DID NOT EXIST** → "restore" means *delete it*
- `/opt/kata`, `/etc/kata-containers` DID NOT EXIST — no Kata installed
- `/opt/qemu-nvkvm` already existed: QEMU **9.2.0**, built 2026-08-24 from
  `/srv/nvkvm-pv` (a *different* nvkvm-pv lineage than `/workspace/nvkvm-pv`).
  **LEFT COMPLETELY UNTOUCHED.** I built a second QEMU elsewhere instead.
- Running: docker compose SteamOS VM at `/opt/nvkvm-steamos-two-container`
  (`nvkvm-steamos-vmm-1`, `-broker-1`, `-audio-1`). **Never stopped, restarted
  or rebuilt.** Verified healthy at the end (see bottom).
- Package list snapshotted: `/root/dpkg-before-kata.txt` (after: `-after-kata.txt`)

---

## EVERYTHING THAT CHANGED ON THIS HOST

### A. Files/dirs created (nothing pre-existing was overwritten)

| path | what | size |
|---|---|---|
| `/opt/kata` | Kata Containers 4.1.0 (`kata-static` + `kata-go-static`) | 3.6 G |
| `/usr/local/bin/containerd-shim-kata-v2` | symlink → `/opt/kata/bin/` | — |
| `/etc/kata-containers/configuration.toml` | **stock** Kata config (untouched by nvkvm) | — |
| `/etc/kata-containers/configuration-nvkvm.toml` | the second, nvkvm config | — |
| `/etc/nvkvm-kata/shim.env` | `NVKVM_QEMU=/opt/qemu-nvkvm-kata/...` + `NVKVM_SHIM_LOG` | — |
| `/usr/local/bin/containerd-shim-nvkvm-kata-v2` | 3-line wrapper around Kata's shim | — |
| `/opt/nvkvm-kata/` | shim, guest kernel, guest rootfs image, driver libs, `vecadd` | 789 M |
| `/opt/qemu-nvkvm-kata/` | **nvkvm's QEMU 11.1.1**, built for this, separate prefix | 466 M |
| `/var/lib/nvkvm-kata/` | build artifacts + backups + `install-manifest` | 3.1 G |
| `/root/qemu-src-nvkvm-kata/` | QEMU 11.1.1 source tree | 1.8 G |
| `/root/kata-containers/` | kata-containers git clone (for `build-kernel.sh`) | 47 M |
| `/root/nvkvm-pv-kata/` | nvkvm-pv @ **main 801dfa0** (QEMU 11.1.1 recipe) | 12 M |
| `/root/nvkvm-kata/` | the nvkvm-kata repo + installer | small |
| `/usr/local/bin/yq` | mikefarah yq v4.44.5, via Kata's own `ci/install_yq.sh` | — |
| `/root/build-qemu-kata.sh`, `/root/build-kernel-kata.sh` + `.log` | my build wrappers | — |
| `/root/nvkvm-pv.tgz`, `/root/nvkvm-kata.tgz` | source tarballs I shipped in | — |

**`/opt/qemu-nvkvm` was deliberately NOT reused and NOT rebuilt.** Two reasons:
it is QEMU 9.2.0 from a divergent nvkvm-pv history (whose `src/abi/nvgpu.h` has
uncommitted local edits), and a guest module must match the QEMU device ABI it
talks to. nvkvm-kata therefore has its own QEMU at `/opt/qemu-nvkvm-kata`,
built from `main` 801dfa0, the same tree the guest module was built from.

### B. Files MODIFIED

| path | change | pre-state |
|---|---|---|
| `/etc/docker/daemon.json` | **created** — one `runtimes.nvkvm-kata` key | **did not exist** |

That is the only modified file. `runc` stays the default; `docker run hello-world`
was re-verified afterwards and works. **`/etc/containerd/config.toml` was NOT
touched** (no `--containerd-cri`; this host has `disabled_plugins = ["cri"]` anyway).

### C. apt packages installed (8)

    bison flex libelf-dev libfl-dev libfl2 libssl-dev libzstd-dev m4

(QEMU's build deps were already present from the SteamOS work.)

### D. NOT touched, explicitly

NVIDIA driver · GPU PCI binding (still `nvidia`, no vfio-pci) · no reboot ·
no firmware change · `/opt/qemu-nvkvm` · `/srv/nvkvm-pv` · the SteamOS compose
stack and its three containers · `containerd.service` (no drop-in) ·
`/etc/containerd/config.toml` · `runc` · the stock Kata config.

---

## UNDO

```bash
# 1. the supported revert — reads /var/lib/nvkvm-kata/install-manifest
sudo /root/nvkvm-kata/scripts/nvkvm-kata-uninstall.sh --purge --remove-kata

# 2. the QEMU this install built (the uninstaller leaves /opt/qemu-nvkvm* alone)
sudo rm -rf /opt/qemu-nvkvm-kata /root/qemu-src-nvkvm-kata

# 3. sources, logs and scratch
sudo rm -rf /root/nvkvm-pv-kata /root/nvkvm-kata /root/kata-containers \
            /root/nvkvm-pv.tgz /root/nvkvm-kata.tgz \
            /root/build-qemu-kata.sh /root/build-kernel-kata.sh \
            /root/build-qemu-kata.log /root/build-kernel-kata.log \
            /root/dpkg-before-kata.txt /root/dpkg-after-kata.txt \
            /root/kata-install-notes.md /usr/local/bin/yq

# 4. the apt packages, only if you want them gone (harmless to keep)
sudo apt-get purge bison flex libelf-dev libfl-dev libfl2 libssl-dev libzstd-dev m4
```

`--remove-kata` is safe **only because this install put `/opt/kata` there** —
the manifest records that. `/etc/docker/daemon.json` is deleted by step 1
(restored from a `.ABSENT` marker) and Docker reloaded.

If you only want to disable the runtime without uninstalling:

```bash
sudo python3 /root/nvkvm-kata/scripts/lib/docker-runtime.py remove --name nvkvm-kata
sudo systemctl reload docker
```

---

## How to use it

```bash
docker run --rm --runtime nvkvm-kata \
  -v /opt/nvkvm-kata/nvidia/lib:/usr/local/nvidia/lib:ro \
  -v /opt/nvkvm-kata/nvidia/bin:/usr/local/nvidia/bin:ro \
  -e VISIBLE_CDI_DEVICES=nvidia.com/gpu=0 \
  -e LD_LIBRARY_PATH=/usr/local/nvidia/lib \
  ubuntu:24.04 /usr/local/nvidia/bin/vecadd        # -> VECADD OK
```

`ctr` equivalent needs `--runtime io.containerd.nvkvm-kata.v2` **and**
`--runtime-config-path /etc/kata-containers/configuration-nvkvm.toml`.
Omitting the config path is a loud error, by design, not a silent stock boot.

Shim argv is logged to `/var/log/nvkvm-shim.log` (I enabled `NVKVM_SHIM_LOG`;
comment it out in `/etc/nvkvm-kata/shim.env` to turn it off).

---

## Results, measured

| rung | result |
|---|---|
| 1 · stock Kata boots | PASS — `ctr --runtime io.containerd.kata.v2` → `uname -r` = `6.18.35` |
| 2 · Kata on nvkvm's QEMU | PASS — `uname -r` = `6.18.35-nvkvm` (nvkvm config selected) |
| 3 · device + module in guest | PASS — `nvkvm_guest 102400 0 - Live` in `/proc/modules` |
| 4 · `/dev/nvidia*` + `nvidia-smi` | PASS — `nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`; `nvidia-smi` reports NVIDIA-SMI 595.84 / RTX 4070 / CUDA 13.2 |
| 5 · `vecadd` on the GPU | PASS — `mismatches: 0`, `VECADD OK` |

Verified through **both** `ctr` and `docker run --runtime nvkvm-kata`.

**Concurrency with the SteamOS VM: works.** The GPU container ran to completion
with the SteamOS VM live; `nvidia-smi` on the host showed both
(`nvkvm_stub` + the desktop's `ptyxis`) and the broker kept serving frames.

### SteamOS VM health at the end
- all three containers `Up`; `broker` and `audio` `RestartCount=0`,
  `vmm` `RestartCount=3` with `StartedAt=22:03Z` — **before** this install began (23:07Z)
- broker log still advancing frames, `clipboard agent present`
- host GPU: driver still bound (`/sys/bus/pci/drivers/nvidia/`), 823 MiB used

---

## Two bugs found and fixed in the installer

Both are in `scripts/nvkvm-kata-install.sh` (fixed here and committed upstream
on branch `pc-install`):

1. **Driver-version parse died on the open kernel module.** The regex anchored
   on `Kernel Module *<digits>`; the open module writes
   `Open Kernel Module for x86_64  595.84`, so preflight aborted with
   "could not parse the driver version". The rented box that proved the recipe
   ran the proprietary module, so this had never been hit.
2. **`--qemu` was only honoured when the `qemu` *stage* ran.** With
   `--only runtime --qemu /opt/qemu-nvkvm-kata/...` the shim env was written
   with the **default** `/opt/qemu-nvkvm/...`. That is the dangerous kind of
   wrong: the VM boots fine, on the wrong hypervisor, with no error.

## UNVERIFIED

- Kubernetes / CRI: not registered, not tested (as upstream documents).
- `--graphics 1`: not built.
- Only one GPU, one driver (595.84), one container at a time was exercised.
- `VISIBLE_CDI_DEVICES` is **not** an access boundary on cgroup v2 — a
  container that asks for no GPU can still reach one. Do not deploy multi-tenant.
- The nvkvm VMM is not confined (no seccomp/jail on Kata's QEMU path).
- Long-running / heavy CUDA workloads: only a 1 Mi-element vector-add was run.
