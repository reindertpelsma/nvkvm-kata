#!/usr/bin/env bash
# split-cdi-spec.sh — split a host CDI spec into the half that may cross the VM
# boundary and the half that may not.
#
# WHY (docs/design/02-libraries-via-cdi.md, and the layering rule in 00):
#   "Libraries traverse nothing. Device nodes traverse everything."
#   A spec from `nvidia-ctk cdi generate` on the host mixes two things:
#     * containerEdits.mounts   -> the host driver userspace. WANTED in the
#       container: it arrives over virtio-fs and is version-matched to the host
#       kernel driver that services every forwarded ioctl, by construction.
#     * containerEdits.deviceNodes -> HOST device nodes, with host major:minor.
#       These must NOT be handed to the container: the container's nodes are
#       created inside the guest by nvkvm-guest.ko and described by a
#       guest-generated CDI spec that kata-agent resolves (design doc 03).
#       Passing the host ones through puts host major:minor into the OCI spec
#       the agent acts on -- harmless for the statically-numbered nodes
#       (major 195) and WRONG for /dev/nvidia-uvm*, whose majors are allocated
#       dynamically and independently on each side.
#     * containerEdits.hooks    -> silently DROPPED by Kata's Go shim
#       (kata-containers#11169), so a spec that relies on `update-ldcache`
#       is broken under Kata whether or not this script keeps the hook.
#       Dropped by default, with a warning; --keep-hooks to override.
#
# It emits:
#   (a) a mounts-only spec  -- safe to request on the workload container
#   (b) the deviceNodes it dropped -- as a human-readable table always, and
#       optionally as a host-side CDI spec (--host-spec) of the kind the VMM
#       sandbox should request so the nodes land in Kata's sandbox device
#       cgroup (design doc 01 §4a).
#
# Usage:
#   split-cdi-spec.sh -i nvidia.yaml [-o libs.yaml] [-d dropped.yaml]
#                     [--kind vendor/class] [--host-spec vmm.yaml]
#                     [--host-kind nvkvm.io/vmm] [--format yaml|json]
#                     [--keep-hooks] [--keep-env]
#   split-cdi-spec.sh --self-test        # no input needed; proves the split
#
# Exit: 0 ok, 2 usage/environment error, 1 self-test failure.
set -uo pipefail
SCRIPT_NAME=$(basename "$0")
die() { echo "$SCRIPT_NAME: $*" >&2; exit 2; }

IN=""; OUT="-"; DROPPED=""; KIND=""; HOST_SPEC=""; HOST_KIND="nvkvm.io/vmm"
FORMAT=""; KEEP_HOOKS=0; KEEP_ENV=1; SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)  IN="$2"; shift 2 ;;
    -o|--output) OUT="$2"; shift 2 ;;
    -d|--dropped) DROPPED="$2"; shift 2 ;;
    --kind)      KIND="$2"; shift 2 ;;
    --host-spec) HOST_SPEC="$2"; shift 2 ;;
    --host-kind) HOST_KIND="$2"; shift 2 ;;
    --format)    FORMAT="$2"; shift 2 ;;
    --keep-hooks) KEEP_HOOKS=1; shift ;;
    --drop-env)  KEEP_ENV=0; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"

SPLITTER=$(mktemp /tmp/split-cdi.XXXXXX.py)
trap 'rm -f "$SPLITTER"' EXIT
cat > "$SPLITTER" <<'PYEOF'
import argparse, json, os, sys

def load(path):
    raw = sys.stdin.read() if path == "-" else open(path).read()
    is_json = raw.lstrip().startswith("{")
    if is_json:
        return json.loads(raw), "json"
    try:
        import yaml
    except ImportError:
        sys.exit("split-cdi-spec: input looks like YAML but PyYAML is not installed.\n"
                 "                 pip install pyyaml, or convert with:\n"
                 "                 nvidia-ctk cdi transform ... --format=json")
    return yaml.safe_load(raw), "yaml"

def dump(obj, fmt):
    if fmt == "json":
        return json.dumps(obj, indent=2) + "\n"
    import yaml
    return yaml.safe_dump(obj, sort_keys=False, default_flow_style=False)

def edits_of(container):
    e = container.get("containerEdits")
    if e is None:
        e = {}
        container["containerEdits"] = e
    return e

