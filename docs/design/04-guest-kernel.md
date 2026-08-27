# 04 — The guest kernel

Citations against `kata-containers/kata-containers` @ **`f62ecce`**, cloned
2026-08-27, and `nvkvm-pv` as checked out locally.

---

## What has to be true

`nvkvm-guest.ko` must be loaded in the Kata guest before the first container
that wants a GPU is created. It is an out-of-tree GPL module, ~7.6 kLoC, built
against the guest kernel's headers
(`nvkvm-pv/docs/reference/guest-kernels.md`). Building it inside the VM at boot
is not acceptable — it would need a toolchain and headers in the guest image and
would add tens of seconds to every sandbox start.

Two build-time properties of the module matter for kernel configuration:

- **it is a module**, so the guest kernel needs `CONFIG_MODULES=y`;
- **the default build (`NVKVM_GRAPHICS=1`) registers a real DRM device**
  (`nvkvm-pv/src/guest/nvkvm_drm.c`), because the NVIDIA Vulkan ICD enumerates
  through `/dev/dri/renderD128` and requires the DRM core's major 226 and the
  matching sysfs tree. That needs `CONFIG_DRM`. The compute-only build
  (`NVKVM_GRAPHICS=0`) drops `nvkvm_drm.o`/`nvkvm_kms.o` entirely and needs no
  DRM. **This project's scope is compute plus headless graphics**, so
  `NVKVM_GRAPHICS=1` and `CONFIG_DRM` are in scope — but starting with the
  compute-only build removes a config dependency and a large chunk of attack
  surface from the first milestone.

The module also needs the guest's virtio-pci support, which Kata already has
(`tools/packaging/kernel/configs/fragments/common/virtio.conf`:
`CONFIG_VIRTIO_PCI=y`, `CONFIG_VIRTIO_PCI_LEGACY=y`, `CONFIG_PCI_MSI=y`).

---

## How Kata builds its guest kernel

`tools/packaging/kernel/build-kernel.sh`, subcommands `setup`, `build`,
`build-headers`, `install`. Relevant flags:

| flag | meaning |
|---|---|
| `-v <version>` | kernel version; otherwise from `versions.yaml` `.assets.kernel.version` |
| `-g <vendor>` | **GPU vendor: `intel` or `nvidia`** — validated against `VENDOR_INTEL`/`VENDOR_NVIDIA` |
| `-H <deb\|rpm>` | build a Linux **headers** package |
| `-b <type>`, `-x`, `-m`, `-p <dir>` | build type, confidential guest, measured rootfs, extra patches |

Config fragments live under `tools/packaging/kernel/configs/fragments/`:
`common/`, `<arch>/`, `build-type/`, `debug/`, and **`gpu/`**. `get_kernel_frag_path()`
assembles the list and merges with the kernel's own
`scripts/kconfig/merge_config.sh -r -n`, then `make oldconfig`, validating the
result against `configs/fragments/whitelist.conf`.

The build directory name carries `kata_config_version` (a one-line file) as a
cache-busting suffix.

### `-g nvidia` is the precedent, and it is a close one

`gpu/nvidia.x86_64.conf.in`, verbatim:

```
CONFIG_PCI_MMCONFIG=y
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_FW_LOADER=y
CONFIG_LOCALVERSION="-nvidia-gpu${CONF_GUEST_SUFFIX}"
CONFIG_X86_MCE=y
CONFIG_ARCH_SUPPORTS_MEMORY_FAILURE=y
CONFIG_X86_SUPPORTS_MEMORY_FAILURE=y
CONFIG_MEMORY_FAILURE=y
CONFIG_MTRR=y
CONFIG_X86_PAT=y
CONFIG_CRYPTO_ECC=y
CONFIG_CRYPTO_ECDH=y
CONFIG_CRYPTO_ECDSA=y
CONFIG_MODULE_SIG=y
```

Two things follow immediately.

**`CONFIG_MODULES=y` is turned on *by this fragment*.** It is not in
`common/base.conf`. Kata's stock guest kernel is essentially monolithic; module
support is an opt-in for the GPU use case. So any nvkvm fragment must set it
too, and a plain Kata kernel cannot load `nvkvm-guest.ko` at all.

**`CONFIG_DRM` appears nowhere.** Not in `common/`, not in the GPU fragment —
VFIO passthrough does not need the guest DRM core, because NVIDIA's own
`nvidia-drm.ko` provides what it needs. nvkvm's graphics build *does* need the
kernel DRM core to claim major 226. **An nvkvm fragment must add `CONFIG_DRM`
(and its dependencies) — this is a real delta from the existing GPU fragment and
should not be assumed to be a one-liner.**
**UNVERIFIED:** the exact minimum `CONFIG_DRM*` set and how much it costs in
kernel size and boot time. Settle by building both variants and comparing
`vmlinuz` size and boot-to-agent time.

