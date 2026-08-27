#!/usr/bin/env bash
# build-guest-kernel.sh -- build a Kata guest kernel that can load nvkvm-guest.ko,
# build the module against it, and lay out a modules tree with a VALID modules.dep.
#
# This implements option 2 of docs/design/04-guest-kernel.md: mirror Kata's own
# `build-kernel.sh -g nvidia` out-of-tree module step, substituting nvkvm-pv's
# src/guest/ for open-gpu-kernel-modules.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID
#   Neither build-kernel.sh nor rootfs.sh runs depmod.  Without modules.dep,
#   `modprobe nvkvm-guest` fails with "module not found" -- which names the
#   module, not the missing index, and sends you looking in the wrong place.
#   Step 5 below runs `depmod -b`, and step 6 asserts modules.dep mentions the
#   module before declaring success.
#
# Usage:
#   scripts/build-guest-kernel.sh --kata-src <dir> --nvkvm-src <dir> [options]
#
#   --kata-src    <dir>  kata-containers checkout (has tools/packaging/kernel)
#   --nvkvm-src   <dir>  nvkvm-pv checkout (has src/guest/Makefile)
#   --out         <dir>  output dir (default: ./nvkvm-guest-kernel)
#   --version     <ver>  kernel version, default: kata's versions.yaml
#   --graphics    <0|1>  NVKVM_GRAPHICS, default 0 (compute-only, no CONFIG_DRM)
#   --jobs        <n>    parallel make jobs, default nproc
#   --skip-kernel        reuse an existing kernel tree, build only the module
#
# Output layout (all under --out):
#   vmlinuz-<release>            bzImage, ready for hypervisor.kernel
#   modules/lib/modules/<release>/extra/nvkvm-guest.ko  + modules.dep
#   kernel-src/                  the kernel tree (headers, Module.symvers)
#   release                      one line: the kernel release string
set -euo pipefail

KATA_SRC="" ; NVKVM_SRC="" ; OUT="$PWD/nvkvm-guest-kernel"
KVER="" ; GRAPHICS=0 ; JOBS="$(nproc)" ; SKIP_KERNEL=0

die() { echo "build-guest-kernel.sh: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kata-src)  KATA_SRC="$2"; shift 2 ;;
        --nvkvm-src) NVKVM_SRC="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        --version)   KVER="$2"; shift 2 ;;
        --graphics)  GRAPHICS="$2"; shift 2 ;;
        --jobs)      JOBS="$2"; shift 2 ;;
        --skip-kernel) SKIP_KERNEL=1; shift ;;
        -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$KATA_SRC" ]  || die "--kata-src is required"
[ -n "$NVKVM_SRC" ] || die "--nvkvm-src is required"
[ -d "$KATA_SRC/tools/packaging/kernel" ] || die "$KATA_SRC is not a kata-containers checkout"
[ -f "$NVKVM_SRC/src/guest/Makefile" ]    || die "$NVKVM_SRC is not an nvkvm-pv checkout"

KATA_SRC="$(cd "$KATA_SRC" && pwd)"
NVKVM_SRC="$(cd "$NVKVM_SRC" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT" ; OUT="$(cd "$OUT" && pwd)"

BK="$KATA_SRC/tools/packaging/kernel/build-kernel.sh"
FRAG_DIR="$KATA_SRC/tools/packaging/kernel/configs/fragments/gpu"

# ---------------------------------------------------------------------------
step "1. install the nvkvm config fragment and widen -g to accept it"
# Kata's build-kernel.sh validates -g against {intel,nvidia} in exactly one
# place.  Widening it is the one-line change docs/design/04-guest-kernel.md
# predicted; the fragment is a new file, so nothing existing changes behaviour.
install -m 0644 "$HERE/../kata/fragments/gpu/nvkvm.x86_64.conf.in" "$FRAG_DIR/"
if [ "$GRAPHICS" = "1" ]; then
    cat "$HERE/../kata/fragments/gpu/nvkvm-graphics.x86_64.conf" \
        >> "$FRAG_DIR/nvkvm.x86_64.conf.in"
    echo "  graphics build: appended CONFIG_DRM fragment"
fi
if ! grep -q 'VENDOR_NVKVM' "$BK"; then
    # Insert the constant next to the existing vendor constants, and add it to
    # the validation.  Idempotent: guarded by the grep above.
    sed -i 's|^readonly VENDOR_NVIDIA="nvidia"|readonly VENDOR_NVIDIA="nvidia"\nreadonly VENDOR_NVKVM="nvkvm"|' "$BK"
    sed -i 's|\[\[ "${gpu_vendor}" == "${VENDOR_INTEL}" \|\| "${gpu_vendor}" == "${VENDOR_NVIDIA}" \]\] \|\| die "GPU vendor only support intel and nvidia"|[[ "${gpu_vendor}" == "${VENDOR_INTEL}" \|\| "${gpu_vendor}" == "${VENDOR_NVIDIA}" \|\| "${gpu_vendor}" == "${VENDOR_NVKVM}" ]] \|\| die "GPU vendor only support intel, nvidia and nvkvm"|' "$BK"
    grep -q 'VENDOR_NVKVM' "$BK" || die "failed to patch $BK -- upstream text changed, re-derive the sed"
    echo "  patched $BK to accept -g nvkvm"