ap = argparse.ArgumentParser()
ap.add_argument("--input", required=True)
ap.add_argument("--output", default="-")
ap.add_argument("--dropped", default="")
ap.add_argument("--kind", default="")
ap.add_argument("--host-spec", default="")
ap.add_argument("--host-kind", default="nvkvm.io/vmm")
ap.add_argument("--format", default="")
ap.add_argument("--keep-hooks", action="store_true")
ap.add_argument("--drop-env", action="store_true")
a = ap.parse_args()

spec, infmt = load(a.input)
fmt = a.format or infmt
if not isinstance(spec, dict) or "cdiVersion" not in spec:
    sys.exit("split-cdi-spec: not a CDI spec (no cdiVersion key)")

orig_kind = spec.get("kind", "")
dropped_nodes = []      # (device-name, node dict)
dropped_hooks = []
seen_paths = set()

def strip(container, where):
    e = edits_of(container)
    for n in e.pop("deviceNodes", []) or []:
        key = n.get("path")
        dropped_nodes.append((where, n))
        seen_paths.add(key)
    if not a.keep_hooks:
        for h in e.pop("hooks", []) or []:
            dropped_hooks.append((where, h))
    if a.drop_env:
        e.pop("env", None)
    # netDevices are host-flavoured too and cannot mean anything in the guest
    for n in e.pop("netDevices", []) or []:
        dropped_nodes.append((where, {"path": "(netDevice) " + str(n)}))
    if not e:
        container.pop("containerEdits", None)

strip(spec, "<spec-level>")
kept_devices = []
for d in spec.get("devices", []) or []:
    strip(d, d.get("name", "?"))
    kept_devices.append(d)
spec["devices"] = kept_devices

# A CDI kind must be unique in a spec directory; the mounts-only spec is a
# DIFFERENT thing from the spec it came from, so it gets its own kind.
if a.kind:
    spec["kind"] = a.kind
elif orig_kind and "/" in orig_kind:
    vendor, cls = orig_kind.split("/", 1)
    spec["kind"] = "%s/%s-libs" % (vendor, cls)

# ---- (a) mounts-only spec
text = dump(spec, fmt)
if a.output == "-":
    sys.stdout.write(text)
else:
    open(a.output, "w").write(text)

# ---- (b) the deviceNodes it dropped
def node_row(n):
    return (n.get("path", "?"), n.get("type", "c"),
            n.get("major", ""), n.get("minor", ""),
            n.get("permissions", "rw"), n.get("hostPath", ""))

sys.stderr.write("\n== dropped deviceNodes (%d) — these must come from the GUEST ==\n" % len(dropped_nodes))
if not dropped_nodes:
    sys.stderr.write("  (none: the input spec had no deviceNodes)\n")
for where, n in dropped_nodes:
    p, t, ma, mi, perm, hp = node_row(n)
    sys.stderr.write("  %-28s %s %s:%s %-4s  from device %s%s\n"
                     % (p, t, ma, mi, perm, where, ("  hostPath=" + hp) if hp else ""))
if dropped_hooks:
    sys.stderr.write("\n== dropped hooks (%d) — Kata's shim drops these anyway "
                     "(kata-containers#11169) ==\n" % len(dropped_hooks))
    for where, h in dropped_hooks:
        sys.stderr.write("  %-20s %s %s   (device %s)\n"
                         % (h.get("hookName", "?"), h.get("path", "?"),
                            " ".join(h.get("args", []) or [])[:80], where))
    sys.stderr.write("  -> if one of these was `update-ldcache`, replace it with an\n"
                     "     LD_LIBRARY_PATH entry in containerEdits.env, or regenerate\n"
                     "     the ldcache inside the guest. See design doc 02.\n")

if a.dropped:
    payload = {"droppedDeviceNodes": [dict(device=w, **n) for w, n in dropped_nodes],
               "droppedHooks": [dict(device=w, **h) for w, h in dropped_hooks],
               "sourceKind": orig_kind}
    open(a.dropped, "w").write(dump(payload, fmt))
    sys.stderr.write("\nwrote dropped deviceNodes -> %s\n" % a.dropped)

# ---- optional: a host-side spec carrying ONLY those nodes
if a.host_spec:
    nodes = []
    for _, n in dropped_nodes:
        if str(n.get("path", "")).startswith("(netDevice)"):
            continue
        nodes.append(n)
    host = {"cdiVersion": spec.get("cdiVersion", "0.6.0"),
            "kind": a.host_kind,
            "devices": [{"name": "all",
                         "containerEdits": {"deviceNodes": nodes}}]}
    open(a.host_spec, "w").write(dump(host, fmt))
    sys.stderr.write("wrote host-side deviceNodes spec -> %s (kind %s)\n"
                     % (a.host_spec, a.host_kind))
    sys.stderr.write("  Request this kind on the POD SANDBOX so its nodes land in\n"
                     "  spec.Linux.Resources.Devices before Kata builds the sandbox\n"
                     "  device cgroup (design doc 01 §4a). Do NOT request it on the\n"
                     "  workload container.\n")
