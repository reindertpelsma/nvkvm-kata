#!/usr/bin/env bash
# prepare-guest-rootfs.sh -- everything the Kata guest rootfs needs BEYOND stock,
# for nvkvm.  Two things, and both are surprises worth naming:
#
#  1. THERE IS NO modprobe IN KATA'S SHIPPED ROOTFS.
#     kata-agent loads `kernel_modules = [...]` by shelling out to
#     /sbin/modprobe (src/agent/src/rpc.rs, MODPROBE_PATH), but
#     kata-containers.img (Ubuntu 24.04 noble, 4.1.0) ships neither modprobe nor
#     kmod nor busybox -- measured, see docs/design/07-end-to-end.md.  So the
#     shipped mechanism for loading a guest kernel module cannot run on the
#     shipped rootfs.  This installs kmod from the matching Ubuntu release.
#
#  2. THE GUEST-SIDE CDI SPEC HAS TO BE WRITTEN AT RUNTIME, NOT BAKED IN.
#     kata-agent's handle_cdi_devices reads /var/run/cdi in the guest -- but the
#     agent mounts a fresh tmpfs on /run during init
#     (src/agent/src/mount.rs:62), so anything placed at /var/run/cdi in the
#     rootfs image is hidden before any container is created.  The spec must
#     therefore be generated after boot.  Upstream's answer is NVRC; ours is a
#     modprobe.d `install` directive, which fires exactly when the agent
#     modprobes the module -- i.e. at create_sandbox, before the first
#     create_container, which is the ordering doc 03/04 need.
#
# Usage (as root, on a host with docker):
#   scripts/prepare-guest-rootfs.sh --image /opt/kata/share/kata-containers/kata-containers.img
#   scripts/prepare-guest-rootfs.sh --rootfs /mnt/somewhere   # already-mounted
set -euo pipefail

IMAGE="" ; ROOTFS="" ; UBUNTU="24.04" ; KMOD_SRC=""
die() { echo "prepare-guest-rootfs.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image)   IMAGE="$2"; shift 2 ;;
        --rootfs)  ROOTFS="$2"; shift 2 ;;
        --ubuntu)  UBUNTU="$2"; shift 2 ;;
        --kmod-from) KMOD_SRC="$2"; shift 2 ;;  # a dir already holding kmod + libs
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$IMAGE$ROOTFS" ] || die "one of --image / --rootfs is required"
[ "$(id -u)" -eq 0 ] || die "must run as root"

# --- 1. harvest kmod + its libraries from the guest's own distro release -----
# Built against the SAME release the rootfs is, so glibc and libcrypto symbol
# versions match by construction.  (A host-built kmod would work forward but not
# backward; this removes the question.)
STAGE="$(mktemp -d)" ; trap 'rm -rf "$STAGE"' EXIT
if [ -n "$KMOD_SRC" ]; then
    cp -a "$KMOD_SRC/." "$STAGE/"
else
    command -v docker >/dev/null || die "need docker to harvest kmod, or pass --kmod-from"
    docker run --rm -v "$STAGE:/out" "ubuntu:$UBUNTU" sh -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null && apt-get install -y -qq kmod >/dev/null
        mkdir -p /out/usr/bin /out/lib/x86_64-linux-gnu
        cp -a /usr/bin/kmod /out/usr/bin/
        for l in $(ldd /usr/bin/kmod | awk "/=>/ {print \$3}"); do cp -aL "$l" /out/lib/x86_64-linux-gnu/; done
        chmod -R a+rX /out
    '
fi
[ -x "$STAGE/usr/bin/kmod" ] || die "no kmod harvested"
echo "harvested kmod: $(ls -l "$STAGE/usr/bin/kmod" | awk '{print $5}') bytes, libs: $(ls "$STAGE/lib/x86_64-linux-gnu" | tr '\n' ' ')"

