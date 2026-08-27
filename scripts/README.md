# scripts/

**Every file in this directory is a stub.** They exist to name the steps the
design implies and to record their inputs and outputs. None of them do anything;
each exits non-zero with a pointer to the design document that would have to be
resolved before it could be written.

There are no fake implementations here on purpose. A script that appears to work
and silently does nothing is worse than no script.

| stub | design doc it depends on |
|---|---|
| `check-vmm-device-access.sh` | [01](../docs/design/01-vmm-confinement.md) — the experiment that settles the cgroup/device question |
| `split-cdi-spec.sh` | [02](../docs/design/02-libraries-via-cdi.md) — take the `mounts`, drop the `deviceNodes` |
| `build-guest-kernel.sh` | [04](../docs/design/04-guest-kernel.md) — Kata kernel + `nvkvm-guest.ko` |
