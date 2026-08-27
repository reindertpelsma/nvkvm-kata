#!/usr/bin/env bash
# check-vmm-device-access.sh — settle docs/design/01-vmm-confinement.md §1.4.
#
# THE QUESTION
#   Kata's shim builds the sandbox's device cgroup itself (sandbox.go
#   createResourceController + resourcecontrol/cgroups.go sandboxDevices).
#   /dev/nvidiactl and /dev/nvidia* are NOT in that allowlist, and root does not
#   bypass a device cgroup. So: can the Kata-launched hypervisor open the host
#   NVIDIA nodes, and does the answer change with sandbox_cgroup_only?
#
# WHAT THIS DOES
#   Starts a Kata sandbox, finds the hypervisor process, prints WHICH cgroup it
#   is in, DUMPS that cgroup's device policy (cgroup v1 devices.list, or the
#   cgroup v2 BPF_CGROUP_DEVICE programs via bpftool, whichever is in use), and
#   then actually joins that cgroup with a probe process and attempts open() on
#   the NVIDIA nodes. Evidence is printed at every step; the verdict is derived
#   from the open() results, never from inference.
#
# CONTROLS (this is why the output can be believed)
#   * /dev/kvm is probed from the same cgroup. Kata's sandboxDevices() puts it
#     in the allowlist unconditionally, so it MUST open. If it does not, the
#     probe never joined the cgroup and every other result is void.
#   * every device is probed a second time from the caller's own cgroup. If a
#     node fails there too, the failure is not attributable to Kata.
#   * the probe prints its own /proc/self/cgroup after joining, so the reader
#     can confirm it measured the cgroup the hypervisor is actually in.
#
# NO GPU? Use --synthesise-nodes. The device cgroup is enforced by
#   (type, major, minor) in an LSM hook on open(), strictly BEFORE the driver's
#   ->open() runs, and it has no idea whether a driver is bound. So a mknod'd
#   c 195:255 node with nothing behind it answers the cgroup question exactly:
#       EPERM  => the cgroup denied it        (this is the Q1 failure mode)
#       ENXIO  => the cgroup ALLOWED it, and then the kernel found no driver
#   ENXIO is a PASS. See the "interpretation" note in the output.
#
# Usage:
#   check-vmm-device-access.sh [--sandbox-cgroup-only both|true|false]
#                              [--config <kata configuration.toml>]
#                              [--runtime io.containerd.kata.v2] [--image REF]
#                              [--device /dev/foo]...  [--synthesise-nodes]
#                              [--pid PID] [--keep] [--outdir DIR]
#   check-vmm-device-access.sh --self-test     # no Kata, no GPU: proves the harness
#
# Exits 0 if every requested sandbox_cgroup_only value PASSED, 1 if any FAILED,
# 2 if the experiment could not be run (which is not an answer -- say so).
set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SCO_MODE=both
KATA_CONFIG=""
RUNTIME="io.containerd.kata.v2"
IMAGE="docker.io/library/busybox:latest"
KEEP=0
PROBE_PID=""
SELF_TEST=0
SYNTH=0
OUTDIR=""
EXTRA_DEVICES=()

DEFAULT_DEVICES=(/dev/nvidiactl /dev/nvidia0 /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset /dev/dri/renderD128)
CONTROL_DEVICE=/dev/kvm

die()  { echo "$SCRIPT_NAME: $*" >&2; exit 2; }
warn() { echo "$SCRIPT_NAME: WARNING: $*" >&2; }
hdr()  { echo; echo "=== $* ==="; }
sub()  { echo; echo "--- $* ---"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox-cgroup-only) SCO_MODE="$2"; shift 2 ;;
    --config)   KATA_CONFIG="$2"; shift 2 ;;
    --runtime)  RUNTIME="$2"; shift 2 ;;
    --image)    IMAGE="$2"; shift 2 ;;
    --device)   EXTRA_DEVICES+=("$2"); shift 2 ;;
    --pid)      PROBE_PID="$2"; shift 2 ;;
    --outdir)   OUTDIR="$2"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --synthesise-nodes|--synthesize-nodes) SYNTH=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

