# 01 — What confinement does Kata put the VMM in, by default?

**This was the gating question for the whole project, and the largest remaining
unknown. It has been measured — 2026-08-27, on two hosts, one of them with a
real NVIDIA GPU.** If the Kata hypervisor process cannot `open()` the host's
`/dev/nvidiactl` and `/dev/nvidia*`, nvkvm cannot forward a single ioctl and
nothing else in this design matters. It can.

**It has now been measured** (§1.4, §1.6). The short answer:

> **On a cgroup v2 host, the Kata-launched QEMU CAN open `/dev/nvidiactl`,
> `/dev/nvidia0`, `/dev/nvidia-uvm` and `/dev/dri/renderD128` — read-write, with
> no configuration, for both values of `sandbox_cgroup_only`.** Verified on a
> real NVIDIA GPU with a real driver. Not because Kata allows them: because on
> cgroup v2 **Kata installs no device policy at all.** It computes the allowlist
> the code below describes and then loses it at the
> `containerd/cgroups` `v2.ToResources()` boundary, which never populates
> `Resources.Devices`. `/dev/mem` opens from the sandbox cgroup too, which is
> how you can tell nothing is being enforced.
>
> The design's reading of *what Kata intends* is correct — a targeted allowlist
> of OCI-spec devices plus a hardcoded set (`/dev/kvm`, `/dev/vfio/vfio`,
> `/dev/vhost-net`, `/dev/vhost-vsock`, the safe chardevs), with the NVIDIA
> nodes absent. A cgroup carrying exactly that policy denies `/dev/nvidiactl`
> with `EPERM`; that counterfactual was run (§1.4.5). Only the installation is
> missing, and **only on cgroup v2** — the v1 path writes the rules.
>
> So: **this is currently the easy case, and it should not be treated as one.**
> Kata plainly intends to restrict, so expect the gap to be closed. Build route
> (a) — the host CDI spec — anyway; it is the only route that is correct on both
> cgroup versions, and the one that survives the fix.

---

## 1. The device cgroup — the part that actually decides

### 1.1 Kata takes the devices cgroup away from the container engine

`docs/design/host-cgroups.md` states that Kata inherits the parent cgroup the
container engine created, **with two named exceptions**:

> "The exception is for the `cpuset` and `devices` cgroup subsystems, which are
> managed by the Kata shim."

— <https://github.com/kata-containers/kata-containers/blob/main/docs/design/host-cgroups.md>

So the device policy on the cgroup the VMM lands in is Kata's own construction,
not containerd's and not the kubelet's. That is where to look.

### 1.2 What Kata puts in it

`Sandbox.createResourceController()` — `src/runtime/virtcontainers/sandbox.go:852`
— seeds the device list straight from the OCI spec it was handed
(`sandbox.go:874-881`):

```go
spec := s.GetPatchedOCISpec()
...
	// Kata relies on the resource controller (cgroups on Linux) parent created and configured by the
	// container engine by default. The exception is for devices whitelist as well as sandbox-level CPUSet.
...
		if spec.Linux.Resources != nil {
			resources.Devices = spec.Linux.Resources.Devices
```

It then **appends**, only where missing (`sandbox.go:886-962`):

- `/dev/null` (1:3) and `/dev/urandom` (1:9) unconditionally
- `/dev/ptmx` (5:2) when `Debug && SandboxCgroupOnly`
- `/dev/loop-control` (10:237) and the `/dev/loop*` block major when `SandboxCgroupOnly`
- every device tracked by the sandbox's device manager (`sandbox.go:976-985`):
  `for _, d := range s.devManager.GetAllDevices() { ... resources.Devices = append(...) }`
  — this is how VFIO group nodes get in

and, unless the hypervisor is the remote one, `sandboxDevices()` —
`src/runtime/pkg/resourcecontrol/cgroups.go:54` — adds the hypervisor's own
needs (`cgroups.go:56-120`):

- `defaultDevices`: `/dev/null`, `/dev/random`, `/dev/full`, `/dev/tty`,
  `/dev/zero`, `/dev/urandom`, `/dev/console`
- `hypervisorDevices`: **`/dev/kvm`** (or `/dev/mshv`) — and the function
  **errors out** if neither could be added:
  `return ..., errors.New("failed to add any hypervisor device to devices cgroup")`
  (`cgroups.go:92-95`). A Kata sandbox cannot be constructed without host KVM
  device access, which is the precedent this design leans on.
- `virtualDevices`: `/dev/vhost-net`, `/dev/vfio/vfio`, `/dev/vhost-vsock`
- `/dev/pts/*` (major 136) and tun/tap (10:200) with `rwm`, plus two true
  wildcards (`Major: -1, Minor: -1`, one char one block) carrying the comment
  `// allow mknod for any device` and **`Access: "m"` — mknod only, not read or
  write** (`cgroups.go:113-129`).

The comment above `hypervisorDevices` states the model plainly
(`cgroups.go:69-72`):

> "Processes running in a device-cgroup are constrained, they have acccess only
> to the devices listed in the devices.list file. In order to run Virtual
> Machines and create virtqueues, hypervisors need access to certain character
> devices in the host, like kvm and vhost-net."

**There is no blanket `{Type: "a", Allow: true}` rule.** The two wildcard
entries that do exist are `m`-only, which permits `mknod` and not `open()` for
read or write — precisely the permission nvkvm needs and does not get.

`/dev/nvidiactl` and `/dev/nvidia*` appear nowhere in that list. Neither does
`/dev/nvidia-uvm`, which nvkvm's QEMU opens directly (it is the one device the
VMM rather than the isolate holds open — see
`nvkvm-pv/docs/internal/isolate-model.md`, "Who opens what").

**Everything in this section is a reading of what Kata computes, and it is
accurate — a cgroup carrying exactly this list denies every NVIDIA node with
`EPERM` while permitting `/dev/kvm`, which was run as a control (§1.4.5).
On cgroup v2, however, the list computed here is never installed on any cgroup
(§1.6), so nothing in it is in force.** Read §1.2 as "what Kata means", and
§1.4/§1.6 as "what a running system does".

### 1.3 A correction worth making explicitly

A tempting shortcut is: "QEMU runs as root, and root bypasses cgroups." **That
is wrong and the design must not rest on it.** The cgroup v1 devices controller
enforces through an LSM hook on every `open()`/`mknod()` regardless of the
calling task's uid; being root does not exempt a task from the device policy of
the cgroup it is in. (Root *can* escape by moving itself into a different
cgroup if it can write cgroupfs, but that is an escape, not an exemption, and it
is not something a design should depend on.) Likewise on cgroup v2, the
`BPF_PROG_TYPE_CGROUP_DEVICE` program attached to the cgroup runs for every
task in it. See [02](02-libraries-via-cdi.md) and
[03](03-guest-side-devices.md) for the two-mechanism split.

On cgroup v2 there is a second, sharper reason the design cannot rely on
after-the-fact fixes: **an additional `BPF_CGROUP_DEVICE` program can only
narrow access, never widen it.** `kernel/bpf/cgroup.c`'s
`bpf_prog_run_array_cg()` starts `retval` at success and only ever *sets*
`-EPERM` when a program in the array denies; nothing resets it back to allow.
So every attached program must independently return 1. Granting a new device on
v2 means recompiling and replacing the whole attached program — which is what
`opencontainers/cgroups` `devices/ebpf_linux.go:loadAttachCgroupDeviceFilter`
does (detach-all-then-attach, or `BPF_F_REPLACE` when available), and what
libnvidia-container's legacy hook has to do by disassembling the existing
program (`src/nvcgo/internal/cgroup/v2.go`, `PrependDeviceFilter`). This is why
every recommendation in this repo puts the allow rule **into the OCI spec
before the runtime configures the cgroup**, never into a hook afterwards.