And `build-kernel.sh` **already builds an out-of-tree NVIDIA module against its
own kernel**:

```bash
if [[ "${gpu_vendor}" == "${VENDOR_NVIDIA}" ]]; then
    make -C "${kernel_path}" -j "$(nproc)" INSTALL_MOD_STRIP=1 \
        INSTALL_MOD_PATH="${kernel_path}" modules_install
    pushd open-gpu-kernel-modules
    make -j "$(nproc)" CC=gcc SYSSRC="${kernel_path}" > /dev/null
    make INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="${kernel_path}" -j "$(nproc)" \
        CC=gcc SYSSRC="${kernel_path}" modules_install
    make -j "$(nproc)" CC=gcc SYSSRC="${kernel_path}" clean > /dev/null
fi
```

with the source fetched in `setup_kernel` from `versions.yaml`
`.externals.nvidia.driver.{version,url}`.

**This is the shape we want, with `src/guest/` substituted for
`open-gpu-kernel-modules`.** nvkvm's own `src/guest/Makefile` already takes
`KDIR`, which maps onto NVIDIA's `SYSSRC` idiom directly.

### Headers are available

`build_kernel_headers()` runs `make bindeb-pkg` or `make rpm-pkg`, producing a
standard `linux-headers-<version>` package with Kbuild scripts, `.config` and
`Module.symvers` — everything an out-of-tree build needs. The static-build
wrapper `tools/packaging/static-build/kernel/build.sh` calls `setup`, `build`,
`install` **and** `build-headers`, so the CI kernel pipeline already produces
one.

**UNVERIFIED:** whether the *published* `kata-static-kernel-*.tar.xz` bundles
that headers package or whether it is a CI-only side artifact. Settle by
downloading one release tarball and `tar tf`-ing it. This decides whether a
DKMS-style approach is even possible for someone consuming Kata binaries rather
than building them.

---

## Getting the `.ko` into the rootfs

`tools/osbuilder/rootfs-builder/rootfs.sh` has a first-class hook:

```
KERNEL_MODULES_DIR=${KERNEL_MODULES_DIR:-""}
...
copy_kernel_modules()
{
    local module_dir="$1" rootfs_dir="$2"
    local dest_dir="${rootfs_dir}/lib/modules"
    info "Copy kernel modules from ${KERNEL_MODULES_DIR}"
    mkdir -p "${dest_dir}"
    cp -a "${KERNEL_MODULES_DIR}" "${dest_dir}/"
```

**Neither `build-kernel.sh` nor `rootfs.sh` runs `depmod`.** That is a real gap
and a classic silent failure: `modprobe` will report the module as not found
with no indication that the problem is a missing `modules.dep`. The rootfs
assembly step must run `depmod -a -b <rootfs> <kernelrelease>` itself.

---

## Loading it

Kata has a shipped mechanism, and it is the right one.

`configuration.toml`:

```toml
# Comma separated list of kernel modules and their parameters.
# These modules will be loaded in the guest kernel using modprobe(8).
kernel_modules = []
```

Wire format, `src/libs/protocols/protos/agent.proto`:

```proto
message KernelModule {
    string name = 1;
    repeated string parameters = 2;
}
```
carried as `repeated KernelModule kernel_modules = 7;` in `CreateSandboxRequest`.

Agent side, `src/agent/src/rpc.rs`:

```rust
for m in req.kernel_modules.iter() {
    load_kernel_module(m).map_ttrpc_err(same)?;
}
```
with `const MODPROBE_PATH: &str = "/sbin/modprobe";` and `load_kernel_module`
invoking `modprobe -v <name> <params...>`. Failure fails sandbox creation, which
is the correct behaviour — a GPU sandbox without the module is not usable.

Per-pod override: the annotation `io.katacontainers.config.agent.kernel_modules`
(semicolon-separated), constant `KernelModules` in
`src/runtime/virtcontainers/pkg/annotations/annotations.go`. Documented in
`docs/how-to/how-to-load-kernel-modules-with-kata.md`.

**Timing:** this fires at `create_sandbox`, i.e. the first agent RPC in the
sandbox's life — before any container is created, and well before
`handle_cdi_devices` runs at container-create time. That ordering is exactly
what the design needs: module loads, udev creates nodes, guest CDI spec is
generated, container asks for a device. And `handle_cdi_devices` already retries
for `cdi_timeout` seconds if the spec is not there yet, which absorbs the race.

