# 03 — Guest-side device nodes

All upstream citations against `kata-containers/kata-containers` @ **`f62ecce`**,
`opencontainers/runc` @ **`9674194`**,
`cncf-tags/container-device-interface` @ **`23b69d2`**, cloned 2026-08-27.

This was written expecting no upstream precedent. **That expectation was
wrong**, and the document is better for it. What follows leads with what already
exists.

---

## The gate is the container's device cgroup, inside the guest

`/dev/nvidiactl` and `/dev/nvidia*` inside the Kata VM are created by
`nvkvm-guest.ko` in the **guest** kernel — not passed from the host, not
hotplugged, not VFIO. udev makes the nodes; the module's `struct class` forces
mode **0666** so unprivileged guest processes can open them
(`nvkvm-pv/src/guest/nvkvm_main.c:100-105`, documented in
`nvkvm-pv/docs/reference/device-nodes.md`). Getting them into the container is
therefore a purely guest-side operation.

Three things must all be true for the container's process to use one, and they
fail with different loudness:

1. **the node is visible in the container's mount namespace** — fails `ENOENT`,
   obvious;
2. **the container's device cgroup allows it** — fails `EPERM`, with no log
   line, no audit record and nothing in `ls -la` to hint at it. **This is the
   one that decides, and the one that fails silently;**
3. **DAC permits it** — nvkvm already forces 0666, so this is a non-issue here.

The numbering question that might seem to loom is narrow and mostly answers
itself: nvkvm registers at major 195 *on purpose*, because NVIDIA's userspace
hardcodes it (`nvkvm_main.c:91-98`), so `/dev/nvidiactl`, `/dev/nvidia0..N` and
`/dev/nvidia-modeset` carry the same numbers in the guest as on the host. Only
`/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` have dynamic majors allocated
independently on each side. And the mechanism recommended below never needs the
numbers at all.

---

## What already works, and where

### Precedent 1 — nvidia-container-toolkit already does exactly this, inside an nvkvm guest

This is not speculation. `nvkvm-pv/README.md`, "Containers":

> "Docker with `nvidia-container-toolkit` works inside the guest with no special
> handling — standard install, `docker run --gpus all`, and the GPU appears:
>
> ```
> $ docker run --rm --gpus all nvidia/cuda:12.9.0-base nvidia-smi
> NVIDIA-SMI 575.51.03   Driver Version: 575.51.03   CUDA Version: 12.9
> 0  NVIDIA GeForce RTX 3070   Off   00000000:00:07.0
> ```
>
> Process enumeration is namespace-correct too — `nvidia-smi` inside a container
> sees only that container's GPU processes, never a host PID."

What that establishes:

- the standard toolkit **discovers nvkvm's device nodes**, writes the container
  device-cgroup allow rules, and produces working GPU access, in this exact
  environment;
- the mechanics are plain Linux — device cgroups and bind mounts. No
  driver involvement at that layer, nothing nvkvm-specific to invent;
- PID-namespace correctness inside the guest is demonstrated too — and by
  design, not by accident: `NV2080_CTRL_CMD_GPU_GET_PIDS` is answered from the
  guest module's own session table and rendered per-caller with `pid_vnr()`
  (`nvkvm-pv/docs/reference/device-nodes.md`, "Container process enumeration").

So the guest half is **not** "invent a mechanism". It is "make kata-agent do
what dockerd + runc + nvidia-container-toolkit already do successfully here".

### Precedent 2 — kata-agent already resolves CDI specs *inside the guest*

`src/agent/src/rpc.rs`, in `do_create_container`:

```rust
    // In guest-kernel mode some devices need extra handling. Taking the
    // GPU as an example the shim will inject CDI annotations that will
    // be used by the kata-agent to do containerEdits according to the
    // CDI spec coming from a registry that is created on the fly by UDEV
    // or other entities for a specifc device.
    // In Kata we only consider the directory "/var/run/cdi", "/etc" may be
    // readonly
    dump_nvidia_cdi_yaml(&sl())?;
    let visible_cdi_devices = if AGENT_CONFIG.visible_cdi_devices {
        cdi_devices_from_visible_devices(&oci)?
    } else {
        Vec::new()
    };
    handle_cdi_devices(&sl(), &mut oci, "/var/run/cdi",
                       AGENT_CONFIG.cdi_timeout, &visible_cdi_devices).await?;
```

