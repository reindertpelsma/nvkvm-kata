#!/bin/sh
# nvkvm-qemu-shim.sh -- what goes at Kata's `[hypervisor.qemu] path =`.
#
# WHY A SHIM AT ALL
#   Kata builds the whole QEMU command line itself (govmm), and has no
#   configuration key for "add this arbitrary -device".  nvkvm needs
#   `-device virtio-nvgpu-pci-non-transitional` on that command line.  Rather
#   than patch Kata, put a shim at hypervisor.path: Kata execs the shim, the
#   shim appends the device and exec()s the real QEMU.
#
#   `path` set in configuration.toml is NOT checked against
#   valid_hypervisor_paths -- that list is only consulted for the
#   io.katacontainers.config.hypervisor.path ANNOTATION
#   (src/runtime/pkg/katautils/config.go:114, used from
#   virtcontainers/hypervisor.go:590).  Add the shim to the list anyway if you
#   intend to select it per-pod.
#
# WHY exec, AND WHY IT IS SAFE
#   exec() preserves the pid, so everything Kata does to the "QEMU process" --
#   cgroup placement, waiting on it, SIGKILL on teardown -- keeps working.
#   It also preserves inherited fds, which matters: Kata passes the QMP socket
#   as `-qmp unix:fd=3,server=on,wait=off` via cmd.ExtraFiles, and QEMU would
#   die immediately on a shim that closed it.
#   QEMU locates its own data directory (bios, vgabios) relative to
#   /proc/self/exe, which after exec is the REAL binary -- so the shim does not
#   need -L and does not break firmware lookup.
#
#   This is the same shape docs/design/06-vmm-confinement-design.md recommends
#   for confinement.  Both uses can share one shim: put the unshare/setpriv in
#   front of the exec here.
#
# ENV
#   NVKVM_QEMU        real qemu binary   (default /opt/qemu-nvkvm/bin/qemu-system-x86_64)
#   NVKVM_EXTRA_ARGS  extra QEMU args    (default the virtio-nvgpu device)
#   NVKVM_SHIM_LOG    if set, append the final argv to this file (debugging)
#
#   Read from /etc/nvkvm-kata/shim.env when that file exists, so an operator can
#   point the shim at a different QEMU or add a device WITHOUT a systemd drop-in
#   on containerd.service.  A drop-in would be global -- it would apply to every
#   runtime the host has -- whereas this file is read only by this shim, and the
#   shim runs only for the nvkvm-kata configuration.  Already-set environment
#   wins, so a drop-in still works if you prefer one.
set -eu

if [ -r /etc/nvkvm-kata/shim.env ]; then
    # Only NVKVM_* assignments, and only ones not already set.
    while IFS='=' read -r _k _v; do
        case "$_k" in
            NVKVM_QEMU|NVKVM_EXTRA_ARGS|NVKVM_SHIM_LOG)
                eval "[ -n \"\${$_k:-}\" ] || { $_k=\$_v; export $_k; }" ;;
        esac
    done < /etc/nvkvm-kata/shim.env
fi

QEMU="${NVKVM_QEMU:-/opt/qemu-nvkvm/bin/qemu-system-x86_64}"
EXTRA="${NVKVM_EXTRA_ARGS:--device virtio-nvgpu-pci-non-transitional,id=nvkvm0}"

[ -x "$QEMU" ] || { echo "nvkvm-qemu-shim: $QEMU is not executable" >&2; exit 127; }

if [ -n "${NVKVM_SHIM_LOG:-}" ]; then
    { date -Is; echo "  argv: $*"; echo "  extra: $EXTRA"; } >> "$NVKVM_SHIM_LOG" 2>/dev/null || true
fi

# $EXTRA is deliberately unquoted: it is a small operator-supplied argument
# list, not user input, and word splitting is the point.
# shellcheck disable=SC2086
exec "$QEMU" "$@" $EXTRA