**A subtlety:** `modprobe` requires `/sbin/modprobe` in the guest rootfs and a
valid `modules.dep`. Kata's minimal rootfs may have neither. Both are rootfs
build-time concerns, not runtime ones.

---

## The three options, and the recommendation

### Option 1 — built into the kernel image (`CONFIG_NVKVM_GUEST=y`)

Patch `src/guest/` into the kernel tree at `setup` time via `build-kernel.sh -p
<patchdir>`, add a Kconfig entry, build it in.

- **for:** no module-loading step, no `depmod`, no `modprobe`, no `/lib/modules`
  in the rootfs, no ordering question at all. Smallest rootfs.
- **against:** the module becomes part of the kernel's build, so every nvkvm
  change is a kernel rebuild. It also fights the module's own design — it uses
  `module_param` (`num_gpus`) and is written as a module. And it forfeits the
  ability to ship a fixed kernel and iterate on the module.

### Option 2 — out-of-tree build at kernel-build time, shipped in the rootfs (**recommended**)

Exactly what `-g nvidia` does today, with `src/guest/` in place of
`open-gpu-kernel-modules`:

1. add `configs/fragments/gpu/nvkvm.x86_64.conf.in` with `CONFIG_MODULES=y`,
   `CONFIG_MODULE_UNLOAD=y`, `CONFIG_DRM` (graphics build only), and
   `CONFIG_LOCALVERSION="-nvkvm${CONF_GUEST_SUFFIX}"`;
2. in `build_kernel`, after `modules_install`, `make -C src/guest KDIR=<kernel_path>`
   and `modules_install` the result into the same tree;
3. `depmod -b` against that tree;
4. pass it to the rootfs builder via `KERNEL_MODULES_DIR`;
5. load it with `kernel_modules = ["nvkvm-guest"]` in the GPU-flavoured
   `configuration.toml`.

- **for:** every step already exists and is exercised by Kata's own NVIDIA path;
  the kernel and the module version independently; the module stays a module;
  the change is additive and plausibly upstreamable as a third `-g` vendor.
- **against:** `-g` currently accepts only `intel` and `nvidia`, so either a
  one-line widening of that validation, or the fragment goes in `common/` and is
  applied unconditionally (worse — it would turn on `CONFIG_MODULES` for every
  Kata user).

### Option 3 — DKMS-style build on the host against Kata's kernel headers

Ship a headers package alongside the Kata kernel, build the module on each node.

- **for:** works without rebuilding Kata's kernel; tolerates Kata kernel bumps.
- **against:** needs a toolchain on every node; needs the headers package to
  actually ship (**UNVERIFIED**, above); and the built `.ko` still has to get
  into the guest rootfs, which means rebuilding the rootfs anyway — so it
  removes the kernel build but not the image build. Worst of both.

**Recommend option 2.** Option 1 is a reasonable fallback if `CONFIG_DRM` in a
modular kernel turns out to be awkward, and option 3 should be treated as a
last resort.

---

## What the guest rootfs does *not* need

**No CUDA userspace.** No `libcuda`, no PTX JIT, no cuDNN, no CUDA toolkit.
Those reach the *container* from the host via CDI mounts
([02](02-libraries-via-cdi.md)), and never touch the guest rootfs. This is the
main reason the image can stay small and is worth stating loudly, because Kata's
own NVIDIA rootfs *does* carry "NVIDIA user space driver libraries" and "NVIDIA
user space tools" (`NVIDIA-GPU-passthrough-and-Kata-QEMU.md`) — it has to,
because its driver runs in the guest. nvkvm's does not.

What the rootfs *does* need beyond stock Kata:
`/lib/modules/<release>/` with `nvkvm-guest.ko` and a valid `modules.dep`;
`/sbin/modprobe`; and — for the guest-side CDI generation in
[03](03-guest-side-devices.md) — `nvidia-ctk` and enough of the toolkit's
discovery path, plus `nvidia-smi`/`libnvidia-ml.so.1` if a
"wait for the driver" step is wanted.

---

## Escape hatch

If none of the packaging machinery fits, `configuration.toml` accepts
`kernel = `, `initrd = ` and `image = ` outright, and the per-pod annotations
`io.katacontainers.config.hypervisor.{kernel,initrd,image,kernel_params}` exist
(`src/runtime/virtcontainers/pkg/annotations/annotations.go`). Hypervisor
annotations are gated by `enable_annotations`, a list of regexes matched against
the annotation's base name — a deliberate security gate, since these override
host-side paths. A fully custom kernel + initrd built entirely outside Kata's
pipeline is therefore supported, and is the right way to prototype before
touching `build-kernel.sh`.