PYEOF

if [ "$SELF_TEST" -eq 1 ]; then
  TD=$(mktemp -d /tmp/split-cdi-selftest.XXXXXX)
  cat > "$TD/in.yaml" <<'YEOF'
cdiVersion: 0.6.0
kind: nvidia.com/gpu
containerEdits:
  env:
  - NVIDIA_VISIBLE_DEVICES=void
  deviceNodes:
  - path: /dev/nvidiactl
    hostPath: /dev/nvidiactl
    type: c
    major: 195
    minor: 255
  - path: /dev/nvidia-uvm
    type: c
    major: 511
    minor: 0
  hooks:
  - hookName: createContainer
    path: /usr/bin/nvidia-cdi-hook
    args: [nvidia-cdi-hook, update-ldcache, --folder, /usr/lib/x86_64-linux-gnu]
  mounts:
  - hostPath: /usr/lib/x86_64-linux-gnu/libcuda.so.580.95.05
    containerPath: /usr/lib/x86_64-linux-gnu/libcuda.so.580.95.05
    options: [ro, nosuid, nodev, bind]
devices:
- name: "0"
  containerEdits:
    deviceNodes:
    - path: /dev/nvidia0
      type: c
      major: 195
      minor: 0
YEOF
  echo "=== self-test: input ==="; cat "$TD/in.yaml"
  echo; echo "=== running split ==="
  python3 "$SPLITTER" --input "$TD/in.yaml" --output "$TD/libs.yaml" \
     --dropped "$TD/dropped.yaml" --host-spec "$TD/vmm.yaml"
  echo; echo "=== (a) mounts-only spec ==="; cat "$TD/libs.yaml"
  echo; echo "=== (b) host-side deviceNodes spec ==="; cat "$TD/vmm.yaml"
  rc=0
  check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; rc=1; fi; }
  echo; echo "=== assertions ==="
  check "no deviceNodes survive in the mounts-only spec" "! grep -q 'deviceNodes' '$TD/libs.yaml'"
  check "no hooks survive in the mounts-only spec"       "! grep -q 'hooks' '$TD/libs.yaml'"
  check "mounts survive"                                 "grep -q 'libcuda.so' '$TD/libs.yaml'"
  check "env survives (LD_LIBRARY_PATH replaces the hook)" "grep -q 'NVIDIA_VISIBLE_DEVICES' '$TD/libs.yaml'"
  check "kind was renamed away from the source kind"     "grep -q 'kind: nvidia.com/gpu-libs' '$TD/libs.yaml'"
  check "per-device deviceNodes were stripped too"       "! grep -q 'nvidia0' '$TD/libs.yaml'"
  check "all 3 nodes appear in the host-side spec"       "[ \$(grep -c 'path: /dev/nvidia' '$TD/vmm.yaml') -eq 3 ]"
  check "host-side spec keeps the dynamic uvm major"     "grep -q '511' '$TD/vmm.yaml'"
  check "dropped file lists the hook"                    "grep -q 'update-ldcache' '$TD/dropped.yaml'"
  echo; [ $rc -eq 0 ] && echo "SELF TEST PASSED" || echo "SELF TEST FAILED"
  rm -rf "$TD"; exit $rc
fi

[ -n "$IN" ] || die "need -i <cdi spec> (or --self-test)"
ARGS=(--input "$IN" --output "$OUT" --host-kind "$HOST_KIND")
[ -n "$DROPPED" ]   && ARGS+=(--dropped "$DROPPED")
[ -n "$KIND" ]      && ARGS+=(--kind "$KIND")
[ -n "$HOST_SPEC" ] && ARGS+=(--host-spec "$HOST_SPEC")
[ -n "$FORMAT" ]    && ARGS+=(--format "$FORMAT")
[ "$KEEP_HOOKS" -eq 1 ] && ARGS+=(--keep-hooks)
[ "$KEEP_ENV" -eq 0 ]   && ARGS+=(--drop-env)
exec python3 "$SPLITTER" "${ARGS[@]}"