DEVICES=("${DEFAULT_DEVICES[@]}")
[ ${#EXTRA_DEVICES[@]} -gt 0 ] && DEVICES+=("${EXTRA_DEVICES[@]}")

[ "$(id -u)" -eq 0 ] || die "must run as root (reads /proc/<pid>/cgroup and writes cgroup.procs)"

if [ -z "$OUTDIR" ]; then OUTDIR=$(mktemp -d /tmp/nvkvm-kata-q1.XXXXXX); else mkdir -p "$OUTDIR"; fi
echo "$SCRIPT_NAME: evidence -> $OUTDIR"

# ---------------------------------------------------------------- probe helper
# A standalone open()-tester. It is exec'd AFTER the calling shell has moved
# itself into the target cgroup, so what it measures is that cgroup's policy.
PROBE=$OUTDIR/open-probe
if command -v python3 >/dev/null 2>&1; then
  cat > "$PROBE" <<'PYEOF'
#!/usr/bin/env python3
import errno, os, sys, stat
print("probe: pid=%d cgroup=%s" % (os.getpid(),
      open("/proc/self/cgroup").read().strip().replace("\n", " | ")))
rc = 0
for p in sys.argv[1:]:
    try:
        st = os.stat(p)
        kind = "c" if stat.S_ISCHR(st.st_mode) else ("b" if stat.S_ISBLK(st.st_mode) else "?")
        node = "%s %d:%d" % (kind, os.major(st.st_rdev), os.minor(st.st_rdev))
    except OSError as e:
        print("  %-26s ABSENT      (stat: %s)" % (p, errno.errorcode.get(e.errno, e.errno)))
        continue
    res = None
    for flags, name in ((os.O_RDWR, "O_RDWR"), (os.O_RDONLY, "O_RDONLY")):
        try:
            fd = os.open(p, flags | os.O_NONBLOCK)
            os.close(fd)
            res = ("OPEN-OK", name, None)
            break
        except OSError as e:
            res = ("OPEN-FAIL", name, e.errno)
    if res[0] == "OPEN-OK":
        print("  %-26s OPEN-OK     [%-10s] %s" % (p, node, res[1]))
    else:
        en = errno.errorcode.get(res[2], str(res[2]))
        verdict = "DENIED-BY-CGROUP" if res[2] == errno.EPERM else (
                  "ALLOWED-BY-CGROUP, no driver bound" if res[2] == errno.ENXIO else "")
        print("  %-26s OPEN-FAIL   [%-10s] errno=%s %s" % (p, node, en, verdict))
        if res[2] == errno.EPERM:
            rc = 1
sys.exit(rc)
PYEOF
  chmod +x "$PROBE"
  PROBE_CMD=("$PROBE")
else
  warn "python3 not found; falling back to a bash prober (errno is coarser)"
  cat > "$PROBE" <<'SHEOF'
#!/usr/bin/env bash
echo "probe: pid=$$ cgroup=$(tr '\n' '|' < /proc/self/cgroup)"
rc=0
for p in "$@"; do
  if [ ! -e "$p" ]; then echo "  $p ABSENT"; continue; fi
  err=$( { exec 9<>"$p"; } 2>&1 ); st=$?
  exec 9>&- 2>/dev/null
  if [ $st -eq 0 ]; then echo "  $p OPEN-OK"
  else
    echo "  $p OPEN-FAIL ${err##*: }"
    case "$err" in *"Operation not permitted"*) rc=1;; esac
  fi
done
exit $rc
SHEOF
  chmod +x "$PROBE"
  PROBE_CMD=("$PROBE")
fi

# ---------------------------------------------- cgroup v2 device-filter query
# bpftool is not dependable across kernel/bpftool skew: on some pairs
# `bpftool cgroup show` bails with ENXIO on an attach type the kernel does not
# know and reports nothing for a cgroup that does have a device filter. Ask
# BPF_PROG_QUERY directly instead -- the same call bpftool makes, minus the skew.
CGDEVQ=$OUTDIR/cgroup-device-query
if command -v python3 >/dev/null 2>&1; then
  cat > "$CGDEVQ" <<'CGQEOF'
#!/usr/bin/env python3
import ctypes, os, struct, sys
BPF_PROG_QUERY, BPF_CGROUP_DEVICE, BPF_F_QUERY_EFFECTIVE = 16, 6, 1
libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.syscall.restype = ctypes.c_long

def query(path, effective):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        ids = (ctypes.c_uint32 * 64)()
        attr = struct.pack("=IIIIQII", fd, BPF_CGROUP_DEVICE,
                           BPF_F_QUERY_EFFECTIVE if effective else 0, 0,
                           ctypes.addressof(ids), 64, 0)
        buf = ctypes.create_string_buffer(attr, len(attr))
        if libc.syscall(321, BPF_PROG_QUERY, ctypes.byref(buf), len(attr)) != 0:
            return None, os.strerror(ctypes.get_errno()), []
        cnt = struct.unpack_from("=I", buf.raw, 24)[0]
        return cnt, None, [ids[i] for i in range(min(cnt, 64))]
    finally:
        os.close(fd)

rc = 0
for path in sys.argv[1:]:
    eff, err, eids = query(path, True)
    att, _, aids = query(path, False)
    if eff is None:
        print("  %-56s QUERY-FAILED (%s)" % (path, err)); rc = 2; continue
    print("  %-56s effective=%d attached=%d ids=%s -> %s"
          % (path, eff, att, aids or "-",
             "device-UNRESTRICTED (nothing gates open() here)" if eff == 0
             else "device-RESTRICTED by %d effective program(s)" % eff))
sys.exit(rc)
CGQEOF
  chmod +x "$CGDEVQ"
else
  CGDEVQ=""
fi

# ------------------------------------------------------- cgroup version + paths
CG_MOUNT=/sys/fs/cgroup
cgroup_version() {
  local t; t=$(stat -fc %T "$CG_MOUNT" 2>/dev/null)
  if [ "$t" = "cgroup2fs" ]; then echo v2
  elif [ -d "$CG_MOUNT/devices" ]; then echo v1
  elif [ "$t" = "tmpfs" ]; then echo v1
  else echo unknown; fi
}
CGV=$(cgroup_version)

# path of <pid> in the devices-enforcing hierarchy
pid_cgroup_path() {
  local pid=$1
  if [ "$CGV" = v2 ]; then
    awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup"
  else
    awk -F: '$2 ~ /(^|,)devices(,|$)/ {print $3}' "/proc/$pid/cgroup"
  fi
}
# directory that a probe process joins, for a given cgroup path
cgroup_dir_for() {
  if [ "$CGV" = v2 ]; then echo "$CG_MOUNT$1"; else echo "$CG_MOUNT/devices$1"; fi
}
cgroup_procs_file() {
  if [ "$CGV" = v2 ]; then echo "$1/cgroup.procs"; else echo "$1/tasks"; fi
}

# ------------------------------------------------- device policy dump (v1 + v2)
dump_device_policy() {
  local cgpath=$1 dir
  dir=$(cgroup_dir_for "$cgpath")
  echo "cgroup version : $CGV"
  echo "cgroup path    : $cgpath"
  echo "cgroup dir     : $dir"
  if [ ! -d "$dir" ]; then echo "!! cgroup directory does not exist"; return; fi

  if [ "$CGV" = v1 ]; then
    sub "cgroup v1 devices.list, walking up to the root"
    local p="$cgpath"
    while :; do
      local d; d=$(cgroup_dir_for "$p")
      if [ -r "$d/devices.list" ]; then
        echo "[$p]"; sed 's/^/    /' "$d/devices.list"
      else
        echo "[$p]  (no readable devices.list)"
      fi
      [ "$p" = "/" ] && break
      p=$(dirname "$p"); [ "$p" = "." ] && p=/
    done
    echo
    echo "NOTE: on v1 the EFFECTIVE policy is the cgroup's own devices.list."
    echo "      A child can only ever be a subset of its parent, and a cgroup"
    echo "      created with an empty device set inherits the parent's list."
  else
    sub "cgroup v2 BPF_CGROUP_DEVICE programs, walking up to the root"
    if [ -n "$CGDEVQ" ]; then
      echo "BPF_PROG_QUERY(BPF_CGROUP_DEVICE), asked of the kernel directly:"
      local q="$cgpath"
      while :; do
        "$CGDEVQ" "$(cgroup_dir_for "$q")"
        [ "$q" = "/" ] && break
        q=$(dirname "$q"); [ "$q" = "." ] && q=/
      done
      echo
      echo "  'effective' counts this cgroup's own programs PLUS every ancestor's,"
      echo "  which is exactly the set that gates open() for a task in it."
      echo "  effective=0 at the leaf therefore means device-UNRESTRICTED, and no"
      echo "  further reading of any program is needed."
      echo
    fi
    if ! command -v bpftool >/dev/null 2>&1; then
      echo "!! bpftool not installed -- install linux-tools / bpftool to dump the"
      echo "   attached device filter. The open() results below still stand."
    else
      local p="$cgpath"
      while :; do
        local d; d=$(cgroup_dir_for "$p")
        local out; out=$(bpftool cgroup show "$d" 2>&1)
        # match the AttachType column exactly. Matching a bare "device" also
        # matches bpftool's own "No such device or address" error text.
        if echo "$out" | grep -q "cgroup_device"; then
          echo "[$p]"; echo "$out" | sed 's/^/    /'
          # dump every attached device program
          echo "$out" | awk '$2=="cgroup_device"{print $1}' | while read -r id; do
            [ -n "$id" ] || continue
            echo "    --- bpftool prog dump xlated id $id ---"
            bpftool prog dump xlated id "$id" 2>&1 | sed 's/^/    /'
          done
        elif echo "$out" | grep -qi "^Error:"; then
          echo "[$p]  bpftool could not query this cgroup: $(echo "$out" | head -1)"
        else
          echo "[$p]  no BPF_CGROUP_DEVICE program attached"
        fi
        [ "$p" = "/" ] && break
        p=$(dirname "$p"); [ "$p" = "." ] && p=/
      done
    fi
    echo
    echo "NOTE: on v2 EVERY BPF_CGROUP_DEVICE program on the path from this"
    echo "      cgroup to the root must return 1 for an open() to be allowed"
    echo "      (kernel/bpf/cgroup.c bpf_prog_run_array_cg only ever SETS"
    echo "      -EPERM, never clears it). So 'no program anywhere on the path'"
    echo "      means device-UNRESTRICTED."
  fi
}

# --------------------------------------------------------- run probe in cgroup
# joins <cgpath> then execs the probe. Prints the join failure if it cannot.
probe_in_cgroup() {
  local cgpath=$1; shift
  local dir procs
  dir=$(cgroup_dir_for "$cgpath")
  procs=$(cgroup_procs_file "$dir")
  if [ ! -w "$procs" ]; then
    echo "!! cannot write $procs -- probe cannot join the cgroup; NOT MEASURED"
    return 3
  fi
  bash -c 'printf "%s\n" "$$" > "$1" || { echo "!! failed to join $1 (errno above)"; exit 3; }; shift; exec "$@"' \
       _ "$procs" "${PROBE_CMD[@]}" "$@"
}

probe_here() { "${PROBE_CMD[@]}" "$@"; }

# ------------------------------------------------------------ synthetic nodes
SYNTH_MADE=()
synthesise_nodes() {
  # NVIDIA's char major is 195 by convention and nvkvm registers there
  # deliberately (nvkvm-pv/docs/reference/device-nodes.md).
  local made=0
  if [ ! -e /dev/nvidiactl ]; then mknod /dev/nvidiactl c 195 255 && SYNTH_MADE+=(/dev/nvidiactl) && made=1; fi
  if [ ! -e /dev/nvidia0 ];   then mknod /dev/nvidia0   c 195 0   && SYNTH_MADE+=(/dev/nvidia0)   && made=1; fi
  if [ $made -eq 1 ]; then
    echo "synthesised NVIDIA-major device nodes (no driver behind them):"
    ls -l "${SYNTH_MADE[@]}"
    echo
    echo "INTERPRETATION for synthetic nodes: the device cgroup check runs in an"
    echo "LSM hook on open() keyed on (type, major, minor), before the driver's"
    echo "->open(). Therefore:"
    echo "    EPERM  = the cgroup DENIED the node      -> Q1 FAIL"
    echo "    ENXIO  = the cgroup ALLOWED it, then the kernel found no driver"
    echo "             bound at 195:x                   -> Q1 PASS"
  fi
}
cleanup_synth() {
  [ ${#SYNTH_MADE[@]} -gt 0 ] && rm -f "${SYNTH_MADE[@]}" 2>/dev/null
}

# ------------------------------------------------------------------- self test
if [ "$SELF_TEST" -eq 1 ]; then
  hdr "SELF TEST (no Kata, no GPU) -- does the harness measure what it claims?"
  echo "cgroup version: $CGV"
  rc=0
  sub "1. the probe reports errno correctly"
  probe_here /dev/null /dev/definitely-not-a-device
  sub "2. a probe process can be moved into a cgroup and knows it"
  if [ "$CGV" = v2 ]; then
    tcg=/sys/fs/cgroup/nvkvm-kata-selftest
    mkdir -p "$tcg" || die "cannot create $tcg"
    out=$(probe_in_cgroup "/nvkvm-kata-selftest" /dev/null); st=$?
    echo "$out"
    echo "$out" | grep -q "cgroup=0::/nvkvm-kata-selftest" \
      && echo "   -> OK: the probe really ran inside the target cgroup" \
      || { echo "   -> FAIL: probe did not join"; rc=1; }
    rmdir "$tcg" 2>/dev/null
    sub "3. cgroup v2: a real BPF_CGROUP_DEVICE denial is reported as EPERM"
    if command -v systemd-run >/dev/null 2>&1; then
      # systemd installs a BPF_CGROUP_DEVICE filter for DevicePolicy=strict.
      # This is the same enforcement mechanism Kata's sandbox cgroup uses.
      out=$(systemd-run --scope --quiet -p DevicePolicy=strict -p DeviceAllow='/dev/null rwm' \
            "${PROBE_CMD[@]}" /dev/null "$CONTROL_DEVICE" 2>&1); echo "$out"
      if echo "$out" | grep -q "DENIED-BY-CGROUP"; then
        echo "   -> OK: harness distinguishes an allowed device from a denied one on v2"
        scope=$(echo "$out" | sed -n 's/.*cgroup=0:://p')
        [ -n "$scope" ] && { echo "   -> dumping that scope's policy, to prove the dumper sees it:"; \
          dump_device_policy "$scope" 2>/dev/null | sed -n '/BPF_CGROUP_DEVICE/,$p' | head -12; }
      else
        echo "   -> INCONCLUSIVE: systemd did not install a device filter here"
      fi
    else
      echo "   -> SKIPPED: systemd-run not available; cannot synthesise a v2 denial"
    fi
  else
    tcg=/sys/fs/cgroup/devices/nvkvm-kata-selftest
    mkdir -p "$tcg" || die "cannot create $tcg"
    out=$(probe_in_cgroup "/nvkvm-kata-selftest" /dev/null); echo "$out"
    sub "3. cgroup v1: deny a device and confirm the probe sees EPERM"
    echo 'a' > "$tcg/devices.deny" 2>/dev/null
    out=$(probe_in_cgroup "/nvkvm-kata-selftest" /dev/null); echo "$out"
    echo "$out" | grep -q "DENIED-BY-CGROUP" \
      && echo "   -> OK: harness distinguishes an allowed device from a denied one" \
      || { echo "   -> FAIL: denial not observed"; rc=1; }
    rmdir "$tcg" 2>/dev/null
  fi
  sub "4. the direct BPF_PROG_QUERY agrees with a known-restricted cgroup"
  if [ -n "$CGDEVQ" ] && command -v systemd-run >/dev/null 2>&1 && [ "$CGV" = v2 ]; then
    out=$(systemd-run --scope --quiet -p DevicePolicy=strict -p DeviceAllow='/dev/null rwm' \
          bash -c 'p=$(awk -F: "\$1==0{print \$3}" /proc/self/cgroup); "$1" "/sys/fs/cgroup$p"' _ "$CGDEVQ" 2>&1)
    echo "$out"
    echo "$out" | grep -q "device-RESTRICTED" \
      && echo "   -> OK: the direct query sees a filter that is really there" \
      || { echo "   -> FAIL: direct query missed a known filter"; rc=1; }
    echo "   and the caller's own cgroup, for contrast:"
    "$CGDEVQ" "$(cgroup_dir_for "$(pid_cgroup_path $$)")"
  else
    echo "   -> SKIPPED (needs python3 + systemd-run on cgroup v2)"
  fi

  sub "5. device policy dumper runs against this shell's own cgroup"
  dump_device_policy "$(pid_cgroup_path $$)" | head -40
  hdr "SELF TEST $([ $rc -eq 0 ] && echo PASSED || echo FAILED)"
  exit $rc
fi

# ------------------------------------------------------- locate kata + config
find_kata_config() {
  [ -n "$KATA_CONFIG" ] && { echo "$KATA_CONFIG"; return; }
  local c
  for c in /etc/kata-containers/configuration.toml \
           /opt/kata/share/defaults/kata-containers/configuration.toml \
           /usr/share/defaults/kata-containers/configuration.toml; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
  echo ""
}

set_sandbox_cgroup_only() {
  local cfg=$1 val=$2
  [ -f "$cfg" ] || return 1
  cp -n "$cfg" "$cfg.nvkvm-kata.bak" 2>/dev/null
  if grep -qE '^[[:space:]]*#?[[:space:]]*sandbox_cgroup_only' "$cfg"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*sandbox_cgroup_only.*|sandbox_cgroup_only=$val|" "$cfg"
  else
    printf '\nsandbox_cgroup_only=%s\n' "$val" >> "$cfg"
  fi
  grep -n "sandbox_cgroup_only" "$cfg"
}

# ------------------------------------------------------- find the hypervisor
# Deliberately NOT pgrep/pkill -f: those match our own command line. comm is
# read from ps -eo, and the sandbox id is matched against /proc/<pid>/cmdline.
find_hypervisor_pid() {
  local want=${1:-}
  local pid comm cmd
  while read -r pid comm; do
    case "$comm" in
      qemu-system-*|cloud-hyperviso*|firecracker|qemu*) ;;
      *) continue ;;
    esac
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
    if [ -n "$want" ]; then
      case "$cmd" in *"$want"*) echo "$pid"; return 0 ;; esac
    else
      echo "$pid"; return 0
    fi
  done < <(ps -eo pid=,comm=)
  return 1
}

