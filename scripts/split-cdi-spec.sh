#!/usr/bin/env bash
# STUB — NOT IMPLEMENTED. This script does nothing and exits non-zero.
#
# Intent (see docs/design/02-libraries-via-cdi.md):
#   Read a CDI spec produced by `nvidia-ctk cdi generate` and emit a second spec
#   that keeps containerEdits.mounts (the host driver userspace, which is what we
#   want in the container) and DROPS containerEdits.deviceNodes (the container's
#   nodes come from the guest's own /dev, not from the host).
#   Hooks need a decision per hook, not a blanket rule -- see 02.
echo "nvkvm-kata: stub, not implemented. See docs/design/02-libraries-via-cdi.md" >&2
exit 64
