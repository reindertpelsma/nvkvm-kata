#!/usr/bin/env bash
# STUB — NOT IMPLEMENTED. This script does nothing and exits non-zero.
#
# Intent (see docs/design/04-guest-kernel.md):
#   Drive Kata's own tools/packaging/kernel/build-kernel.sh with an added config
#   fragment and an added out-of-tree module build, by exact analogy with the
#   existing `-g nvidia` path -- which already downloads open-gpu-kernel-modules,
#   runs `make ... SYSSRC=<kernel_path>` and `modules_install`s the result into
#   the kernel tree. The nvkvm case substitutes src/guest/ for that source and
#   needs a fragment that turns on CONFIG_MODULES and (for Vulkan) CONFIG_DRM.
echo "nvkvm-kata: stub, not implemented. See docs/design/04-guest-kernel.md" >&2
exit 64
