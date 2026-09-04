#!/usr/bin/env bash
# nvkvm-kata-install.sh -- build nvkvm-kata from source and install it on this
# host, so that a container can select it PER CONTAINER:
#
#     services:
#       cuda:
#         runtime: nvkvm-kata          # <- stock kata and runc are untouched
#
# ONE SCRIPT, SOURCE -> INSTALLED.  It is a CONVENIENCE over the documented
# manual steps, never a replacement for them: every stage below maps 1:1 onto a
# numbered section of docs/install.md, and that document is written so a person
# can do every step by hand and get a byte-equivalent result.  If this script
# and that document ever disagree, the document is right.
#
# HOUSE STYLE (nvkvm-steamos/boot/steamos_boot.sh): check first, act only if
# wrong, log what changed.  Every stage is idempotent -- running the script
# twice converges, it does not duplicate.  Nothing is half-installed: the
# preflight refuses early, with a message that names the fix, rather than
# failing forty minutes deep in a kernel build.
#
# STAGES  (--only <name>, repeatable; --build / --install / --verify are groups)
#   0 preflight   root, /dev/kvm, NVIDIA driver, Kata, build deps, disk    [always]
#   1 kata        verify Kata Containers is present (--install-kata fetches it)
#   2 qemu        build nvkvm's QEMU                        BUILD
#   3 kernel      guest kernel + nvkvm-guest.ko + depmod    BUILD
#   4 rootfs      kata-nvkvm.image: kmod, CDI generator, module   BUILD
#   5 runtime     the shim + /etc/kata-containers/configuration-nvkvm.toml
#   6 engine      register the runtime with Docker / containerd
#   7 libs        host driver userspace bundle + the vecadd proof binary
#   8 verify      RUN the proof: vecadd in a container on the new runtime
#
#   BUILD stages (2,3,4) write only into --artifacts (default
#   /var/lib/nvkvm-kata/build) plus /opt/qemu-nvkvm.  INSTALL stages (1,5,6,7)
#   read from there and touch the host.  They are separable on purpose: a
#   prebuilt tarball, later, is nothing but a cached BUILD stage --
#   `--only install --artifacts /path/to/unpacked/tarball`.
#
# UNINSTALL
#   scripts/nvkvm-kata-uninstall.sh   -- reverts everything, from the manifest
#   this script writes at /var/lib/nvkvm-kata/install-manifest.
#
# USAGE
#   sudo scripts/nvkvm-kata-install.sh [options]
#     --nvkvm-src DIR     nvkvm-pv checkout      (default: clone into state dir)
#     --kata-src  DIR     kata-containers source (default: clone into state dir)
#     --artifacts DIR     build output dir       (default /var/lib/nvkvm-kata/build)
#     --prefix    DIR     install prefix         (default /opt/nvkvm-kata)
#     --runtime-name N    engine runtime name    (default nvkvm-kata)
#     --graphics  0|1     NVKVM_GRAPHICS         (default 0, compute-only)
#     --jobs      N       parallel make jobs     (default nproc)
#     --install-kata      download+install Kata Containers if absent
#     --kata-version V    Kata release to install (default 4.1.0)
#     --install-deps      apt-get the build dependencies that are missing
#     --containerd-cri    also register a CRI runtime handler in containerd
#     --no-docker         do not touch /etc/docker/daemon.json
#     --qemu PATH         use this QEMU binary instead of building one
#     --only STAGE        run only this stage (repeatable)
#     --build|--install|--verify   stage groups
#     --force             rebuild even when the artifact stamp already matches
#     --yes               do not prompt
set -uo pipefail

# ── constants ────────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# The driver-version rule, shared with gpu-cdi.py.  Sourced rather than
# retyped: the injector re-derives this on every container start and refuses to
# run if it disagrees with what the installer recorded.
# shellcheck source=lib/driver-version.sh
. "$HERE/lib/driver-version.sh"
STATE=/var/lib/nvkvm-kata
ARTIFACTS="$STATE/build"
BACKUP="$STATE/backup"
MANIFEST="$STATE/install-manifest"
PREFIX=/opt/nvkvm-kata
RUNTIME_NAME=nvkvm-kata
KATA_VERSION=4.1.0
# Named separately so the "no pinned digest" error can point at the version
# that HAS one, rather than at whatever --kata-version the operator just typed.
KATA_VERSION_DEFAULT=4.1.0
KATA_CONF_DIR=/etc/kata-containers
SHIM_ENV=/etc/nvkvm-kata/shim.env
GRAPHICS=0
JOBS="$(nproc 2>/dev/null || echo 4)"
NVKVM_SRC="" ; KATA_SRC="" ; QEMU_BIN=""
DO_INSTALL_KATA=0 ; DO_INSTALL_DEPS=0 ; DO_CRI=0 ; NO_DOCKER=0 ; FORCE=0 ; ASSUME_YES=0
STAGES=()
MIN_FREE_GB=40

# ── logging ──────────────────────────────────────────────────────────────────
# All diagnostics on stderr, so a helper's stdout stays its return value.
log()    { printf '[nvkvm-kata] %s\n' "$*" >&2; }
step()   { printf '\n[nvkvm-kata] ===== %s =====\n' "$*" >&2; }
ok()     { printf '[nvkvm-kata]   ok   %s\n' "$*" >&2; }
change() { printf '[nvkvm-kata]  CHANGED  %s\n' "$*" >&2; }
warn()   { printf '[nvkvm-kata] WARNING: %s\n' "$*" >&2; }
die() {
    printf '\n[nvkvm-kata] FATAL: %s\n' "$1" >&2
    [ $# -gt 1 ] && printf '[nvkvm-kata]   fix: %s\n' "$2" >&2
    exit 1
}

# ── argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --nvkvm-src)    NVKVM_SRC="$2"; shift 2 ;;
        --kata-src)     KATA_SRC="$2"; shift 2 ;;
        --artifacts)    ARTIFACTS="$2"; shift 2 ;;
        --prefix)       PREFIX="$2"; shift 2 ;;
        --runtime-name) RUNTIME_NAME="$2"; shift 2 ;;
        --graphics)     GRAPHICS="$2"; shift 2 ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --kata-version) KATA_VERSION="$2"; shift 2 ;;
        --qemu)         QEMU_BIN="$2"; shift 2 ;;
        --install-kata) DO_INSTALL_KATA=1; shift ;;
        --install-deps) DO_INSTALL_DEPS=1; shift ;;
        --containerd-cri) DO_CRI=1; shift ;;
        --no-docker)    NO_DOCKER=1; shift ;;
        --force)        FORCE=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --only)         STAGES+=("$2"); shift 2 ;;
        --build)        STAGES+=(qemu kernel rootfs); shift ;;
        --install)      STAGES+=(kata runtime engine libs); shift ;;
        --verify)       STAGES+=(verify); shift ;;
        -h|--help)      sed -n '2,70p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" "run $0 --help" ;;
    esac
done
[ ${#STAGES[@]} -eq 0 ] && STAGES=(kata qemu kernel rootfs runtime engine libs verify)

# ── which QEMU the shim will exec ────────────────────────────────────────────
# Resolved HERE, at parse time, and deliberately NOT inside stage_qemu().
#
# It used to be resolved inside that stage, which meant --qemu was silently
# ignored whenever the qemu stage did not run.  `--only runtime --qemu /path`
# therefore wrote the DEFAULT path into /etc/nvkvm-kata/shim.env.  That is not a
# loud failure: stage 5 asserts only that SOME executable is at the default
# path, and on a host that already has an unrelated /opt/qemu-nvkvm -- a
# different nvkvm-pv lineage, a distro QEMU, an older build -- the assertion
# passes.  You get a VM that boots perfectly on the wrong hypervisor and says
# nothing, and the two halves disagree about src/abi/nvgpu.h in ways that
# surface much later as garbage.  MEASURED 2026-08-28 on a host carrying a
# pre-existing QEMU 9.2.0 at that path.
#
# A flag that is accepted must take effect regardless of which stages run.
NVKVM_QEMU_PATH=/opt/qemu-nvkvm/bin/qemu-system-x86_64
QEMU_EXPLICIT=0
if [ -n "$QEMU_BIN" ]; then
    [ -x "$QEMU_BIN" ] || die "--qemu $QEMU_BIN is not executable" \
        "point it at a built qemu-system-x86_64"
    # Absolute: the shim exec()s this from a different working directory.
    NVKVM_QEMU_PATH="$(cd "$(dirname "$QEMU_BIN")" && pwd)/$(basename "$QEMU_BIN")"
    QEMU_EXPLICIT=1
fi

want() { local s; for s in "${STAGES[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# ── manifest: every path we create, every file we modify ─────────────────────
# The uninstaller reads this and nothing else, so "revert" is exact rather than
# a second list of guesses that drifts from the first.
manifest_add() {   # kind path [note]
    mkdir -p "$STATE"
    grep -qxF "$1	$2	${3:-}" "$MANIFEST" 2>/dev/null && return 0
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$MANIFEST"
}
backup_once() {    # path -- copy to $BACKUP the first time we touch it
    # Two statements, not one: `local p="$1" b="...${p#/}..."` expands every
    # argument BEFORE the builtin assigns any of them, so $p is still unset when
    # b is built -- "p: unbound variable" under set -u, and a silently wrong
    # backup filename without it.
    local p="$1"
    local b="$BACKUP/$(echo "${p#/}" | tr / _)"
    mkdir -p "$BACKUP"
    #
    # ONCE PER INSTALL CYCLE, NOT ONCE PER HOST.  This used to `return 0` the
    # moment a backup file existed, which also skipped the manifest_add -- so on
    # the SECOND install cycle it recorded nothing at all, and the uninstaller,
    # which reads the manifest and nothing else, silently reverted nothing.  The
    # "exact revert" property held only for the first install ever performed on
    # a host, which is not a property anyone would have assumed from the name.
    #
    # It is also why a stale backup could be restored over a good file: an
    # uninstall without --purge keeps $BACKUP, so an operator's own later edit
    # to /etc/docker/daemon.json was never backed up on the next install and
    # was overwritten on the next uninstall by a copy from the cycle before.
    # The uninstaller now rotates $BACKUP aside when it finishes, so an existing
    # backup here really does belong to the cycle in progress.
    #
    # The manifest entry is written on EVERY call.  manifest_add is idempotent
    # (it greps for the exact line first), so re-recording costs nothing and
    # the record is complete whichever call first touched the path.
    if [ -e "$b" ]; then       manifest_add modified "$p" "$b";       return 0; fi
    if [ -e "$b.ABSENT" ]; then manifest_add created "$p" "$b.ABSENT"; return 0; fi
    if [ -e "$p" ]; then cp -a "$p" "$b"; manifest_add modified "$p" "$b"
    else                 : > "$b.ABSENT";  manifest_add created  "$p" "$b.ABSENT"; fi
}

# ═════════════════════════════════════════════════════════════════════════════
# ═════════════════════════════════════════════════════════════════════════════
# DISTRO LAYER
# Everything this installer needs is checked by COMMAND or by HEADER, never by
# package name -- "is there a gcc" is the same question everywhere, and only the
# answer to "what do I install to get one" is distro-specific.  So there is one
# check list and one translation table, rather than three copies of the logic.
#
# Families, not distributions: Ubuntu and Debian differ in ways that do not
# matter here, and so do Fedora, Rocky and RHEL.  ID_LIKE from os-release is the
# standard way to ask, and derivatives (Mint, Manjaro, Alma) fall out for free.
# ═════════════════════════════════════════════════════════════════════════════
DISTRO_ID="" ; DISTRO_FAMILY="" ; DISTRO_PRETTY="" ; PKG_MGR=""

detect_distro() {
    local like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-}" ; DISTRO_PRETTY="${PRETTY_NAME:-${ID:-unknown}}" ; like="${ID_LIKE:-}"
    fi
    case " $DISTRO_ID $like " in
        *" debian "*|*" ubuntu "*)            DISTRO_FAMILY=debian ;;
        *" arch "*)                           DISTRO_FAMILY=arch ;;
        *" rhel "*|*" fedora "*|*" centos "*) DISTRO_FAMILY=rhel ;;
        *) case "$DISTRO_ID" in
               debian|ubuntu|linuxmint|pop|raspbian)      DISTRO_FAMILY=debian ;;
               arch|archarm|manjaro|endeavouros|garuda)   DISTRO_FAMILY=arch ;;
               fedora|rhel|centos|rocky|almalinux|ol)     DISTRO_FAMILY=rhel ;;
               *)                                         DISTRO_FAMILY=unknown ;;
           esac ;;
    esac
    case "$DISTRO_FAMILY" in
        debian) PKG_MGR="apt-get" ;;
        arch)   PKG_MGR="pacman" ;;
        rhel)   PKG_MGR="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)" ;;
    esac
}