`handle_cdi_devices` (`src/agent/src/device/mod.rs`) parses `cdi.k8s.io/*`
annotations off the container spec (`cdi::annotations::parse_annotations`),
builds a CDI cache scoped to the guest directory
(`with_spec_dirs(&[spec_dir])`, `with_auto_refresh(false)`), and calls
`cache.inject_devices(Some(spec), devices)` — **applying `containerEdits` from a
CDI spec that exists only in the guest, to the container's OCI spec, before the
container is created.** It retries for `cdi_timeout` seconds (default 100,
`src/agent/src/config.rs`) waiting for the spec to appear, which is exactly the
"driver is still initialising" case.

The Rust `container-device-interface` crate (workspace dep `1.1.1`) mirrors the
Go library: for each device node it calls `spec_gen.add_device(...)` **and**
`spec_gen.add_linux_resources_device(true, dev_typ, Some(major), Some(minor),
dev_access)`. **The cgroup allow rule comes for free from the deviceNodes
entry.**

And `insert_devices_cgroup_rule()` exists in `src/agent/src/device/mod.rs`
independently, for the protobuf-device path.

The whole thing is then applied to a real cgroup by rustjail:
`src/agent/rustjail/src/cgroups/fs/mod.rs:142-145` calls
`set_devices_resources(&self.cgroup, devices, res, pod_res)` from
`r.devices()`, via the `cgroups-rs` crate, which covers both v1 `devices.allow`
files and the v2 eBPF filter.

### Precedent 3 — the whole shape exists as a shipped Kata feature

Kata's own NVIDIA-QEMU GPU path (`docs/use-cases/NVIDIA-GPU-passthrough-and-Kata-QEMU.md`)
is structurally what we want, with VFIO where nvkvm has virtio:

> "NVRC scans for NVIDIA GPUs on the PCI bus, loads the NVIDIA kernel modules,
> waits for driver initialization, creates the device nodes, and initializes the
> GPU hardware (using the `nvidia-smi` binary). NVRC also creates the guest-side
> CDI specification file (using the `nvidia-ctk cdi generate` command)."

NVRC is "the NVIDIA Runtime Container init system"; it runs as the guest's init
and forks kata-agent. The shim injects `cdi.k8s.io/vfio<num>` →
`nvidia.com/gpu=<index>` annotations (`annotateContainerWithVFIOMetadata`), and
the agent resolves them against the guest spec.

**Substituting nvkvm for VFIO changes one thing in that picture: what makes the
GPU appear in the guest.** Everything downstream of "the guest has NVIDIA device
nodes" is unchanged.

---

## What is genuinely missing

One thing, and it is on the host side, not the guest side.

The shim's annotation injection is keyed on a **VFIO device**
(`annotateContainerWithVFIOMetadata`, driven by
`src/runtime/pkg/containerd-shim-v2/device_cold_plug.go`). Under nvkvm there is
no VFIO device to key on, so nothing tells the agent which CDI device the
container wants.

There are two ways round it and one of them needs no code at all:

### (a) `VISIBLE_CDI_DEVICES` — zero upstream change

`cdi_devices_from_visible_devices()` (`src/agent/src/device/mod.rs`) reads the
`VISIBLE_CDI_DEVICES` environment variable off the container's own spec and
merges the result with the annotation-derived list:

```rust
const VISIBLE_CDI_DEVICES_ENV: &str = "VISIBLE_CDI_DEVICES";
```

Entries are `kind=indices`, colon-separated, e.g.
`VISIBLE_CDI_DEVICES=nvidia.com/gpu=0`, with `all` supported and
`""`/`none`/`void` meaning nothing. It is gated by `AGENT_CONFIG.visible_cdi_devices`,
default **false**, enabled by the kernel-cmdline parameter
`agent.visible_cdi_devices` (`src/agent/src/config.rs`) — which is settable
through `kernel_params` in `configuration.toml` or the
`io.katacontainers.config.hypervisor.kernel_params` annotation.

