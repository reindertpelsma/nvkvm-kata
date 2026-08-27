#!/usr/bin/env bash
# nvkvm-kata-uninstall.sh -- put this host back exactly as it was.
#
# Non-negotiable, because the installer edits /etc/docker/daemon.json and can
# edit /etc/containerd/config.toml.  Anything that touches a container engine's
# configuration has to be reversible, and reversible from a RECORD rather than
# from a second list of guesses that drifts away from the first.
#
# The record is /var/lib/nvkvm-kata/install-manifest, written by the installer:
#     created   <path>  [<absent-marker>]     -> remove it
#     modified  <path>  <backup>              -> restore the backup
# plus the two engine registrations, which are removed by the same helpers that
# added them so the removal is exact rather than textual.
#
# WHAT IT DOES NOT REMOVE unless you ask
#   --purge          also delete /var/lib/nvkvm-kata (the build artifacts: the
#                    guest kernel, the modules tree, the rootfs image).  Keeping
#                    them by default means a re-install is seconds, not an hour.
#   --remove-qemu    also delete /opt/qemu-nvkvm (nvkvm's QEMU).  Left alone by
#                    default because nvkvm-pv may be using it outside Kata.
#   --remove-kata    also delete /opt/kata, and ONLY if this installer put it
#                    there (the manifest says so).  Never removes a Kata you
#                    installed yourself.
#
# Usage: sudo scripts/nvkvm-kata-uninstall.sh [--purge] [--remove-qemu] [--remove-kata] [--yes]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=/var/lib/nvkvm-kata
MANIFEST="$STATE/install-manifest"
BACKUP="$STATE/backup"
PREFIX=/opt/nvkvm-kata
RUNTIME_NAME=nvkvm-kata
PURGE=0 ; RM_QEMU=0 ; RM_KATA=0 ; ASSUME_YES=0

docker_has_runtime() {
    docker info -f '{{range $k, $v := .Runtimes}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -qx "$RUNTIME_NAME"
}

log()    { printf '[nvkvm-kata] %s\n' "$*" >&2; }
change() { printf '[nvkvm-kata]  REMOVED  %s\n' "$*" >&2; }
ok()     { printf '[nvkvm-kata]   ok   %s\n' "$*" >&2; }
warn()   { printf '[nvkvm-kata] WARNING: %s\n' "$*" >&2; }
die()    { printf '\n[nvkvm-kata] FATAL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '[nvkvm-kata]   fix: %s\n' "$2" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)        PURGE=1; shift ;;
        --remove-qemu)  RM_QEMU=1; shift ;;
        --remove-kata)  RM_KATA=1; shift ;;
        --runtime-name) RUNTIME_NAME="$2"; shift 2 ;;
        --prefix)       PREFIX="$2"; shift 2 ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" "run $0 --help" ;;
    esac
done
[ "$(id -u)" -eq 0 ] || die "must run as root" "re-run under sudo"

if [ ! -f "$MANIFEST" ]; then
    warn "no manifest at $MANIFEST -- nvkvm-kata was probably never installed by the script."
    warn "Proceeding with the well-known paths only; anything else was not ours to remove."
fi

if [ "$ASSUME_YES" = 0 ]; then
    printf '[nvkvm-kata] About to remove nvkvm-kata from this host.\n' >&2
    printf '[nvkvm-kata]   runtime name : %s\n' "$RUNTIME_NAME" >&2
    printf '[nvkvm-kata]   prefix       : %s\n' "$PREFIX" >&2
    printf '[nvkvm-kata]   purge build  : %s   remove qemu: %s   remove kata: %s\n' "$PURGE" "$RM_QEMU" "$RM_KATA" >&2
    printf '[nvkvm-kata] Continue? [y/N] ' >&2
    read -r a; case "$a" in y|Y|yes) ;; *) die "aborted by the user" "re-run with --yes to skip this prompt";; esac
fi

# ── 1. engine registrations, first, so nothing new can start on the runtime ──
if command -v docker >/dev/null 2>&1 && [ -e /etc/docker/daemon.json ]; then
    python3 "$HERE/lib/docker-runtime.py" remove --name "$RUNTIME_NAME"
    case $? in
        0) change "docker runtime '$RUNTIME_NAME' from /etc/docker/daemon.json"
           systemctl reload docker >/dev/null 2>&1 || systemctl restart docker >/dev/null 2>&1 || true ;;
        1) ok "docker runtime '$RUNTIME_NAME' was not registered" ;;
        *) warn "could not edit /etc/docker/daemon.json -- remove the '$RUNTIME_NAME' key by hand" ;;
    esac
