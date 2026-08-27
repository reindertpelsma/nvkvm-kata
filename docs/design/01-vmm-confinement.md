# 01 — What confinement does Kata put the VMM in, by default?

**This is the gating question for the whole project, and it is the largest
remaining unknown.** If the Kata hypervisor process cannot `open()` the host's
`/dev/nvidiactl` and `/dev/nvidia*`, nvkvm cannot forward a single ioctl and
nothing else in this design matters.

The short answer, with the reasoning below:

> The device cgroup is the gate, not the namespaces and not the file
> permissions. QEMU under Kata runs as **root** in the host mount, PID and user
> namespaces (only the network namespace confines it), so DAC is not an
> obstacle. But Kata's shim **builds the sandbox's device cgroup itself**, as a
> targeted allowlist — OCI-spec devices plus a hardcoded set (`/dev/kvm`,
> `/dev/vfio/vfio`, `/dev/vhost-net`, `/dev/vhost-vsock`, the safe chardevs).
> **The NVIDIA nodes are not in that set.** So this is **NOT** the easy case:
> the nodes must be granted explicitly. The good news is that the supported way
> to grant them already exists and needs no Kata patch — declare them on the
> OCI spec Kata is handed, and Kata copies them into the sandbox cgroup.

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

**UNVERIFIED:** I did not read `security/device_cgroup.c` directly in this pass.
Settle by reading it, or empirically: put a root shell in a cgroup whose
`devices.list` excludes a node and try to open it.

### 1.4 Which cgroup, and what `sandbox_cgroup_only` changes

Also from `docs/design/host-cgroups.md`:

- **`sandbox_cgroup_only = true`** — the shim "will move itself to it, **before**
  starting the virtual machine. As a consequence all processes subsequently
  created by the Kata Containers shim (the VMM itself, and all vCPU and I/O
  related threads) will be created in the `/kata_<PodSandboxID>` cgroup." Under
  Kubernetes that is `/kubepods/kata_<PodSandboxID>`.
- **`sandbox_cgroup_only = false`** — "The Kata Containers shim will move itself
  to the overhead cgroup first, and then move the vCPU threads to the sandbox
  cgroup as they're created. All Kata processes and threads will run under the
  overhead cgroup except for the vCPU threads." The overhead cgroup is
  `/kata_overhead/<sandbox-id>` and Kata "does not add any constraints or
  limitations" on it.

Default is **`false`** (`DEFSANDBOXCGROUPONLY ?= false` in
`src/runtime/Makefile`) — but Kata's own NVIDIA build profile sets
`DEFSANDBOXCGROUPONLY_NV = true`, with the comment that leaving it false "can
lead to cgroup leakages in the host. Best practice for production is to set
this to true."

**What this changes for us is which cgroup the QEMU main thread sits in**, and
therefore which device policy applies to it — the constrained
`/kubepods/.../kata_<id>` one, or the unconstrained overhead one. The QEMU main
thread is where nvkvm's virtio-nvgpu device lives and where the isolates are
spawned from, so it is the thread that matters.

**UNVERIFIED, and this is the single most important thing to measure.** The
overhead cgroup is created with an **empty** resource set
(`sandbox.go:1012`):

```go
overheadController, err := resCtrl.NewResourceController(fmt.Sprintf("%s%s", resCtrlKataOverheadID, s.id), &specs.LinuxResources{})
```

and `resCtrlKataOverheadID = "/kata_overhead/"` (`sandbox.go:83`) — a path at
the **cgroup root**, not under `kubepods`. `NewResourceController`
(`src/runtime/pkg/resourcecontrol/cgroups.go:153`) passes that empty set
straight to `cgroups.New(cgroups.V1, ...)` or `cgroupsv2.NewManager(...)`.

Reasoning from cgroup semantics, this points at a surprising answer: with an
empty device list, **no** device rules are written, so on v1 the new cgroup
inherits its parent's whitelist — and its parent chain reaches the root, which
is `a *:* rwm`; and on v2 no `BPF_CGROUP_DEVICE` program is attached and there
is no ancestor program to inherit, since the path is not under `kubepods`.
**If that holds, then with the default `sandbox_cgroup_only=false` the QEMU main
thread lands somewhere device-unrestricted and the NVIDIA nodes are reachable
for free** — while `sandbox_cgroup_only=true` (Kata's own NVIDIA-profile
default, and the production recommendation) puts it in the *restricted* sandbox
cgroup and breaks it. That is an uncomfortable inversion: the safer-looking
setting is the one that blocks us.

I did not verify this empirically and it turns on `containerd/cgroups` v1.1.0
behaviour that is not vendored in this tree, so treat it as a hypothesis, not a
finding.
**Experiment:** on a node running a Kata pod, with each setting in turn:
`cat /proc/$(pgrep -f qemu-system-x86_64)/cgroup`, then for v1
`cat /sys/fs/cgroup/devices/<that path>/devices.list`, and for v2
`bpftool cgroup show /sys/fs/cgroup/<that path>` plus
`bpftool prog dump xlated id <n>`. Then simply attempt the open, from that
cgroup, and see. `scripts/check-vmm-device-access.sh` is the stub for this.

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

## 2. Namespaces — secondary, and mostly absent

Stated briefly because they turn out not to be the gate.