# What provides <token>, per family.  Tokens are the things the checks below
# actually look for, so this table is the ONLY place a package name appears.
pkg_for() {   # token
    case "$DISTRO_FAMILY:$1" in
        debian:cc)        echo build-essential ;;
        debian:cxx)       echo build-essential ;;
        arch:cxx)         echo base-devel ;;
        rhel:cxx)         echo gcc-c++ ;;
        arch:cc)          echo base-devel ;;
        rhel:cc)          echo "gcc make" ;;
        debian:kvmhdr)    echo linux-libc-dev ;;
        arch:kvmhdr)      echo linux-api-headers ;;
        rhel:kvmhdr)      echo kernel-headers ;;
        debian:sslhdr)    echo libssl-dev ;;
        arch:sslhdr)      echo openssl ;;
        rhel:sslhdr)      echo openssl-devel ;;
        debian:elfhdr)    echo libelf-dev ;;
        arch:elfhdr)      echo libelf ;;
        rhel:elfhdr)      echo elfutils-libelf-devel ;;
        debian:losetup)   echo mount ;;
        *:losetup)        echo util-linux ;;
        arch:python3)     echo python ;;
        *:python3)        echo python3 ;;
        debian:xxd)       echo xxd ;;
        arch:xxd)         echo tinyxxd ;;
        rhel:xxd)         echo vim-common ;;
        debian:tomli)     echo python3-tomli ;;
        arch:tomli)       echo python-tomli ;;
        rhel:tomli)       echo python3-tomli ;;
        debian:docker)    echo docker.io ;;
        arch:docker)      echo docker ;;
        rhel:docker)      echo docker-ce ;;
        debian:objdump|arch:objdump|rhel:objdump) echo binutils ;;
        debian:depmod|arch:depmod|rhel:depmod)    echo kmod ;;
        # Everything else is named after itself in all three families:
        # git gzip flex bison cpio curl zstd patch file bc rsync tar
        *) echo "${1}" ;;
    esac
}

# Never swallow the package manager's own error.  An unsubscribed RHEL says
# "No match for argument: bc / Unable to find a match" -- which names the exact
# problem -- and hiding it behind "dnf failed installing: bc patch zstd" turns a
# 5-second diagnosis into a 20-minute one.  MEASURED on RHEL 9.5, 2026-08-28.
PKG_LOG=""
pkg_install() {   # packages...
    PKG_LOG="$(mktemp)"
    local rc=0
    case "$DISTRO_FAMILY" in
        debian) { DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; } \
                  >"$PKG_LOG" 2>&1 || rc=$? ;;
        arch)   pacman -Sy --noconfirm --needed "$@" >"$PKG_LOG" 2>&1 || rc=$? ;;
        rhel)   "$PKG_MGR" install -y "$@" >"$PKG_LOG" 2>&1 || rc=$? ;;
        *)      return 1 ;;
    esac
    if [ "$rc" != 0 ]; then
        warn "$PKG_MGR said:"
        sed 's/^/[nvkvm-kata]      | /' "$PKG_LOG" | tail -15 >&2
    fi
    return "$rc"
}

# EL9 hides a chunk of the build world in CRB (CodeReady Builder; "powertools"
# on EL8), which is DISABLED by default.  ninja-build, meson and libslirp-devel
# all live there, and without it nvkvm's own build_qemu.sh dies with
# "Unable to find a match: ninja-build meson libslirp-devel" on a host that
# looks perfectly well provisioned.  MEASURED on RHEL 9.5, 2026-08-28.
# EPEL carries a few others.  Both are no-ops if already enabled.
enable_extra_repos() {
    [ "$DISTRO_FAMILY" = rhel ] || return 0
    command -v dnf >/dev/null 2>&1 || return 0
    dnf -y install dnf-plugins-core >/dev/null 2>&1 || true
    local r
    for r in crb powertools; do
        if dnf config-manager --set-enabled "$r" >/dev/null 2>&1; then
            change "enabled the '$r' repository (ninja-build, meson, libslirp-devel live there)"
            return 0
        fi
    done
    warn "could not enable CRB/powertools -- if the QEMU build cannot find ninja-build,"
    warn "  meson or libslirp-devel, enable it by hand: dnf config-manager --set-enabled crb"
}

# The exact command a human should run, for the die() hint.  Generic advice
# ("install the build dependencies") is useless at 2am on an unfamiliar box.
pkg_install_cmd() {
    case "$DISTRO_FAMILY" in
        debian) echo "apt-get install $*" ;;
        arch)   echo "pacman -S $*" ;;
        rhel)   echo "$PKG_MGR install $*" ;;
        *)      echo "install (unknown package manager): $*" ;;
    esac
}

# STAGE 0 -- PREFLIGHT.  docs/install.md §0
# Everything this build needs, checked before anything is built, so a missing
# 200 KB package fails in one second instead of twenty minutes in.
# ═════════════════════════════════════════════════════════════════════════════
KATA_ROOT="" ; KATA_VER_FOUND="" ; DRIVER_VERSION="" ; DOCKER_OK=0 ; CTR_OK=0
CONTAINERD_MAJOR=""