fi

CFG=/etc/containerd/config.toml
if [ -e "$CFG" ] && grep -q '^# >>> nvkvm-kata >>>' "$CFG"; then
    # Delete the marker-delimited block only.  Everything outside it was not
    # ours and is left byte-identical.
    python3 - "$CFG" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out, skip = [], False
for l in lines:
    if l.startswith('# >>> nvkvm-kata >>>'):
        skip = True
        # also drop the blank line the installer wrote before the marker
        while out and out[-1].strip() == '':
            out.pop()
        continue
    if l.startswith('# <<< nvkvm-kata <<<'):
        skip = False
        continue
    if not skip:
        out.append(l)
open(p, 'w').writelines(out)
PY
    change "containerd CRI handler '$RUNTIME_NAME' from $CFG"
    systemctl restart containerd >/dev/null 2>&1 || true
    sleep 2
    ctr version >/dev/null 2>&1 || warn "containerd is not answering after the restart -- check journalctl -u containerd"
fi

# ── 2. the manifest, in reverse order of creation ────────────────────────────
if [ -f "$MANIFEST" ]; then
    tac "$MANIFEST" | while IFS=$'\t' read -r kind path note; do
        [ -n "${path:-}" ] || continue
        case "$kind" in
            created)
                if [ "$path" = /opt/kata ]; then
                    if [ "$RM_KATA" = 1 ]; then rm -rf /opt/kata; change "/opt/kata (installed by us: $note)"
                    else ok "/opt/kata left in place (this installer put it there; --remove-kata deletes it)"; fi
                    continue
                fi
                if [ -e "$path" ] || [ -L "$path" ]; then rm -rf "$path"; change "$path"; fi
                ;;
            modified)
                if [ -n "${note:-}" ] && [ -e "$note" ]; then
                    cp -a "$note" "$path"; change "restored $path from backup"
                else
                    warn "no backup recorded for $path -- left as it is"
                fi
                ;;
        esac
    done
fi

# ── 3. the well-known paths, whether or not the manifest mentioned them ──────
for p in "/usr/local/bin/containerd-shim-${RUNTIME_NAME}-v2" \
         "/etc/kata-containers/configuration-nvkvm.toml" \
         "/etc/nvkvm-kata/shim.env"; do
    [ -e "$p" ] && { rm -f "$p"; change "$p"; }
done
[ -d /etc/nvkvm-kata ] && rmdir /etc/nvkvm-kata 2>/dev/null && change "/etc/nvkvm-kata"
[ -d "$PREFIX" ] && { rm -rf "$PREFIX"; change "$PREFIX"; }

[ "$RM_QEMU" = 1 ] && [ -d /opt/qemu-nvkvm ] && { rm -rf /opt/qemu-nvkvm; change "/opt/qemu-nvkvm"; }

if [ "$PURGE" = 1 ]; then
    rm -rf "$STATE"; change "$STATE (build artifacts and backups)"
else
    rm -f "$MANIFEST"
    ok "kept $STATE (build artifacts) -- pass --purge to delete, re-install is fast without a rebuild"
fi

# ── 4. prove the host is back ────────────────────────────────────────────────
log ""
log "checking the host's own runtimes still work:"
FAIL=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_has_runtime \
        && { warn "docker STILL lists runtime '$RUNTIME_NAME'"; FAIL=1; } \
        || ok "docker no longer lists '$RUNTIME_NAME'"
    docker run --rm docker.io/library/ubuntu:24.04 /bin/true >/dev/null 2>&1 \
        && ok "docker + runc still runs containers" \
        || { warn "docker could not run a container -- investigate before trusting this host"; FAIL=1; }
fi
if [ -x /usr/local/bin/containerd-shim-kata-v2 ] || [ -x /usr/bin/containerd-shim-kata-v2 ]; then
    ok "stock kata shim still present (never touched)"
fi
[ -e /etc/kata-containers/configuration.toml ] && ok "stock /etc/kata-containers/configuration.toml still present"

[ "$FAIL" = 0 ] && log "uninstall complete." || die "uninstall finished with warnings above" "read them; backups are in $BACKUP unless --purge was given"