**So a pod can request a guest-resident GPU by setting one environment
variable, with no patch to Kata anywhere.** This is the recommended starting
point, and it is a striking result for something that was expected to need
upstream work.

Its limitation is honest: it is a container-driven request, not an
orchestrator-driven allocation. There is no scheduler integration, no device
plugin, no capacity accounting. For a first working system that is fine; for a
production multi-GPU node it is not.

### (b) Teach the shim to inject the annotation — small upstream change

The orchestrator-grade version mirrors what `device_cold_plug.go` does for VFIO:
resolve the pod's GPU allocation and emit `cdi.k8s.io/nvkvm0 = nvidia.com/gpu=<idx>`
on the container spec. This is additive — a second annotation source next to the
VFIO one — and it lands in code Kata already maintains for this exact purpose.
It would be a genuinely small PR, and the "no upstream precedent" expectation
does not survive contact with `device_cold_plug.go`.

---

## Bind mount vs mknod, in the guest

Once the OCI spec carries the guest's device nodes and their cgroup rules,
rustjail materialises them. `src/agent/rustjail/src/mount.rs:917`:

```rust
fn create_devices(devices: &[LinuxDevice], bind: bool) -> Result<()> {
    let op: fn(&LinuxDevice, &Path) -> Result<()> = if bind { bind_dev } else { mknod_dev };
```

- `mknod_dev` (`mount.rs:967`) — `stat::mknod(relpath, ..., makedev(dev.major(), dev.minor()))`
- `bind_dev` (`mount.rs:994`) — creates an empty file at the destination and
  `mount(Some(dev.path()), relpath, None, MsFlags::MS_BIND, None)`. It binds
  **from `dev.path()` as seen in the agent's current mount namespace**, i.e. the
  guest's live `/dev`, because `init_rootfs` runs before `pivot_root`. This is
  literally "the node already exists in the guest; bind it into the container."

**Bind is preferable** and should be the recommendation:

- it references the existing inode, so majors/minors — dynamic, fallback-allocated,
  per-boot — become irrelevant;
