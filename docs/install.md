# Installing nvkvm-kata

**What you get:** a second container runtime on the host, selected *per
container*, that runs the workload in a Kata Containers VM with an NVIDIA GPU
reached through [nvkvm](https://github.com/reindertpelsma/nvkvm-pv) instead of
VFIO passthrough. Stock Kata and `runc` keep working, unchanged, side by side.

```yaml
services:
  cuda:
    image: ubuntu:24.04
    runtime: nvkvm-kata            # <- this is the whole user-facing surface
    environment:
      VISIBLE_CDI_DEVICES: nvidia.com/gpu=0
      LD_LIBRARY_PATH: /usr/local/nvidia/lib
    volumes:
      - /opt/nvkvm-kata/nvidia/lib:/usr/local/nvidia/lib:ro
```

There are two ways to install it, and **both are first-class**:

| | |
|---|---|
| **[the script](#the-script)** | `sudo scripts/nvkvm-kata-install.sh --install-kata --install-deps` |
| **[by hand](#0-preflight)** | §0–§8 below. The script's stages are these sections, one for one; it runs the same commands. |

The script is a convenience over the manual steps, not a replacement for them.
If the two ever disagree, **this document is right** — the script has a
[stage ↔ section table](#stage--section) and every stage names the section it
implements in its own output.

Read [07 — End to end](design/07-end-to-end.md) first if you want to know *why*
each step exists. This document is the recipe; that one is the evidence.

### Where this has been run

| host | GPU | driver | OS | result |
|---|---|---|---|---|
| rented box | RTX 3090 | proprietary module | — | all 8 stages, `VECADD OK` — [07](design/07-end-to-end.md) |
| a physical desktop | RTX 4070 | **595.84, open module** | Ubuntu 26.04, containerd 2.3.3, docker 29.7.2 | all 8 stages, `VECADD OK`, 2026-08-28 |

The second host cost two fixes, both in the script and both recorded below
([§0](#0-preflight), [§2](#2-nvkvms-qemu)). It also ran the proof **while a
second, unrelated nvkvm VM was live on the same GPU** — the container completed
and the other VM kept rendering. One data point, not a concurrency guarantee.

---

## What it will do to your host

Everything, exhaustively. There is no other list.

| path | what |
|---|---|
| `/opt/qemu-nvkvm/` | nvkvm's QEMU (built by `nvkvm-pv/scripts/build_qemu.sh`, which owns this path) |
| `/opt/nvkvm-kata/` | the shim, the guest kernel, the guest rootfs image, the host driver library bundle, `vecadd` |
| `/etc/nvkvm-kata/shim.env` | the shim's environment — **not** a `containerd.service` drop-in |
| `/etc/kata-containers/configuration-nvkvm.toml` | the second Kata configuration |
| `/usr/local/bin/containerd-shim-nvkvm-kata-v2` | the containerd shim wrapper: 3 lines, execs Kata's real shim |
| `/etc/docker/daemon.json` | **modified** — one key added under `runtimes` |
| `/etc/containerd/config.toml` | **modified, only with `--containerd-cri`** — one marker-delimited block appended |
| `/var/lib/nvkvm-kata/` | build artifacts, backups of every modified file, and the install manifest |
| `/opt/kata/`, `/usr/local/bin/containerd-shim-kata-v2`, `/etc/kata-containers/configuration.toml` | only if **absent** and `--install-kata` was given |

**Not touched:** the stock `/etc/kata-containers/configuration.toml`, the stock
`containerd-shim-kata-v2`, `runc`, `containerd.service`, the NVIDIA driver, and
the GPU's PCI binding.

Revert with [`scripts/nvkvm-kata-uninstall.sh`](#uninstall).

---

## The script

```bash
git clone https://github.com/reindertpelsma/nvkvm-kata
cd nvkvm-kata
sudo scripts/nvkvm-kata-install.sh --install-kata --install-deps
```

It ends by **running the proof** — a CUDA vector-add, in a container, on the new
runtime — and fails loudly if that does not print `VECADD OK`. Installed-but-
broken is not reported as success.

Useful flags:

```
--nvkvm-src DIR      nvkvm-pv checkout (default: clone one)
--kata-src DIR       kata-containers source (default: clone one)
--artifacts DIR      build output       (default /var/lib/nvkvm-kata/build)
--prefix DIR         install prefix     (default /opt/nvkvm-kata)
--runtime-name NAME  what compose says  (default nvkvm-kata)
--graphics 0|1       NVKVM_GRAPHICS     (default 0 = compute-only)
--containerd-cri     also register a CRI runtime handler, for Kubernetes
--no-docker          do not touch /etc/docker/daemon.json
--only STAGE         run one stage; --build / --install / --verify are groups
--force              rebuild even when the artifact stamp matches
```

Every stage is **idempotent**: it checks first, acts only if the host is wrong,
and logs what it changed. Running the script twice converges; it does not
duplicate. A second run with nothing to do takes about as long as the
verification container.

### Build and install are separable

`--build` (stages 2–4) writes only into `--artifacts` and `/opt/qemu-nvkvm`.
`--install` (stages 1, 5–7) reads from there and touches the host. So:

```bash
# on a build host
sudo scripts/nvkvm-kata-install.sh --build --artifacts /tmp/art
tar caf nvkvm-kata-artifacts.tar.zst -C /tmp/art .

# on the target
sudo scripts/nvkvm-kata-install.sh --install --verify --artifacts /tmp/art
```

That is deliberate: **a prebuilt tarball, later, is nothing but a cached build
stage.** No prebuilt artifacts are designed for or shipped yet, and the split
above is the whole preparation for them.
UNVERIFIED: the tarball round-trip has not been run; only same-host
`--build` then `--install` has.

### Stage ↔ section

| stage | section | group |
|---|---|---|
| 0 `preflight` | [§0](#0-preflight) | always |
| 1 `kata` | [§1](#1-kata-containers) | install |
| 2 `qemu` | [§2](#2-nvkvms-qemu) | build |
| 3 `kernel` | [§3](#3-the-guest-kernel-and-nvkvm-guestko) | build |
| 4 `rootfs` | [§4](#4-the-guest-rootfs) | build |
| 5 `runtime` | [§5](#5-the-shim-and-a-second-kata-configuration) | install |
| 6 `engine` | [§6](#6-registering-the-runtime-with-the-container-engine) | install |
| 7 `libs` | [§7](#7-the-host-drivers-userspace) | install |
| 8 `verify` | [§8](#8-verify-by-running-the-proof) | verify |

---

# The manual path

Each section below is one stage. Run them in order. Everything here was run by
hand before it was scripted — [07 §10](design/07-end-to-end.md#10-reproducing-it)
is the shorter, transcript-style version of the same sequence.

## 0. Preflight

Check these **before** building anything. Each one, skipped, fails much later
and much less legibly.

```bash
ls -l /dev/kvm                      # must exist.  See below.
systemd-detect-virt                 # kvm or none.  "docker" means you rented a container.
cat /proc/driver/nvidia/version     # the host driver.  nvkvm forwards to it.
stat -fc %T /sys/fs/cgroup          # cgroup2fs
containerd --version                # required
docker version -f '{{.Server.Version}}'   # >= 23.0 for the per-container selection below
df -h /var/lib                      # >= 40 GB free
```

- **`/dev/kvm` is the one that ends the attempt.** CPU `vmx`/`svm` flags in
  `/proc/cpuinfo` prove nothing — a container inherits its host's flags. Test
  the device node.
- **The open kernel module writes a different banner**, and anything that
  scrapes a version out of it must cope with both:

  ```
  proprietary:  NVIDIA UNIX x86_64 Kernel Module  580.95.05  Release Build ...
  open:         NVIDIA UNIX Open Kernel Module for x86_64  595.84  Release Build ...
  ```

  The arch moves from *before* "Kernel Module" to *after* it, so a pattern
  anchored on `Kernel Module *<digits>` matches the first line and not the
  second. MEASURED: that is exactly how the installer's preflight died on the
  first open-module host it met. Take the first version-shaped field on the
  line, or ask `nvidia-smi --query-gpu=driver_version`.
- **`docker` older than 23.0** cannot map a named runtime onto a containerd
  shim (`runtimeType` in `daemon.json` landed in 23.0). The containerd path
  still works; the compose-file path does not. Upgrade Docker.
- **On cgroup v2, the container's device cgroup is not enforced inside the
  guest** — `kata-agent` computes the allowlist and `cgroups-rs 0.5.1` discards
  it ([07 §8.1](design/07-end-to-end.md#81-finding-the-containers-device-cgroup-is-not-enforced-in-the-guest)).
  `VISIBLE_CDI_DEVICES` decides which device *nodes are created for you*; it is
  **not** an access boundary. Know this before you deploy anything multi-tenant.

Build dependencies (Ubuntu/Debian):

```bash
apt-get install -y build-essential git flex bison bc cpio curl zstd kmod \
                   mount python3 patch file binutils gzip \
                   libssl-dev libelf-dev linux-libc-dev docker.io
```

QEMU has its own longer list; `build_qemu.sh --install-deps` in §2 installs it.

Kata's `build-kernel.sh` also needs **`yq`** — and specifically
[mikefarah/yq](https://github.com/mikefarah/yq) v4, not the Python one — to read
`versions.yaml`. Without it §3 dies with `ERROR: yq command is not in your
$PATH`, and it dies *after* the QEMU build if you have not checked first:

```bash
command -v yq || ( cd /root/kata-containers && INSTALL_IN_GOPATH=false ./ci/install_yq.sh )
```

Kata ships that installer and it pins the version Kata expects; use it rather
than a distro package.

## 1. Kata Containers

**Both tarballs.** `kata-static` carries the guest assets and the VMMs;
`kata-go-static` carries `containerd-shim-kata-v2` and the configuration files.
Installing only the first leaves `configuration.toml` a **dangling symlink** and
no shim — a failure that reads as "Kata is installed" right up until nothing
starts.

```bash
V=4.1.0
for a in kata-static kata-go-static; do
  curl -fsSL -o /tmp/$a.tar.zst \
    https://github.com/kata-containers/kata-containers/releases/download/$V/$a-$V-amd64.tar.zst
  tar -I zstd -xf /tmp/$a.tar.zst -C /
done
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
mkdir -p /etc/kata-containers
cp "$(readlink -f /opt/kata/share/defaults/kata-containers/configuration-qemu.toml)" \
   /etc/kata-containers/configuration.toml
```

Check it: `ctr run --rm --runtime io.containerd.kata.v2 docker.io/library/ubuntu:24.04 k uname -r`
should print Kata's own guest kernel version. Get stock Kata working **before**
adding nvkvm; otherwise the first failure has two possible causes.

## 2. nvkvm's QEMU

Kata generates the whole QEMU command line itself and has no key for an
arbitrary `-device`, so nvkvm needs its own QEMU *and* the shim in §5.

```bash
git clone https://github.com/reindertpelsma/nvkvm-pv /root/nvkvm-pv
bash /root/nvkvm-pv/scripts/build_qemu.sh --install-deps
/opt/qemu-nvkvm/bin/qemu-system-x86_64 -device help | grep nvgpu   # expect 4 lines
```

**Assert the last line.** A QEMU that builds but has no `virtio-nvgpu` produces
a VM that boots perfectly and has no GPU, and nothing in the logs says why.

**If `/opt/qemu-nvkvm` already exists, find out what put it there before you
reuse it.** `build_qemu.sh` skips the build when that path is populated, so an
nvkvm QEMU left behind by *some other* nvkvm-pv checkout is silently adopted —
and the guest module in §3 is built from *your* checkout. The device ABI is
shared between the two halves, so two checkouts that disagree about
`src/abi/nvgpu.h` give you a VM that boots, loads the module, and misbehaves
later for reasons that look like driver bugs. On the 2026-08-28 host,
`/opt/qemu-nvkvm` held a 9.2.0 build from a divergent lineage, so the install
built its own into a separate prefix and left the existing one alone:

```bash
NVKVM_QEMU_PREFIX=/opt/qemu-nvkvm-kata NVKVM_QEMU_SRC=/root/qemu-src-nvkvm-kata \
  bash /root/nvkvm-pv/scripts/build_qemu.sh --install-deps
sudo scripts/nvkvm-kata-install.sh --qemu /opt/qemu-nvkvm-kata/bin/qemu-system-x86_64 ...
```

`--qemu` is written into `/etc/nvkvm-kata/shim.env` by [§5b](#5b-the-shims-environment),
so it has to be passed on **every** invocation that runs the `runtime` stage,
not only the one that builds. (The script used to honour it only when the
`qemu` stage itself ran; `--only runtime --qemu …` then wrote the *default*
path into `shim.env` — a VM that boots on the wrong hypervisor and says
nothing. Fixed.)

## 3. The guest kernel and `nvkvm-guest.ko`

```bash
git clone --depth 1 https://github.com/kata-containers/kata-containers /root/kata-containers
scripts/build-guest-kernel.sh \
    --kata-src /root/kata-containers --nvkvm-src /root/nvkvm-pv \
    --out /var/lib/nvkvm-kata/build --graphics 0
```

Two things in that script are the whole reason it exists:

1. **The one upstream change in this project.** `build-kernel.sh` validates its
   `-g` vendor argument against `{intel, nvidia}` at
   `tools/packaging/kernel/build-kernel.sh:652`. Accepting `nvkvm` as a third
   value is the entire delta; the script applies it with a guarded `sed` that
   doubles as a check that upstream's text has not moved. `-g nvidia` is the
   close precedent — the NVIDIA path already does everything else this needs.
2. **`depmod`.** *Neither `build-kernel.sh` nor `rootfs.sh` runs it.* The module
   lands, and `modprobe nvkvm-guest` then fails with a message that names the
   **module** and not the missing index, sending you to look in the wrong place.
   The script runs `depmod -a -b <modroot> <release>` and then **asserts
   `modules.dep` mentions the module** — because `depmod` exits 0 on a tree it
   indexed to nothing.

   Upstream already solved this on the NVIDIA path
   (`tools/osbuilder/rootfs-builder/nvidia/nvidia_rootfs.sh:709-716`); the gap
   is that none of it is in the generic path. See
   [04](design/04-guest-kernel.md) and [07 §8.3](design/07-end-to-end.md#83-correction-to-04-upstreams-nvidia-rootfs-already-runs-depmod).

`--graphics 0` is compute-only and keeps the config fragment to three lines.
`--graphics 1` exists and is **UNVERIFIED** — never built, never booted.

Output: `vmlinuz-<release>`, `modules/lib/modules/<release>/…` with a valid
`modules.dep`, and a one-line `release` file.

## 4. The guest rootfs

**Work on a copy.** Never edit the shipped image in place: the copy is what
makes this step re-runnable.

```bash
A=/var/lib/nvkvm-kata/build
cp "$(readlink -f /opt/kata/share/kata-containers/kata-ubuntu-noble.image)" $A/kata-nvkvm.image
```

### 4a. kmod and the guest-side CDI generator

```bash
scripts/prepare-guest-rootfs.sh --image $A/kata-nvkvm.image
```

**Kata's shipped generic rootfs cannot load a kernel module at all.**
`kernel_modules = [...]` shells out to `/sbin/modprobe`
(`src/agent/src/rpc.rs:124`), and `kata-containers.img` 4.1.0 ships no
`modprobe`, no `kmod`, no `busybox` and no `/lib/modules`. The shipped mechanism
cannot run on the shipped image. This script harvests `kmod` from the guest's
*own* distro release, so glibc and libcrypto symbol versions match by
construction.

**The usrmerge trap, which costs a build cycle:** Ubuntu noble's `/sbin` is
itself a symlink to `usr/sbin`, so `ln -s ../usr/bin/kmod $rootfs/sbin/modprobe`
resolves to `$rootfs/usr/usr/bin/kmod` — dangling. The symptom is *byte
identical* to having no modprobe at all: `No such file or directory (os error
2)`, with a 21-frame backtrace of `<unknown>` and no mention of modprobe,
modules, or the module name. Use **absolute** link targets, for the same reason
`nvidia_rootfs.sh:838-841` gives.

The same script installs `/usr/local/bin/nvkvm-guest-cdi-gen` and a
`modprobe.d` `install` directive that fires it when the agent modprobes the
module. The spec **must** be generated after boot: kata-agent reads
`/var/run/cdi` *in the guest*, and mounts a fresh tmpfs on `/run` during init,
so anything baked into the image at that path is invisible.

### 4b. the module and a valid `modules.dep`

```bash
scripts/inject-guest-modules.sh --image $A/kata-nvkvm.image \
    --modules $A/modules --release "$(cat $A/release)"
```

Runs `depmod -a -b` *inside the rootfs it just wrote* and asserts the result.

## 5. The shim and a second Kata configuration

This is where per-container selection is actually built.

### 5a. the shim

```bash
install -D -m0755 scripts/nvkvm-qemu-shim.sh /opt/nvkvm-kata/bin/nvkvm-qemu-shim
install -D -m0644 $A/vmlinuz-$(cat $A/release) /opt/nvkvm-kata/share/vmlinuz-$(cat $A/release)
install -D -m0644 $A/kata-nvkvm.image          /opt/nvkvm-kata/share/kata-nvkvm.image
```

The shim appends `-device virtio-nvgpu-pci-non-transitional,id=nvkvm0` and
`exec()`s the real QEMU. `exec` preserves the pid (so Kata's cgroup placement,
its wait and its SIGKILL all still land on the right process), preserves
inherited fds (Kata passes the QMP socket as `-qmp unix:fd=3`; closing it kills
the VM instantly), and preserves QEMU's data-directory lookup (QEMU finds it
from `/proc/self/exe`). All three were verified, not assumed —
[07 §2](design/07-end-to-end.md#why-a-shim-at-all-and-why-exec-is-safe).

### 5b. the shim's environment

```bash
mkdir -p /etc/nvkvm-kata
printf 'NVKVM_QEMU=/opt/qemu-nvkvm/bin/qemu-system-x86_64\n' > /etc/nvkvm-kata/shim.env
```

[07](design/07-end-to-end.md) passed `NVKVM_EXTRA_ARGS` through a **systemd
drop-in on `containerd.service`**. Do not do that here. A drop-in is *global* —
it applies to every runtime on the host — and it is awkward to revert. It is
also unnecessary: the shim already defaults to exactly the device we want, and
this file is read **only by the shim**, which runs **only for the nvkvm-kata
configuration**. Already-set environment still wins, so a drop-in remains
available if you want one.

### 5c. the second configuration

Copy `/etc/kata-containers/configuration.toml` to
`/etc/kata-containers/configuration-nvkvm.toml` and change exactly these keys:

```toml
[hypervisor.qemu]
path   = "/opt/nvkvm-kata/bin/nvkvm-qemu-shim"          # the shim, not QEMU
kernel = "/opt/nvkvm-kata/share/vmlinuz-<release>"
image  = "/opt/nvkvm-kata/share/kata-nvkvm.image"
kernel_params = "<whatever was there> agent.visible_cdi_devices=true"
valid_hypervisor_paths = [ ..., "/opt/nvkvm-kata/bin/nvkvm-qemu-shim" ]

[agent.kata]
kernel_modules = ["nvkvm-guest"]
```

(and comment out `initrd` if your template sets it — `image` and `initrd` are
mutually exclusive.)

**`path` is not checked against `valid_hypervisor_paths`.** That list is
consulted only for the `io.katacontainers.config.hypervisor.path` *annotation*
(`src/runtime/virtcontainers/hypervisor.go:590`, parsed at
`src/runtime/pkg/katautils/config.go:114`). Setting `path` directly needs no
allowlist entry. Add it anyway, so per-pod annotation selection works later.

The script derives this file with `scripts/lib/kata-conf-edit.py`, which edits
*lines* rather than round-tripping through a TOML parser — Kata's
`configuration.toml` is ~90% comment and every comment is load-bearing for
whoever reads the file next.

### 5d. the containerd shim wrapper — half one of the selection mechanism

```bash
cat > /usr/local/bin/containerd-shim-nvkvm-kata-v2 <<'EOF'
#!/bin/sh
exec env KATA_CONF_FILE=/etc/kata-containers/configuration-nvkvm.toml \
     /opt/kata/bin/containerd-shim-kata-v2 "$@"
EOF
chmod 0755 /usr/local/bin/containerd-shim-nvkvm-kata-v2
```

Why a new binary at all: containerd derives a shim **binary name** from a
runtime **type** by the fixed rule `io.containerd.<NAME>.v2` →
`containerd-shim-<NAME>-v2`, looked up on containerd's own `PATH`. So
"register a new runtime" means "provide a new binary name", and the binary can
be a wrapper around Kata's real shim. `kata-deploy` generates exactly this
wrapper for `kata-qemu`, `kata-clh` and the rest.

**But `KATA_CONF_FILE` is no longer how the configuration gets chosen, and this
is the one place where the older Kata documentation — and kata-deploy's own
idiom — will lead you wrong.** MEASURED on Kata 4.1.0:

```
$ docker run --rm --runtime nvkvm-kata ubuntu:24.04 uname -r
docker: Error response from daemon: failed to create task for container:
failed to create shim task: invalid KATA_CONF_FILE
"/etc/kata-containers/configuration-nvkvm.toml":
only shipped Kata configuration files are accepted: unknown
```

The shim's `loadRuntimeConfig`
(`src/runtime/pkg/containerd-shim-v2/create.go:273`) takes the configuration
path from, in order:

1. **the shim-v2 create-task `ConfigPath` runtime option** — *not validated*;
2. the `KATA_CONF_FILE` environment variable — **validated**, by
   `isShippedKataConfigPath` (same file, `:325`), which resolves the path and
   compares it against `katautils.GetDefaultConfigFilePaths()`
   (`pkg/katautils/config.go:2229`). That list has exactly two entries —
   `/etc/kata-containers/configuration.toml` and
   `/opt/kata/share/defaults/kata-containers/configuration.toml` — so **no
   second configuration can ever be selected through the environment.**

So the wrapper above is not the selecting half; [§6](#6-registering-the-runtime-with-the-container-engine)
is. **Set `KATA_CONF_FILE` anyway.** Without it, a caller that forgets the
`ConfigPath` option silently gets the *stock* configuration — a container that
boots perfectly, on Kata's own kernel, with no GPU and no error. With it, that
caller gets the one-line error above, naming the file. Wrong-and-loud beats
wrong-and-silent. MEASURED both ways:

```
# ctr WITHOUT --runtime-config-path  -> the loud error above
# ctr WITH    --runtime-config-path  -> VECADD OK
```

Nothing global changed either way: the stock shim, the stock configuration and
`runc` are all still there, and a container that does not ask for `nvkvm-kata`
cannot reach any of this.

## 6. Registering the runtime with the container engine

**This is where the configuration actually gets selected** — see
[§5d](#5d-the-containerd-shim-wrapper--half-one-of-the-selection-mechanism) for
why it is not `KATA_CONF_FILE`. Every form below carries the same one key:
`ConfigPath`.

### 6a. containerd, bare — one flag, no configuration

```bash
ctr run --rm --runtime io.containerd.nvkvm-kata.v2 \
    --runtime-config-path /etc/kata-containers/configuration-nvkvm.toml \
    docker.io/library/ubuntu:24.04 t uname -r          # -> 6.18.35-nvkvm
```

`ctr` resolves the binary off containerd's `PATH`; `--runtime-config-path` is
the `ConfigPath` runtime option. **Omit the flag and you get the error from
§5d**, which is the intended behaviour — not a silent stock boot.

### 6b. Docker — one key in `daemon.json`  ← what `runtime:` in compose reads

```json
{
  "runtimes": {
    "nvkvm-kata": {
      "runtimeType": "io.containerd.nvkvm-kata.v2",
      "options": { "ConfigPath": "/etc/kata-containers/configuration-nvkvm.toml" }
    }
  }
}
```

then `systemctl reload docker`. `docker info` should list `nvkvm-kata`.

**`options` is load-bearing, not decoration.** Docker forwards it to the shim
as containerd's runtime options, which is the unvalidated path Kata reads
first. Without it the runtime resolves, the shim starts, and then refuses with
the §5d error.

Requires Docker **≥ 23.0** — older daemons only understand `{"path": ...}` OCI
runtimes and cannot express a containerd shim at all. Docker does not use
containerd's CRI plugin, so **no containerd configuration change is needed for
the Docker path**; §6c is for Kubernetes only.

Now `docker run --runtime nvkvm-kata …` and `runtime: nvkvm-kata` in a compose
file both work, and `runc` remains the default for everything else. MEASURED,
same host, same compose file, one line apart:

```
services.cuda    (runtime: nvkvm-kata)  -> VECADD OK, RTX 3090, guest 6.18.35-nvkvm
services.control (default runtime)      -> 6.8.0-59-generic, no /dev/nvidia* (expected)
```

### 6c. containerd CRI handler — for Kubernetes

Only needed if a kubelet talks to containerd's CRI plugin. Append to
`/etc/containerd/config.toml` (the plugin id is `io.containerd.grpc.v1.cri` on
containerd 1.x, `io.containerd.cri.v1.runtime` on 2.x):

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvkvm-kata]
  runtime_type = "io.containerd.nvkvm-kata.v2"
  privileged_without_host_devices = true
  pod_annotations = ["io.katacontainers.*"]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvkvm-kata.options]
    ConfigPath = "/etc/kata-containers/configuration-nvkvm.toml"
```

`systemctl restart containerd`, then `runtimeClassName: nvkvm-kata` in a pod
spec. The script does this only with `--containerd-cri`, wraps the block in
`# >>> nvkvm-kata >>>` markers, and reverts it automatically if containerd does
not come back.

**Check `disabled_plugins` first.** The containerd that ships with Docker sets
`disabled_plugins = ["cri"]`, so this stanza parses, containerd restarts
happily, and *nothing reads it*. The installer warns when it sees that.

**UNVERIFIED: no Kubernetes was involved in any of this.** The block was
written, containerd parsed it and restarted cleanly — that is all that was
established. No kubelet, no CRI, no device plugin, no scheduler, no
`RuntimeClass` object. See
[07 §11 item 3](design/07-end-to-end.md#11-what-is-still-not-done).

## 7. The host driver's userspace

The container needs NVIDIA userspace **version-matched to the host driver**,
because the host driver is what services every forwarded ioctl. That falls out
of the architecture: no version-matching machinery is needed, but the libraries
do have to get in there.

```bash
bash /root/nvkvm-pv/scripts/make_host_bundle.sh /var/lib/nvkvm-kata
cp -a /var/lib/nvkvm-kata/host-libs-<version>/. /opt/nvkvm-kata/nvidia/lib/
cd /opt/nvkvm-kata/nvidia/lib && for f in *.so.*; do
    so=$(objdump -p "$f" | awk '/SONAME/{print $2}')
    [ -n "$so" ] && ln -sf "$f" "$so"
done
gcc -O2 -o /opt/nvkvm-kata/nvidia/bin/vecadd scripts/e2e/vecadd.c -ldl
```

**The SONAME links are not optional.** Kata drops CDI's hooks
(kata#11169), so *nothing* runs `ldconfig` inside the container:
`libcuda.so.1` has to exist as a name on disk or every
`dlopen("libcuda.so.1")` fails. The versioned symlink chain does survive
virtio-fs — verified in [07 §6](design/07-end-to-end.md#6-rung-4--nvidia-smi).

This is an **install** step, not a build step: the bundle is host-specific by
construction, and the NVIDIA libraries are not redistributable, so no prebuilt
artifact can ever carry it.

## 8. Verify, by running the proof

Not `ls`. Not "the service started". Run the workload.

```bash
docker run --rm --runtime nvkvm-kata \
  -v /opt/nvkvm-kata/nvidia/lib:/usr/local/nvidia/lib:ro \
  -v /opt/nvkvm-kata/nvidia/bin:/usr/local/nvidia/bin:ro \
  -e VISIBLE_CDI_DEVICES=nvidia.com/gpu=0 \
  -e LD_LIBRARY_PATH=/usr/local/nvidia/lib \
  ubuntu:24.04 /usr/local/nvidia/bin/vecadd
```

Expect:

```
devices: 1
device 0: NVIDIA GeForce RTX 3090
elements: 1048576  mismatches: 0  sample: c[7]=21.0 (want 21.0)
VECADD OK
```

`vecadd` checks the arithmetic, because "it ran" and "it computed" are different
claims. It uses the driver API through `dlopen` with embedded PTX, so no CUDA
toolkit is needed on the host or in the image.

Four more checks worth running, and all four are in the script's verify stage:

```bash
# the nvkvm configuration was actually selected, not the stock one
docker run --rm --runtime nvkvm-kata ubuntu:24.04 uname -r      # -> <release>-nvkvm
# the module loaded
docker run --rm --runtime nvkvm-kata ubuntu:24.04 grep nvidia /proc/devices
# runc still works
docker run --rm ubuntu:24.04 /bin/true
# the host never lost the card
nvidia-smi -L ; ls /sys/bus/pci/drivers/nvidia/
```

### When it fails

| symptom | cause |
|---|---|
| `failed to create shim task: No such file or directory (os error 2)` | `/sbin/modprobe` missing or dangling in the guest rootfs — §4a, and the usrmerge trap |
| container starts, `uname -r` is Kata's **stock** kernel | the `ConfigPath` runtime option did not reach the shim — §6. This is the silent failure; §5d's `KATA_CONF_FILE` exists to convert it into the next row |
| `invalid KATA_CONF_FILE …: only shipped Kata configuration files are accepted` | no `ConfigPath` option was passed. Docker: §6b's `options`. `ctr`: `--runtime-config-path`. CRI: §6c |
| no `/dev/nvidia*` in the container | `VISIBLE_CDI_DEVICES` unset, or the guest CDI generator did not run — §4a |
| `cuInit` fails / no `libcuda.so.1` | the SONAME links in §7 |
| VM boots but no `virtio-nvgpu` device | wrong QEMU at `NVKVM_QEMU`, or a QEMU built without nvkvm's patches — §2 |
| `unknown or invalid runtime name` from Docker | Docker < 23.0, or `daemon.json` not reloaded — §6b |

`NVKVM_SHIM_LOG=/var/log/nvkvm-shim.log` in `/etc/nvkvm-kata/shim.env` records
the exact argv the shim exec'd, which settles most of the QEMU-side questions in
one line. `journalctl -t kata` carries the guest console and the agent's errors.

---

## Uninstall

```bash
sudo scripts/nvkvm-kata-uninstall.sh
```

Reverts from `/var/lib/nvkvm-kata/install-manifest`, which the installer wrote
as it went: every file it created is removed, every file it modified is restored
from `/var/lib/nvkvm-kata/backup/`. It removes the engine registrations *first*,
so nothing new can start on the runtime while it works, and it ends by checking
that Docker and `runc` still run a container.

```
--purge         also delete /var/lib/nvkvm-kata (the build artifacts)
--remove-qemu   also delete /opt/qemu-nvkvm  (left alone by default: nvkvm-pv may use it)
--remove-kata   also delete /opt/kata, and only if this installer put it there
```

By hand, the whole reversal is:

```bash
python3 scripts/lib/docker-runtime.py remove --name nvkvm-kata && systemctl reload docker
# if you used --containerd-cri: delete the "# >>> nvkvm-kata >>>" block from
# /etc/containerd/config.toml, then systemctl restart containerd
rm -f /usr/local/bin/containerd-shim-nvkvm-kata-v2
rm -f /etc/kata-containers/configuration-nvkvm.toml
rm -rf /etc/nvkvm-kata /opt/nvkvm-kata
```

Nothing in that list is shared with stock Kata or with `runc`.

---

## What this installer does *not* do

Named here so nobody has to find out the hard way.

1. **Kubernetes is untested.** §6c writes the CRI handler; no kubelet has ever
   used it. No device plugin, no scheduler integration,
   no `RuntimeClass` object is created.
2. **`VISIBLE_CDI_DEVICES` is not an access boundary** on cgroup v2 —
   [07 §8.1](design/07-end-to-end.md#81-finding-the-containers-device-cgroup-is-not-enforced-in-the-guest).
   A container that asks for no GPU can still use one. Do not deploy this
   multi-tenant.
3. **The VMM is not confined.** Kata jails Firecracker and enables Cloud
   Hypervisor's seccomp; its QEMU driver gets neither, and nvkvm is QEMU-only —
   [01 §3](design/01-vmm-confinement.md), [06](design/06-vmm-confinement-design.md).
   The shim is the natural place to add `unshare`/`setpriv`, and that has not
   been done.
4. **No prebuilt artifacts.** Build and install are separable so that they can
   exist later; nothing is cached, signed or published today.
5. **The graphics build** (`--graphics 1`) has never been built or booted.
6. **cgroup v1 is untested.** Entirely.
7. **One GPU, one architecture, one driver** has ever been exercised end to end
   at a time. Nothing here generalises to multi-GPU or to a driver outside
   nvkvm's ABI profiles without being run again.