preflight() {
    step "stage 0/8  preflight"

    [ "$(id -u)" -eq 0 ] || die "must run as root" "re-run under sudo"

    detect_distro
    if [ "$DISTRO_FAMILY" = unknown ]; then
        warn "unrecognised distribution '${DISTRO_ID:-?}' -- treating dependencies as pre-installed"
        warn "  tested families: debian/ubuntu, arch, rhel/fedora.  --install-deps cannot help here."
    else
        ok "$DISTRO_PRETTY (family: $DISTRO_FAMILY, packages: $PKG_MGR)"
    fi
    [ "$(uname -m)" = "x86_64" ] || die "nvkvm is x86-64 only (this host is $(uname -m))" \
        "nothing fixes this; see nvkvm-pv/scripts/build_qemu.sh"

    # /dev/kvm.  CPU vmx/svm flags prove nothing -- a container inherits its
    # host's flags -- so test the device node itself, and say what a container
    # looks like when it fails.
    if [ ! -c /dev/kvm ]; then
        die "/dev/kvm is missing -- Kata cannot start a VM here" \
            "on a rented GPU box this usually means you got a container, not a VM: check 'systemd-detect-virt' (want kvm/none, not docker)"
    fi
    [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm is not read-write for root" "check ownership/permissions on /dev/kvm"
    ok "/dev/kvm present ($(systemd-detect-virt 2>/dev/null || echo 'virt unknown'))"

    # python3 is GLOBAL, not a build dependency.  Three helpers here are Python
    # -- kata-conf-edit.py (stage 5), docker-runtime.py (stage 6) and
    # lib/gpu-cdi.py -- and gpu-cdi.py runs from the shim on EVERY container
    # start, forever.  A host without python3 cannot run a GPU container at all,
    # whichever stages were used to install.
    #
    # It used to be asserted only under `want qemu || kernel || rootfs || libs`,
    # so `--only runtime` or `--only engine` failed deep inside a stage instead
    # of here.  That is the same shape as the `--qemu`-ignored-unless-the-qemu-
    # stage-ran bug fixed earlier: a dependency guarded by the wrong stage.
    #
    # tomllib/tomli is NOT checked here on purpose -- that one really is
    # build-only (QEMU 11's configure parses pyproject.toml), and our own
    # helpers use nothing outside the standard library.
    command -v python3 >/dev/null 2>&1 \
        || die "python3 is required but not installed" \
               "install the $(pkg_for python3) package for your distro"
    ok "python3 present ($(python3 --version 2>&1))"

    # NVIDIA driver.  Read /proc, not nvidia-smi: nvidia-smi can fail for
    # reasons that have nothing to do with the driver being loaded.
    [ -r /proc/driver/nvidia/version ] || die \
        "no NVIDIA driver loaded (/proc/driver/nvidia/version is absent)" \
        "install the NVIDIA driver on the HOST; nvkvm forwards to it and never unbinds it"
    # How the version is parsed is subtle enough, and has broken enough real
    # installs, to live in one sourceable file with its evidence: see
    # scripts/lib/driver-version.sh.  It is the SAME rule gpu-cdi.py applies on
    # every container start, and `gpu-cdi.py self-test` asserts the two agree.
    DRIVER_VERSION="$(nvkvm_driver_version)"
    [ -n "$DRIVER_VERSION" ] || die "could not parse the driver version out of /proc/driver/nvidia/version" \
        "cat it and report the format"
    ok "NVIDIA host driver $DRIVER_VERSION"
    ls /dev/nvidiactl >/dev/null 2>&1 || warn "/dev/nvidiactl is absent -- the driver is loaded but no device node exists"

    # cgroup version -- not fatal, but it changes what is TRUE about isolation,
    # and a silent v1 host would invalidate docs/design/07's findings.
    if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
        ok "cgroup v2"
        warn "on cgroup v2 the container device cgroup is NOT enforced inside the guest"
        warn "  (kata-agent computes the allowlist and cgroups-rs discards it --"
        warn "   docs/design/07-end-to-end.md §8.1).  VISIBLE_CDI_DEVICES controls"
        warn "   which device NODES are created, not access.  Do not rely on it as a boundary."
    else
        warn "cgroup v1 -- UNTESTED for this stack (docs/design/07 §11 item 5)"
    fi

    # Kata.
    detect_kata
    if [ -z "$KATA_ROOT" ]; then
        if want kata && [ "$DO_INSTALL_KATA" = 1 ]; then
            log "Kata Containers not found; --install-kata given, will fetch $KATA_VERSION"
        else
            die "Kata Containers is not installed (looked for /opt/kata/bin/containerd-shim-kata-v2)" \
                "re-run with --install-kata, or install Kata $KATA_VERSION by hand -- docs/install.md §1"
        fi
    else
        ok "Kata $KATA_VER_FOUND at $KATA_ROOT"
    fi

    # Container engine.  A fresh RHEL box has docker and containerd INSTALLED
    # and both units inactive, so "is the binary there" is not the question.
    # Starting a service we are about to reconfigure is squarely in scope --
    # stage 6 restarts both anyway.
    local svc
    for svc in containerd docker; do
        if command -v "$svc" >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
            if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 \
               && ! systemctl is-active --quiet "$svc" 2>/dev/null; then
                change "$svc is installed but not running -- starting it"
                systemctl enable --now "$svc" >/dev/null 2>&1 \
                    || warn "could not start $svc -- 'systemctl status $svc' will say why"
                sleep 2
            fi
        fi
    done

    if command -v containerd >/dev/null 2>&1; then
        CTR_OK=1
        CONTAINERD_MAJOR="$(containerd --version 2>/dev/null | awk '{print $3}' | sed 's/^v//' | cut -d. -f1)"
        ok "containerd $(containerd --version 2>/dev/null | awk '{print $3}')"
    else
        local hint
        case "$DISTRO_FAMILY" in
            debian) hint="apt-get install containerd.io  (or docker-ce, which brings it)" ;;
            arch)   hint="pacman -S containerd  (or docker, which brings it)" ;;
            rhel)   hint="$PKG_MGR install containerd.io  -- needs Docker's repo: $PKG_MGR config-manager --add-repo https://download.docker.com/linux/${DISTRO_ID}/docker-ce.repo" ;;
            *)      hint="install containerd" ;;
        esac
        die "containerd is not installed" "$hint"
    fi
    # Docker is OPTIONAL from here down.  Its absence is a normal, supported
    # configuration (k8s nodes, podman hosts) and must never fail a stage.
    if [ "$NO_DOCKER" = 1 ]; then
        log "docker: SKIPPED (--no-docker); containerd is the baseline and is enough"
    elif ! command -v docker >/dev/null 2>&1; then
        ok "no Docker on this host -- installing for containerd only (this is supported)"
    fi
    if [ "$NO_DOCKER" = 0 ] && command -v docker >/dev/null 2>&1; then
        local dv dmaj
        dv="$(docker version -f '{{.Server.Version}}' 2>/dev/null)"
        if [ -z "$dv" ]; then
            warn "docker CLI present but the daemon does not answer -- skipping Docker registration"
        else
            dmaj="${dv%%.*}"
            if [ "${dmaj:-0}" -ge 23 ] 2>/dev/null; then
                DOCKER_OK=1; ok "docker $dv (>= 23, supports containerd shims as named runtimes)"
            else
                warn "docker $dv is older than 23.0 and cannot map a named runtime onto a containerd shim"
                warn "  -> skipping Docker registration; the containerd path still works"
                warn "  -> fix: upgrade Docker, then re-run with --only engine"
            fi
        fi
    fi

    # Build dependencies.  Checked by command and by header -- never by package
    # name -- so the same list serves every family; pkg_for() translates.
    if want qemu || want kernel || want rootfs || want libs; then
        local missing=() tokens=()
        _need() {   # command token
            command -v "$1" >/dev/null 2>&1 || { missing+=("$1"); tokens+=("$2"); }
        }
        _need gcc cc      ; _need make cc      ; _need git git
        # QEMU's meson probes for a C++ compiler.  Debian's build-essential and
        # Arch's base-devel bring one; a minimal RHEL does not.
        _need g++ cxx
        _need objdump objdump ; _need gzip gzip ; _need tar tar
        _need flex flex   ; _need bison bison  ; _need cpio cpio
        _need curl curl   ; _need zstd zstd    ; _need depmod depmod
        # bzip2 is a QEMU meson dependency ("ERROR: Program 'bzip2' not found").
        # Debian/Ubuntu ship it in a base install; a minimal RHEL does not.
        _need bzip2 bzip2
        # xxd is a QEMU build dependency, and it is packaged under a DIFFERENT
        # NAME in all three families: `xxd` on Debian/Ubuntu, `tinyxxd` on Arch
        # (Arch has no package called xxd at all -- it is owned by tinyxxd, vim
        # or gvim), `vim-common` on RHEL.  nvkvm-pv's build_qemu.sh asks pacman
        # for "xxd" and gets nothing, then fails its own check with
        # "ERROR: missing build dependencies: xxd".  MEASURED on Arch,
        # 2026-08-28.  Satisfying it here means that never happens.
        _need xxd xxd
        _need losetup losetup
        _need patch patch ; _need file file
        # bc and rsync are needed by the KERNEL build, not by us, and their
        # absence surfaces two minutes in as an unattributable make error.
        _need bc bc       ; _need rsync rsync
        [ -e /usr/include/linux/kvm.h ] || { missing+=("linux/kvm.h"); tokens+=(kvmhdr); }
        # One header per operand: `ls a b` exits non-zero when EITHER is
        # absent, so a glob-plus-literal `ls` reported libssl-dev/libelf-dev
        # missing on every run, installed or not, and re-ran the package
        # manager each time.
        _need_hdr() {   # header token
            local h
            for h in "/usr/include/$1" /usr/include/*/"$1"; do [ -e "$h" ] && return 0; done
            missing+=("$1"); tokens+=("$2")
        }
        _need_hdr openssl/ssl.h sslhdr
        _need_hdr libelf.h      elfhdr
        # QEMU 11's configure parses pyproject.toml, so it needs tomllib --
        # stdlib from Python 3.11, a separate `tomli` package before that.
        # RHEL 9 ships Python 3.9, so a perfectly provisioned EL9 host fails
        # deep inside the QEMU build with
        #     *** Ouch! *** found no usable tomli, please install it
        # MEASURED on RHEL 9.5, 2026-08-28.  Debian 12 and Ubuntu 22.04+ are
        # already on 3.11+; Arch is current.  Only check when it is needed.
        if ! python3 -c 'import tomllib' >/dev/null 2>&1 \
           && ! python3 -c 'import tomli'   >/dev/null 2>&1; then
            missing+=("python tomllib/tomli"); tokens+=(tomli)
        fi
        # NOTE: no container engine in this list.  Docker is NOT required to
        # install nvkvm-kata -- a Kubernetes node or a podman host has
        # containerd and no Docker at all, and those are exactly the hosts this
        # project is for.  The rootfs stage used to need `docker` to harvest
        # kmod; it now fetches the .deb directly, so nothing here does.
        if [ ${#missing[@]} -gt 0 ]; then
            local pkgs t
            pkgs="$(for t in "${tokens[@]}"; do pkg_for "$t"; done | tr ' ' '\n' | sort -u | tr '\n' ' ')"
            if [ "$DO_INSTALL_DEPS" = 1 ] && [ "$DISTRO_FAMILY" != unknown ]; then
                enable_extra_repos
                change "installing build deps ($DISTRO_FAMILY): $pkgs"
                # shellcheck disable=SC2086
                pkg_install $pkgs \
                  || die "$PKG_MGR failed installing: $pkgs" \
                         "run it by hand and re-run: $(pkg_install_cmd "$pkgs")"
            else
                die "missing build dependencies: ${missing[*]}" \
                    "re-run with --install-deps, or: $(pkg_install_cmd "$pkgs")"
            fi
        fi
        ok "build dependencies present"
        # QEMU has its own long dependency list; build_qemu.sh --install-deps owns it.
    fi

    # Disk.  A guest kernel tree plus a QEMU tree plus a 270 MB rootfs copy.
    local free_gb blocks bsize
    mkdir -p "$ARTIFACTS"
    blocks="$(stat -f -c %a "$ARTIFACTS")"; bsize="$(stat -f -c %S "$ARTIFACTS")"
    free_gb=$(( blocks / 1024 * bsize / 1024 / 1024 ))
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        die "only ${free_gb} GB free on $ARTIFACTS, need >= ${MIN_FREE_GB} GB" \
            "free space, or point --artifacts at a bigger filesystem"
    fi
    ok "${free_gb} GB free on $ARTIFACTS"

    # Sources.
    resolve_sources
    want kernel && ensure_yq
    ok "preflight passed"
}

# Kata's build-kernel.sh reads tools/packaging/kernel/kata_config_version and
# versions.yaml with yq(1), and dies "yq command is not in your $PATH" -- a
# message that arrives AFTER the QEMU build if you let it, which is exactly the
# fail-late this preflight exists to prevent.  Use Kata's own installer so the
# version is the one Kata expects (v4.44.5, mikefarah/yq, not the python yq).
ensure_yq() {
    if command -v yq >/dev/null 2>&1; then ok "yq: $(yq --version 2>&1 | head -1)"; return 0; fi
    [ -x "$KATA_SRC/ci/install_yq.sh" ] || die \
        "yq is not on PATH and $KATA_SRC/ci/install_yq.sh is absent" \
        "install mikefarah/yq onto PATH -- kata's build-kernel.sh cannot read versions.yaml without it"
    change "installing yq with kata's own ci/install_yq.sh (INSTALL_IN_GOPATH=false -> /usr/local/bin)"
    ( cd "$KATA_SRC" && INSTALL_IN_GOPATH=false ./ci/install_yq.sh >/dev/null 2>&1 ) \
        || die "kata's ci/install_yq.sh failed" "install mikefarah/yq onto PATH by hand"
    # Deliberately NOT recorded in the manifest: yq is a general-purpose tool and
    # an uninstall of nvkvm-kata has no business deleting it.
    command -v yq >/dev/null 2>&1 || die "yq still not on PATH after ci/install_yq.sh" "install it by hand"
    ok "yq: $(yq --version 2>&1 | head -1)"
}

detect_kata() {
    KATA_ROOT="" ; KATA_VER_FOUND=""
    local r
    for r in /opt/kata /usr/local /usr; do
        if [ -x "$r/bin/containerd-shim-kata-v2" ]; then KATA_ROOT="$r"; break; fi
    done
    [ -n "$KATA_ROOT" ] || return 0
    if [ -x "$KATA_ROOT/bin/kata-runtime" ]; then
        # `kata-runtime --version` prints "kata-runtime  : 4.1.0" on the first
        # line, then commit and OCI spec lines.  Take the first version-looking
        # token, not a keyword match -- the word "version" never appears.
        KATA_VER_FOUND="$("$KATA_ROOT/bin/kata-runtime" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1)"
    fi
    [ -n "$KATA_VER_FOUND" ] || KATA_VER_FOUND="unknown"
}

resolve_sources() {
    if [ -z "$NVKVM_SRC" ]; then
        for c in /workspace/nvkvm-pv "$REPO/../nvkvm-pv" "$STATE/src/nvkvm-pv"; do
            [ -f "$c/src/guest/Makefile" ] && { NVKVM_SRC="$(cd "$c" && pwd)"; break; }
        done
    fi
    if [ -z "$KATA_SRC" ]; then
        for c in "$STATE/src/kata-containers" /root/kata-containers; do
            [ -d "$c/tools/packaging/kernel" ] && { KATA_SRC="$(cd "$c" && pwd)"; break; }
        done
    fi
    if want qemu || want kernel; then
        # Clone it, the same way kata-containers is cloned below.  --help and
        # docs/install.md both promise "default: clone into state dir"; before
        # this, resolve_sources only *searched* and then died, so the README's
        # one-command Quickstart could never work on a genuinely fresh host.
        if [ -z "$NVKVM_SRC" ]; then
            change "cloning nvkvm-pv source into $STATE/src/nvkvm-pv"
            mkdir -p "$STATE/src"
            git clone --depth 1 https://github.com/reindertpelsma/nvkvm-pv "$STATE/src/nvkvm-pv" \
                >/dev/null 2>&1 || die "clone of nvkvm-pv failed" \
                    "clone it by hand and pass --nvkvm-src DIR"
            NVKVM_SRC="$STATE/src/nvkvm-pv"
        fi
        [ -f "$NVKVM_SRC/src/guest/Makefile" ] || die "$NVKVM_SRC is not an nvkvm-pv checkout" "expected src/guest/Makefile in it"
        ok "nvkvm-pv: $NVKVM_SRC"
    fi
    if want kernel; then
        if [ -z "$KATA_SRC" ]; then
            change "cloning kata-containers source into $STATE/src/kata-containers"
            mkdir -p "$STATE/src"
            git clone --depth 1 https://github.com/kata-containers/kata-containers "$STATE/src/kata-containers" \
                >/dev/null 2>&1 || die "clone of kata-containers failed" "clone it by hand and pass --kata-src"
            KATA_SRC="$STATE/src/kata-containers"
        fi
        [ -d "$KATA_SRC/tools/packaging/kernel" ] || die "$KATA_SRC is not a kata-containers checkout" "expected tools/packaging/kernel in it"
        ok "kata-containers source: $KATA_SRC"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 1 -- KATA.  docs/install.md §1
#
# TWO TARBALLS, DOWNLOADED AND EXTRACTED TO `/` AS ROOT.  Until now that was
# done on nothing but "curl -f succeeded", which is the weakest check in this
# installer guarding the most privileged action in it.  Both halves are closed
# below, and they close different things:
#
#   verify_kata_tarball   -- pins the SHA-256 of each release artifact.  The
#       digests come from GitHub's own release API, so this pins the artifact
#       rather than independently authenticating it: what it buys is that a
#       retagged or re-uploaded release stops the install instead of silently
#       changing what runs the guests.  Unknown versions (--kata-version) have
#       no pin and are refused unless the operator says so explicitly, because
#       the alternative is a flag whose use is indistinguishable from the
#       default.
#
#   assert_tar_confined   -- reads the member list BEFORE extracting and
#       refuses anything outside opt/kata/: an absolute path, a `..`, or a
#       symlink pointing out of the tree.  GNU tar strips a leading `/` but
#       follows an existing symlink on the way in, so `-C /` on an archive
#       nobody has looked at is a write-anywhere primitive.  This costs one
#       decompression pass over an archive we are about to decompress anyway.
# ═════════════════════════════════════════════════════════════════════════════

# Recorded 2026-08-29 from the GitHub release API for tag 4.1.0.
# To add a version: curl the release JSON and read each asset's `digest`.
# shellcheck disable=SC2034  # read by indirect expansion in verify_kata_tarball
KATA_SHA256_kata_static_4_1_0=3dc6b69c4acb787b967b04b64599a20d02a8beb1a8eaab3084110df9d0b08c96
# shellcheck disable=SC2034  # read by indirect expansion in verify_kata_tarball
KATA_SHA256_kata_go_static_4_1_0=8b32080424c884238ee8d52060fdfd060fbe2b5fdfa4eb9ff2772b382b432b55

verify_kata_tarball() {   # <artifact name> <file>
    local a="$1" f="$2" var want got
    var="KATA_SHA256_$(printf '%s_%s' "$a" "$KATA_VERSION" | tr '.-' '__')"
    want="${!var:-}"
    if [ -z "$want" ]; then
        [ "${NVKVM_KATA_ALLOW_UNPINNED:-0}" = 1 ] || die \
            "no pinned SHA-256 for $a $KATA_VERSION" \
            "this installer extracts that tarball to / as root. Either use a pinned version (default $KATA_VERSION_DEFAULT), add the digest to $var in this script, or set NVKVM_KATA_ALLOW_UNPINNED=1 if you have checked it yourself"
        warn "$a $KATA_VERSION has no pinned digest and NVKVM_KATA_ALLOW_UNPINNED=1 -- extracting it unverified"
        return 0
    fi
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || die \
        "SHA-256 mismatch for $a $KATA_VERSION" \
        "expected $want, got $got -- do not extract this; the release was re-uploaded, or the download was tampered with"
    ok "$a $KATA_VERSION matches its pinned digest"
}

assert_tar_confined() {   # <tarball> <required top-level prefix>
    local f="$1" prefix="$2" listing bad allow acc comp rest
    # The ANCESTORS of the prefix are legitimate members: an archive rooted at
    # opt/kata/ still carries `opt/` itself, and a check that rejected that
    # would reject every real Kata release -- a check nobody can ship is worse
    # than none, because it gets deleted rather than fixed.  Build the allowed
    # set from the prefix's own components instead of hardcoding it.
    allow=""; acc=""; rest="$prefix"
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        acc="${acc:+$acc/}$comp"
        allow="${allow:+$allow|}$acc/?"
        case "$rest" in *"/"*) rest="${rest#*/}" ;; *) rest="" ;; esac
    done
    # The listing is captured WHOLE before anything filters it.  A
    # `tar -tf | grep | head` pipeline under `set -o pipefail` dies with a bare
    # exit 141 the moment head closes the pipe on a large archive -- the same
    # SIGPIPE trap that silently broke fetch_deb_kmod in this repo.
    listing="$(tar -I zstd -tf "$f" 2>/dev/null)" \
        || die "could not list $(basename "$f")" "the archive is truncated, or not zstd"
    # Absolute members and any `..` component are rejected outright: GNU tar
    # strips a leading `/` but still follows a symlink already on disk, so
    # `-C /` on an archive nobody has read is a write-anywhere primitive.
    # `.` / `./` is the archive root and is a real member of both Kata
    # tarballs -- VERIFIED against the published kata-static-4.1.0, whose first
    # member is exactly `./`.  Omitting it here would reject every genuine
    # release, which is how a confinement check turns into a deleted one.
    bad="$(printf '%s\n' "$listing" | grep -vE "^(\.|\./|(\./)?($allow|$prefix/.+))\$" || true)"
    bad="$bad$(printf '%s\n' "$listing" | grep -E '(^|/)\.\.(/|$)' || true)"
    [ -z "$bad" ] || die \
        "$(basename "$f") has members outside $prefix/ -- refusing to extract it to /" \
        "first offenders: $(printf '%s\n' "$bad" | sed -n '1,5p' | tr '\n' ' ')"
}

