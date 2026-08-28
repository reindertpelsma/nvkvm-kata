# scripts/

All of these are real. The two experiment scripts are self-testing; the five
`07` scripts were exercised end to end on real hardware.
Every script that can be exercised without hardware has a `--self-test` that
rents nothing, needs no GPU and no Kata, and proves the machinery it depends on
before you trust a result from it.

The GPU injector's is a subcommand rather than a flag, because it has
subcommands already:

```bash
scripts/lib/gpu-cdi.py self-test     # 33 checks, no GPU, no root, no Kata
```

It pins the three things that have actually broken a real install: the
driver-version rule (all three `/proc/driver/nvidia/version` formats, in BOTH
the shell and the Python implementation, and that they agree), the detection of
a `--gpus` request that Docker's daemon already resolved through CDI, and the
rule that only regular files and directories can cross virtio-fs.

| script | status | design doc |
|---|---|---|
| `check-vmm-device-access.sh` | **implemented** — the Q1 experiment | [01](../docs/design/01-vmm-confinement.md) |
| `split-cdi-spec.sh` | **implemented** — split a host CDI spec | [02](../docs/design/02-libraries-via-cdi.md) |
| `build-guest-kernel.sh` | **implemented and run end to end** | [04](../docs/design/04-guest-kernel.md), [07](../docs/design/07-end-to-end.md) |
| `prepare-guest-rootfs.sh` | **implemented and run end to end** | [07](../docs/design/07-end-to-end.md) |
| `inject-guest-modules.sh` | **implemented and run end to end** | [04](../docs/design/04-guest-kernel.md), [07](../docs/design/07-end-to-end.md) |
| `nvkvm-qemu-shim.sh` | **implemented and run end to end** | [07](../docs/design/07-end-to-end.md) |
| `e2e/vecadd.c` | **implemented** — the rung-5 proof | [07](../docs/design/07-end-to-end.md) |
| `nvkvm-kata-install.sh` | **implemented and run end to end** — source → installed, one script | [install](../docs/install.md) |
| `nvkvm-kata-uninstall.sh` | **implemented and run** — reverts from the install manifest | [install](../docs/install.md#uninstall) |
| `lib/gpu-cdi.py` | **implemented and run end to end** — `discover` asks `nvidia-ctk` which files are driver files; `inject` puts them in the OCI spec per container, from the shim wrapper. This is what removes the manual `volumes:` + `LD_LIBRARY_PATH` | [09](../docs/design/09-gpu-libraries-automatically.md) |
| `lib/driver-version.sh` | **implemented** — the ONE driver-version rule, sourced by the installer and mirrored by `gpu-cdi.py`; `gpu-cdi.py self-test` asserts the two agree on all three real `/proc/driver/nvidia/version` formats | [install](../docs/install.md) |
| `lib/kata-conf-edit.py` | derive a second `configuration.toml` without losing its comments | [install §5c](../docs/install.md#5c-the-second-configuration) |
| `lib/docker-runtime.py` | add/remove one named runtime in `/etc/docker/daemon.json` | [install §6b](../docs/install.md#6b-docker--one-key-in-daemonjson---what-runtime-in-compose-reads) |

## `nvkvm-kata-install.sh` — the one that installs it

```bash
sudo ./scripts/nvkvm-kata-install.sh --install-kata --install-deps
```

Source to installed, in nine stages (0-8), ending by **running the CUDA proof** on
the runtime it just registered. Every stage maps 1:1 onto a numbered section of
[`docs/install.md`](../docs/install.md), which is the manual path and stays
first-class: the script runs those commands, it does not replace them.

Idempotent (check first, act only if wrong, log what changed), stamped so a
re-run does not rebuild, and `--build` / `--install` are separable so a prebuilt
tarball later is just a cached build stage. Revert with
`nvkvm-kata-uninstall.sh`, which works from the manifest the installer wrote.

Verified end to end on an RTX 3090 (Ampere) on 2026-08-27/28: cold host →
installed → `VECADD OK`, then uninstall → reinstall → a third run with zero
changes. Raw output: [`docs/design/evidence/08/`](../docs/design/evidence/08/).

The five scripts below it were written for [07](../docs/design/07-end-to-end.md), which ran
a CUDA workload in an OCI container in a Kata VM through nvkvm on a real
RTX 4070 Ti SUPER. Read that document before using them: two of its findings
(the container device cgroup is not enforced in the guest; the shipped Kata
rootfs has no `modprobe`) change what the earlier design docs claim.

## `check-vmm-device-access.sh`

Answers: **can the Kata-launched hypervisor `open()` the host's `/dev/nvidiactl`
and `/dev/nvidia*`, and does the answer change with `sandbox_cgroup_only`?**

```bash
sudo ./scripts/check-vmm-device-access.sh --self-test           # no Kata, no GPU
sudo ./scripts/check-vmm-device-access.sh                       # both values, needs Kata
sudo ./scripts/check-vmm-device-access.sh --sandbox-cgroup-only true
sudo ./scripts/check-vmm-device-access.sh --pid 12345           # probe a running VMM
sudo ./scripts/check-vmm-device-access.sh --synthesise-nodes    # Kata but no GPU
```

It starts a Kata sandbox with `ctr`, finds the hypervisor process, prints its
namespaces, SELinux label and `/proc/<pid>/cgroup`, labels the cgroup as the
**sandbox** (`kata_<id>`) or the **overhead** (`kata_overhead/<id>`) one, dumps
that cgroup's device policy — `devices.list` walking to the root on v1; on v2 a
direct `BPF_PROG_QUERY(BPF_CGROUP_DEVICE)` walking to the root, plus
`bpftool prog dump xlated` for any program it finds — and then **joins that exact
cgroup with a probe process and calls `open()`**.

The v2 query goes to the kernel rather than through `bpftool` because `bpftool`
is not dependable across version skew: on Ubuntu 22.04 / kernel 6.8 / bpftool
7.4.0 it answered `Error: can't query bpf programs attached to …: No such device
or address` for **every** cgroup including the root, which reads exactly like
"there is nothing here" while proving nothing. The direct query reports
`effective` (this cgroup's programs plus every ancestor's — the set that
actually gates `open()`) and `attached` separately; `effective=0` at the leaf is
a complete answer.

Four things make the output believable rather than merely plausible:

* the probe prints its own `/proc/self/cgroup` after joining, so you can see it
  measured the cgroup the hypervisor is really in;
* `/dev/kvm` is probed alongside. Kata's `sandboxDevices()` allows it
  unconditionally, so if it fails the run is reported **VOID**, not FAIL;
* every device is probed a second time from the caller's own cgroup, so a
  failure that is not Kata's is visible as such;
* `--self-test` synthesises a *real* cgroup v2 device filter with
  `systemd-run -p DevicePolicy=strict` and checks that the probe reports `EPERM`
  and the query reports `device-RESTRICTED` — so a run that reports "nothing is
  enforced" has already demonstrated it can tell the difference.

`--synthesise-nodes` makes the experiment runnable on a **GPU-less** box. The
device cgroup is enforced in an LSM hook keyed on `(type, major, minor)` before
the driver's `->open()`, so a `mknod`'d `c 195:255` with nothing behind it
answers the cgroup question exactly: `EPERM` means the cgroup denied it,
`ENXIO` means the cgroup allowed it and the kernel then found no driver. `ENXIO`
is a **PASS**.

**Result so far:** see [01 §1.4](../docs/design/01-vmm-confinement.md).
On cgroup v2 every NVIDIA node opens read-write from inside the Kata sandbox
cgroup, for both `sandbox_cgroup_only` values and both Kata runtimes, because
Kata's device policy is never installed there.

## `split-cdi-spec.sh`

Splits a host CDI spec (from `nvidia-ctk cdi generate`) along the design's
organising rule — *libraries traverse nothing, device nodes traverse
everything*.

```bash
./scripts/split-cdi-spec.sh --self-test
./scripts/split-cdi-spec.sh -i /etc/cdi/nvidia.yaml \
    -o /etc/cdi/nvidia-libs.yaml \
    --host-spec /etc/cdi/nvkvm-vmm.yaml --host-kind nvkvm.io/vmm
```

Emits **(a)** a mounts-only spec (new `kind`, since a kind must be unique in a
spec directory) safe to request on the workload container, and **(b)** the
`deviceNodes` it dropped — as a table on stderr always, and optionally as a
host-side CDI spec to request on the **pod sandbox** so those nodes reach Kata's
sandbox device cgroup. Hooks are dropped with a warning by default, because
Kata's shim drops them anyway (kata-containers#11169); `--keep-hooks` overrides.

Exercised against a real spec from `nvidia-ctk cdi generate` (toolkit 1.20.0,
driver 575.51.03, RTX 3060): 12 `deviceNodes` dropped and 9 hooks dropped —
including the `update-ldcache` hook design doc 02 calls out — with 50 library
mounts and the `env` block kept. The dropped list showed `/dev/nvidia-uvm` at
host major **236**, the dynamically-allocated major that will not match the
guest's; the script says so in its output.
