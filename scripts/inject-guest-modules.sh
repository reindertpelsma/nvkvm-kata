#!/usr/bin/env bash
# inject-guest-modules.sh -- put nvkvm-guest.ko (and a valid modules.dep) into a
# Kata guest rootfs, without rebuilding the rootfs.
#
# Kata's own hook for this is rootfs.sh's KERNEL_MODULES_DIR + copy_kernel_modules,
# but reaching it means running the whole osbuilder pipeline (docker, a distro
# bootstrap, an agent build).  For bring-up, editing the SHIPPED image is far
# cheaper and changes nothing else about it.  Use the osbuilder hook for release
# builds; use this to find out whether the design works at all.
#
# TWO FORMATS, BOTH SUPPORTED
#   --image  <kata-containers.img>          a partitioned raw disk, one ext4/xfs
#                                           partition (image_builder.sh:419).
#                                           Edited in place via losetup -P.
#   --initrd <kata-containers-initrd.img>   a gzip/zstd/xz cpio archive.
#                                           Unpacked, edited, repacked.
#
# THE POINT OF THIS SCRIPT: depmod.  See docs/design/04-guest-kernel.md.  Kata
# copies modules but never indexes them, and kata-agent loads them with
# modprobe(8), which needs modules.dep.  Both paths below re-run depmod inside
# the rootfs it just wrote, then assert the module resolves.
set -euo pipefail

IMAGE="" ; INITRD="" ; MODULES="" ; RELEASE="" ; ONLY="nvkvm-guest" ; BUSYBOX=""
die() { echo "inject-guest-modules.sh: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image)   IMAGE="$2"; shift 2 ;;
        --initrd)  INITRD="$2"; shift 2 ;;
        --modules) MODULES="$2"; shift 2 ;;   # the staging root: <dir>/lib/modules/<rel>
        --release) RELEASE="$2"; shift 2 ;;
        --only)    ONLY="$2"; shift 2 ;;      # module basename to keep; "all" keeps everything
        --busybox) BUSYBOX="$2"; shift 2 ;;   # static busybox to install as /sbin/modprobe if absent
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$MODULES" ] || die "--modules is required"
[ -n "$IMAGE$INITRD" ] || die "one of --image / --initrd is required"
[ -z "$IMAGE" ] || [ -z "$INITRD" ] || die "--image and --initrd are mutually exclusive"
[ "$(id -u)" -eq 0 ] || die "must run as root (losetup/mount/chown)"

if [ -z "$RELEASE" ]; then
    RELEASE="$(ls "$MODULES/lib/modules" | head -1)"
    [ -n "$RELEASE" ] || die "cannot infer release from $MODULES/lib/modules"
fi
SRC="$MODULES/lib/modules/$RELEASE"
[ -d "$SRC" ] || die "$SRC does not exist"

# --- build the exact tree we want inside the guest, in a temp dir -----------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$RELEASE"
if [ "$ONLY" = "all" ]; then
    cp -a "$SRC/." "$STAGE/$RELEASE/"
else
    # Keep the tree minimal: the module itself plus the index inputs depmod
    # needs to produce a correct modules.dep for a builtin-heavy kernel.
    found="$(find "$SRC" -name "${ONLY}.ko*" | head -1)"
    [ -n "$found" ] || die "no ${ONLY}.ko under $SRC"
    mkdir -p "$STAGE/$RELEASE/extra"
    cp -a "$found" "$STAGE/$RELEASE/extra/"
    for f in modules.builtin modules.builtin.modinfo modules.order; do
        [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$STAGE/$RELEASE/" || true
    done
fi
echo "staged $(du -sh "$STAGE" | cut -f1) for release $RELEASE"

install_into() {   # $1 = rootfs mount point
    local root="$1"
    mkdir -p "$root/lib/modules"
    rm -rf "${root:?}/lib/modules/$RELEASE"
    cp -a "$STAGE/$RELEASE" "$root/lib/modules/"

    # --- THE STEP KATA OMITS ------------------------------------------------
    depmod -a -b "$root" "$RELEASE"
    local dep="$root/lib/modules/$RELEASE/modules.dep"
    [ -f "$dep" ] || die "depmod wrote no modules.dep in $root"
    if [ "$ONLY" != "all" ]; then
        grep -q "${ONLY}\.ko" "$dep" \
            || die "modules.dep does not mention ${ONLY}.ko -- modprobe WOULD FAIL"
    fi
    echo "  modules.dep: $(grep -c . "$dep") entries; nvkvm line: $(grep "${ONLY}\.ko" "$dep" || echo NONE)"

    # kata-agent shells out to /sbin/modprobe (src/agent/src/rpc.rs,
    # MODPROBE_PATH).  A minimal rootfs may not have one.
    if [ ! -x "$root/sbin/modprobe" ] && [ ! -x "$root/bin/modprobe" ]; then
        if [ -n "$BUSYBOX" ] && [ -x "$BUSYBOX" ]; then
            mkdir -p "$root/sbin"
            cp -a "$BUSYBOX" "$root/sbin/busybox"
            ln -sf busybox "$root/sbin/modprobe"
            echo "  installed busybox as /sbin/modprobe"
        else
            echo "  WARNING: no /sbin/modprobe in this rootfs and no --busybox given." >&2
            echo "           kata-agent's kernel_modules step will fail." >&2
        fi
    else
        echo "  /sbin/modprobe present: $(ls -l "$root"/sbin/modprobe 2>/dev/null || ls -l "$root"/bin/modprobe)"
    fi
}

if [ -n "$IMAGE" ]; then
    step "injecting into disk image $IMAGE"
    cp -f "$IMAGE" "$IMAGE.orig" 2>/dev/null || true
    LOOP="$(losetup -f --show -P "$IMAGE")"
    trap 'umount /mnt/nvkvm-rootfs 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; rm -rf "$STAGE"' EXIT
    PART="${LOOP}p1" ; [ -b "$PART" ] || PART="$LOOP"
    mkdir -p /mnt/nvkvm-rootfs
    mount "$PART" /mnt/nvkvm-rootfs
    df -h /mnt/nvkvm-rootfs | tail -1
    install_into /mnt/nvkvm-rootfs
    sync ; umount /mnt/nvkvm-rootfs ; losetup -d "$LOOP"
    trap 'rm -rf "$STAGE"' EXIT
    echo "OK: $IMAGE updated (original saved as $IMAGE.orig)"
else
    step "injecting into initrd $INITRD"
    cp -f "$INITRD" "$INITRD.orig" 2>/dev/null || true
    WORK="$(mktemp -d)" ; trap 'rm -rf "$STAGE" "$WORK"' EXIT
    mkdir -p "$WORK/root"
    case "$(file -b --mime-type "$INITRD")" in
        application/gzip|application/x-gzip) DEC="gzip -dc"  ; ENC="gzip -9 -c" ;;
        application/zstd|application/x-zstd) DEC="zstd -dc"  ; ENC="zstd -19 -c" ;;
        application/x-xz)                    DEC="xz -dc"    ; ENC="xz -9 -c" ;;
        *)                                   DEC="cat"       ; ENC="cat" ;;
    esac
    ( cd "$WORK/root" && $DEC "$INITRD" | cpio -idm --quiet )
    install_into "$WORK/root"
    ( cd "$WORK/root" && find . | cpio -o -H newc --quiet ) | $ENC > "$INITRD"
    echo "OK: $INITRD updated (original saved as $INITRD.orig, $(stat -c %s "$INITRD") bytes)"
fi