**MEASURED — root does not bypass a device cgroup.** The experiment suggested
here was run (§1.4.5's counterfactual, and again in the harness self-test): a
**root** process moved into a cgroup carrying a `BPF_CGROUP_DEVICE` filter gets
`EPERM` on `open()` of any node the filter does not allow — `/dev/nvidiactl`,
`/dev/nvidia0`, `/dev/nvidia-uvm`, `/dev/dri/renderD128` and `/dev/mem` all
returned `EPERM` while `/dev/kvm` and `/dev/null` opened, in the same process,
in the same call. Being root is not an exemption. This is the one assumption in
this document that everything else rests on, and it holds.

### 1.4 Which cgroup, and what `sandbox_cgroup_only` changes — **MEASURED**

> **This section was a prediction. It is now a measurement, and the prediction
> was wrong in an interesting way.** What follows is what was run, on what, and
> what came back. The reasoning that produced the (incorrect) prediction is kept
> at the end of the section, because the code it cites is still accurate — it is
> the conclusion drawn from it that did not survive contact with a running
> system.

#### 1.4.1 The measured answer

**On a cgroup v2 (unified) host, the Kata-launched QEMU can open the host's
NVIDIA device nodes, and `sandbox_cgroup_only` makes no difference — because
Kata's Go runtime never installs a device policy on cgroup v2 at all.**

| `sandbox_cgroup_only` | cgroup QEMU lands in | device filter on it | `open("/dev/nvidiactl")` |
|---|---|---|---|
| `false` (default) | `/default/kata_<sandbox-id>` — the **sandbox** cgroup | **none attached, at any level to the root** | **not denied** |
| `true` (NVIDIA profile) | `/default/kata_<sandbox-id>` — the **sandbox** cgroup | **none attached, at any level to the root** | **not denied** |

Both values: **PASS**. Neither the predicted inversion nor the predicted
denial occurred.

Measured twice, on two independent hosts, with two containerd major versions,
and — on the second — against a real GPU with a real driver and the real device
nodes, plus once more against the **Rust** runtime:

| host | GPU | containerd | Kata runtime | nodes | result |
|---|---|---|---|---|---|
| A — test host, kernel 7.0.0-29 | none | 2.2.3 | Go 4.1.0 | synthesised `c 195:255`, `c 195:0` | PASS / PASS |
| B — rented RTX 3060, Ubuntu 22.04, kernel 6.8.0-59 | RTX 3060, driver 575.51.03 | 1.7.27 | Go 4.1.0 | **real** | PASS / PASS |
| A — same host | none | 2.2.3 | **runtime-rs 4.1.0** | synthesised | PASS / PASS |

#### 1.4.2 What was run

`scripts/check-vmm-device-access.sh --synthesise-nodes --device /dev/mem`,
which starts a Kata sandbox with `ctr`, finds the hypervisor process, dumps its
cgroup and that cgroup's device policy, then **joins that exact cgroup with a
probe process and calls `open()`**.

| | host A (no GPU) | host B (rented, GPU) |
|---|---|---|
| date | 2026-08-27 | 2026-08-27 |
| kernel | `7.0.0-29-generic`, x86_64 | `6.8.0-59-generic`, x86_64, Ubuntu 22.04.5 |
| cgroup mode | **v2 unified** (`stat -fc %T /sys/fs/cgroup` = `cgroup2fs`) | **v2 unified** |
| containerd | `v2.2.3`, cgroupfs driver, `ctr run --runtime io.containerd.kata.v2` | `1.7.27`, same |
| Kata | `kata-go-static-4.1.0-amd64` — the **Go** runtime, `kata-runtime 4.1.0`, commit `ddcb1ad8`; and separately `kata-static-4.1.0-amd64`, the **runtime-rs** build | `kata-go-static-4.1.0-amd64` |
| hypervisor | `/opt/kata/bin/qemu-system-x86_64`, `-machine q35,accel=kvm` | same |
| config | `/etc/kata-containers/configuration.toml`, from the shipped `configuration-qemu.toml` | same |
| SELinux | not installed; `/proc/<qemu-pid>/attr/current` = `unconfined` | same |
| GPU | none | **NVIDIA GeForce RTX 3060**, `/proc/driver/nvidia/version` = `575.51.03` |
| NVIDIA nodes | **synthesised**: `mknod /dev/nvidiactl c 195 255`, `mknod /dev/nvidia0 c 195 0`, no driver bound — see 1.4.6 | **real**: `/dev/nvidiactl` `c 195:255`, `/dev/nvidia0` `c 195:0`, `/dev/nvidia-uvm` `c 236:0`, `/dev/nvidia-uvm-tools` `c 236:1`, `/dev/dri/renderD128` `c 226:128` |

Host B was a vast.ai KVM instance (`systemd-detect-virt` = `kvm`, `/dev/kvm`
present, GPU VFIO-passed-through), so the Kata VM ran as a nested guest. It was
destroyed after the run.

Two shipped defaults were confirmed on disk while doing this, both as the design
claimed: `configuration-qemu.toml` ships `sandbox_cgroup_only = false` (line
658) and `configuration-qemu-nvidia-gpu.toml` ships `sandbox_cgroup_only = true`
(line 689).

#### 1.4.3 The exact cgroup path

`sandbox_cgroup_only=false` (the default), sandbox `nvkvm-kata-q1-sco-false-1102923`:

```
$ cat /proc/1103077/cgroup                    # the QEMU main thread
0::/default/kata_nvkvm-kata-q1-sco-false-1102923

$ cat /run/vc/sbs/<id>/persist.json | jq …
SandboxCgroupPath  = /default/kata_<id>
OverheadCgroupPath = /kata_overhead/<id>
```

The overhead cgroup **is** created — `/sys/fs/cgroup/kata_overhead/<id>` exists —
but **QEMU is not in it.** In a separate run its membership was enumerated
directly:

```
/sys/fs/cgroup/kata_overhead/<id>/cgroup.procs   -> 1099887 1099897 1099902
                                                    (shim + two virtiofsd)
/sys/fs/cgroup/default/kata_<id>/cgroup.procs    -> 1099900   (QEMU)
$ cat /proc/1099887/cgroup                        # the shim
0::/kata_overhead/<id>
```

and every one of QEMU's threads — main, `CPU 0/KVM`, `vhost-*`,
`IO mon_iothread`, `call_rcu` — reported the **same** sandbox cgroup, not a mix.

With `sandbox_cgroup_only=true` the path is the same
(`/default/kata_<sandbox-id>`), which is expected: with no overhead controller
everything is in the sandbox cgroup by construction.

**Why the whole QEMU process moves, and not just its vCPU threads:**
`constrainHypervisor()` moves only `tids.vcpus` with `sandboxController.AddThread(i)`
(`sandbox.go:2816-2827`) — but on cgroup v2 `AddThread` is not thread-granular:

```go
func (c *LinuxCgroup) AddThread(pid int, subsystems ...string) error {
	switch cg := c.cgroup.(type) {
	case cgroups.Cgroup:
		return cg.AddTask(cgroups.Process{Pid: pid})   // v1: cgroup "tasks", per-thread
	case *cgroupsv2.Manager:
		return cg.AddProc(uint64(pid))                 // v2: cgroup.procs, WHOLE PROCESS
	}
}
```
— `src/runtime/pkg/resourcecontrol/cgroups.go:340-348`

Writing a thread id to `cgroup.procs` migrates the entire thread group. So on
cgroup v2 the "move only the vCPU threads" design collapses into "move all of
QEMU", and the QEMU main thread ends up in the **sandbox** cgroup for **both**
values of `sandbox_cgroup_only`. **The predicted overhead-cgroup inversion does
not exist on cgroup v2.** (On v1 it plausibly does — `AddTask` there really is
per-thread — but that is UNVERIFIED, see 1.4.7.)

#### 1.4.4 The exact device policy dump

```
--- cgroup v2 BPF_CGROUP_DEVICE programs, walking up to the root ---
[/default/kata_nvkvm-kata-q1-sco-false-1102923]  no BPF_CGROUP_DEVICE program attached
[/default]                                       no BPF_CGROUP_DEVICE program attached
[/]                                              no BPF_CGROUP_DEVICE program attached
```

identically for `sandbox_cgroup_only=true`. **There is no device policy. Not a
permissive one — none at all.**

On host B `bpftool` refused to answer at all (`Error: can't query bpf programs
attached to …: No such device or address`, on every cgroup including the root —
a bpftool 7.4.0 / kernel 6.8 skew). So the script no longer depends on it: it
asks the kernel the same question `bpftool` would, via `BPF_PROG_QUERY` with
`attach_type=BPF_CGROUP_DEVICE` and `BPF_F_QUERY_EFFECTIVE`, which counts this
cgroup's programs **plus every ancestor's** — precisely the set that gates
`open()` for a task in it. On host B, with a real GPU:

```
BPF_PROG_QUERY(BPF_CGROUP_DEVICE), asked of the kernel directly:
  /sys/fs/cgroup/default/kata_nvkvm-kata-q1-sco-false-2627 effective=0 attached=0 ids=- -> device-UNRESTRICTED
  /sys/fs/cgroup/default                                   effective=0 attached=0 ids=- -> device-UNRESTRICTED
  /sys/fs/cgroup/                                          effective=0 attached=0 ids=- -> device-UNRESTRICTED
```

and identically for `sandbox_cgroup_only=true`. `effective=0` at the leaf is a
complete answer: there is no program anywhere on the path, so nothing can deny
anything.

This is not a `bpftool` failure. On the same host, at the same moment, `bpftool`
happily enumerates the `cgroup_device` programs systemd attaches to its own
units:

```
$ bpftool cgroup tree
/sys/fs/cgroup/system.slice/systemd-journald.service
    1241     cgroup_device   multi           sd_devices
/sys/fs/cgroup/system.slice/polkit.service
    1225     cgroup_device   multi           sd_devices
…
```

And it is not because Kata had nothing to install. The OCI spec containerd
handed the shim carries the full deny-all-plus-allowlist that
`createResourceController()` reads from `spec.Linux.Resources.Devices`:

```
$ ctr container info <id> | jq .Spec.linux.resources.devices
{"allow": false, "access": "rwm"}                                  <- deny-all
{"allow": true, "type": "c", "major": 1, "minor": 3, "access": "rwm"}
{"allow": true, "type": "c", "major": 1, "minor": 8, "access": "rwm"}
… /dev/tty, /dev/zero, /dev/full, /dev/urandom, /dev/console, 136:*, /dev/ptmx
$ ctr container info <id> | jq .Spec.linux.cgroupsPath
"/default/katathr"
```

That also settles the second UNVERIFIED item in §4(a): **the OCI spec that feeds
`createResourceController()` is the one containerd builds for the container it
is handed**, `linux.cgroupsPath` and all, and its `linux.resources.devices` is a
deny-all followed by the curated safe set. Kata reads it, appends
`sandboxDevices()` to it — and then loses the result (§1.6).

#### 1.4.5 The `open()` results

From inside `/default/kata_<sandbox-id>` — the probe prints its own
`/proc/self/cgroup` first, so there is no doubt which cgroup it measured:

```
probe: pid=1103211 cgroup=0::/default/kata_nvkvm-kata-q1-sco-false-1102923
  /dev/kvm                   OPEN-OK     [c 10:232  ] O_RDWR
  /dev/nvidiactl             OPEN-FAIL   [c 195:255 ] errno=ENXIO ALLOWED-BY-CGROUP, no driver bound
  /dev/nvidia0               OPEN-FAIL   [c 195:0   ] errno=ENXIO ALLOWED-BY-CGROUP, no driver bound
  /dev/mem                   OPEN-OK     [c 1:1     ] O_RDWR
```

```
probe: pid=1103435 cgroup=0::/default/kata_nvkvm-kata-q1-sco-true-1102923
  /dev/kvm                   OPEN-OK     [c 10:232  ] O_RDWR
  /dev/nvidiactl             OPEN-FAIL   [c 195:255 ] errno=ENXIO ALLOWED-BY-CGROUP, no driver bound
  /dev/nvidia0               OPEN-FAIL   [c 195:0   ] errno=ENXIO ALLOWED-BY-CGROUP, no driver bound
  /dev/mem                   OPEN-OK     [c 1:1     ] O_RDWR
```

**`/dev/mem` is the load-bearing line.** Character device `1:1` is not in the
OCI spec's allowlist, not in `defaultDevices`, not in `hypervisorDevices`, not
in `virtualDevices`, and the two wildcard entries are `m`-only. If Kata's device
cgroup were doing anything at all, `open("/dev/mem", O_RDWR)` from inside the
sandbox cgroup would return `EPERM`. It returns a file descriptor. In the same
run `/dev/vhost-net` and `/dev/loop-control` also opened, which is consistent
but proves less, since those *are* on the list.

`/dev/kvm` opening is the positive control: Kata's `sandboxDevices()` always
allows it, and had it failed the harness would have reported the run **VOID**
rather than PASS, on the grounds that the probe cannot have been measuring the
right cgroup.

**On host B, with the real driver loaded and the real nodes present**, the same
probe inside the same kind of cgroup:

```
probe: pid=2177 cgroup=0::/default/kata_nvkvm-kata-q1-sco-false-1996
  /dev/kvm                   OPEN-OK     [c 10:232  ] O_RDWR
  /dev/nvidiactl             OPEN-OK     [c 195:255 ] O_RDWR
  /dev/nvidia0               OPEN-OK     [c 195:0   ] O_RDWR
  /dev/nvidia-uvm            OPEN-OK     [c 236:0   ] O_RDWR
  /dev/nvidia-uvm-tools      OPEN-OK     [c 236:1   ] O_RDWR
  /dev/nvidia-modeset        ABSENT      (stat: ENOENT)
  /dev/dri/renderD128        OPEN-OK     [c 226:128 ] O_RDWR
  /dev/mem                   OPEN-OK     [c 1:1     ] O_RDWR
```

— and byte-identically for `sandbox_cgroup_only=true`. **Every node nvkvm needs
opens read-write from inside the Kata sandbox cgroup.** (`/dev/nvidia-modeset`
is absent because nothing had loaded `nvidia-modeset` on that box, not because
it was denied.)

##### The counterfactual: what Kata's intended policy *would* do

Run on host B, against the same real device nodes: a cgroup carrying exactly the
policy Kata computes and does not install — `DevicePolicy=strict` plus
`DeviceAllow` for `sandboxDevices()`' list and the OCI safe set.

```
  …run-rec701e…scope  effective=1 attached=1 ids=[79] -> device-RESTRICTED by 1 effective program(s)
probe: pid=4316 cgroup=0::/system.slice/run-rec701e…scope
  /dev/kvm                   OPEN-OK     [c 10:232  ] O_RDWR
  /dev/null                  OPEN-OK     [c 1:3     ] O_RDWR
  /dev/nvidiactl             OPEN-FAIL   [c 195:255 ] errno=EPERM DENIED-BY-CGROUP
  /dev/nvidia0               OPEN-FAIL   [c 195:0   ] errno=EPERM DENIED-BY-CGROUP
  /dev/nvidia-uvm            OPEN-FAIL   [c 236:0   ] errno=EPERM DENIED-BY-CGROUP
  /dev/dri/renderD128        OPEN-FAIL   [c 226:128 ] errno=EPERM DENIED-BY-CGROUP
  /dev/mem                   OPEN-FAIL   [c 1:1     ] errno=EPERM DENIED-BY-CGROUP
```

This is the load-bearing control for the whole document, and it establishes
three things at once:

1. **§1.2's reading of Kata's allowlist is correct.** That policy really does
   deny every NVIDIA node while permitting `/dev/kvm`. The design was right
   about what Kata means to do.
2. **These specific device nodes on this specific host are deniable.** The PASS
   above is not some property of `/dev/nvidia*` being exempt from device
   cgroups; the identical nodes return `EPERM` two commands later.
3. **The only difference between PASS and FAIL is whether the policy got
   installed.** Which is §1.6.

#### 1.4.6 Why synthetic device nodes answer the real question

The host used for this measurement has no NVIDIA GPU, so `/dev/nvidiactl` and
`/dev/nvidia0` were created with `mknod` at the majors nvkvm deliberately
registers at (195; `nvkvm-pv/docs/reference/device-nodes.md`), with no driver
behind them.

This is not a weaker experiment for the question being asked, because the device
cgroup is keyed on `(type, major, minor)` and is enforced in an LSM hook on
`open()` **before** the driver's `->open()` ever runs. So:

- `EPERM` ⇒ the cgroup denied the node. This is the Q1 failure mode, and it is
  what the design predicted.
- `ENXIO` ⇒ the cgroup **allowed** it and the kernel then found no driver bound
  at `195:x`. The cgroup gate was passed.

`ENXIO` is therefore a PASS on the cgroup question, and the identical `ENXIO`
from the caller's unrestricted cgroup (printed as a control in every run)
confirms `ENXIO` is what "allowed, but no driver" looks like on this host.

What synthetic nodes cannot tell you is anything downstream of the cgroup — that
a real `/dev/nvidiactl` `open()` succeeds, that `ioctl` forwarding works, or
that a real driver is happy. Those are Phase 1/2 questions, not Q1.

#### 1.4.7 What is still UNVERIFIED

- **cgroup v1.** Not measured — the host boots unified, and `cgroups.Mode()`
  keys off `/sys/fs/cgroup`'s filesystem type, so the v1 path cannot be reached
  without a reboot. **From source, the v1 answer is expected to be the
  opposite** (§1.6): `cgroups.New(cgroups.V1, …)` passes `*specs.LinuxResources`
  straight through, and `devicesController.Create` writes every entry to
  `devices.allow`/`devices.deny`, deny-all included. So on a legacy or hybrid
  host the sandbox cgroup should be a real allowlist and `/dev/nvidiactl` should
  be **denied**. Treat "v2 is unrestricted" as measured and "v1 restricts" as
  read-from-source-only.
- ~~**runtime-rs.**~~ **Also MEASURED, same answer.** `kata-static-4.1.0-amd64`
  (the Rust shim, `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2`) was
  installed on host A and run through the same experiment. Both
  `sandbox_cgroup_only` values: `effective=0 attached=0` on the QEMU cgroup and
  every ancestor, `/dev/mem` opens, synthetic `/dev/nvidiactl` returns `ENXIO`.
  **PASS / PASS.** One structural difference worth recording: runtime-rs does
  **not** create a `kata_<id>` sandbox cgroup at all — QEMU sits directly in the
  containerd-provided path (`/default/<container-id>`) for both values of
  `sandbox_cgroup_only`, where the Go runtime uses `/default/kata_<id>`. Its
  shipped `configuration-qemu-runtime-rs.toml` also defaults
  `sandbox_cgroup_only = true`, unlike the Go `configuration-qemu.toml`.
  The Rust code path was not read; only its behaviour was measured.
- **Kubernetes.** Measured under `ctr`, so the cgroup parent is `/default/…`
  rather than `/kubepods/…`. The mechanism is parent-independent — no device
  program is attached anywhere on the path to the root — but a kubelet-managed
  parent that itself carried a `BPF_CGROUP_DEVICE` program would change the
  answer, and that was not tested.
- **A real driver.** See 1.4.6.

#### 1.4.8 The prediction this replaces, and why it was wrong

The original reasoning ran: `sandbox_cgroup_only=false` makes the shim move
itself to `/kata_overhead/<id>`, which is created with an **empty** resource set
(`sandbox.go:1012`, `&specs.LinuxResources{}`) at a path outside `kubepods`;
therefore QEMU, forked from the shim, inherits a device-unrestricted cgroup,
while `sandbox_cgroup_only=true` puts it in the restricted sandbox cgroup and
breaks nvkvm. An uncomfortable inversion: the safer-looking setting blocks us.

Every code citation in that paragraph is correct. The conclusion is wrong for
two independent reasons, and either one alone would have been enough:

1. QEMU does **not** stay in the cgroup it was forked into. `constrainHypervisor`
   moves it, and on cgroup v2 that move is process-granular (§1.4.3), so QEMU
   ends up in the *sandbox* cgroup either way.
2. The sandbox cgroup is not restricted on cgroup v2 in the first place (§1.6),
   so there is nothing for the inversion to invert.

The lesson worth keeping: the argument reasoned carefully about which cgroup a
process is *placed in* and never checked whether the policy it worried about was
ever *installed*. Both halves needed measuring; only one was identified as
needing it.

### 1.5 What the surrounding platform contributes

Below Kata, the kubelet and containerd set the baseline:

- The kubelet's pod-cgroup manager has **no device field at all** — its
  `ResourceConfig` covers cpu/memory/pids/hugetlb/unified only. It never writes
  a device policy at the pod cgroup level, privileged or not.
  (<https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/cm/types.go>)
- containerd sets device policy at the **container** level when building the OCI
  spec: `populateDefaultUnixSpec` installs a deny-all base
  (`[]specs.LinuxDeviceCgroup{{Allow: false, Access: "rwm"}}`), `WithDefaultUnixDevices`
  adds the curated safe set, and only the **privileged** path adds
  `oci.WithAllDevicesAllowed`. Non-privileged containers get a restricted
  allowlist plus explicitly-requested devices.
  (<https://github.com/containerd/containerd/blob/main/pkg/oci/spec.go>,
   `spec_opts.go`, `internal/cri/server/container_create.go`)

So the default posture from the platform is deny-all-plus-allowlist, and Kata
copies that spec's device list into the sandbox cgroup. Nothing along that path
adds the NVIDIA nodes on its own.

---

### 1.6 The root cause: on cgroup v2 the device list is computed and then thrown away — **MEASURED**

§1.4 measured that nothing is enforced. This is why, and it is a two-line
answer sitting in a dependency.

`NewResourceController()` is the single place Kata turns its computed
`specs.LinuxResources` into a live cgroup
(`src/runtime/pkg/resourcecontrol/cgroups.go:154-186`):

```go
if cgroups.Mode() == cgroups.Legacy || cgroups.Mode() == cgroups.Hybrid {
	cgroup, err = cgroups.New(cgroups.V1, cgroups.StaticPath(cgroupPath), resources)
} else if cgroups.Mode() == cgroups.Unified {
	cgroup, err = cgroupsv2.NewManager(unifiedMountpoint, cgroupPath, cgroupsv2.ToResources(resources))
}
```

Note the asymmetry. The **v1** branch hands `*specs.LinuxResources` through
whole. The **v2** branch converts it first, with
`containerd/cgroups` v1.1.0's `v2.ToResources()` — and that function translates
CPU, memory, hugetlb, pids, blkio and RDMA, and **never assigns
`Resources.Devices`**. The word `Devices` does not appear anywhere in
`v2/utils.go`:

```
$ grep -n Devices v2/utils.go        # containerd/cgroups v1.1.0
(none)
```

The receiving struct has the field, and `NewManager` does act on it — gated
exactly the way that makes the omission silent
(`containerd/cgroups` v1.1.0 `v2/manager.go`):

```go
type Resources struct {
	CPU     *CPU
	Memory  *Memory
	Pids    *Pids
	IO      *IO
	RDMA    *RDMA
	HugeTlb *HugeTlb
	// When len(Devices) is zero, devices are not controlled
	Devices []specs.LinuxDeviceCgroup
}
…
	if err := setDevices(path, resources.Devices); err != nil {   // manager.go:220
```

`len(Devices)` is always zero on this path, so `setDevices` attaches nothing and
returns nil. No error is logged, nothing fails, and the sandbox cgroup is
created device-unrestricted. That is exactly what `bpftool` reports (§1.4.4).

The v1 branch, by contrast, does enforce. `containerd/cgroups` v1.1.0
`devices.go`:

```go
func (d *devicesController) Create(path string, resources *specs.LinuxResources) error {
	os.MkdirAll(d.Path(path), defaultDirPerm)
	for _, device := range resources.Devices {
		file := denyDeviceFile
		if device.Allow { file = allowDeviceFile }
		if device.Type == "" { device.Type = "a" }
		retryingWriteFile(filepath.Join(d.Path(path), file), []byte(deviceString(device)), …)
	}
}
```

— every entry written, and the OCI spec's leading `{"allow": false, "access":
"rwm"}` (§1.4.4) becomes `a *:* rwm` into `devices.deny`, i.e. a real deny-all
followed by the allowlist.

#### What this means for the design

**The gate the whole project was organised around is, on cgroup v2 with the Go
runtime, not closed.** Three consequences, in order of how much they change the
plan:

1. **Route (a) — the host CDI spec — is not required to make nvkvm work on a v2
   host.** It is still the right thing to ship, for the reasons in §4(a) and
   because it is the only route that is correct on *both* cgroup versions. But
   it is no longer load-bearing for a v2 prototype: the nodes are already
   reachable.
2. **Route (c) — patching `sandboxDevices()` — would not help on v2 at all.**
   Adding the NVIDIA nodes to that list appends entries to a `[]LinuxDeviceCgroup`
   that `ToResources()` discards. Anyone reaching for that patch on a v2 host
   would see no change and would have a very confusing afternoon. If the list
   is to be patched, the `ToResources()` gap has to be fixed first or at the
   same time.
3. **Do not build on this.** A Kata sandbox on cgroup v2 not restricting devices
   is, from Kata's point of view, a bug — the code plainly intends an allowlist,
   and `/dev/mem` opening from a sandbox cgroup is not a defensible posture for
   a project whose pitch is isolation. It is reasonable to expect it to be
   fixed. A design that quietly depends on it working today is a design that
   breaks on a patch release. So: **treat the v2 result as "the gate is
   currently open, and will close", implement route (a) anyway, and use the open
   gate only to unblock Phase 1 and 2 work while route (a) is built.**

This is also worth reporting upstream on its own merits, independently of nvkvm.
It is a silent security-relevant divergence between cgroup v1 and cgroup v2
hosts, and the code reads as if it were version-agnostic.

**UNVERIFIED:** whether `src/runtime-rs` (the Rust shim, shipped as
`kata-static-*.tar.zst`) has the same gap. It has its own cgroup layer and was
not measured.

## 2. Namespaces — secondary, and mostly absent

Stated briefly because they turn out not to be the gate.

| namespace | what the VMM gets | evidence |
|---|---|---|
| **network** | **joins the pod/CNI netns** | `doNetNS()` in `src/runtime/virtcontainers/network_linux.go` does `runtime.LockOSThread()` then `targetNS.Set()` (a `setns(2)`); `Sandbox.startVM` wraps `hypervisor.StartVM` in `s.network.Run(...)`, so the fork/exec inherits the netns. Design doc: "It is given a separate network namespace from the host." (`docs/design/architecture/README.md`) |
| **mount** | **host mount namespace** | No `unshare`, `CLONE_NEWNS`, `pivot_root` or `chroot` in `qemu.go` or govmm's `LaunchCustomQemu`; `SysProcAttr` carries only `Credential`. There is no jailer. `/run/vc/vm/<sandbox-id>` is an ordinary host directory for sockets and the pidfile, not a root. |
| **PID** | **host PID namespace** (inferred) | The shim runs under containerd's standard `shimapi.Run` with `NoReaper/NoSubreaper`; no `CLONE_NEWPID` anywhere in the launch path. **UNVERIFIED as an explicit statement** — settle by comparing `readlink /proc/<shim>/ns/pid` and `/proc/1/ns/pid`. |
| **user** | **none** | `rootless = false` by default (`src/runtime/config/configuration-qemu.toml.in`: "By default QEMU VMM run as root"). Even when enabled it is a **setuid/setgid to a random uid** via `SysProcAttr.Credential`, **not** `CLONE_NEWUSER`; and it only covers QEMU — "Other processes such as Kata Container shimv2 and virtiofsd still run as the root user" (`docs/how-to/how-to-run-rootless-vmm.md`). |

### MEASURED (2026-08-27, containerd 2.2.3 + Kata 4.1.0 Go runtime, `ctr`)

`readlink /proc/<pid>/ns/*` for the QEMU process, its parent shim, and PID 1:

```
        qemu                     shim                     pid1
mnt     mnt:[4026532806]         mnt:[4026532806]         mnt:[4026531832]
pid     pid:[4026531836]         pid:[4026531836]         pid:[4026531836]
net     net:[4026532807]         net:[4026531833]         net:[4026531833]
user    user:[4026531837]        user:[4026531837]        user:[4026531837]
ipc     ipc:[4026531839]         ipc:[4026531839]         ipc:[4026531839]
uts     uts:[4026531838]         uts:[4026531838]         uts:[4026531838]
cgroup  cgroup:[4026531835]      cgroup:[4026531835]      cgroup:[4026531835]
```

Three things to take from that:

- **PID, user, IPC, UTS and cgroup namespaces are the host's.** The table's
  UNVERIFIED note on the PID namespace is now settled: QEMU and PID 1 share it.
- **The network namespace is QEMU's own and is *not* the shim's**, exactly as
  `doNetNS()` implies — the shim stays in the host netns and only the fork/exec
  of the VMM is wrapped.
- **The mount namespace needs a correction.** The table says "host mount
  namespace", reasoning from the absence of any `unshare`/`CLONE_NEWNS` in
  Kata's launch path. That reasoning is right about *Kata* and wrong about the
  outcome: QEMU is in the **containerd shim's** mount namespace, which is not
  PID 1's (`containerd` itself was measured in `mnt:[4026531832]`, PID 1's). So
  the VMM does get a mount namespace — it just is not Kata that creates it, and
  Kata does not `pivot_root` or otherwise populate it, so it is a copy of the
  host tree rather than a jail. Nothing in this design depends on it, but
  "the VMM is in the host mount namespace" is not what a reader would find.

The VMM does **not** join "the container's namespaces" — there are none on the
host to join. `docs/design/architecture/README.md`: "Linux cgroups and
namespaces are created inside the VM by the guest kernel to isolate the workload
from the VM environment." The workload process is created by kata-agent inside
the guest and is never a host process.

### Why the namespace answer still matters to nvkvm

nvkvm spawns one **isolate** per guest process and sandboxes it on a degradation
ladder (`nvkvm-pv/docs/internal/isolate-model.md`). The strongest rung,
`namespace`, needs `CLONE_NEWUSER` to be permitted. Under Kata that is a live
question in a way it is not under Docker:

- QEMU is root and has no seccomp or AppArmor applied by Kata (see §3), so the
  usual Docker blocker (the default seccomp profile plus `docker-default`
  AppArmor) is **absent**. `namespace` mode should therefore be *available*,
  which is better than the container case nvkvm documents.
- But nvkvm's own doc is emphatic that the sysctls lie and the only correct test
  is to attempt the `clone()`. `NVKVM_ISOLATE_MODE=auto` does exactly that and
  logs the rung it landed on at warning level, and exposes it as the QOM
  property `isolate-mode-active`. **Recommendation: leave the mode on `auto`,
  and assert on `isolate-mode-active` in deployment checks** rather than
  assuming the rung.

---

## 3. Other confinement Kata applies to the VMM: almost none — and that is a per-driver choice, not an oversight

- **seccomp on the host QEMU: none.** The `seccompsandbox` knob (QEMU's own
  `-sandbox`) defaults to empty/off (`DEFSECCOMPSANDBOXPARAM :=`,
  `src/runtime/Makefile:259`; confirmed on disk in the shipped 4.1.0 release as
  `seccompsandbox = ""`). No external seccomp filter is attached to the QEMU
  `exec.Cmd`. **Turn it on** — §3.3 has the measured values and the traps.
  (An earlier draft attributed the off-by-default to performance and cited kata
  issue #2266; that issue number is **not referenced anywhere in the tree** and
  is **UNVERIFIED**. The config comment does say "enabling this feature may
  reduce performance", which is the citable form.)
  **Do not confuse this with `disable_guest_seccomp`** (default `true`), which
  governs whether container seccomp profiles are applied *inside the guest* by
  kata-agent and has nothing to do with the host VMM.
- **AppArmor: none shipped.** Kata does not provide a host AppArmor profile for
  QEMU or the shim. Guest-side AppArmor is an open proposal (kata issues #7586,
  #2227). Anything present would come from the distro, out of band.
- **SELinux: attempted by default, effective only if the host has the policy.**
  `disable_selinux = false` by default; `qemu.go`'s `StartVM` calls
  `selinux.SetExecLabel(q.config.SELinuxProcessLabel)` immediately before
  launching QEMU. The `container_kvm_t` domain that confines it comes from the
  external `container-selinux` package (RHEL/OpenShift), **not** from the Kata
  repo (kata issue #4812). On a vanilla Ubuntu + containerd node it is very
  likely absent.
  **MEASURED on two distros, both negative.** `/proc/<qemu-pid>/attr/current`
  read `unconfined` on both the Ubuntu 22.04 GPU box and the test host; neither
  had SELinux installed at all (`getenforce` absent, no `container-selinux`).
  So on a vanilla Ubuntu + containerd node SELinux is **not** a second gate.
  Still **UNVERIFIED on RHEL/OpenShift**, which is precisely where
  `container-selinux` ships and where it would matter — re-run
  `scripts/check-vmm-device-access.sh` there, it prints the label.
  **This matters:** if `container_kvm_t` *is* enforcing, it is a second,
  independent gate on opening `/dev/nvidia*` that the device cgroup work will
  not address, and it will need a policy module of its own.

### 3.1 Kata confines Firecracker. Kata does not confine QEMU.

The bullets above read as a list of small omissions. They are not: they are a
**per-hypervisor-driver policy difference**, and the QEMU driver is the one on
the wrong side of it.

Grepping the three drivers for `jailer|seccomp|chroot`
(`kata-containers` @ `f62ecce`):

| driver | matches | what is actually there |
|---|---|---|
| `src/runtime/virtcontainers/fc.go` | **46** | the full Firecracker **jailer**: `chrootBaseDir` (`:151`, set to `/run/<storage-suffix>` at `:240`), `jailerRoot` (`:152`, `:243`), a `jailed` flag (`:164`), and an exec of `fc.config.JailerPath` with `--chroot-base-dir`, `--id`, `--exec-file`, `--daemonize` and `--netns` (`:379-394`) |
| `src/runtime/virtcontainers/clh.go` | 3 | Cloud Hypervisor's **own** `--seccomp` support, **on by default** and only turned off if `DisableSeccomp` is set (`:1860-1863`) |
| `src/runtime/virtcontainers/qemu.go` | **3** | nothing but plumbing for QEMU's own `-sandbox`: `SeccompSandbox: q.config.SeccompSandbox` (`:1285`), `if q.config.SeccompSandbox != ""` (`:1349`), and a `bpf_jit_enable` performance warning (`:1362`) |

So for the QEMU path there is **no jailer, no chroot, no external seccomp
filter, and no namespace beyond the pod netns** (§2). Its only mitigation is
QEMU's internal seccomp — and that is **off by default**
(`DEFSECCOMPSANDBOXPARAM :=`, `src/runtime/Makefile:259`).

**MEASURED on the shipped 4.1.0 release**, which is the cleanest statement of
the difference:

```
$ grep jailer_path      /opt/kata/share/defaults/kata-containers/configuration-fc.toml
jailer_path = "/opt/kata/bin/jailer"
$ grep ^seccompsandbox  /opt/kata/share/defaults/kata-containers/configuration-qemu.toml
seccompsandbox = ""
```

Firecracker ships jailed. QEMU ships with every mitigation off.

Two honest qualifications, because the asymmetry is real but not total:

- **The jailer does not drop uid either.** `fc.go:382-383` passes `--uid 0
  --gid 0`, citing kata-containers/runtime#1869. So Firecracker gets chroot,
  namespaces, cgroups and Firecracker's own seccomp — but still runs as root.
  "Kata drops privileges for Firecracker" would be wrong.
- **QEMU is not entirely without a uid-drop path.** `qemu.go` does plumb
  `Uid`/`Gid`/`Groups` into the launch config (`:1277-1279`) — but that is the
  `rootless` VMM feature, which defaults to `false`, is a `setuid`/`setgid`
  rather than a user namespace, and is documented incompatible with VFIO (§2).
  It is not applied on the default path.

### 3.2 Why this is the risk that actually matters here

**Most QEMU exploits give code execution in the VMM's host userspace, not in
the KVM kernel module.** Device-model bugs — a heap overflow in a virtio
backend, a UAF in a device's reset path — land the attacker inside the
`qemu-system-x86_64` process. "There is a VM boundary" is worth little at that
point, because the boundary is the process that was just compromised. What
matters next is what that process can still reach.

Combining §1.4/§1.6 with §2 and §3, on a cgroup v2 host today, a QEMU RCE under
Kata yields, all measured:

| | |
|---|---|
| uid | **0** (`/proc/<qemu-pid>/status` `Uid: 0`) |
| seccomp | **none** — `seccompsandbox = ""`, and no external filter |
| AppArmor / SELinux | **none** (`attr/current` = `unconfined` on both hosts tested) |
| device cgroup | **none attached**, `effective=0` to the root (§1.4.4) — so every host device node opens, `/dev/mem` included |
| chroot / jail | **none** for the QEMU driver |
| PID namespace | **the host's** (§2) |
| mount namespace | the **containerd shim's**, not PID 1's — a copy of the host tree with no `pivot_root` (§2) |
| network namespace | the pod's — the one thing that *is* confined |

That is not "a contained blast radius". **That is root on the host**, with the
network namespace as the only meaningful restriction, and a `/dev/mem` handle
available to remove even that. It should be written down as a full host
compromise rather than softened.

Note also what upstream's own comparison says. `docs/design/virtualization.md`
rates **Security Isolation**: QEMU "Good"; Cloud Hypervisor "Excellent
(seccomp)"; Firecracker "Excellent"; Dragonball "Excellent" (`:238`) — and its
decision matrix lists "Maximum security isolation → Cloud Hypervisor (seccomp),
Firecracker, Dragonball" (`:255`), **omitting QEMU**. Upstream's strategy for
VMM attack surface is visible in that table and in the three alternatives it
offers, all of them Rust (`:104-106`; Firecracker described as "a minimalist
VMM built on rust-vmm crates", `:204`): **make the VMM small, do not confine the
big one.** That is a coherent strategy. It is also one nvkvm cannot follow —
see [05 §2](05-caveats-and-scope.md).

### 3.3 The one lever that exists today: `seccompsandbox` — **MEASURED**

There is exactly one confinement knob upstream already built for the QEMU path,
it needs no patch, and this design should recommend setting it.

**The key.** `seccompsandbox`, a string, in the hypervisor section of
`configuration.toml` — `SeccompSandbox string \`toml:"seccompsandbox"\`` at
`src/runtime/pkg/katautils/config.go:107`, carried to
`HypervisorConfig.SeccompSandbox` (`:1112`, declared
`virtcontainers/hypervisor.go:614-615`), read by `qemu.go:1285`, and appended
**verbatim** as QEMU's `-sandbox <value>` by govmm
(`src/runtime/pkg/govmm/qemu/qemu.go:3121-3125`).

**The default is off**, in the template (`configuration-qemu.toml.in:75`,
`seccompsandbox = "@DEFSECCOMPSANDBOXPARAM@"`), in the Makefile
(`:259`, `DEFSECCOMPSANDBOXPARAM :=`) and on disk in the shipped 4.1.0 release
(`seccompsandbox = ""`).

**The value.** The shipped config's own comment
(`configuration-qemu.toml.in:71-74`) says:

> Recommended value when enabling:
> `"on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"`

Measured, on the 4.1.0 QEMU, driving real Kata sandboxes and reading
`/proc/<qemu-pid>/cmdline` back:

| value | result |
|---|---|
| `""` (default) | boots; **no `-sandbox` on the QEMU command line at all** |
| `"on"` | boots; `-sandbox on` |
| `"on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"` | boots; passed through verbatim |
| `"on,obsolete=deny,resourcecontrol=deny"` | boots; passed through verbatim |
| `"on,obsolete=deny,elevateprivileges=children,resourcecontrol=deny"` | **QEMU exits 1**: `failed to set no_new_privs aborting` |
| `"enable=1"` | **QEMU rejects it**: `Parameter 'enable' expects 'on' or 'off'` |

Two traps in that table:

- **`"enable=1"` does not work.** It appears in
  `virtcontainers/qemu_test.go:121` as a Go-side unit-test fixture and is easy
  to copy out of the tree, but QEMU's `-sandbox` implied option is `enable`
  taking `on`/`off`, and `1` is rejected at parse. Use `on`.
- **A bad value fails badly.** QEMU exits immediately, but the shim does not
  surface it: `ctr run` blocked until its timeout, and containerd then logged
  `failed to delete task: context deadline exceeded` and `failed to delete dead
  shim`. Validate the string on one sandbox before rolling it out.

**What it does not cover.** `-sandbox` is a seccomp filter on the QEMU process
and nothing else. It does **not** give a chroot, a mount namespace, a uid drop,
or a device cgroup, and it does not narrow what an attacker who already has code
execution can reach through file descriptors QEMU legitimately holds — which,
under nvkvm, includes `/dev/nvidia-uvm` (`nvkvm-pv/docs/internal/isolate-model.md`,
"Who opens what"). It reduces syscall surface; it does not confine.

**The conflict with nvkvm, which is why the recommendation is qualified.**
QEMU's own help text for the sub-options (`qemu-system-x86_64 --help`, verified
against the 4.1.0 build) reads:

> use `elevateprivileges` to allow or deny the QEMU process ability to elevate
> privileges using `set*uid|gid` system calls. The value `children` will deny
> `set*uid|gid` system calls for main QEMU process but will allow forks and
> execves to run unprivileged
>
> use `spawn` to avoid QEMU to spawn new threads or processes by blocking
> `*fork` and `execve`

nvkvm **spawns one isolate process per guest process** and drops privileges in
it (`nvkvm-pv/docs/internal/isolate-model.md`, "Isolation modes"). So Kata's
recommended string is the wrong one for us on two counts: `spawn=deny` blocks
the `fork`/`execve` the isolate spawn path is built on, and
`elevateprivileges=deny` blocks the `set*uid|gid` the `uid` and `uid+chroot`
rungs need. The obvious repair — `elevateprivileges=children`, which exists
precisely for "deny for the parent, allow unprivileged children" — **does not
work on Kata's QEMU build**, as measured above.

**Recommendation, with its uncertainty stated:**

```toml
# in the [hypervisor.qemu] section of configuration.toml
seccompsandbox = "on,obsolete=deny,resourcecontrol=deny"
```

— seccomp on, obsolete syscalls denied, affinity and scheduler-priority
manipulation denied, while leaving `fork`/`execve` and `set*uid|gid` available
to the isolate path. It is measurably weaker than Kata's recommended string and
measurably stronger than the default of nothing.

**UNVERIFIED — and this is Phase 1 work, not a claim:** none of the five values
above was tested against an **nvkvm-patched** QEMU. Whether `spawn=deny` really
breaks isolate spawn, whether `elevateprivileges=deny` really breaks the `uid`
rung, and whether the recommended string above leaves nvkvm fully functional,
all have to be measured once such a build exists. The reasoning is from QEMU's
documented semantics and nvkvm's documented isolate model, not from a run.
**Settle it by running `tests/validate.sh` under each of the five values.**
Also unmeasured here: the **performance cost**. Kata's config comment says
"enabling this feature may reduce performance" and recommends
`/proc/sys/net/core/bpf_jit_enable=1` to reduce it, and `qemu.go:1349-1367`
warns at runtime when that sysctl is 0 — but no number is given anywhere, and
nvkvm's ioctl-forwarding path is syscall-heavy in a way a general container
workload is not, so the cost may be atypical. Measure it alongside
`tests/perf/`.

### 3.4 The larger option: give the QEMU driver what `fc.go` already has

Setting `seccompsandbox` is the thing to do this week. It is not a confinement
story. The confinement story for the QEMU path does not exist upstream, and
[00](00-overview.md) argues that **nvkvm is unusually well placed to contribute
it** — its architecture already assumes the VMM is untrusted. What that would
take, and how plausible it is upstream, is discussed there.

---

## 4. Verdict and what to configure

**MEASURED VERDICT: on cgroup v2, the nodes are reachable today with no
configuration at all — and that is a bug, not a feature, so build as if it were
not true.**

The pre-measurement verdict read "NOT easy, explicit device access is required".
That is still the right thing to *engineer against*, for exactly one reason: the
only thing standing between here and there is a missing `Devices` assignment in
a dependency (§1.6), and Kata's code plainly intends the restriction. A project
that ships on the current behaviour ships on a bug that its upstream will fix.

Concretely:

| | cgroup v2 (measured) | cgroup v1 (from source, UNVERIFIED) |
|---|---|---|
| is a device policy installed on the sandbox cgroup? | **no** | yes |
| can the VMM open `/dev/nvidia*` unconfigured? | **yes** | no |
| does `sandbox_cgroup_only` change it? | **no** | it changes which cgroup the *threads* land in; see §1.4.3 |
| is route (a) needed? | not to work today; **yes** to be correct and to survive the fix | **yes** |
| would route (c) (`sandboxDevices()`) help? | **no** — the list it appends to is discarded | yes |

So the ordering below is unchanged and route (a) is still the recommendation;
what changed is that Phase 1 and Phase 2 of the build plan are **unblocked
right now** on a v2 host and do not have to wait for route (a) to be built.

Three ways to grant it, in order of preference:

### (a) Declare the nodes on the OCI spec Kata is handed — no Kata patch (recommended)

`createResourceController()` seeds the sandbox cgroup's device list directly
from `spec.Linux.Resources.Devices` (`sandbox.go:881`), and additionally appends
everything the device manager tracks (`sandbox.go:976-985`). A host-side CDI
spec whose `containerEdits.deviceNodes` name `/dev/nvidiactl`,
`/dev/nvidia0..N`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools` and (for Vulkan)
`/dev/dri/renderD128` causes containerd to inject them into `linux.devices`
**and** `linux.resources.devices` before the shim is invoked — CDI's
`ContainerEdits.Apply` does both from a single `deviceNodes` entry
(`container-device-interface` `pkg/cdi/container-edits.go:110-121`:
`editor.AddDevice(dev)` then `editor.AddLinuxResourcesDevice(true, dev.Type,
&dev.Major, &dev.Minor, access)`). Kata then copies them into the sandbox
cgroup, and the VMM can open them. See [02](02-libraries-via-cdi.md) §B.

Critically, **Kata will not try to hotplug them into the guest.** A character
device that is neither VFIO nor block is classified as `DeviceGeneric` by
`src/runtime/pkg/device/manager/manager.go::createDevice`; `GenericDevice`'s
`Attach`/`Detach` only bump a refcount
(`src/runtime/pkg/device/drivers/generic.go`), `sandbox.go`'s
`HotplugAddDevice` has a literal `case config.DeviceGeneric: // TODO: what?
return nil`, and `kata_agent.go::appendDevices` has no case for it, so no
protobuf `Device` entry reaches the agent. The device is registered on the host,
allowed in the sandbox cgroup, and otherwise ignored — which is exactly the
behaviour we want.

**The one wrinkle**, and the one place the coordinator's earlier
major/minor concern is real: those same `linux.devices` entries carry **host**
major/minor and remain in the OCI spec sent to the agent, where rustjail's
`create_devices` will act on them inside the guest. For `/dev/nvidiactl`,
`/dev/nvidia0..N` and `/dev/nvidia-modeset` this is harmless — nvkvm registers
at major 195 deliberately, so the numbers agree (`nvkvm-pv/docs/reference/device-nodes.md`).
For `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools`, whose majors are dynamically
allocated independently on each side, they will not agree. The fix is
structural, not arithmetic: **request the host-side CDI kind on the pod
sandbox, and the guest-side kind on the workload container** — see
[03](03-guest-side-devices.md).

**UNVERIFIED:** whether `createResourceController()` reads the *pod-sandbox*
OCI spec or a per-container one, which decides whether the sandbox-level request
above actually reaches the sandbox cgroup. This is the second experiment to run.
Settle with `crictl inspectp` plus the cgroup dump from §1.4.

### (b) `sandbox_cgroup_only`

> **MEASURED:** on cgroup v2 this knob does **not** affect device access — both
> values put QEMU in the same (unrestricted) sandbox cgroup, §1.4.3. Pick it for
> the cgroup-leak reason Kata's own NVIDIA profile gives (`true`), not for
> device reasons.

Set it deliberately rather than by default, once §1.4's experiment says which
value puts the QEMU main thread somewhere the nodes are reachable. Kata's own
NVIDIA profile uses `true`; if the measurement says `false` works only because
the overhead cgroup is unconstrained, that is a fragile reason to pick it and
route (a) should be used instead.

### (c) Patch `sandboxDevices()`

> **MEASURED CAVEAT:** on cgroup v2 this route is inert. `sandboxDevices()`
> appends to the `[]LinuxDeviceCgroup` that `v2.ToResources()` discards (§1.6),
> so the patch would change nothing observable and would be very hard to debug.
> Fix `ToResources()` first, or send both together.

Add the NVIDIA nodes to the hardcoded hypervisor-device list in
`src/runtime/pkg/resourcecontrol/cgroups.go`, next to `/dev/kvm` and
`/dev/vfio/vfio`. This is a two-line upstream change and is defensible — under
nvkvm the NVIDIA nodes genuinely *are* hypervisor devices in the same sense
`/dev/kvm` is. It should be the fallback if (a) proves not to work, not the
opening move.

### Configuration summary

| knob | file | default | why we touch it |
|---|---|---|---|
| `sandbox_cgroup_only` | `configuration-qemu.toml.in` | `false` (NVIDIA profile: `true`; runtime-rs: `true`) | **MEASURED: no effect on device access on cgroup v2** — both values put QEMU in the same sandbox cgroup (§1.4.3), and that cgroup has no device policy (§1.6). Set it `true` for the cgroup-leak reason Kata's NVIDIA profile gives |
| `rootless` | same | `false` | **leave false.** Rootless is documented incompatible with VFIO for permission reasons and would add a DAC problem we do not currently have |
| `disable_selinux` | same | `false` | if the host ships `container-selinux`, expect a second gate; measure before assuming |
| `seccompsandbox` | same | **off** (`""`, confirmed on disk in the 4.1.0 release) | **turn it on** — §3.3. It is the only VMM-confinement lever upstream built for the QEMU path. Use `"on,obsolete=deny,resourcecontrol=deny"`: Kata's own recommended string adds `spawn=deny` and `elevateprivileges=deny`, which are expected to break nvkvm's isolate spawn and its `uid` rung (UNVERIFIED against a patched build), and `elevateprivileges=children` is measured **broken** on Kata's QEMU |
| `NVKVM_ISOLATE_MODE` | nvkvm (env on the VMM) | `auto` | leave on `auto`; assert on the `isolate-mode-active` QOM property |

---

## Upstream reference

Measurements in §1.4, §1.6 and §2 were made on 2026-08-27 against released
binaries: `kata-go-static-4.1.0-amd64` and `kata-static-4.1.0-amd64`
(`kata-runtime 4.1.0`, commit `ddcb1ad8`), with `containerd/cgroups` v1.1.0 as
pinned by `src/runtime/go.mod`. Raw output — the cgroup dumps, the
`BPF_PROG_QUERY` results, the `open()` transcripts, the OCI spec dump, the
counterfactual, and the real `nvidia-ctk` CDI spec the splitter was tested on —
was retained outside this repository; `scripts/check-vmm-device-access.sh`
regenerates all of it.

All Kata file:line citations in this document are against
`github.com/kata-containers/kata-containers` at commit **`f62ecce`**
(shallow clone, 2026-08-27). CDI citations are against
`github.com/cncf-tags/container-device-interface` at **`23b69d2`**; runc at
**`9674194`**; nvidia-container-toolkit at **`b5a4721`**. Paths move between
releases — check the commit before trusting a line number.

---

## Experiments that would settle this document

1. ~~**The device cgroup dump**, both `sandbox_cgroup_only` values~~ — **DONE**,
   §1.4, on two hosts, two containerd versions, both Kata runtimes, real GPU.
   Still open for **cgroup v1**, which needs a host that boots
   `systemd.unified_cgroup_hierarchy=0`; from source the answer should invert
   (§1.6).
2. ~~**Which OCI spec feeds `createResourceController`**~~ — **DONE**, §1.4.4.
   It is the OCI spec containerd builds for the container the shim is handed;
   its `linux.resources.devices` is a deny-all plus the curated safe set, and
   `linux.cgroupsPath` is the parent Kata renames to `kata_<id>`.
3. **`container_kvm_t` presence and enforcement** on the target distro — §3.
   **Partly done**: negative on two Ubuntu hosts (label `unconfined`, no
   `container-selinux`). Still open on RHEL/OpenShift.
4. ~~**PID namespace** of the VMM vs PID 1~~ — **DONE**, §2: shared. The same
   dump also corrected the mount-namespace claim.
5. **Which nvkvm isolate rung `auto` selects under Kata** — read
   `isolate-mode-active` over QMP. Expected `namespace` (better than Docker),
   but nvkvm's own docs say never to infer this. **Not attempted** — it needs an
   nvkvm-patched QEMU, which is Phase 1 of the build plan.

New experiments this round created:

6. **Does the `ToResources()` gap still exist in whatever `containerd/cgroups`
   version Kata ships next?** This finding has a shelf life measured in
   releases. `scripts/check-vmm-device-access.sh` is the regression test; run it
   on every Kata bump before assuming the gate is still open.
7. **Does a kubelet-managed pod cgroup change the answer?** Everything here was
   measured under `ctr`, so the parent was `/default/…` and carried no device
   program of its own. A `/kubepods/…` parent that did would change the
   effective count without Kata doing anything.

### How to reproduce

```bash
sudo ./scripts/check-vmm-device-access.sh --self-test        # proves the harness; no Kata, no GPU
sudo ./scripts/check-vmm-device-access.sh --device /dev/mem  # the real thing, on a GPU host
sudo ./scripts/check-vmm-device-access.sh --synthesise-nodes --device /dev/mem   # on a GPU-less host
```
