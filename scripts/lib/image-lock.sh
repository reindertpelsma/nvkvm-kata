# shellcheck shell=bash
# nvkvm-kata -- serialise the two scripts that edit a guest rootfs image, and
# give each run a mount point nobody else can be standing on.
#
# Sourced by prepare-guest-rootfs.sh (stage 4a) and inject-guest-modules.sh
# (stage 4b).  It lives in one file because the hazard is shared: both mount a
# loop partition of the SAME image, and before this there was no lock of any
# kind anywhere in this repo.
#
# THE MOUNT POINT.  Both scripts used a hardcoded path -- /mnt/nvkvm-prep and
# /mnt/nvkvm-rootfs.  Two runs at once (two installs on one host, or an install
# racing a hand-run --image) had the second mount SHADOW the first: run A's
# `install_into /mnt/nvkvm-prep` then wrote into run B's image, and A's trap
# umounted once and left B's mount stacked underneath.  Nothing failed loudly;
# you got an image missing the files the log said it had written.  A private
# mktemp directory removes the shared name entirely, which is a better fix than
# locking a path both scripts have to agree on.
#
# THE IMAGE.  Serialising the mount points is not enough on its own: stage 4a
# and stage 4b edit the same file, and the installer's own sequence only avoids
# overlap because it happens to run them one after another.  Anything else --
# --force in one terminal, --only rootfs in another -- has both losetup'ing the
# same image, and the loser's write lands in a page cache the winner is about to
# invalidate.  The lock is a sidecar next to the image rather than a lock on the
# image itself: flock(1) on the image would need it open for write, and losetup
# is the thing that should own that.
#
# BLOCKING, with a timeout that fails loudly.  A rootfs edit takes seconds, so a
# wait longer than a couple of minutes means a crashed run left the lock held
# through an unkillable process, and continuing anyway would corrupt the image
# the other run is inside.

NVKVM_IMAGE_LOCK_WAIT="${NVKVM_IMAGE_LOCK_WAIT:-300}"

# nvkvm_lock_image <image> -- blocks until this process owns the image.
# The fd stays open for the life of the process on purpose: there is then no
# unlock step to forget on an error path, and every exit releases it.
nvkvm_lock_image() {
    local img="$1" lock
    lock="$img.nvkvm-lock"
    if ! command -v flock >/dev/null 2>&1; then
        echo "  WARNING: no flock(1) -- editing $img UNSERIALISED." >&2
        echo "           A concurrent edit of the same image would corrupt it." >&2
        return 0
    fi
    exec {NVKVM_IMAGE_LOCK_FD}>"$lock" \
        || { echo "  WARNING: cannot open $lock -- editing unserialised." >&2; return 0; }
    if ! flock -n "$NVKVM_IMAGE_LOCK_FD"; then
        echo "  another nvkvm image edit holds $lock -- waiting up to ${NVKVM_IMAGE_LOCK_WAIT}s" >&2
        flock -w "$NVKVM_IMAGE_LOCK_WAIT" "$NVKVM_IMAGE_LOCK_FD" \
            || { echo "$(basename "$0"): timed out waiting for $lock" >&2
                 echo "  another process is editing $img. If nothing is, remove $lock." >&2
                 exit 1; }
    fi
}

# nvkvm_mktemp_mnt <tag> -- a mount point private to this run.
nvkvm_mktemp_mnt() {
    mktemp -d "${TMPDIR:-/tmp}/nvkvm-$1.XXXXXX"
}
