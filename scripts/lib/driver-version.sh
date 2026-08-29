# shellcheck shell=bash
# nvkvm-kata -- parse the NVIDIA driver version out of /proc/driver/nvidia/version.
#
# Sourced by nvkvm-kata-install.sh.  Exercised, together with gpu-cdi.py's
# driver_version(), by `scripts/lib/gpu-cdi.py self-test`.
#
# THE TWO IMPLEMENTATIONS MUST AGREE.  The installer records a driver version in
# the GPU manifest; the injector re-derives it on EVERY container start and
# refuses to run when the two differ.  A shell rule and a Python rule that drift
# apart therefore do not produce a wrong version, they produce a runtime that
# will not start any GPU container at all.  That is why the self-test asserts
# equality between them rather than testing each in isolation, and why this rule
# lives in one sourceable file instead of being retyped in the installer.
#
# THREE formats, all of them real and all of them observed:
#   proprietary        NVRM version: NVIDIA UNIX x86_64 Kernel Module  575.51.03  Fri May 30 ...
#   open, 3-component  NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  580.95.05  Wed Sep 10 ...
#   open, 2-component  NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.84  Thu Jul 17 ...
#
# and TWO traps, both of which have cost a real install:
#
#   * the arch moves ACROSS the words "Kernel Module" between the proprietary
#     and the open flavour, so anchoring on those words yields the literal
#     string "for" on an open-module host.
#
#   * a driver version may have only TWO components -- 595.84 is not 575.51.03 --
#     and the file's SECOND line is the compiler, which is ALWAYS three:
#         GCC version:  gcc version 15.2.0 (Ubuntu 15.2.0-16ubuntu1)
#     So a file-wide search for a three-component number does not fail loudly on
#     a two-component driver.  It silently returns GCC's version.  That is
#     exactly how a host running 595.84 printed "ok NVIDIA host driver 15.2.0",
#     passed preflight, and died four stages later against a driver that does
#     not exist.  MEASURED 2026-08-28, RTX 4070 / Ubuntu 26.04.
#
# Hence both rules below: the NVRM line ONLY, and a WHOLE-FIELD match of two or
# three components.  Whole-field matters -- a substring search would happily
# find a version inside a longer token.  A fourth component is deliberately NOT
# accepted: an unrecognised format should fail loudly here rather than be
# guessed at, which is the same wrong-and-loud-beats-wrong-and-silent rule the
# rest of this installer follows.

# Parse a version out of a file in /proc/driver/nvidia/version's format.
# Echoes the version, or nothing at all if the file has no usable NVRM line.
nvkvm_driver_version_from_file() {   # <path>
    awk '/NVRM version/ {
             for (i = 1; i <= NF; i++)
                 if ($i ~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/) { print $i; exit }
             exit
         }' "$1" 2>/dev/null
}

# The host's driver version.  /proc first; nvidia-smi only as a last resort,
# because nvidia-smi can fail for reasons that have nothing to do with the
# driver being loaded -- but a format /proc parsing does not recognise is still
# better answered by NVIDIA than guessed at.  gpu-cdi.py falls back the same
# way, and must keep doing so, or the two can disagree on an unknown format.
nvkvm_driver_version() {
    local v
    v="$(nvkvm_driver_version_from_file /proc/driver/nvidia/version)"
    [ -n "$v" ] || v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader \
                        2>/dev/null | head -1 | tr -d '[:space:]')"
    printf '%s' "$v"
}