- it inherits devtmpfs ownership and permissions rather than re-deriving them
  (nvkvm's 0666 comes along for free);
- it cannot go stale if numbering changes;
- it does not need `CAP_MKNOD` in the container context.

**But the existing bind path is not directly reusable as-is**, and this is where
Kata differs from runc in a way that matters.

**runc has two triggers for binding** (`libcontainer/rootfs_linux.go:957-1011`):

```go
	useBindMount := userns.RunningInUserNS() || config.Namespaces.Contains(configs.NEWUSER)
	...
	if err := mknodDevice(destDir, destName, node); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil
		} else if errors.Is(err, os.ErrPermission) {
			return bindMountDeviceNode(destDir, destName, node)   // <-- reactive fallback
		}
		return err
	}
```

an upfront decision *and* a reactive `EPERM` fallback.

**kata-agent has only the upfront decision, and it is global.**
`src/agent/rustjail/src/container.rs:532` sets `let mut bind_device = false;`,
and it becomes true only on joining or creating a user namespace
(`container.rs:558`, `container.rs:571`). `mknod_dev` failing is a hard error —
there is no fallback. So on the normal Kata path (no user namespace) rustjail
**always** mknods.

### What this means

**Functionally, nothing is blocked.** kata-agent runs as root in the guest's
init namespace with `CAP_MKNOD`, the numbers in the spec come from a CDI spec
generated *in the guest* against the real nodes, so `mknod_dev` produces correct
nodes. **The design works today without any change**, using mknod.

**Structurally, bind is still the better answer**, and getting it is small. Two
options, in increasing invasiveness:

1. **Port runc's `EPERM` fallback** into `mknod_dev`'s caller — ~6 lines in
   `create_devices`. Framed as "align rustjail with runc's device handling",
   which it is, this is an easy upstream sell. It does not by itself make bind
   the default, but it removes the failure mode where a hardened guest cannot
   create the node at all.
2. **Make `bind` selectable per device**, e.g. honouring an annotation or a
   marker on the `LinuxDevice`. More invasive, because `create_devices` takes a
   single bool for the whole list including `DEFAULT_DEVICES`.

**Honest answer to "does this need an upstream patch": no, not to work.** Option
(a) above plus mknod is a complete path using only shipped code. A patch is
wanted for the *better* mechanism (bind) and for *orchestrator-grade* device
requests, and both patches are small and land in code Kata already maintains for
NVIDIA GPUs.

---

## Recommendation: (a) reuse the toolkit in the guest, not (b) reimplement

The question posed was whether kata-agent should invoke the toolkit's CDI
generation inside the guest, or reimplement the allow-rule + bind logic itself.

**Recommend (a), and note that it barely counts as a recommendation because it
is what Kata already does for VFIO GPUs.** kata-agent does not need to invoke
anything: the guest's init needs to, once, at boot — exactly NVRC's role. The
agent's side is already written and shipped.

Reasons:

- it is the shipped upstream path (`handle_cdi_devices`, NVRC,
  `/var/run/cdi/nvidia.yaml`), so the code is maintained by people who are not us;
- the toolkit's node enumeration is `stat()`-based against real nodes
  (libnvidia-container's `find_device_node()` uses `s.st_rdev`, not
  `/proc/devices`), so dynamic UVM majors resolve correctly by construction;
- the cgroup rules follow from the deviceNodes entries via the CDI library, so
  neither the toolkit nor kata-agent has to hand-roll v1-vs-v2 cgroup logic —
  which matters, because those two mechanisms have nothing in common and
  **on v2 an added program can only narrow access**, so an after-the-fact fix is
  not even possible;
- reimplementing (b) means owning a second copy of `nvidia-ctk`'s discovery
  logic, forever, against a driver whose device surface changes.

### Cost in the guest rootfs

Option (a) means shipping **the toolkit, not CUDA**, in the Kata guest image:

- `nvidia-ctk` (Go binary, tens of MB unstripped, less when stripped)
- enough of `libnvidia-container` / the discovery path for `cdi generate`
- `nvidia-smi` and `libnvidia-ml.so.1` if you want NVRC's "wait for driver init"
  step, which uses `nvidia-smi`

**UNVERIFIED: the exact size.** Settle by building the rootfs and measuring;
Kata's own NVIDIA rootfs is the reference point, and its "chiseled build"
(`nvidia_rootfs.sh`, per `NVIDIA-GPU-passthrough-and-Kata-QEMU.md`) exists
precisely to keep this small by copying only the needed pieces into a distro-less
final image.

**It does not require CUDA userspace.** `libcuda`, the PTX JIT, cuDNN, none of
it. Those reach the container from the host over CDI mounts
([02](02-libraries-via-cdi.md)), and the Kata guest rootfs deliberately carries
none of them.

**A wrinkle to flag, because it is where (a) is not free:** a toolkit running
in the guest enumerates *guest* libraries, and the guest has none. Its generated
spec's `mounts` will therefore be empty or wrong. **Use the guest-generated CDI
spec for `deviceNodes` and `env` only; take `mounts` from the host spec.** That
is the same split [02](02-libraries-via-cdi.md) argues for, arriving from the
other direction. Concretely, generate in the guest with the hooks and mounts
that reference nonexistent guest paths stripped — or accept the spec as
generated and let the host's mounts win, since the two edit different fields.

**UNVERIFIED:** how `nvidia-ctk cdi generate` behaves on a host with device
nodes but no driver libraries — whether it errors, warns, or emits a
device-only spec. Settle by running it inside an nvkvm guest that has *not* had
`stage_guest_libs.sh` run. This is a cheap experiment and it decides how much
post-processing the guest-side generation needs.

---

## Summary

| question | answer |
|---|---|
| Where does the container's node come from? | the guest's own `/dev`, created by `nvkvm-guest.ko` |
| What actually gates access? | the container's device cgroup, written by rustjail from `linux.resources.devices` |
| Where does that rule come from? | a CDI `deviceNodes` entry, applied in the guest by `handle_cdi_devices` |
| Which component discovers the node identity? | `nvidia-ctk cdi generate`, run in the guest, `stat()`ing the real nodes |
| mknod or bind? | mknod works today; bind is better and needs a small rustjail change |
| Upstream patch required? | **not to work.** Wanted for bind, and for orchestrator-driven requests |
