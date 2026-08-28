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

# losetup -P asks the kernel to scan the partition table, but the p1 device node
# is created ASYNCHRONOUSLY by udev.  A bare `[ -b "${LOOP}p1" ]` therefore loses
# a race on a busy host and silently falls back to mounting the WHOLE DISK,
# which fails with "wrong fs type, bad option, bad superblock" and names
# nothing useful.  MEASURED on 2026-08-28.  Wait for the node instead.
wait_for_part() {   # $1 = loop device -> echoes the partition (or the loop) to mount
    local loop="$1" i
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5 >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -b "${loop}p1" ] && { echo "${loop}p1"; return 0; }
        sleep 0.5
    done
    echo "$loop"   # genuinely unpartitioned image
}


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
# the host over virtio-fs.  Writing a few lines of YAML avoids importing a Go
# binary and its discovery path into the guest image to get a result we would
# then have to strip.
#
# major/minor are deliberately omitted: the CDI library fills them in by
# stat()ing the path, IN THE GUEST, which is the whole point -- /dev/nvidia-uvm's
# major is allocated dynamically and per-boot and never matches the host's.
#
# The device NAMES matter and are the reason this file enumerates rather than
# hardcoding "0".  kata-agent turns VISIBLE_CDI_DEVICES=nvidia.com/gpu=all into
# a lookup for a device literally named "all"
# (src/agent/src/device/mod.rs, token_to_kind_and_device), and `docker run
# --gpus all` is the request this project exists to answer.  So emit one device
# per GPU *and* an "all" device, exactly as `nvidia-ctk cdi generate` does.
#
# A NOTE ON `set -e` IN THIS FILE, because getting it wrong costs an hour and
# lies to you while it does.  kmod runs this from a modprobe.d `install`
# directive, so a non-zero exit here fails the module load, and kmod reports
# that as:
#
#     modprobe: ERROR: could not insert 'nvkvm_guest': Invalid argument
#
# -- which names neither this script nor the real problem, and sends you off
# debugging nvkvm-guest.ko, which loaded perfectly.  MEASURED 2026-08-28: an
# `[ -e "$n" ] && echo ...` as the LAST statement of a loop or function returns
# 1 when the last path does not exist (`/dev/dri/renderD128` on a compute-only
# build always does not), and `set -e` turns that into exactly that message.
# So: no bare `&&` in tail position anywhere below, and every helper ends in an
# explicit `return 0`.
set -eu
report() { echo "nvkvm-guest-cdi-gen: $*" > /dev/kmsg 2>/dev/null || true; }
trap 'report "FAILED at line $LINENO -- the sandbox will fail to start"' EXIT
OUT=/var/run/cdi
mkdir -p "$OUT"
tmp="$OUT/.nvkvm.yaml.$$"

gpus=""
for n in /dev/nvidia[0-9]*; do
    if [ -e "$n" ]; then gpus="$gpus $n"; fi
done

# $1 is the indent, because this block appears at two different depths (inside
# a device, and at spec level) and YAML will not forgive mixing them -- a
# 6-space `deviceNodes:` next to a 2-space `hooks:` under the same mapping
# makes kata-agent fail the whole sandbox with
# `SpecError { message: "spec error message parse spec file failed" }`, which
# names neither the file nor the line.  MEASURED 2026-08-28.
nodes() {
    ind="$1"; shift
    echo "${ind}deviceNodes:"
    for n in "$@"; do
        if [ -e "$n" ]; then echo "${ind}  - path: \"$n\""; fi
    done
    return 0
}

