#!/usr/bin/env python3
"""gpu-cdi.py -- host driver userspace into an nvkvm-kata container, automatically.

The problem this solves, in one sentence: `nvidia-container-toolkit` does four
things for a GPU container, and only two of them survive the Kata boundary.

    1. bind-mount the device nodes         -- guest-side, already solved (doc 03)
    2. bind-mount the host CUDA libraries  -- THIS FILE
    3. allow the nodes in the device cgroup-- guest-side, already solved (doc 03)
    4. create SONAME symlinks + ldcache
       entries in the container's WRITABLE
       layer, via CDI `createContainer`
       hooks                               -- THIS FILE

(4) is the interesting half.  The host's driver libraries are *version
postfixed* -- `libcuda.so.575.51.03` -- and every consumer asks for the SONAME,
`libcuda.so.1`.  Under plain runc, NVIDIA's `update-ldcache` hook runs
`ldconfig` inside the container and ldconfig creates that link.  Under Kata,
host-injected hooks are deleted before the spec ever reaches the guest:

    src/runtime/virtcontainers/kata_agent.go:1055 constrainGRPCSpec()
        // Disable Hooks since they have been handled on the host and there is
        // no reason to send them to the agent.
        grpcSpec.Hooks = nil

so nothing runs ldconfig in there and `libcuda.so.1` never comes into being.
That is why the old README told people to bind-mount a hand-built bundle and
set LD_LIBRARY_PATH.

The fix here needs no hook and no guest-side code: a SONAME is just a *name*,
and a bind mount can supply a name.  We mount the same host file twice -- once
at its versioned path and once at its SONAME path -- so `libcuda.so.1` exists
in the container as a real file in a directory glibc searches by default.
`dlopen("libcuda.so.1")` resolves with no ldcache, no symlink, no
LD_LIBRARY_PATH.

WHAT IS NOT REIMPLEMENTED HERE.  *Which* files are driver files is NVIDIA's
question, and it changes with every driver release, so we ask NVIDIA:
`nvidia-ctk cdi generate` -- the same command Kata's own NVIDIA-GPU-passthrough
path runs in the guest, and the same code `nvidia-container-runtime` uses in CDI
mode.  We consume its output as data and take exactly two fields:

    containerEdits.mounts               -> the file list, verbatim
    hooks[create-symlinks] --link a::b  -> the extra non-SONAME links NVIDIA
                                           wants (libcuda.so, libGLX_indirect...)

The only thing computed here is DT_SONAME, read straight out of the ELF -- and
that is glibc semantics, not NVIDIA's, so it cannot rot when NVIDIA ships a new
library.  Add a library to the driver and it appears in the mount list on the
next `discover` with no change to this file.

Deliberately invoked as a subprocess rather than linked as a Go library: the
list then tracks the toolkit *installed on this host*, which is also the toolkit
whose `nvidia-container-runtime-hook` Docker requires before `--gpus` works at
all.  A compiled-in copy could disagree with the host's driver; this cannot.

USAGE
  gpu-cdi.py discover [--out FILE] [--force]
        Ask nvidia-ctk, distil, write the manifest.  Idempotent; a no-op when
        the manifest already matches the running driver unless --force.

  gpu-cdi.py inject --bundle DIR [--manifest FILE]
        Per container.  Edit the OCI config.json containerd wrote into the
        bundle.  Silent no-op when the container did not ask for a GPU.
"""

import argparse
import json
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import time

DEFAULT_MANIFEST = "/var/lib/nvkvm-kata/gpu-mounts.json"

# THE TOOLKIT FLOOR, and why there is a floor rather than a pin.
#
# We call the host's own `nvidia-ctk`, never a bundled copy, and that is
# deliberate: new driver releases ship new libraries, and it is the toolkit's
# discovery that knows their names.  A pin would freeze exactly the thing that
# has to stay current, and would buy no reproducibility worth having -- the
# libraries it finds are the host's either way.  It also costs nothing to
# depend on, because Docker already refuses `--gpus` without
# nvidia-container-runtime-hook, which ships in the same package.
#
# So: no ceiling, but a floor, determined by running the real thing rather than
# guessed.  See docs/install.md §7 for the version-by-version test.
MIN_TOOLKIT = "1.14.6"
NVIDIA_VISIBLE_DEVICES = "NVIDIA_VISIBLE_DEVICES"
NVIDIA_DRIVER_CAPABILITIES = "NVIDIA_DRIVER_CAPABILITIES"
VISIBLE_CDI_DEVICES = "VISIBLE_CDI_DEVICES"
CDI_KIND = "nvidia.com/gpu"
# What Docker's --gpus and NVIDIA's images use to mean "no GPU".
NO_GPU = ("", "void", "none")