stage_kata() {
    step "stage 1/8  Kata Containers"
    detect_kata
    if [ -n "$KATA_ROOT" ]; then ok "already installed: Kata $KATA_VER_FOUND at $KATA_ROOT"; else
        [ "$DO_INSTALL_KATA" = 1 ] || die "Kata is absent and --install-kata was not given" "re-run with --install-kata"
        # BOTH tarballs.  kata-static carries the guest assets and the VMMs;
        # kata-go-static carries containerd-shim-kata-v2 and the configs.
        # Installing only the first leaves configuration.toml a DANGLING SYMLINK
        # and no shim -- measured, docs/design/07-end-to-end.md §10.
        local a url
        for a in kata-static kata-go-static; do
            url="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${a}-${KATA_VERSION}-amd64.tar.zst"
            change "fetching $a $KATA_VERSION"
            curl -fsSL -o "$STATE/$a.tar.zst" "$url" || die "download failed: $url" "check the version with --kata-version"
            verify_kata_tarball "$a" "$STATE/$a.tar.zst"
            assert_tar_confined "$STATE/$a.tar.zst" opt/kata
            tar -I zstd -xf "$STATE/$a.tar.zst" -C / || die "extract failed for $a" "check disk space in /opt"
            rm -f "$STATE/$a.tar.zst"
        done
        manifest_add created /opt/kata "kata-$KATA_VERSION installed by this script"
        detect_kata
        [ -n "$KATA_ROOT" ] || die "Kata still not found after extracting both tarballs" "inspect /opt/kata"
        change "installed Kata $KATA_VERSION at $KATA_ROOT"
    fi

    # The stock shim on PATH, so the stock `kata` runtime keeps working.  Only
    # create it if it is missing: never overwrite someone's existing shim.
    if [ ! -e /usr/bin/containerd-shim-kata-v2 ] && [ ! -e /usr/local/bin/containerd-shim-kata-v2 ]; then
        ln -sf "$KATA_ROOT/bin/containerd-shim-kata-v2" /usr/local/bin/containerd-shim-kata-v2
        manifest_add created /usr/local/bin/containerd-shim-kata-v2
        change "linked /usr/local/bin/containerd-shim-kata-v2 -> $KATA_ROOT/bin/"
    else
        ok "stock kata shim already on PATH"
    fi

    # The stock configuration, if the admin has none.  We never edit it.
    if [ ! -e "$KATA_CONF_DIR/configuration.toml" ]; then
        mkdir -p "$KATA_CONF_DIR"
        cp "$(stock_kata_config)" "$KATA_CONF_DIR/configuration.toml"
        manifest_add created "$KATA_CONF_DIR/configuration.toml"
        change "installed stock $KATA_CONF_DIR/configuration.toml"
    else
        ok "stock $KATA_CONF_DIR/configuration.toml present -- NOT touched"
    fi
}