{
  echo 'cdiVersion: "0.6.0"'
  echo 'kind: nvidia.com/gpu'
  echo 'devices:'
  i=0
  for g in $gpus; do
      echo "  - name: \"$i\""
      echo '    containerEdits:'
      nodes "      " "$g"
      i=$((i+1))
  done
  echo '  - name: "all"'
  echo '    containerEdits:'
  nodes "      " $gpus
  # Spec-level edits apply whenever ANY device from this spec is requested --
  # the control nodes every CUDA process needs regardless of which GPU it got.
  echo 'containerEdits:'
  nodes "  " /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools \
             /dev/nvidia-modeset /dev/dri/renderD128
  # THE HOOK.  This is the half of nvidia-container-toolkit's job that a host
  # can no longer do once there is a VM in the way: `update-ldcache`, run
  # inside the container's own filesystem.  A host-injected hook would be
  # deleted (kata_agent.go:1055); a hook that arrives on a GUEST-side CDI spec
  # is executed by rustjail (container.rs:621-632) -- MEASURED, see
  # docs/design/09-gpu-libraries-automatically.md.
  echo '  hooks:'
  echo '    - hookName: createContainer'
  echo '      path: /usr/local/bin/nvkvm-cdi-hook-ldcache'
  echo '      args: ["nvkvm-cdi-hook-ldcache"]' 
} > "$tmp"
mv -f "$tmp" "$OUT/nvkvm.yaml"
trap - EXIT
report "wrote $OUT/nvkvm.yaml for$gpus"
GEN
    chmod 0755 "$root/usr/local/bin/nvkvm-guest-cdi-gen"

    # --- the guest-side ldcache hook ----------------------------------------
    # nvidia-container-toolkit does four things for a GPU container.  Three of
    # them are mounts and cgroup rules and survive the VM boundary.  The
    # fourth -- writing SONAME symlinks and /etc/ld.so.cache into the
    # container's WRITABLE layer -- is a `createContainer` CDI hook, and Kata
    # deletes host-injected hooks before the agent ever sees them
    # (src/runtime/virtcontainers/kata_agent.go:1055).
    #
    # It does NOT delete hooks that arrive on a CDI spec found INSIDE the
    # guest.  Those reach rustjail's own hook runner
    # (src/agent/rustjail/src/container.rs:621-632), which executes them in the
    # container's mount namespace, after the rootfs is assembled and before
    # pivot_root.  MEASURED 2026-08-28 -- a hook that touched a file in the
    # container root, and the file was there inside the container.  That is the
    # single measurement this whole feature turns on.
    #
    # Why it matters beyond tidiness: NVIDIA's own images gate on the cache.
    # /opt/nvidia/entrypoint.d/50-gpu-driver-check.sh runs
    # `ldconfig -p | grep libcuda.so.1` and, finding nothing, prints "The
    # NVIDIA Driver was not detected" and exports NVIDIA_CPU_ONLY=1 -- with a
    # perfectly working GPU attached.  Mounting the library at its SONAME path
    # is enough for dlopen; it is not enough for that check.
    cat > "$root/usr/local/bin/nvkvm-cdi-hook-ldcache" <<'HOOK'
#!/bin/sh
# nvkvm-cdi-hook-ldcache -- the guest half of NVIDIA's `update-ldcache` hook.
#
# Runs as a createContainer hook, from the guest CDI spec, in the container's
# mount namespace before pivot_root.  Reads the OCI State JSON on stdin (the
# runtime-spec contract) and runs the CONTAINER's own ldconfig, under chroot,
# against the container's root.
#
# chroot, not `ldconfig -r`: the container's ldconfig is linked against the
# container's glibc, and running it from the guest would resolve its
# interpreter against the GUEST's glibc -- an Ubuntu 24.04 guest cannot be
# relied on to run an Ubuntu 26.04 binary.  Under chroot both come from the
# image, so they match by construction.
#
# Failure is never fatal.  A non-zero exit here fails container creation, and
# an image with no ldconfig (distroless, Alpine) is a legitimate thing to run:
# the libraries are already mounted at their SONAME paths in a directory glibc
# searches by default, so such a container still works, it just has no cache.
set -u
state=$(cat 2>/dev/null || true)

# Pull "id" out of the state without a JSON parser.  Split on the structural
# characters first so a greedy .* cannot walk into an annotation that happens
# to contain the word id.
cid=$(printf '%s' "$state" | tr '{},' '\n\n\n' \
      | sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

root=""
if [ -n "$cid" ] && [ -d "/run/kata-containers/$cid/rootfs" ]; then
    root="/run/kata-containers/$cid/rootfs"
else
    # Fallback: the OCI spec's own root path, which rustjail has already
    # canonicalised by the time hooks run.
    for c in /run/kata-containers/*/rootfs; do
        if [ -d "$c" ]; then root="$c"; fi
    done
fi
[ -n "$root" ] || exit 0

ld=""
for cand in /sbin/ldconfig /usr/sbin/ldconfig; do
    if [ -x "$root$cand" ]; then ld="$cand"; break; fi
done
if [ -z "$ld" ]; then
    echo "nvkvm-cdi-hook-ldcache: no ldconfig in the image; skipping (libraries are still mounted at their SONAME paths)" > /dev/kmsg 2>/dev/null
    exit 0
fi

if chroot "$root" "$ld" >/dev/null 2>&1; then
    echo "nvkvm-cdi-hook-ldcache: ldconfig ok in $root" > /dev/kmsg 2>/dev/null
else
    echo "nvkvm-cdi-hook-ldcache: ldconfig returned $? in $root (continuing)" > /dev/kmsg 2>/dev/null
fi
exit 0
HOOK
    chmod 0755 "$root/usr/local/bin/nvkvm-cdi-hook-ldcache"

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
    PART="$(wait_for_part "$LOOP")"
    mkdir -p /mnt/nvkvm-prep && mount "$PART" /mnt/nvkvm-prep
    install_into /mnt/nvkvm-prep
    df -h /mnt/nvkvm-prep | tail -1
    sync; umount /mnt/nvkvm-prep; losetup -d "$LOOP"
    trap 'rm -rf "$STAGE"' EXIT
    echo "OK: $IMAGE prepared"
fi