CTR_CID=""
teardown_sandbox() {
  [ -z "$CTR_CID" ] && return
  [ "$KEEP" -eq 1 ] && { echo "--keep: leaving container $CTR_CID running"; return; }
  # -a is load-bearing: without it the sandbox VM survives `ctr task rm` and
  # the next run measures a stale hypervisor.
  ctr task kill -a -s SIGKILL "$CTR_CID" >/dev/null 2>&1
  sleep 3
  ctr task rm -f "$CTR_CID" >/dev/null 2>&1
  ctr container rm "$CTR_CID" >/dev/null 2>&1
  local i
  for i in $(seq 1 15); do
    find_hypervisor_pid "$CTR_CID" >/dev/null || break
    sleep 1
  done
  if find_hypervisor_pid "$CTR_CID" >/dev/null; then
    warn "hypervisor for $CTR_CID is STILL running after teardown; later runs may be measuring it"
  fi
  CTR_CID=""
}
trap 'teardown_sandbox; cleanup_synth' EXIT

launch_sandbox() {
  local tag=$1
  CTR_CID="nvkvm-kata-q1-$tag-$$"
  command -v ctr >/dev/null 2>&1 || { echo "!! ctr not found"; return 1; }
  ctr image pull "$IMAGE" >/dev/null 2>&1 || warn "image pull failed (may already be present)"
  echo "+ ctr run -d --runtime $RUNTIME $IMAGE $CTR_CID sleep 600"
  if ! ctr run -d --runtime "$RUNTIME" "$IMAGE" "$CTR_CID" sleep 600 >"$OUTDIR/ctr-$tag.log" 2>&1; then
    echo "!! ctr run failed:"; sed 's/^/    /' "$OUTDIR/ctr-$tag.log"; CTR_CID=""; return 1
  fi
  local i pid=""
  for i in $(seq 1 30); do
    # `ctr task ls` reports the hypervisor pid for a Kata task; cross-check it
    # against /proc so a wrong answer cannot pass silently.
    pid=$(ctr task ls 2>/dev/null | awk -v c="$CTR_CID" '$1==c{print $2}')
    if [ -n "$pid" ] && [ -r "/proc/$pid/comm" ]; then
      case "$(cat /proc/$pid/comm)" in qemu*|cloud-hyperviso*|firecracker) break ;; esac
    fi
    pid=$(find_hypervisor_pid "$CTR_CID") && [ -n "$pid" ] && break
    pid=""; sleep 1
  done
  [ -n "$pid" ] || { echo "!! no hypervisor process found for $CTR_CID"; return 1; }
  echo "$pid"
}