| namespace | what the VMM gets | evidence |
|---|---|---|
| **network** | **joins the pod/CNI netns** | `doNetNS()` in `src/runtime/virtcontainers/network_linux.go` does `runtime.LockOSThread()` then `targetNS.Set()` (a `setns(2)`); `Sandbox.startVM` wraps `hypervisor.StartVM` in `s.network.Run(...)`, so the fork/exec inherits the netns. Design doc: "It is given a separate network namespace from the host." (`docs/design/architecture/README.md`) |
| **mount** | **host mount namespace** | No `unshare`, `CLONE_NEWNS`, `pivot_root` or `chroot` in `qemu.go` or govmm's `LaunchCustomQemu`; `SysProcAttr` carries only `Credential`. There is no jailer. `/run/vc/vm/<sandbox-id>` is an ordinary host directory for sockets and the pidfile, not a root. |
| **PID** | **host PID namespace** (inferred) | The shim runs under containerd's standard `shimapi.Run` with `NoReaper/NoSubreaper`; no `CLONE_NEWPID` anywhere in the launch path. **UNVERIFIED as an explicit statement** — settle by comparing `readlink /proc/<shim>/ns/pid` and `/proc/1/ns/pid`. |
| **user** | **none** | `rootless = false` by default (`src/runtime/config/configuration-qemu.toml.in`: "By default QEMU VMM run as root"). Even when enabled it is a **setuid/setgid to a random uid** via `SysProcAttr.Credential`, **not** `CLONE_NEWUSER`; and it only covers QEMU — "Other processes such as Kata Container shimv2 and virtiofsd still run as the root user" (`docs/how-to/how-to-run-rootless-vmm.md`). |

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

## 3. Other confinement Kata applies to the VMM: almost none

- **seccomp on the host QEMU: none.** The `seccompsandbox` knob (QEMU's own
  `-sandbox`) defaults to empty/off (`DEFSECCOMPSANDBOXPARAM :=` in
  `src/runtime/Makefile`, disabled for performance, kata issue #2266). No
  external seccomp filter is attached to the QEMU `exec.Cmd`.
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
  **UNVERIFIED per distro** — settle with `cat /proc/<qemu-pid>/attr/current`
  and `semodule -l | grep container`.
  **This matters:** if `container_kvm_t` *is* enforcing, it is a second,
  independent gate on opening `/dev/nvidia*` that the device cgroup work will
  not address, and it will need a policy module of its own.

---

## 4. Verdict and what to configure

**NOT easy. Explicit device access is required.** The nodes are not reachable by
default, and the reason is the device cgroup Kata builds for the sandbox, not
file permissions and not namespaces.

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

Set it deliberately rather than by default, once §1.4's experiment says which
value puts the QEMU main thread somewhere the nodes are reachable. Kata's own
NVIDIA profile uses `true`; if the measurement says `false` works only because
the overhead cgroup is unconstrained, that is a fragile reason to pick it and
route (a) should be used instead.

### (c) Patch `sandboxDevices()`

Add the NVIDIA nodes to the hardcoded hypervisor-device list in
`src/runtime/pkg/resourcecontrol/cgroups.go`, next to `/dev/kvm` and
`/dev/vfio/vfio`. This is a two-line upstream change and is defensible — under
nvkvm the NVIDIA nodes genuinely *are* hypervisor devices in the same sense
`/dev/kvm` is. It should be the fallback if (a) proves not to work, not the
opening move.

### Configuration summary

| knob | file | default | why we touch it |
|---|---|---|---|
| `sandbox_cgroup_only` | `configuration-qemu.toml.in` | `false` (NVIDIA profile: `true`) | decides which cgroup's device policy applies to the QEMU main thread |
| `rootless` | same | `false` | **leave false.** Rootless is documented incompatible with VFIO for permission reasons and would add a DAC problem we do not currently have |
| `disable_selinux` | same | `false` | if the host ships `container-selinux`, expect a second gate; measure before assuming |
| `seccompsandbox` | same | off | leave off; QEMU's `-sandbox` would interfere with the isolate spawn path |
| `NVKVM_ISOLATE_MODE` | nvkvm (env on the VMM) | `auto` | leave on `auto`; assert on the `isolate-mode-active` QOM property |

---

## Upstream reference

All Kata file:line citations in this document are against
`github.com/kata-containers/kata-containers` at commit **`f62ecce`**
(shallow clone, 2026-08-27). CDI citations are against
`github.com/cncf-tags/container-device-interface` at **`23b69d2`**; runc at
**`9674194`**; nvidia-container-toolkit at **`b5a4721`**. Paths move between
releases — check the commit before trusting a line number.

---

## Experiments that would settle this document

1. **The device cgroup dump**, both `sandbox_cgroup_only` values, both cgroup
   versions — §1.4. This is the one that decides whether route (a) is needed at
   all.
2. **Which OCI spec feeds `createResourceController`** — §4(a).
3. **`container_kvm_t` presence and enforcement** on the target distro — §3.
4. **PID namespace** of the VMM vs PID 1 — §2.
5. **Which nvkvm isolate rung `auto` selects under Kata** — read
   `isolate-mode-active` over QMP. Expected `namespace` (better than Docker),
   but nvkvm's own docs say never to infer this.