stock_kata_config() {
    local c
    for c in "$KATA_ROOT/share/defaults/kata-containers/configuration-qemu.toml" \
             "$KATA_ROOT/share/defaults/kata-containers/configuration.toml"; do
        # -e follows symlinks; the shipped configuration.toml is a symlink and
        # is DANGLING when only one of the two tarballs was installed.
        [ -e "$c" ] && { readlink -f "$c"; return 0; }
    done
    die "no stock Kata QEMU configuration found under $KATA_ROOT/share/defaults/kata-containers" \
        "install the kata-static tarball too -- docs/install.md §1"
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 2 -- QEMU.  docs/install.md §2
# ═════════════════════════════════════════════════════════════════════════════
stage_qemu() {
    # build_qemu.sh installs its own dependencies, and on EL9 half of them are
    # in CRB.  Enable it here too: --only qemu skips preflight's dep block.
    [ "$DO_INSTALL_DEPS" = 1 ] && enable_extra_repos
    step "stage 2/8  nvkvm's QEMU"
    if [ "$QEMU_EXPLICIT" = 1 ]; then
        # Already resolved and checked at parse time.  An explicitly supplied
        # binary is never rebuilt over, not even under --force.
        ok "using --qemu $NVKVM_QEMU_PATH"
    elif [ -x "$NVKVM_QEMU_PATH" ] && [ "$FORCE" = 0 ]; then
        ok "already built: $NVKVM_QEMU_PATH"
    else
        change "building nvkvm QEMU (this is the long one, ~10-20 min on a cold tree)"
        local fargs=(--install-deps); [ "$FORCE" = 1 ] && fargs+=(--force)
        bash "$NVKVM_SRC/scripts/build_qemu.sh" "${fargs[@]}" \
            || die "nvkvm QEMU build failed" "run $NVKVM_SRC/scripts/build_qemu.sh by hand and read its output"
    fi
    # Assert the device exists.  A QEMU that builds but has no virtio-nvgpu is
    # the failure mode that produces a booting VM with no GPU and no clue why.
    "$NVKVM_QEMU_PATH" -device help 2>/dev/null | grep -q 'virtio-nvgpu' \
        || die "$NVKVM_QEMU_PATH has no virtio-nvgpu device" \
               "the QEMU build did not apply nvkvm's patches: rebuild with --force"
    ok "$NVKVM_QEMU_PATH has virtio-nvgpu ($("$NVKVM_QEMU_PATH" --version | head -1))"
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 3 -- GUEST KERNEL.  docs/install.md §3
# The one upstream change in the whole project lives inside build-guest-kernel.sh
# (widening build-kernel.sh's -g vendor validation), and so does the depmod that
# neither build-kernel.sh nor rootfs.sh runs.
# ═════════════════════════════════════════════════════════════════════════════
stage_kernel() {
    step "stage 3/8  guest kernel + nvkvm-guest.ko"
    mkdir -p "$ARTIFACTS"
    local nvkvm_sha; nvkvm_sha="$(git -C "$NVKVM_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    local stamp="$ARTIFACTS/kernel.stamp"
    local want_stamp="nvkvm=$nvkvm_sha graphics=$GRAPHICS"

    if [ "$FORCE" = 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want_stamp" ] \
       && [ -f "$ARTIFACTS/release" ] && [ -f "$ARTIFACTS/vmlinuz-$(cat "$ARTIFACTS/release")" ] \
       && [ -d "$ARTIFACTS/modules" ]; then
        ok "already built: $(cat "$ARTIFACTS/release") (stamp matches)"
        return 0
    fi
    change "building guest kernel (NVKVM_GRAPHICS=$GRAPHICS, -j$JOBS)"
    bash "$HERE/build-guest-kernel.sh" \
        --kata-src "$KATA_SRC" --nvkvm-src "$NVKVM_SRC" \
        --out "$ARTIFACTS" --graphics "$GRAPHICS" --jobs "$JOBS" \
        || die "guest kernel build failed" "re-run scripts/build-guest-kernel.sh by hand -- docs/install.md §3"
    printf '%s' "$want_stamp" > "$stamp"
    local rel; rel="$(cat "$ARTIFACTS/release")"
    # build-guest-kernel.sh asserts modules.dep itself; assert the output here
    # too, because a stage that reports success without an artifact is the exact
    # failure this project has been bitten by.
    [ -f "$ARTIFACTS/vmlinuz-$rel" ] || die "no vmlinuz-$rel in $ARTIFACTS" "the kernel stage reported success but produced nothing"
    grep -q 'nvkvm-guest\.ko' "$ARTIFACTS/modules/lib/modules/$rel/modules.dep" \
        || die "modules.dep does not mention nvkvm-guest.ko" "modprobe would fail in the guest -- docs/design/04-guest-kernel.md"
    ok "guest kernel $rel, module depmod'd and resolvable"
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 4 -- GUEST ROOTFS.  docs/install.md §4
# Always rebuilt from the pristine stock image, never edited in place, so the
# stage is idempotent by construction rather than by cleanup.
# ═════════════════════════════════════════════════════════════════════════════
NVKVM_IMAGE=""
stage_rootfs() {
    step "stage 4/8  guest rootfs (kmod + CDI generator + the module)"
    [ -f "$ARTIFACTS/release" ] || die "no kernel artifacts in $ARTIFACTS" "run the kernel stage first (--only kernel)"
    local rel; rel="$(cat "$ARTIFACTS/release")"
    detect_kata
    [ -n "$KATA_ROOT" ] || die "Kata not found" "run the kata stage first"

    local stock=""
    for c in "$KATA_ROOT/share/kata-containers/kata-ubuntu-noble.image" \
             "$KATA_ROOT/share/kata-containers/kata-containers.img"; do
        [ -e "$c" ] && { stock="$(readlink -f "$c")"; break; }
    done
    [ -n "$stock" ] || die "no stock Kata rootfs image found in $KATA_ROOT/share/kata-containers" \
        "install the kata-static tarball -- docs/install.md §1"

    NVKVM_IMAGE="$ARTIFACTS/kata-nvkvm.image"
    local stamp="$ARTIFACTS/rootfs.stamp"
    #
    # THE STAMP HAS TO COVER EVERY INPUT, not just the stock image.
    #
    # It used to be `rel=<kernel release> stock=<hash of the stock image>`, and
    # neither term moves when the thing that actually changed is ours:
    #
    #   * update this repo -- a fix to prepare-guest-rootfs.sh's CDI generator,
    #     say -- and the stamp still matches, so the stage says "already built"
    #     and the fix never reaches the image.  The comment above this stage
    #     says it is "idempotent by construction" because it always rebuilds
    #     from pristine stock; the stamp is exactly the cleanup-shaped shortcut
    #     that claim rules out, and it is what made the claim untrue.
    #
    #   * change nvkvm-guest's source and rebuild stage 3, and $rel is unchanged
    #     whenever the kernel release is -- which it usually is.  The rootfs
    #     then keeps the OLD module while the kernel stamp reports a new build,
    #     and the guest runs a module that does not match the source tree.
    #
    # kernel= folds in stage 3's stamp, which already carries the nvkvm commit;
    # tools= folds in the two scripts that do the editing.
    local kstamp; kstamp="$(cat "$ARTIFACTS/kernel.stamp" 2>/dev/null || echo none)"
    local tools; tools="$(sha256sum "$HERE/prepare-guest-rootfs.sh" "$HERE/inject-guest-modules.sh" \
                            "$HERE/lib/image-lock.sh" 2>/dev/null | sha256sum | cut -c1-16)"
    local want_stamp
    want_stamp="rel=$rel stock=$(sha256sum "$stock" | cut -c1-16) kernel=$kstamp tools=$tools"
    if [ "$FORCE" = 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want_stamp" ] && [ -f "$NVKVM_IMAGE" ]; then
        ok "already built: $NVKVM_IMAGE (stamp matches)"
        return 0
    fi

    change "copying stock rootfs $(basename "$stock") -> $(basename "$NVKVM_IMAGE")"
    rm -f "$NVKVM_IMAGE" "$NVKVM_IMAGE.orig"
    cp -f "$stock" "$NVKVM_IMAGE"

    # 4a. kmod + the guest-side CDI generator.  Kata's shipped rootfs has NO
    #     modprobe, no kmod and no busybox, so the shipped kernel_modules
    #     mechanism cannot run on the shipped image at all.
    bash "$HERE/prepare-guest-rootfs.sh" --image "$NVKVM_IMAGE" \
        || die "prepare-guest-rootfs.sh failed" "docs/install.md §4a"
    # 4b. the module + a VALID modules.dep.
    bash "$HERE/inject-guest-modules.sh" --image "$NVKVM_IMAGE" \
        --modules "$ARTIFACTS/modules" --release "$rel" \
        || die "inject-guest-modules.sh failed" "docs/install.md §4b"
    rm -f "$NVKVM_IMAGE.orig"

    printf '%s' "$want_stamp" > "$stamp"
    ok "$NVKVM_IMAGE ($(du -h "$NVKVM_IMAGE" | cut -f1))"
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 5 -- RUNTIME.  docs/install.md §5
# The shim, the shim's environment file, and a SECOND Kata configuration.  The
# stock /etc/kata-containers/configuration.toml is never read except as a
# template and never written.
# ═════════════════════════════════════════════════════════════════════════════
NVKVM_CONF="" ; SHIM_PATH=""
stage_runtime() {
    step "stage 5/8  the QEMU shim and a second Kata configuration"
    local rel; rel="$(cat "$ARTIFACTS/release" 2>/dev/null)" || true
    [ -n "$rel" ] || die "no $ARTIFACTS/release" "run the build stages first (--build)"
    [ -f "$ARTIFACTS/kata-nvkvm.image" ] || die "no $ARTIFACTS/kata-nvkvm.image" "run the rootfs stage first"
    detect_kata
    [ -n "$KATA_ROOT" ] || die "Kata not found" "run the kata stage first"

    NVKVM_CONF="$KATA_CONF_DIR/configuration-nvkvm.toml"
    SHIM_PATH="$PREFIX/bin/nvkvm-qemu-shim"
    # The shim exec()s this.  Assert it here as well as in stage 2, because
    # --only runtime skips stage 2 entirely and a shim pointing at nothing
    # fails as an unattributable "failed to create shim task".
    [ -x "$NVKVM_QEMU_PATH" ] || die "no nvkvm QEMU at $NVKVM_QEMU_PATH" \
        "run the qemu stage (--only qemu), or pass --qemu /path/to/qemu-system-x86_64"

    # --- 5a. install the artifacts under one prefix ------------------------
    install -d "$PREFIX/bin" "$PREFIX/share" "$PREFIX/nvidia/lib" "$PREFIX/nvidia/bin"
    manifest_add created "$PREFIX"
    install -m0755 "$HERE/nvkvm-qemu-shim.sh" "$SHIM_PATH"
    # The GPU injector.  Runs once per container, from the containerd shim
    # wrapper below, and is what removes the manual `volumes:` +
    # LD_LIBRARY_PATH the README used to require.  docs/install.md 7.
    install -m0755 "$HERE/lib/gpu-cdi.py" "$PREFIX/bin/nvkvm-kata-gpu-cdi"
    install -m0644 "$ARTIFACTS/vmlinuz-$rel" "$PREFIX/share/vmlinuz-$rel"
    install -m0644 "$ARTIFACTS/kata-nvkvm.image" "$PREFIX/share/kata-nvkvm.image"
    ok "installed shim, vmlinuz-$rel and kata-nvkvm.image under $PREFIX"

    # --- 5b. the shim's environment ----------------------------------------
    # docs/design/07 passed NVKVM_EXTRA_ARGS through a systemd drop-in on
    # containerd.service.  That is GLOBAL and hard to revert cleanly, and it is
    # not needed: the shim already defaults to exactly the device we want, and
    # anything an operator does want to override belongs in a file only the shim
    # reads.  So this installer does NOT touch containerd.service.
    install -d /etc/nvkvm-kata
    if [ ! -e "$SHIM_ENV" ] || ! grep -q "^NVKVM_QEMU=$NVKVM_QEMU_PATH\$" "$SHIM_ENV" 2>/dev/null; then
        backup_once "$SHIM_ENV"
        cat > "$SHIM_ENV" <<EOF
# nvkvm-kata shim environment.  Read by $SHIM_PATH, and by nothing else.
# Deliberately NOT a containerd.service drop-in: this file affects only the
# nvkvm-kata runtime, so stock Kata and runc cannot be perturbed by editing it.
NVKVM_QEMU=$NVKVM_QEMU_PATH
# NVKVM_EXTRA_ARGS=-device virtio-nvgpu-pci-non-transitional,id=nvkvm0
# NVKVM_SHIM_LOG=/var/log/nvkvm-shim.log
EOF
        # (backup_once already recorded it in the manifest)
        change "wrote $SHIM_ENV (NVKVM_QEMU=$NVKVM_QEMU_PATH)"
    else
        ok "$SHIM_ENV already correct"
    fi

    # --- 5c. the second Kata configuration ---------------------------------
    local template
    if [ -e "$KATA_CONF_DIR/configuration.toml" ]; then template="$(readlink -f "$KATA_CONF_DIR/configuration.toml")"
    else template="$(stock_kata_config)"; fi
    log "configuration template: $template"

    local tmp; tmp="$(mktemp)"
    python3 "$HERE/lib/kata-conf-edit.py" \
        --in "$template" --out "$tmp" \
        --set 'hypervisor.qemu:path='"$SHIM_PATH" \
        --set 'hypervisor.qemu:kernel='"$PREFIX/share/vmlinuz-$rel" \
        --set 'hypervisor.qemu:image='"$PREFIX/share/kata-nvkvm.image" \
        --append-list 'hypervisor.qemu:valid_hypervisor_paths='"$SHIM_PATH" \
        --append-list 'agent.kata:kernel_modules=nvkvm-guest' \
        --append-words 'hypervisor.qemu:kernel_params=agent.visible_cdi_devices=true' \
        --comment-out 'hypervisor.qemu:initrd' \
        || die "failed to derive $NVKVM_CONF from $template" "edit it by hand -- docs/install.md §5c"

    if [ -e "$NVKVM_CONF" ] && cmp -s "$tmp" "$NVKVM_CONF"; then
        ok "$NVKVM_CONF already correct"
        rm -f "$tmp"
    else
        backup_once "$NVKVM_CONF"
        install -m0644 "$tmp" "$NVKVM_CONF"; rm -f "$tmp"
        change "wrote $NVKVM_CONF"
    fi
    # Assert what the file must say, rather than trusting the editor.
    local f
    for f in "path *= *\"$SHIM_PATH\"" "kernel *= *\"$PREFIX/share/vmlinuz-$rel\"" \
             "image *= *\"$PREFIX/share/kata-nvkvm.image\"" "kernel_modules *= *\[\"nvkvm-guest\"\]"; do
        grep -Eq "^ *$f" "$NVKVM_CONF" || die "$NVKVM_CONF is missing: $f" "the config editor did not do its job; edit by hand -- docs/install.md §5c"
    done
    grep -q 'agent.visible_cdi_devices=true' "$NVKVM_CONF" \
        || die "$NVKVM_CONF kernel_params lacks agent.visible_cdi_devices=true" "add it by hand -- docs/install.md §5c"
    ok "configuration asserted: shim, kernel $rel, nvkvm image, kernel_modules, visible_cdi_devices"

    # --- 5d. the containerd shim wrapper -----------------------------------
    # THE PER-CONTAINER SELECTION MECHANISM, half one of two.
    #
    # containerd derives a shim BINARY NAME from a runtime TYPE by a fixed rule:
    #   io.containerd.<NAME>.v2  ->  containerd-shim-<NAME>-v2, on containerd's
    # own PATH.  So "register a new runtime" means "provide a new binary name",
    # and the binary can be a wrapper around Kata's real shim.  Half two is the
    # ConfigPath runtime option in stage 6, which is what actually picks the
    # configuration.
    #
    # KATA_CONF_FILE here is a DELIBERATE, DOCUMENTED FALLBACK, not the
    # mechanism.  MEASURED on Kata 4.1.0: the shim reads the ConfigPath runtime
    # option first and only consults the environment when no option was passed
    # (src/runtime/pkg/containerd-shim-v2/create.go:273), and when it does
    # consult it, isShippedKataConfigPath (:325) accepts ONLY the two hardcoded
    # default paths and rejects ours:
    #    invalid KATA_CONF_FILE "/etc/kata-containers/configuration-nvkvm.toml":
    #    only shipped Kata configuration files are accepted
    # That is a hardening upstream added after kata-deploy's wrapper idiom was
    # written, and it means the environment variable can no longer select a
    # second configuration.  We set it anyway, because the alternative is worse:
    # a caller that forgets the ConfigPath option would otherwise get the STOCK
    # configuration SILENTLY -- a container that boots fine and has no GPU.
    # With the variable set, that caller gets the loud error above, naming the
    # file.  Wrong-and-loud beats wrong-and-silent.
    local wrapper="/usr/local/bin/containerd-shim-${RUNTIME_NAME}-v2"
    local wrapper_body
    wrapper_body="$(cat <<EOF
#!/bin/sh
# containerd-shim-${RUNTIME_NAME}-v2 -- installed by nvkvm-kata-install.sh.
#
# containerd derives this filename from the runtime type
# "io.containerd.${RUNTIME_NAME}.v2".  Existing under this name is most of what
# it does; the configuration is selected by the ConfigPath runtime option that
# Docker (daemon.json) and containerd's CRI plugin pass to the shim.
#
# KATA_CONF_FILE below is a fallback for a caller that passes no options -- ctr
# without --runtime-config-path, say.  On Kata 4.1.0 it is REJECTED for a
# non-shipped path, which is intentional here: it turns "silently ran on the
# stock configuration with no GPU" into a one-line error naming this file.
#
# THE GPU INJECTION POINT.  containerd writes the OCI config.json into the
# bundle BEFORE it exec's this binary with \`start\`, and it exec's us with the
# bundle as the working directory (MEASURED --
# docs/design/evidence/09/shim-bundle-probe.log).  That is the last place on
# the host where the spec can still be edited: Kata's own shim reads
# config.json from the bundle, and by the time the agent sees the spec its
# hooks have been deleted (kata_agent.go:1055 constrainGRPCSpec).
#
# So a container that asked for a GPU the Docker way -- \`docker run --gpus\`,
# which sets NVIDIA_VISIBLE_DEVICES -- gets the host driver's libraries as
# mounts and the one environment variable kata-agent needs, right here.  A
# container that did not ask is not touched at all.
last=""; for a in "\$@"; do last="\$a"; done
if [ "\$last" = "start" ]; then
    ${PREFIX}/bin/nvkvm-kata-gpu-cdi inject --bundle "\$PWD" || exit 1
fi
exec env KATA_CONF_FILE=${NVKVM_CONF} ${KATA_ROOT}/bin/containerd-shim-kata-v2 "\$@"
EOF
)"
    if [ ! -e "$wrapper" ] || [ "$(cat "$wrapper")" != "$wrapper_body" ]; then
        backup_once "$wrapper"
        printf '%s\n' "$wrapper_body" > "$wrapper"; chmod 0755 "$wrapper"
        change "wrote $wrapper"
    else
        ok "$wrapper already correct"
    fi
    ok "runtime type: io.containerd.${RUNTIME_NAME}.v2"
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 6 -- ENGINE.  docs/install.md §6
# Per-container selection.  Docker is the one the brief asks for; containerd's
# CRI handler is opt-in because most Docker hosts ship with the CRI plugin
# disabled and editing a config nobody uses is pure risk.
# ═════════════════════════════════════════════════════════════════════════════
stage_engine() {
    step "stage 6/8  register the runtime with the container engine"
    local rt="io.containerd.${RUNTIME_NAME}.v2"

    # --- 6a. containerd, bare.  Nothing to configure: `ctr --runtime <type>`
    #         resolves the binary off containerd's PATH.  Verify that it can.
    if ! command -v "containerd-shim-${RUNTIME_NAME}-v2" >/dev/null 2>&1; then
        die "containerd-shim-${RUNTIME_NAME}-v2 is not on PATH" \
            "run the runtime stage (--only runtime); it installs it into /usr/local/bin"
    fi
    ok "ctr/nerdctl:  --runtime $rt  (no configuration needed)"

    # --- 6b. Docker: a named runtime in daemon.json ------------------------
    if [ "$DOCKER_OK" = 1 ]; then
        backup_once /etc/docker/daemon.json
        python3 "$HERE/lib/docker-runtime.py" add --name "$RUNTIME_NAME" --type "$rt" \
                --config-path "$KATA_CONF_DIR/configuration-nvkvm.toml"
        case $? in
            0) change "registered docker runtime '$RUNTIME_NAME' -> $rt in /etc/docker/daemon.json"
               reload_docker ;;   # backup_once above already recorded it
            1) ok "docker runtime '$RUNTIME_NAME' already registered" ;;
            *) die "could not edit /etc/docker/daemon.json" "fix the JSON by hand, then re-run with --only engine" ;;
        esac
        docker_has_runtime \
            || die "docker did not pick up the runtime '$RUNTIME_NAME'" \
                   "check 'docker info | grep -i runtime' and /etc/docker/daemon.json, then: systemctl restart docker"
        ok "docker runtime '$RUNTIME_NAME' live -- compose can now say: runtime: $RUNTIME_NAME"
    else
        log "docker: SKIPPED (absent, too old, or --no-docker)"
    fi

    # --- 6c. containerd CRI handler (Kubernetes) ---------------------------
    if [ "$DO_CRI" = 1 ]; then
        register_cri "$rt"
    else
        log "containerd CRI handler: SKIPPED (pass --containerd-cri for Kubernetes)"
    fi
}

# `docker info -f '{{json .Runtimes}}'` prints every runtime's full OCI feature
# blob -- about 8 KB per runtime -- which is unreadable in a log and pointless
# here.  Ask for the names only.
docker_has_runtime() {
    docker info -f '{{range $k, $v := .Runtimes}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -qx "$RUNTIME_NAME"
}

reload_docker() {
    # SIGHUP reloads daemon.json's `runtimes` without stopping containers.
    # Restart only if that did not take -- a restart kills every container on
    # the host and must not be a routine part of an installer.
    systemctl reload docker >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        docker_has_runtime && return 0
        sleep 1
    done
    warn "docker did not pick the runtime up on reload; restarting dockerd"
    systemctl restart docker >/dev/null 2>&1 || die "systemctl restart docker failed" "journalctl -u docker -n50 -- daemon.json may be invalid; the original is in $BACKUP"
    sleep 2
}

register_cri() {
    local rt="$1" cfg=/etc/containerd/config.toml
    local NVKVM_CONF_PATH="$KATA_CONF_DIR/configuration-nvkvm.toml"
    local plugin='io.containerd.grpc.v1.cri'
    [ "${CONTAINERD_MAJOR:-1}" -ge 2 ] 2>/dev/null && plugin='io.containerd.cri.v1.runtime'
    [ -e "$cfg" ] || { mkdir -p /etc/containerd; containerd config default > "$cfg" 2>/dev/null || : > "$cfg"; }
    backup_once "$cfg"
    if grep -q '^# >>> nvkvm-kata >>>' "$cfg"; then ok "containerd CRI handler already present"; return 0; fi
    cat >> "$cfg" <<EOF

# >>> nvkvm-kata >>>   (remove this block and the marker lines to revert)
[plugins."$plugin".containerd.runtimes.${RUNTIME_NAME}]
  runtime_type = "$rt"
  privileged_without_host_devices = true
  pod_annotations = ["io.katacontainers.*"]
  # ConfigPath is what actually selects the nvkvm configuration.  Kata's shim
  # reads it ahead of KATA_CONF_FILE, and on 4.1.0 the environment route is
  # rejected for anything but the two shipped default paths.
  [plugins."$plugin".containerd.runtimes.${RUNTIME_NAME}.options]
    ConfigPath = "$NVKVM_CONF_PATH"
# <<< nvkvm-kata <<<
EOF
    change "appended a CRI runtime handler '$RUNTIME_NAME' to $cfg"
    # Say so out loud when the handler cannot possibly be used: the containerd
    # that ships with Docker sets disabled_plugins = ["cri"], so the stanza
    # parses, containerd restarts happily, and NOTHING reads it.  That is a
    # perfectly good "installed but inert" trap.
    if grep -Eq '^[[:space:]]*disabled_plugins[[:space:]]*=.*"cri"' "$cfg"; then
        warn "$cfg has disabled_plugins = [\"cri\"] -- the CRI plugin is OFF on this host,"
        warn "  so the handler just written is INERT.  It is correct and it parses, but nothing"
        warn "  will use it until you enable the CRI plugin (Docker does not use it at all)."
    fi
    systemctl restart containerd >/dev/null 2>&1
    sleep 2
    if ! ctr version >/dev/null 2>&1; then
        warn "containerd did not come back after the config change -- REVERTING it"
        cp -a "$BACKUP/etc_containerd_config.toml" "$cfg" 2>/dev/null
        systemctl restart containerd >/dev/null 2>&1; sleep 2
        die "the CRI stanza broke containerd; it has been reverted" \
            "run without --containerd-cri, or add the handler by hand -- docs/install.md §6c"
    fi
    ok "containerd restarted cleanly with the CRI handler"
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 7 -- LIBS.  docs/install.md §7
# The host driver's own userspace, for containers to get automatically.
# Host-specific by construction (it must match the servicing kernel driver
# exactly), which is why it is an INSTALL step and not a BUILD step -- a
# prebuilt tarball can never carry it, and the NVIDIA libraries are not
# redistributable anyway.
#
# THIS STAGE USED TO COPY A HAND-PICKED BUNDLE and leave the user to bind-mount
# it with a `volumes:` line and an LD_LIBRARY_PATH.  It no longer does either.
# It asks NVIDIA which files are driver files -- `nvidia-ctk cdi generate`, the
# same command Kata's own NVIDIA-GPU path runs -- and records the answer as a
# mount manifest that the shim wrapper applies per container.  A new driver
# release that ships a new library needs no change here.
# ═════════════════════════════════════════════════════════════════════════════
stage_libs() {
    step "stage 7/8  host driver userspace (discovered by nvidia-ctk) + the vecadd proof"
    install -d "$PREFIX/nvidia/bin"

    # `docker run --gpus` needs nvidia-container-toolkit on this host anyway:
    # Docker only registers its "nvidia" device driver when
    # nvidia-container-runtime-hook is on PATH, and without it `--gpus all`
    # fails with "could not select device driver".  So requiring the toolkit
    # costs nothing that was not already required, and it is also where the
    # discovery comes from.
    # nvidia-container-toolkit is REQUIRED, and deliberately not installed by
    # this script.  Setting up NVIDIA's package repository on someone else's
    # host is invasive, it is the most distro-divergent work in the whole
    # install, and a GPU host that runs containers already has the toolkit --
    # it is how anyone runs a GPU container at all.  So: detect, and fail
    # loudly naming the exact command for THIS distribution.
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        local tkhint
        case "$DISTRO_FAMILY" in
            debian) tkhint="curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list && apt-get update && apt-get install -y nvidia-container-toolkit" ;;
            arch)   tkhint="pacman -S nvidia-container-toolkit    (it is in [extra])" ;;
            rhel)   tkhint="$PKG_MGR config-manager --add-repo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo && $PKG_MGR install -y nvidia-container-toolkit" ;;
            *)      tkhint="install nvidia-container-toolkit -- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html" ;;
        esac
        die "nvidia-container-toolkit is required and was not found (no nvidia-ctk on PATH)" \
            "$tkhint"
    fi

    local manifest="$STATE/gpu-mounts.json"
    local args=(discover --out "$manifest")
    [ "$FORCE" = 1 ] && args+=(--force)
    python3 "$HERE/lib/gpu-cdi.py" "${args[@]}" \
        || die "gpu-cdi.py discover failed" "run it by hand -- docs/install.md §7"
    manifest_add created "$manifest"
    local nmounts
    nmounts="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["mounts"]))' "$manifest" 2>/dev/null || echo 0)"
    [ "$nmounts" -gt 0 ] || die "$manifest lists no mounts" \
        "nvidia-ctk found no driver files; check that the NVIDIA driver is loaded"
    python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
d=[x["destination"] for x in m["mounts"]]
missing=[n for n in ("/usr/bin/nvidia-smi",) if n not in d]
soname=[x for x in d if x.endswith("libcuda.so.1")]
sys.exit(0 if (not missing and soname) else 1)' "$manifest" \
        || die "$manifest is missing libcuda.so.1 or nvidia-smi" \
               "the SONAME pass failed; without it every dlopen in the container fails"
    ok "$nmounts container mounts recorded for driver $DRIVER_VERSION ($manifest)"

    # nvidia-smi is NOT staged here any more.  It is in the manifest above --
    # nvidia-ctk lists it as a driver file -- so every GPU container gets the
    # host's own /usr/bin/nvidia-smi automatically, on PATH, with no volume.
    rm -f "$PREFIX/nvidia/bin/nvidia-smi"

    # The proof binary.  Driver API through dlopen with embedded PTX, so it
    # needs no CUDA toolkit anywhere -- neither on this host nor in the image.
    if [ "$FORCE" = 1 ] || [ ! -x "$PREFIX/nvidia/bin/vecadd" ] \
       || [ "$HERE/e2e/vecadd.c" -nt "$PREFIX/nvidia/bin/vecadd" ]; then
        gcc -O2 -o "$PREFIX/nvidia/bin/vecadd" "$HERE/e2e/vecadd.c" -ldl \
            || die "could not compile scripts/e2e/vecadd.c" "install gcc, or build it by hand -- docs/install.md §7"
        change "built $PREFIX/nvidia/bin/vecadd"
    else
        ok "vecadd already built"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# STAGE 8 -- VERIFY.  docs/install.md §8
# "Installed" and "working" are different claims.  This stage RUNS THE PROOF.
# It also runs the two negative/regression controls, because an installer that
# breaks the host's existing runtimes has not succeeded either.
# ═════════════════════════════════════════════════════════════════════════════
VERIFY_FAILED=0
verify_fail() { printf '[nvkvm-kata]  FAIL  %s\n' "$*" >&2; VERIFY_FAILED=1; }
verify_pass() { printf '[nvkvm-kata]  PASS  %s\n' "$*" >&2; }

stage_verify() {
    step "stage 8/8  verify -- running the real proof, not a file listing"
    local rel; rel="$(cat "$ARTIFACTS/release" 2>/dev/null || echo '')"
    local img=docker.io/library/ubuntu:24.04
    local out eng

    # WHICH ENGINE PROVES THE INSTALL.
    # Docker if it is here, `ctr` if it is not -- and `ctr` is not a lesser
    # path, it is the baseline: a Kubernetes node or a podman host has
    # containerd and no Docker, and skipping the proof there would mean
    # reporting success on the one configuration we never checked.  Both arms
    # run the SAME checks, including a real CUDA workload.
    if [ "$DOCKER_OK" = 1 ]; then eng=docker; else eng=ctr; fi
    ok "proving the install with: $eng"

    if [ "$eng" = docker ]; then
        docker pull -q "$img" >/dev/null 2>&1 || warn "could not pull $img"
        if out="$(docker run --rm "$img" /bin/true 2>&1)"; then
            verify_pass "control: runc still runs containers"
        else
            verify_fail "control: runc is BROKEN after install -- $out"
        fi
    else
        ctr images pull "$img" >/dev/null 2>&1 || warn "could not pull $img with ctr"
        ok "control: no Docker on this host -- verifying through containerd only"
    fi

    # 1. the nvkvm configuration was selected, not the stock one.
    if out="$(run_nvkvm "$eng" "$img" /bin/sh -c 'uname -r' 2>&1)"; then
        if [ -n "$rel" ] && printf '%s' "$out" | grep -q "$rel"; then
            verify_pass "guest kernel is $rel (the nvkvm-kata configuration was selected, not the stock one)"
        else
            verify_fail "guest kernel is '$out', expected $rel -- the configuration did not reach the shim"
        fi
    else
        verify_fail "could not start a container on runtime $RUNTIME_NAME: $out"
    fi

    # 2. the module loaded and registered its char devices.
    if out="$(run_nvkvm "$eng" "$img" /bin/sh -c 'grep -E "nvidia|nvidia-uvm" /proc/devices' 2>&1)"; then
        printf '%s' "$out" | grep -q nvidiactl \
            && verify_pass "nvkvm-guest.ko loaded: $(printf '%s' "$out" | tr '\n' ' ')" \
            || verify_fail "no nvidia char devices in the guest -- module did not load: $out"
    else
        verify_fail "device probe failed: $out"
    fi

    # 3. the libraries arrived on their own, and resolve on their own.  This is
    #    the check that stage 7 actually replaced the manual volume: no -v, no
    #    LD_LIBRARY_PATH, and libcuda.so.1 still resolves.
    #    `|| true` because grep exits 1 on the GOOD outcome (no unresolved
    #    libraries) and that would fail the check backwards.
    # `ldd /usr/bin/nvidia-smi` is NOT a good check and was one here briefly:
    # nvidia-smi dlopen()s libnvidia-ml at run time rather than linking it, so
    # ldd reports nothing missing even when the loader cannot find a single
    # NVIDIA library.  It passed green on a RHEL host where libcuda.so.1 was
    # unreachable.  Ask the loader the question the workload will ask instead:
    # is libcuda.so.1 in the cache, and does it dlopen.
    if out="$(run_nvkvm "$eng" "$img" /bin/sh -c 'nvidia-smi -L; ldconfig -p | grep -c "libcuda.so.1" || true' 2>&1)"; then
        if printf '%s' "$out" | grep -q 'GPU 0' && ! printf '%s' "$out" | grep -qx '0'; then
            verify_pass "nvidia-smi works and libcuda.so.1 is in the container's ldcache, with no volume and no LD_LIBRARY_PATH: $(printf '%s' "$out" | grep 'GPU 0')"
        else
            verify_fail "nvidia-smi did not enumerate a GPU, or libcuda.so.1 is not resolvable: $out"
        fi
    else
        verify_fail "nvidia-smi could not run in the container: $out"
    fi

    # 4. THE PROOF -- a real CUDA workload that checks its own arithmetic.
    log "running the CUDA vector-add in a container on runtime '$RUNTIME_NAME' (via $eng)..."
    if out="$(run_nvkvm "$eng" "$img" /usr/local/nvidia/bin/vecadd 2>&1)"; then
        printf '%s\n' "$out" | sed 's/^/[nvkvm-kata]      | /' >&2
        printf '%s' "$out" | grep -q 'VECADD OK' \
            && verify_pass "CUDA vector-add ran on the GPU, in a container, in a Kata VM, through nvkvm" \
            || verify_fail "vecadd ran but did not print VECADD OK"
    else
        printf '%s\n' "$out" | sed 's/^/[nvkvm-kata]      | /' >&2
        verify_fail "vecadd did not run"
    fi

    # 5. the host never lost the card -- the entire point of nvkvm.
    if [ -r /proc/driver/nvidia/gpus ] || ls /sys/bus/pci/drivers/nvidia/0000:* >/dev/null 2>&1; then
        verify_pass "host driver still bound to the GPU (no VFIO, no unbind)"
    else
        warn "could not confirm the host driver is still bound (this is informational)"
    fi

    if [ "$VERIFY_FAILED" != 0 ]; then
        die "VERIFICATION FAILED -- nvkvm-kata is installed but NOT working" \
            "read the failures above; 'journalctl -t kata -n200', /var/log/nvkvm-kata-gpu.log and NVKVM_SHIM_LOG in $SHIM_ENV are the next places to look. Revert with scripts/nvkvm-kata-uninstall.sh"
    fi
}

# Run a container on the nvkvm-kata runtime, THE WAY A USER WOULD.
#
# The only bind mount here is the harness's own proof binary; there is
# deliberately no driver-library volume and no LD_LIBRARY_PATH, because the
# whole point of stage 7 is that a user never has to supply either.  If this
# function ever needs one back, the feature is broken.
#
# `ctr` has no --gpus, so the ctr arm sets the variable Docker's --gpus would
# have set.  Both arms therefore exercise the same code path in the injector.
run_nvkvm() {   # engine image command...
    local engine="$1" image="$2"; shift 2
    if [ "$engine" = docker ]; then
        timeout 180 docker run --rm --runtime "$RUNTIME_NAME" --gpus all \
            -v "$PREFIX/nvidia/bin:/usr/local/nvidia/bin:ro" \
            "$image" "$@"
    else
        timeout 180 ctr run --rm --runtime "io.containerd.${RUNTIME_NAME}.v2" \
            --runtime-config-path "$KATA_CONF_DIR/configuration-nvkvm.toml" \
            --mount "type=bind,src=$PREFIX/nvidia/bin,dst=/usr/local/nvidia/bin,options=rbind:ro" \
            --env NVIDIA_VISIBLE_DEVICES=all \
            "$image" "nvkvm-verify-$$" "$@"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
main() {
    preflight
    want kata    && stage_kata
    want qemu    && stage_qemu
    want kernel  && stage_kernel
    want rootfs  && stage_rootfs
    want runtime && stage_runtime
    want engine  && stage_engine
    want libs    && stage_libs
    want verify  && stage_verify

    step "done"
    cat >&2 <<EOF
[nvkvm-kata]
[nvkvm-kata]   Select it per container.  Nothing global changed:
[nvkvm-kata]
[nvkvm-kata]     docker run --runtime=$RUNTIME_NAME --gpus all --rm \\
[nvkvm-kata]         nvidia/cuda:13.3.1-cudnn-devel-ubuntu26.04 nvidia-smi
[nvkvm-kata]
[nvkvm-kata]   No volume, no LD_LIBRARY_PATH, no VISIBLE_CDI_DEVICES.  The host driver's
[nvkvm-kata]   userspace arrives on its own and ldconfig has run inside the container
[nvkvm-kata]   before your command does.  --gpus 1 / --gpus '"device=0"' /
[nvkvm-kata]   --gpus '"device=GPU-<uuid>"' select devices the way the toolkit does.
[nvkvm-kata]
[nvkvm-kata]   (examples/docker-compose.yml is the compose spelling, ready to run.)
[nvkvm-kata]   Revert everything:  scripts/nvkvm-kata-uninstall.sh
EOF
}
main "$@"