# --------------------------------------------------------------- one measurement
OVERALL=0
RESULTS=()

measure() {
  local tag=$1 pid=$2
  local cgpath; cgpath=$(pid_cgroup_path "$pid")

  sub "hypervisor process"
  echo "pid            : $pid"
  echo "comm           : $(cat /proc/$pid/comm 2>/dev/null)"
  echo "uid            : $(awk '/^Uid:/{print $2}' /proc/$pid/status 2>/dev/null)"
  echo "cmdline        : $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-400)"
  echo "selinux label  : $(cat /proc/$pid/attr/current 2>/dev/null || echo '(none)')"
  sub "namespaces (hypervisor vs PID 1)"
  local ns
  for ns in mnt pid net user ipc uts cgroup; do
    printf '  %-7s hypervisor=%-22s pid1=%s\n' "$ns" \
      "$(readlink /proc/$pid/ns/$ns 2>/dev/null)" "$(readlink /proc/1/ns/$ns 2>/dev/null)"
  done
  sub "/proc/$pid/cgroup"
  sed 's/^/    /' "/proc/$pid/cgroup"
  echo
  echo "cgroup that carries the device policy: $cgpath"
  case "$cgpath" in
    *kata_overhead*) echo "  -> this is the OVERHEAD cgroup (sandbox.go:1012, created with empty LinuxResources{})" ;;
    *kata_*)         echo "  -> this is the SANDBOX cgroup (kata_<sandbox-id>, built by createResourceController)" ;;
    *)               echo "  -> neither kata_ nor kata_overhead: note this, it is itself a finding" ;;
  esac

  sub "device policy on that cgroup"
  dump_device_policy "$cgpath"

  sub "open() from the hypervisor's OWN cgroup  <<< THE MEASUREMENT"
  local out st
  out=$(probe_in_cgroup "$cgpath" "$CONTROL_DEVICE" "${DEVICES[@]}" 2>&1); st=$?
  echo "$out"

  sub "open() from the caller's cgroup (control: is the node openable at all?)"
  probe_here "$CONTROL_DEVICE" "${DEVICES[@]}" 2>&1

  # ---- verdict
  local verdict reason
  if [ $st -eq 3 ]; then
    verdict="NOT-MEASURED"; reason="probe could not join the cgroup"
  elif ! echo "$out" | grep -q "^probe: pid=.*cgroup=.*$(basename "$cgpath")"; then
    verdict="NOT-MEASURED"; reason="probe did not confirm it was in $cgpath"
  elif echo "$out" | grep -E "^\s+$CONTROL_DEVICE\s+OPEN-FAIL" >/dev/null; then
    verdict="VOID"; reason="$CONTROL_DEVICE failed to open -- Kata always allows it, so the probe is not measuring the right cgroup"
  elif echo "$out" | grep -E "^\s+/dev/nvidiactl\s+" | grep -q "DENIED-BY-CGROUP"; then
    verdict="FAIL"; reason="/dev/nvidiactl open() -> EPERM: the device cgroup denied it"
  elif echo "$out" | grep -E "^\s+/dev/nvidiactl\s+" | grep -qE "OPEN-OK|ALLOWED-BY-CGROUP"; then
    verdict="PASS"; reason="/dev/nvidiactl was not denied by the device cgroup"
  elif echo "$out" | grep -E "^\s+/dev/nvidiactl\s+ABSENT" >/dev/null; then
    verdict="NOT-MEASURED"; reason="/dev/nvidiactl does not exist on this host (use --synthesise-nodes)"
  else
    verdict="NOT-MEASURED"; reason="no conclusive result for /dev/nvidiactl"
  fi
  RESULTS+=("$tag|$verdict|$cgpath|$reason")
  [ "$verdict" = FAIL ] && OVERALL=1
  [ "$verdict" = VOID ] && OVERALL=1
  hdr "$tag: $verdict -- $reason"
}