else
    echo "  $BK already accepts -g nvkvm"
fi

# The NVIDIA-specific source fetch and out-of-tree build are keyed on
# gpu_vendor == nvidia, so -g nvkvm takes neither.  Assert that, because a
# silent match would download open-gpu-kernel-modules and add ~10 minutes.
grep -q 'gpu_vendor}" == "${VENDOR_NVIDIA}' "$BK" || die "expected NVIDIA guards not found"

# ---------------------------------------------------------------------------
KPATH=""
if [ "$SKIP_KERNEL" = "0" ]; then
    step "2. build the guest kernel (-g nvkvm)"
    VARGS=()
    [ -n "$KVER" ] && VARGS+=(-v "$KVER")
    ( cd "$OUT" && bash "$BK" -g nvkvm "${VARGS[@]}" -f setup )
    KPATH="$(find "$OUT" -maxdepth 1 -type d -name 'kata-linux-*' | head -1)"
    [ -n "$KPATH" ] || die "setup produced no kata-linux-* tree in $OUT"
    grep -q '^CONFIG_MODULES=y' "$KPATH/.config" \
        || die "CONFIG_MODULES is not set in the generated config -- the fragment did not apply"
    ( cd "$OUT" && bash "$BK" -g nvkvm "${VARGS[@]}" build )
else
    step "2. SKIPPED (--skip-kernel); reusing existing kernel tree"
    KPATH="$(find "$OUT" -maxdepth 1 -type d -name 'kata-linux-*' | head -1)"
    [ -n "$KPATH" ] || die "--skip-kernel but no kata-linux-* tree in $OUT"
fi
echo "kernel tree: $KPATH"

RELEASE="$(cat "$KPATH/include/config/kernel.release")"
echo "kernel release: $RELEASE"
echo "$RELEASE" > "$OUT/release"

# ---------------------------------------------------------------------------
step "3. install in-tree modules into a staging root"
MODROOT="$OUT/modules"
rm -rf "$MODROOT" ; mkdir -p "$MODROOT"
make -C "$KPATH" -j "$JOBS" INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$MODROOT" modules_install >/dev/null

# ---------------------------------------------------------------------------
step "4. build nvkvm-guest.ko out-of-tree against that kernel (NVKVM_GRAPHICS=$GRAPHICS)"
# nvkvm's src/guest/Makefile takes KDIR, which is the same idiom as NVIDIA's
# SYSSRC -- this is the substitution docs/design/04-guest-kernel.md describes.
make -C "$NVKVM_SRC/src/guest" clean KDIR="$KPATH" >/dev/null 2>&1 || true
make -C "$NVKVM_SRC/src/guest" -j "$JOBS" KDIR="$KPATH" NVKVM_GRAPHICS="$GRAPHICS"
[ -f "$NVKVM_SRC/src/guest/nvkvm-guest.ko" ] || die "nvkvm-guest.ko was not produced"
make -C "$KPATH" M="$NVKVM_SRC/src/guest" INSTALL_MOD_STRIP=1 \
     INSTALL_MOD_PATH="$MODROOT" NVKVM_GRAPHICS="$GRAPHICS" modules_install >/dev/null

# ---------------------------------------------------------------------------
step "5. depmod  <-- THE STEP KATA'S OWN TOOLING OMITS"
# Kata's build-kernel.sh does not run depmod, and rootfs.sh's copy_kernel_modules
# only cp -a's the directory.  Without this, modprobe(8) -- which is what
# kata-agent runs for `kernel_modules = [...]` -- reports the module as not
# found.  docs/design/04-guest-kernel.md flags this; here is where it is fixed.
depmod -a -b "$MODROOT" "$RELEASE"

# ---------------------------------------------------------------------------
step "6. verify the module is actually resolvable"
DEP="$MODROOT/lib/modules/$RELEASE/modules.dep"
[ -f "$DEP" ] || die "depmod produced no $DEP"
grep -q 'nvkvm-guest\.ko' "$DEP" \
    || die "modules.dep exists but does not mention nvkvm-guest.ko -- modprobe would fail"
KO="$(find "$MODROOT/lib/modules/$RELEASE" -name 'nvkvm-guest.ko*' | head -1)"
[ -n "$KO" ] || die "nvkvm-guest.ko not present under $MODROOT"
echo "  modules.dep entry : $(grep 'nvkvm-guest\.ko' "$DEP")"
echo "  module            : $KO ($(stat -c %s "$KO") bytes)"
modinfo "$KO" | sed -n '1,12p'

# ---------------------------------------------------------------------------
step "7. stage the kernel image"
cp -f "$KPATH/arch/x86/boot/bzImage" "$OUT/vmlinuz-$RELEASE"
ln -sf "vmlinuz-$RELEASE" "$OUT/vmlinuz-nvkvm.container"
cp -f "$KPATH/.config" "$OUT/config-$RELEASE"

echo
echo "=== done ==="
echo "  kernel  : $OUT/vmlinuz-$RELEASE"
echo "  modules : $MODROOT/lib/modules/$RELEASE  (depmod'd)"
echo "  release : $RELEASE"
echo
echo "Next: scripts/inject-guest-modules.sh --image <kata rootfs image> --modules $MODROOT"