# WHERE OUTPUT IS ALLOWED TO GO, and why it matters.
#
# containerd collects the shim binary's COMBINED output from `start` and parses
# the whole thing as the shim's ttrpc address
# (runtime/v2/shim/util.go, cmd.CombinedOutput()).  One byte on stdout OR
# stderr from anything the wrapper runs and the address becomes garbage:
#
#   failed to create TTRPC connection: dial unix  gpu-cdi: NVIDIA_VISIBLE...
#   unix:///run/containerd/s/9be05aa...: connect: invalid argument
#
# MEASURED on 2026-08-28, docs/design/evidence/09/.  So `inject` prints
# NOTHING on success -- it appends to a log file instead.  On FAILURE it does
# print, deliberately: the injector exits non-zero, the wrapper exits non-zero,
# containerd never gets an address, and the message it mangles into its error
# is still the fastest way to see what went wrong.  Wrong-and-loud beats
# wrong-and-silent, which is the same rule the KATA_CONF_FILE fallback follows.
LOGFILE = os.environ.get("NVKVM_GPU_LOG", "/var/log/nvkvm-kata-gpu.log")


def log(msg):
    try:
        with open(LOGFILE, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    except OSError:
        pass


def warn(msg):
    print("gpu-cdi: %s" % msg, file=sys.stderr)


def die(msg, hint=None):
    log("FATAL: %s%s" % (msg, (" -- " + hint) if hint else ""))
    print("gpu-cdi: %s" % msg, file=sys.stderr)
    if hint:
        print("gpu-cdi:   -> %s" % hint, file=sys.stderr)
    sys.exit(1)


# ── DT_SONAME, straight out of the ELF ───────────────────────────────────────
# ~40 lines instead of a binutils dependency.  We need this because NVIDIA's
# CDI spec does NOT carry the SONAME links: `nvidia-ctk cdi generate` emits
# create-symlinks only for the odd ones out (libcuda.so, libGLX_indirect.so.0,
# the gbm and xorg links) and leaves libcuda.so.1 to ldconfig.  MEASURED --
# docs/design/evidence/09/nvidia-ctk-cdi-generate.json.
def read_soname(path):
    """Return DT_SONAME of an ELF shared object, or None."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    if data[4] != 2:            # ELFCLASS64 only; nvkvm is x86_64-only anyway
        return None
    little = data[5] == 1
    end = "<" if little else ">"
    e_phoff, = struct.unpack_from(end + "Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from(end + "HH", data, 0x36)
    dyn_off = dyn_size = None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 56 > len(data):
            return None
        p_type, = struct.unpack_from(end + "I", data, off)
        if p_type == 2:                                  # PT_DYNAMIC
            p_offset, = struct.unpack_from(end + "Q", data, off + 0x08)
            p_filesz, = struct.unpack_from(end + "Q", data, off + 0x20)
            dyn_off, dyn_size = p_offset, p_filesz
            break
    if dyn_off is None:
        return None
    strtab_addr = strtab_off = soname_idx = None
    # d_tag/d_val pairs until DT_NULL
    for off in range(dyn_off, min(dyn_off + dyn_size, len(data) - 15), 16):
        d_tag, d_val = struct.unpack_from(end + "qQ", data, off)
        if d_tag == 0:                                   # DT_NULL
            break
        elif d_tag == 5:                                 # DT_STRTAB (a vaddr)
            strtab_addr = d_val
        elif d_tag == 14:                                # DT_SONAME (a strtab index)
            soname_idx = d_val
    if soname_idx is None or strtab_addr is None:
        return None
    # Translate the DT_STRTAB virtual address to a file offset through the
    # program headers -- .dynstr is always inside a PT_LOAD.
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from(end + "I", data, off)
        if p_type != 1:                                  # PT_LOAD
            continue
        p_offset, p_vaddr = struct.unpack_from(end + "QQ", data, off + 0x08)
        p_filesz, = struct.unpack_from(end + "Q", data, off + 0x20)
        if p_vaddr <= strtab_addr < p_vaddr + p_filesz:
            strtab_off = p_offset + (strtab_addr - p_vaddr)
            break
    if strtab_off is None:
        return None
    end_idx = data.find(b"\0", strtab_off + soname_idx)
    if end_idx < 0:
        return None
    name = data[strtab_off + soname_idx:end_idx].decode("utf-8", "replace")
    return name or None


# ── discover ─────────────────────────────────────────────────────────────────
def driver_version():
    """The host driver version, from /proc, for both kernel-module flavours.

    Take the first dotted number, NOT the token after "Kernel Module": the open
    module writes "... Open Kernel Module for x86_64  580.95.05 ..." and the
    proprietary one writes "... x86_64 Kernel Module  575.51.03 ...", so
    anchoring on the words yields "for" on an open-module host.  This must stay
    byte-identical to the installer's rule -- `inject` compares its result
    against the manifest on every container start.
    """
    try:
        with open("/proc/driver/nvidia/version") as f:
            m = re.search(r"\d+\.\d+(?:\.\d+)+", f.read())
            return m.group(0) if m else None
    except OSError:
        return None


def parse_version(text):
    """First dotted numeric run in a version string -> tuple of ints."""
    m = re.search(r"(\d+(?:\.\d+)+)", text or "")
    return tuple(int(x) for x in m.group(1).split(".")) if m else None


def toolkit_version(exe):
    """(version_tuple, raw_string) for an nvidia-ctk, or (None, raw)."""
    try:
        p = subprocess.run([exe, "--version"], capture_output=True, text=True)
        raw = ((p.stdout or "") + (p.stderr or "")).strip()
    except OSError:
        return None, ""
    return parse_version(raw), raw


def check_shape(spec, exe, raw_version):
    """Assert the CDI spec has the fields we actually consume, non-empty.

    A version floor alone is not enough: a toolkit can be new enough and still
    produce an empty spec (no driver loaded, a container without the device
    nodes, a partially installed driver).  Both failures look identical later
    on -- a GPU container with no libraries and no error -- so both are caught
    here, at install time, where there is a human to read the message.
    """
    problems = []
    edits = spec.get("containerEdits")
    if not isinstance(edits, dict):
        problems.append("no top-level containerEdits object")
        edits = {}
    mounts = edits.get("mounts")
    if not mounts:
        problems.append("containerEdits.mounts is empty -- no driver libraries were discovered")
    else:
        for m in mounts:
            if not m.get("hostPath") or not (m.get("containerPath") or m.get("hostPath")):
                problems.append("a mount entry has no hostPath/containerPath")
                break
        names = {os.path.basename(m.get("containerPath") or m.get("hostPath") or "")
                 for m in mounts}
        if not any(n.startswith("libcuda.so.") for n in names):
            problems.append("no libcuda.so.* among the mounts -- this spec cannot run CUDA")
        if not any(n == "nvidia-smi" for n in names):
            problems.append("nvidia-smi is not among the mounts")
    if not spec.get("devices"):
        problems.append("the spec declares no devices")
    if not problems:
        return
    die("`%s cdi generate` produced a spec this installer cannot use:\n    - %s"
        % (exe, "\n    - ".join(problems)),
        "toolkit version: %s.  Check that the NVIDIA driver is loaded and "
        "complete (`nvidia-smi`, `ls /dev/nvidia*`), then re-run.  Inspect the "
        "raw spec with: %s cdi generate --format=json" % (raw_version or "unknown", exe))


def userspace_versions():
    """Driver versions visible as libcuda.so.<v> on this host."""
    out = set()
    for d in ("/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib"):
        try:
            for n in os.listdir(d):
                m = re.match(r"libcuda\.so\.(\d+\.\d+(?:\.\d+)?)$", n)
                if m:
                    out.add(m.group(1))
        except OSError:
            continue
    return out


def check_driver_consistency():
    """Catch the classic 'Driver/library version mismatch' host, by name.

    A package upgrade replaces the driver's USERSPACE on disk while the running
    KERNEL MODULE stays at the old version until reboot.  Everything NVIDIA
    then fails, with errors that describe the symptom rather than the cause --
    `nvidia-smi` says "Failed to initialize NVML", `nvidia-ctk` says "failed to
    construct device spec generators".  Seen for real 2026-08-28, when
    unattended-upgrades installed 580.173.02 over a running 580.95.05 in the
    middle of an install.
    """
    live = driver_version()
    disk = userspace_versions()
    if not live or not disk:
        return
    # Compare on the first two components: NVIDIA ships libcuda.so.580.173.02
    # against module 580.173.02, but some distros truncate the patch level.
    short = lambda v: ".".join(v.split(".")[:2])
    if short(live) in {short(d) for d in disk} or live in disk:
        return
    die("this host has a driver/library version mismatch: the loaded kernel "
        "module is %s but the userspace on disk is %s"
        % (live, ", ".join(sorted(disk))),
        "a package upgrade replaced the driver without reloading the module. "
        "Reboot, or unload and reload the nvidia modules, then re-run. "
        "`nvidia-smi` will fail on this host too, for any runtime.")


def run_nvidia_ctk():
    """Return the CDI spec `nvidia-ctk cdi generate` produces, as a dict."""
    exe = None
    for cand in ("nvidia-ctk", "/usr/bin/nvidia-ctk", "/usr/local/nvidia/toolkit/nvidia-ctk"):
        try:
            subprocess.run([cand, "--version"], check=True, capture_output=True)
            exe = cand
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    if exe is None:
        die("nvidia-ctk not found",
            "install nvidia-container-toolkit -- Docker also needs it before "
            "`docker run --gpus` will work at all")
    ver, raw = toolkit_version(exe)
    floor = tuple(int(x) for x in MIN_TOOLKIT.split("."))
    if ver is None:
        warn("could not parse a version out of `%s --version` (%r); continuing"
             % (exe, raw))
    elif ver < floor:
        die("nvidia-container-toolkit %s is too old (need >= %s)"
            % (".".join(map(str, ver)), MIN_TOOLKIT),
            "upgrade it: this is the oldest release whose `cdi generate` output "
            "this installer was tested against -- docs/install.md #7")
    with tempfile.NamedTemporaryFile(suffix=".json") as tmp:
        p = subprocess.run(
            [exe, "cdi", "generate", "--format=json", "--output=" + tmp.name],
            capture_output=True, text=True)
        if p.returncode != 0:
            die("`%s cdi generate` failed (rc=%d)" % (exe, p.returncode),
                (p.stderr or "").strip().splitlines()[-1] if p.stderr else None)
        with open(tmp.name) as f:
            spec = json.load(f)
    check_shape(spec, exe, raw)
    return spec, exe, raw


def hook_args(spec, hook_name):
    """Every argv of every createContainer hook whose subcommand is hook_name."""
    out = []
    edits = spec.get("containerEdits") or {}
    for h in edits.get("hooks") or []:
        args = h.get("args") or []
        if hook_name in args[:3]:
            out.append(args)
    return out


def discover(out_path, force):
    ver = driver_version()
    if ver is None:
        die("no /proc/driver/nvidia/version", "the NVIDIA driver is not loaded on this host")
    check_driver_consistency()
    if not force and os.path.exists(out_path):
        try:
            with open(out_path) as f:
                old = json.load(f)
            if old.get("driver_version") == ver and old.get("mounts"):
                print("gpu-cdi: manifest already matches driver %s (%d mounts); "
                      "nothing to do" % (ver, len(old["mounts"])))
                return 0
        except (OSError, ValueError):
            pass

    spec, exe, tk_raw = run_nvidia_ctk()
    edits = spec.get("containerEdits") or {}

    mounts = []          # [{source, destination, options}]
    skipped = []         # [{source, destination, why, reason}]
    seen_dest = set()

    def add(src, dst, options, why):
        dst = os.path.normpath(dst)
        if dst in seen_dest:
            return
        if not os.path.exists(src):
            warn("skipping %s: host path %s does not exist" % (dst, src))  # discover only
            skipped.append({"source": src, "destination": dst, "why": why,
                            "reason": "host path does not exist"})
            return
        # ONLY REGULAR FILES AND DIRECTORIES CROSS THE VM BOUNDARY.
        #
        # Kata shares an OCI mount by bind-mounting it into the sandbox's
        # shared directory and exporting that over virtio-fs.  A socket, a
        # FIFO or a device node cannot be carried that way, and the failure is
        # not a warning -- the agent aborts createContainer with a bare
        #     Input/output error (os error 5)
        # and a stack of <unknown> frames that names nothing.
        #
        # This is not hypothetical: nvidia-container-toolkit 1.18.0's IPC
        # discoverer emits /run/nvidia-persistenced/socket, which is a UNIX
        # socket, and it made every GPU container on the runtime fail to start.
        # MEASURED 2026-08-28 on driver 580.95.05 / toolkit 1.18.0; toolkit
        # 1.17.1 on another host did not emit it, which is exactly why this is
        # filtered by KIND rather than by name.
        try:
            st = os.stat(src)          # follow symlinks: the target is what gets bound
        except OSError as e:
            skipped.append({"source": src, "destination": dst, "why": why,
                            "reason": "stat failed: %s" % e})
            return
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            kind = ("socket" if stat.S_ISSOCK(st.st_mode) else
                    "fifo" if stat.S_ISFIFO(st.st_mode) else
                    "char device" if stat.S_ISCHR(st.st_mode) else
                    "block device" if stat.S_ISBLK(st.st_mode) else "not a regular file")
            warn("skipping %s: %s is a %s and cannot cross virtio-fs" % (dst, src, kind))
            skipped.append({"source": src, "destination": dst, "why": why,
                            "reason": "%s -- cannot cross virtio-fs" % kind})
            return
        seen_dest.add(dst)
        mounts.append({"source": os.path.realpath(src), "destination": dst,
                       "options": options, "why": why})

    # (2) the file list, verbatim from NVIDIA.
    ro = ["ro", "nosuid", "nodev", "rbind", "rprivate"]
    for m in edits.get("mounts") or []:
        src = m.get("hostPath")
        dst = m.get("containerPath") or src
        if not src:
            continue
        add(src, dst, m.get("options") or ro, "nvidia-ctk mount")

    # (4a) SONAME names, so that dlopen("libcuda.so.1") resolves with no
    #      ldcache and no hook.  NVIDIA leaves these to ldconfig; we cannot run
    #      ldconfig in the container, so we supply the name as a mount.
    for m in list(mounts):
        base = os.path.basename(m["destination"])
        if ".so" not in base:
            continue
        soname = read_soname(m["source"])
        if not soname or soname == base:
            continue
        add(m["source"], os.path.join(os.path.dirname(m["destination"]), soname),
            m["options"], "SONAME of " + base)

    # (4b) the extra links NVIDIA asks for by name -- libcuda.so, the GLX
    #      indirect link, the gbm/xorg links.  Resolved against the host and
    #      supplied as a mount of the file they end up pointing at.  Links
    #      under /dev are device links and belong to the guest, not here.
    symlinks = []
    for args in hook_args(spec, "create-symlinks"):
        it = iter(args)
        for a in it:
            if a != "--link":
                continue
            pair = next(it, "")
            if "::" not in pair:
                continue
            target, link = pair.split("::", 1)
            symlinks.append({"target": target, "link": link})
            if link.startswith("/dev/"):
                continue
            host = target if os.path.isabs(target) else \
                os.path.normpath(os.path.join(os.path.dirname(link), target))
            add(host, link, ro, "create-symlinks %s" % pair)

    ldcache_folders = []
    for args in hook_args(spec, "update-ldcache"):
        it = iter(args)
        for a in it:
            if a == "--folder":
                ldcache_folders.append(next(it, ""))

    # THE CROSS-DISTRO CASE, and why these folders are not just informational.
    #
    # The mounts land at the HOST's paths.  On a Debian/Ubuntu host that is
    # /usr/lib/x86_64-linux-gnu, which is also a default library directory in
    # most containers, so everything resolves by luck.  On a RHEL host it is
    # /usr/lib64 -- and in an Ubuntu container /usr/lib64 is not searched, not
    # in ld.so.conf, and not built in.  MEASURED on RHEL 9.5, 2026-08-28:
    # libcuda.so.1 sitting in /usr/lib64 inside an ubuntu:24.04 container, and
    # `ldconfig -p | grep libcuda` completely empty.
    #
    # NVIDIA solves this by passing these same --folder arguments to its
    # update-ldcache hook, which writes them into the container's ld.so.conf
    # before running ldconfig.  We cannot pass arguments to a hook that lives in
    # the guest -- but we do not need to.  A .conf file is just a file, and we
    # already have a way to put a file in the container: mount it.  ldconfig
    # then finds it by itself.
    if ldcache_folders:
        conf_dir = os.path.dirname(out_path) or "."
        conf = os.path.join(conf_dir, "nvkvm-nvidia-ld.conf")
        os.makedirs(conf_dir, exist_ok=True)
        with open(conf, "w") as f:
            f.write("# Written by nvkvm-kata's gpu-cdi.py -- the directories the host\n"
                    "# NVIDIA driver's libraries are mounted into.  Read by ldconfig,\n"
                    "# which the guest-side CDI hook runs at container create.\n")
            for d in ldcache_folders:
                f.write(d + "\n")
        add(conf, "/etc/ld.so.conf.d/nvkvm-nvidia.conf", ro, "ldconfig search path")

    # index -> uuid, so that `--gpus '"device=GPU-<uuid>"'` can be answered.
    uuids = {}
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=index,uuid",
                            "--format=csv,noheader"], capture_output=True, text=True)
        for line in (p.stdout or "").splitlines():
            if "," in line:
                i, u = line.split(",", 1)
                uuids[u.strip()] = i.strip()
    except OSError:
        pass

    manifest = {
        "driver_version": ver,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "generator": "%s cdi generate" % exe,
        "toolkit_version": tk_raw.splitlines()[0] if tk_raw else "unknown",
        "cdi_kind": spec.get("kind"),
        "mounts": mounts,
        "skipped": skipped,
        "symlinks": symlinks,
        "ldcache_folders": ldcache_folders,
        "gpu_uuid_to_index": uuids,
        # Recorded, not honoured -- see docs/design/09.  NVIDIA's own CDI mode
        # is capability-complete: `nvidia-ctk cdi generate` merges the graphics
        # discoverer unconditionally (pkg/nvcdi/common-nvml.go:27-50) and no
        # public entry point takes a capability set.
        "capabilities": "all (CDI mode is capability-complete)",
    }
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, out_path)
    for sk in skipped:
        log("discover: skipped %s (%s)" % (sk["destination"], sk["reason"]))
    nsoname = sum(1 for m in mounts if m["why"].startswith("SONAME"))
    print("gpu-cdi: driver %s -> %d mounts (%d from nvidia-ctk, %d SONAME names, "
          "%d named links%s) -> %s"
          % (ver, len(mounts), sum(1 for m in mounts if m["why"] == "nvidia-ctk mount"),
             nsoname, sum(1 for m in mounts if m["why"].startswith("create-symlinks")),
             ("; %d skipped, see \"skipped\" in the manifest" % len(skipped)) if skipped else "",
             out_path))
    return 0


# ── inject ───────────────────────────────────────────────────────────────────
def env_get(env, key):
    pre = key + "="
    for e in env:
        if e.startswith(pre):
            return e[len(pre):]
    return None


def visible_to_cdi(value, uuid_to_index):
    """Docker's NVIDIA_VISIBLE_DEVICES -> kata-agent's VISIBLE_CDI_DEVICES.

    `--gpus all`               -> NVIDIA_VISIBLE_DEVICES=all   -> nvidia.com/gpu=all
    `--gpus 2`                 -> NVIDIA_VISIBLE_DEVICES=0,1   -> nvidia.com/gpu=0,1
    `--gpus '"device=1"'`      -> NVIDIA_VISIBLE_DEVICES=1     -> nvidia.com/gpu=1
    `--gpus '"device=GPU-..."'`-> a UUID, mapped back to its index here because
                                  the guest spec is indexed (the guest has no
                                  NVML to resolve a UUID with).
    """
    toks = [t.strip() for t in value.split(",") if t.strip()]
    if "all" in toks:
        return CDI_KIND + "=all"
    out = []
    for t in toks:
        if t.isdigit():
            out.append(t)
        elif t in uuid_to_index:
            out.append(uuid_to_index[t])
        else:
            die("cannot map %s=%r to a CDI device" % (NVIDIA_VISIBLE_DEVICES, t),
                "supported: 'all', device indices, and GPU UUIDs known to this "
                "host; MIG device references are not supported by nvkvm")
    return CDI_KIND + "=" + ",".join(out)


def inject(bundle, manifest_path):
    cfg_path = os.path.join(bundle, "config.json")
    if not os.path.exists(cfg_path):
        # Not every shim invocation has a bundle (`delete` after a crash, say).
        return 0
    with open(cfg_path) as f:
        cfg = json.load(f)

    process = cfg.setdefault("process", {})
    env = process.setdefault("env", [])
    want = env_get(env, NVIDIA_VISIBLE_DEVICES)
    if want is None or want.strip() in NO_GPU:
        return 0                      # not a GPU container; leave it alone

    if not os.path.exists(manifest_path):
        die("%s asked for a GPU but %s does not exist" % (bundle, manifest_path),
            "run: nvkvm-kata-install.sh --only libs   (or scripts/lib/gpu-cdi.py discover)")
    with open(manifest_path) as f:
        man = json.load(f)

    # A driver upgrade under a running installation would otherwise hand the
    # container the previous driver's libraries, which fail with the least
    # helpful error CUDA has ("version mismatch").  Cheap check, every time.
    live = driver_version()
    if live and live != man.get("driver_version"):
        die("host driver is %s but %s was built for %s"
            % (live, manifest_path, man.get("driver_version")),
            "re-run: scripts/lib/gpu-cdi.py discover --force")

    # (1)+(3): ask kata-agent to apply the GUEST's CDI spec, which is where the
    # device nodes and their cgroup rules come from (doc 03).  Host device
    # nodes are deliberately never injected -- the guest's /dev/nvidia-uvm has a
    # different major (doc 07 sec 5).
    cdi = visible_to_cdi(want.strip(), man.get("gpu_uuid_to_index") or {})
    env[:] = [e for e in env if not e.startswith(VISIBLE_CDI_DEVICES + "=")]
    env.append(VISIBLE_CDI_DEVICES + "=" + cdi)

    # The manifest can go stale WITHOUT the driver version changing -- a
    # package upgrade can replace the files while the module keeps running.
    # Kata's report of that is "Could not resolve symlink for source <path>",
    # which does not say what to do about it.  Stat-ing 80 paths costs about a
    # millisecond, once per container, and turns it into a sentence.
    gone = [m["source"] for m in man["mounts"] if not os.path.exists(m["source"])]
    if gone:
        die("%d of the %d driver files in %s no longer exist (first: %s)"
            % (len(gone), len(man["mounts"]), manifest_path, gone[0]),
            "the host driver's userspace changed after the manifest was built. "
            "Re-run: nvkvm-kata-gpu-cdi discover --force")

    # (2)+(4): the libraries, and the names they have to be reachable under.
    mounts = cfg.setdefault("mounts", [])
    have = {m.get("destination") for m in mounts}
    added = 0
    for m in man["mounts"]:
        if m["destination"] in have:
            continue
        mounts.append({"destination": m["destination"], "type": "bind",
                       "source": m["source"], "options": m["options"]})
        added += 1

    # Docker adds nvidia-container-runtime-hook as a `prestart` hook whenever
    # --gpus is used and the toolkit is installed.  Kata DOES run prestart
    # hooks, on the host (katautils/create.go:194) -- where the hook would
    # bind-mount host libraries into a rootfs the guest sees over virtio-fs
    # (bind mounts do not traverse it) and mknod host-numbered device nodes
    # (wrong majors in the guest).  It is also the hook that fails under Kata
    # in kata#10672.  Remove it: everything it would have done is done above.
    hooks = cfg.get("hooks") or {}
    dropped = 0
    for phase in ("prestart", "createRuntime", "createContainer", "startContainer"):
        keep = []
        for h in hooks.get(phase) or []:
            if "nvidia-container-runtime-hook" in (h.get("path") or "") or \
               "nvidia-container-toolkit" in (h.get("path") or ""):
                dropped += 1
                continue
            keep.append(h)
        if phase in hooks:
            hooks[phase] = keep

    tmp = cfg_path + ".nvkvm.tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f)
    os.replace(tmp, cfg_path)

    caps = env_get(env, NVIDIA_DRIVER_CAPABILITIES)
    log("%s %s=%s -> %s=%s, +%d mounts, -%d host hooks%s"
        % (os.path.basename(bundle.rstrip("/")), NVIDIA_VISIBLE_DEVICES, want,
           VISIBLE_CDI_DEVICES, cdi, added, dropped,
           (", capabilities=%s (recorded, not filtered: CDI mode is "
            "capability-complete)" % caps) if caps else ""))
    return 0


def main():
    ap = argparse.ArgumentParser(prog="gpu-cdi.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("discover")
    d.add_argument("--out", default=DEFAULT_MANIFEST)
    d.add_argument("--force", action="store_true")
    i = sub.add_parser("inject")
    i.add_argument("--bundle", default=".")
    i.add_argument("--manifest", default=DEFAULT_MANIFEST)
    a = ap.parse_args()
    if a.cmd == "discover":
        return discover(a.out, a.force)
    return inject(a.bundle, a.manifest)


if __name__ == "__main__":
    sys.exit(main())
