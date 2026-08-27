# scripts/

Two of these are now **real, self-testing experiments**; one is still a stub.
Every script that can be exercised without hardware has a `--self-test` that
rents nothing, needs no GPU and no Kata, and proves the machinery it depends on
before you trust a result from it.

| script | status | design doc |
|---|---|---|
| `check-vmm-device-access.sh` | **implemented** — the Q1 experiment | [01](../docs/design/01-vmm-confinement.md) |
| `split-cdi-spec.sh` | **implemented** — split a host CDI spec | [02](../docs/design/02-libraries-via-cdi.md) |
| `build-guest-kernel.sh` | stub | [04](../docs/design/04-guest-kernel.md) |

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
that cgroup's device policy — `devices.list` walking to the root on v1,
`bpftool cgroup show` + `bpftool prog dump xlated` walking to the root on v2 —
and then **joins that exact cgroup with a probe process and calls `open()`**.

Three things make the output believable rather than merely plausible:

* the probe prints its own `/proc/self/cgroup` after joining, so you can see it
  measured the cgroup the hypervisor is really in;
* `/dev/kvm` is probed alongside. Kata's `sandboxDevices()` allows it
  unconditionally, so if it fails the run is reported **VOID**, not FAIL;
* every device is probed a second time from the caller's own cgroup, so a
  failure that is not Kata's is visible as such.

`--synthesise-nodes` makes the experiment runnable on a **GPU-less** box. The
device cgroup is enforced in an LSM hook keyed on `(type, major, minor)` before
the driver's `->open()`, so a `mknod`'d `c 195:255` with nothing behind it
answers the cgroup question exactly: `EPERM` means the cgroup denied it,
`ENXIO` means the cgroup allowed it and the kernel then found no driver. `ENXIO`
is a **PASS**.

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