install_into() {
    local root="$1"

    # --- kmod ---------------------------------------------------------------
    mkdir -p "$root/usr/bin" "$root/usr/lib/x86_64-linux-gnu" "$root/sbin"
    cp -a "$STAGE/usr/bin/kmod" "$root/usr/bin/kmod"
    for l in "$STAGE"/lib/x86_64-linux-gnu/*; do
        b="$(basename "$l")"
        # Only fill gaps: never shadow a library the rootfs already has.
        if [ ! -e "$root/usr/lib/x86_64-linux-gnu/$b" ] && [ ! -e "$root/lib/x86_64-linux-gnu/$b" ]; then
            cp -a "$l" "$root/usr/lib/x86_64-linux-gnu/$b"
            echo "  added missing lib $b"
        fi
    done
    # THE usrmerge TRAP.  Ubuntu noble is usr-merged: $root/sbin is itself a
    # symlink to usr/sbin.  A naive `ln -s ../usr/bin/kmod $root/sbin/modprobe`
    # therefore lands in $root/usr/sbin and resolves to $root/usr/usr/bin/kmod --
    # a dangling link.  The agent then fails create_sandbox with
    # "No such file or directory (os error 2)" and names nothing.  Compute the
    # relative target from the REAL directory instead.  (Ubuntu's own kmod
    # package ships /sbin/modprobe -> ../bin/kmod for exactly this reason.)
    # Absolute target, for the same reason upstream's NVIDIA rootfs builder gives
    # at tools/osbuilder/rootfs-builder/nvidia/nvidia_rootfs.sh:838-841 -- "so
    # they resolve regardless of whether /sbin is a real dir or a usr-merge
    # symlink".  A relative ../usr/bin/kmod lands in $root/usr/sbin on
    # usr-merged Ubuntu and then resolves to $root/usr/usr/bin/kmod; the agent
    # fails create_sandbox with "No such file or directory (os error 2)" and
    # names nothing.  Measured, see docs/design/07-end-to-end.md.
    local sbin_real
    sbin_real="$(cd "$root/sbin" && pwd -P)"
    for applet in modprobe insmod rmmod lsmod depmod modinfo; do
        ln -sf /usr/bin/kmod "$sbin_real/$applet"
    done
    [ -x "$root/usr/bin/kmod" ] || die "kmod missing at $root/usr/bin/kmod"
    echo "  $sbin_real/modprobe -> /usr/bin/kmod"

    # --- the guest-side CDI generator ---------------------------------------
    mkdir -p "$root/usr/local/bin" "$root/etc/modprobe.d"
    cat > "$root/usr/local/bin/nvkvm-guest-cdi-gen" <<'GEN'
#!/bin/sh
# nvkvm-guest-cdi-gen -- write the guest-side CDI spec kata-agent resolves.
#
# This stands in for NVRC (docs/use-cases/NVIDIA-GPU-passthrough-and-Kata-QEMU.md),
# which does the same job for the VFIO path by running `nvidia-ctk cdi generate`.
# It is deliberately not nvidia-ctk: the toolkit in a guest with device nodes but
# no driver libraries emits an empty/wrong `mounts` list (doc 03, UNVERIFIED),
# and this design wants the guest spec for deviceNodes only -- mounts come from
# the host over virtio-fs.  Writing five lines of YAML avoids importing a Go
# binary and its discovery path into the guest image to get a result we would
# then have to strip.
#
# major/minor are deliberately omitted: the CDI library fills them in by
# stat()ing the path, IN THE GUEST, which is the whole point -- /dev/nvidia-uvm's
# major is allocated dynamically and per-boot and never matches the host's.
set -eu
OUT=/var/run/cdi
mkdir -p "$OUT"
tmp="$OUT/.nvkvm.yaml.$$"
{
  echo 'cdiVersion: "0.6.0"'
  echo 'kind: nvidia.com/gpu'
  echo 'devices:'
  echo '  - name: "0"'
  echo '    containerEdits:'
  echo '      deviceNodes:'
  for n in /dev/nvidiactl /dev/nvidia0 /dev/nvidia-uvm /dev/nvidia-uvm-tools \
           /dev/nvidia-modeset /dev/dri/renderD128; do
      [ -e "$n" ] && echo "        - path: \"$n\""
  done
  echo 'containerEdits: {}'
} > "$tmp"
mv -f "$tmp" "$OUT/nvkvm.yaml"
GEN
    chmod 0755 "$root/usr/local/bin/nvkvm-guest-cdi-gen"

    # modprobe.d `install` directive: kmod runs this instead of a plain load, and
    # --ignore-install is what stops the recursion.  Ordering is what makes it
    # correct -- kata-agent runs kernel_modules at create_sandbox, well before
    # the first create_container calls handle_cdi_devices, and that call retries
    # for cdi_timeout (default 100s) anyway.
    cat > "$root/etc/modprobe.d/nvkvm-guest.conf" <<'MC'
install nvkvm-guest /sbin/modprobe --ignore-install nvkvm-guest $CMDLINE_OPTS && /usr/local/bin/nvkvm-guest-cdi-gen
MC
    echo "  installed /usr/local/bin/nvkvm-guest-cdi-gen + /etc/modprobe.d/nvkvm-guest.conf"
}

if [ -n "$ROOTFS" ]; then
    install_into "$ROOTFS"
else
    LOOP="$(losetup -f --show -P "$IMAGE")"
    trap 'umount /mnt/nvkvm-prep 2>/dev/null||true; losetup -d "$LOOP" 2>/dev/null||true; rm -rf "$STAGE"' EXIT
    PART="${LOOP}p1"; [ -b "$PART" ] || PART="$LOOP"
    mkdir -p /mnt/nvkvm-prep && mount "$PART" /mnt/nvkvm-prep
    install_into /mnt/nvkvm-prep
    df -h /mnt/nvkvm-prep | tail -1
    sync; umount /mnt/nvkvm-prep; losetup -d "$LOOP"
    trap 'rm -rf "$STAGE"' EXIT
    echo "OK: $IMAGE prepared"
fi