# ------------------------------------------------------------------------ main
hdr "nvkvm-kata Q1: can the Kata hypervisor open the host NVIDIA device nodes?"
echo "date        : $(date -u +%FT%TZ)"
echo "kernel      : $(uname -r)"
echo "cgroup      : $CGV"
echo "host        : $(hostname)"
echo "runtime     : $RUNTIME"
command -v kata-runtime >/dev/null 2>&1 && kata-runtime --version 2>&1 | sed 's/^/kata        : /'
echo "selinux     : $( (command -v getenforce >/dev/null && getenforce) || echo 'not installed')"
command -v semodule >/dev/null 2>&1 && echo "container-selinux: $(semodule -l 2>/dev/null | grep -c container) module(s) matching 'container'"

[ "$SYNTH" -eq 1 ] && { sub "synthetic device nodes"; synthesise_nodes; }

if [ -n "$PROBE_PID" ]; then
  measure "pid-$PROBE_PID" "$PROBE_PID"
else
  CFG=$(find_kata_config)
  [ -n "$CFG" ] || die "no Kata configuration.toml found; pass --config"
  echo "kata config : $CFG"
  case "$SCO_MODE" in
    both)  VALUES=(false true) ;;
    true)  VALUES=(true) ;;
    false) VALUES=(false) ;;
    auto)  VALUES=(current) ;;
    *) die "--sandbox-cgroup-only must be both|true|false|auto" ;;
  esac
  for v in "${VALUES[@]}"; do
    hdr "sandbox_cgroup_only = $v"
    if [ "$v" != current ]; then
      set_sandbox_cgroup_only "$CFG" "$v" | sed 's/^/config: /'
    fi
    pid=$(launch_sandbox "sco-$v" | tail -1)
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      echo "!! could not start a Kata sandbox for sandbox_cgroup_only=$v"
      RESULTS+=("sco=$v|NOT-MEASURED|-|sandbox did not start")
      teardown_sandbox
      continue
    fi
    measure "sco=$v" "$pid"
    teardown_sandbox
  done
fi

hdr "SUMMARY"
printf '%-12s %-13s %-50s %s\n' SETTING VERDICT CGROUP REASON
for r in "${RESULTS[@]}"; do
  IFS='|' read -r a b c d <<< "$r"
  printf '%-12s %-13s %-50s %s\n' "$a" "$b" "$c" "$d"
done
echo
echo "PASS = the Kata-launched hypervisor's device cgroup permits open() of /dev/nvidiactl."
echo "FAIL = it does not (EPERM), which is the case docs/design/01-vmm-confinement.md §4 must solve."
echo "Full evidence in $OUTDIR"
exit $OVERALL
