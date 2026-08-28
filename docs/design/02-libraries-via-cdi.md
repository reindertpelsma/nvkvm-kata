# 02 — Host NVIDIA libraries into the container, via CDI

> **RESOLVED, 2026-08-28 — read [09](09-gpu-libraries-automatically.md) with
> this document.** Three of this document's open questions were settled by
> measurement, and one of its recommendations was overtaken:
>
> - **§D's pivotal UNVERIFIED — "whether kata-agent actually executes hooks
>   arriving via the guest CDI path" — is now VERIFIED, positively.** It does
>   (`src/agent/rustjail/src/container.rs:621-632`), in the container's mount
>   namespace, before `pivot_root`. So §D option 3 is the one that ships, and
>   §D option 2 ("replace `update-ldcache` with `LD_LIBRARY_PATH`") is
>   **withdrawn** — it was the manual step this project has since removed.
> - **§A's UNVERIFIED request for literal generated YAML is answered**:
>   [`evidence/09/nvidia-ctk-cdi-generate.json`](evidence/09/nvidia-ctk-cdi-generate.json)
>   is a committed fixture from a real driver host. It shows something §A gets
>   slightly wrong: `create-symlinks` does **not** emit the SONAME links.
>   `libcuda.so.1` is made by `ldconfig`, from `update-ldcache`.
> - **§C.1's UNVERIFIED symlink-chain question** was already answered in
>   [07 §6](07-end-to-end.md#6-rung-4--nvidia-smi); 09 adds that a *file*
>   mounted at a SONAME path works just as well as a symlink.
> - The split this document recommends is exactly what shipped, with the
>   `mounts` half generated on the host by `nvidia-ctk` and the `deviceNodes`
>   half generated in the guest — but the split is performed by
>   `scripts/lib/gpu-cdi.py`, per container, not by `split-cdi-spec.sh`.

All upstream citations in this document are against
`kata-containers/kata-containers` @ **`f62ecce`**,
`cncf-tags/container-device-interface` @ **`23b69d2`**,
`NVIDIA/nvidia-container-toolkit` @ **`b5a4721`**, all shallow-cloned 2026-08-27.

---

## The layering model this document exists to serve

Two kinds of thing have to reach the workload, and they travel completely
differently.

**Libraries traverse nothing.** `libcuda.so.<version>`, `libnvidia-ml.so.1`,
the PTX JIT compiler, the GSP firmware blobs — these only ever need to exist in
the **container**, inside the guest. The VMM does not need them. The Kata guest
rootfs does not need them. They go host → container in one hop and skip every
intermediate layer.

**Device nodes exist at every layer**, because each layer's existence depends
on the one below:

| layer | node it needs | who creates it |
|---|---|---|
| VMM (host process) | host `/dev/nvidiactl`, `/dev/nvidia*`, `/dev/nvidia-uvm` | the host NVIDIA driver |
| guest root | guest `/dev/nvidiactl`, `/dev/nvidia*`, … | `nvkvm-guest.ko`, in the guest kernel |
| container | the same nodes, in its own `/dev` | kata-agent, from the guest's `/dev` |

So a **host-generated CDI spec must be split, not consumed whole**:

- its **`mounts`** are the host driver userspace — portable, and exactly what we
  want in the container;
- its **`deviceNodes`** describe *host* nodes. They are useful on the host — see
  [01 §4(a)](01-vmm-confinement.md), where they are what authorises the VMM —
  but they are the wrong source for the container's nodes, which come from the
  guest ([03](03-guest-side-devices.md));
- its **`hooks`** need a decision per hook, and most of them do not survive the
  guest boundary (§D).

**A property worth naming.** Because CDI supplies the *host's own* driver
libraries into the container, and the host kernel driver is the one actually
servicing every forwarded ioctl, **the container's driver userspace matches the
servicing kernel driver by construction.** On a normal nvkvm deployment this
matching is a real piece of machinery — `make_host_bundle.sh` on the host and
`stage_guest_libs.sh` in the guest, with the failure mode that a mismatch
produces `cuInit` → 803 or "Driver/library version mismatch"
(`nvkvm-pv/docs/howto/stage-guest-libraries.md`). Under Kata that machinery
disappears: the mount *is* the bundle, and it is generated from the same host
that is running the driver.

---

## A) What a CDI spec can carry

Per the CDI specification
(<https://github.com/cncf-tags/container-device-interface/blob/main/SPEC.md>),
`containerEdits` appears at spec level (applied whenever any device from the
spec is requested) and per device, and may contain:

- **`deviceNodes[]`** — `path` (container-side), `hostPath` (defaults to
  `path`), `type`, `major`, `minor`, `fileMode`, `permissions` (cgroup-style
  `rwm`, default `rwm`), `uid`, `gid`
- **`mounts[]`** — `hostPath`, `containerPath`, `type`, `options[]`
- **`hooks[]`** — `hookName` ∈ {`createRuntime`, `createContainer`,
  `startContainer`, `poststart`, `poststop`}, `path`, `args`, `env`, `timeout`.
  Note the set **excludes** the legacy `prestart`.
- **`env[]`**, and newer `intelRdt`, `additionalGids`, `netDevices`

### What `nvidia-ctk cdi generate` emits for a plain GPU

- **device nodes**: `/dev/nvidiactl`, `/dev/nvidia<N>`, `/dev/nvidia-uvm`,
  `/dev/nvidia-uvm-tools`, `/dev/nvidia-modeset`, and `/dev/dri/card*` +
  `renderD*` for graphics-capable configurations
- **mounts**: the versioned driver libraries and firmware from the host driver
  store, read-only
- **hooks**, all `createContainer`, run via `nvidia-cdi-hook`:
  `create-symlinks`, `disable-device-node-modification`, `enable-cuda-compat`,
  `update-application-profile`, `update-ldcache`
- **env**: `PATH`, `LD_LIBRARY_PATH`, `NVIDIA_VISIBLE_DEVICES=void`

Source: <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html>

**UNVERIFIED:** I did not capture literal generated YAML from a GPU host in this
pass — the list above is from NVIDIA's documentation plus the toolkit's
generator source, not from an artifact. Settle by running
`nvidia-ctk cdi generate --output=/dev/stdout` on a driver-installed host and
committing the output as a fixture; the exact mount list is what
`split-cdi-spec.sh` has to operate on.

### The toolkit does not touch cgroups in CDI mode

Worth stating because it shapes [03](03-guest-side-devices.md). In CDI mode the
toolkit only emits spec data; the cgroup rule is derived by the CDI library, not
written by the toolkit. Its own source says so —
`internal/edits/device.go`, `fromPathOrDefault()`:

> ```
> // * dn.Rule.Allow: This has no equivalent in the CDI spec and is used for
> //                  specifying cgroup rules in a container.
> ```

The toolkit's direct cgroup manipulation (`nvidia-container-cli configure
--device=...`, `libnvidia-container`'s `setup_device_cgroup()` writing
`c %u:%u rw` into `devices.allow`, and its cgroup-v2 eBPF program rewriting in
`src/nvcgo/internal/cgroup/v2.go`) belongs to the **legacy prestart-hook mode**,
which NVIDIA documents as mutually exclusive with CDI.

---

## B) How CDI flows through containerd

Both request paths converge on one function,
`WithCDI(annotations map[string]string, CDIDevices []*runtime.CDIDevice) oci.SpecOpts`
in containerd's CRI options package (`pkg/cri/opts/spec_linux.go`, now
`internal/cri/opts/`):

- **`cdi.k8s.io/*` OCI annotations** — parsed with `cdi.ParseAnnotations()`
- **the CRI `CDIDevices` field** — `ContainerConfig.CDIDevices`, populated by
  kubelet from device-plugin / DRA allocations

Both lists are merged and passed to `cdi.InjectDevices(spec, devices...)`, which
calls `ContainerEdits.Apply(spec)`. **Injection happens while containerd builds
the OCI spec, strictly before the shim is invoked.** containerd's own comment on
`pkg/cdi/oci_opt.go` makes the ordering explicit:

> "CDI device injection might add OCI Spec environment variables, hooks, and
> mounts as well. Therefore it is important that none of the corresponding OCI
> Spec fields are reset up in the call stack once we return."

**What `Apply` does per device node** — this is the load-bearing detail for
[01](01-vmm-confinement.md) and worth quoting
(`pkg/cdi/container-edits.go:110-121`):

```go
		editor.RemoveDevice(dev.Path)
		editor.AddDevice(dev)

		if dev.Type == "b" || dev.Type == "c" {
			access := d.Permissions
			switch access {
			case "":            access = "rwm"
			case NoPermissions: access = ""
			}
			editor.AddLinuxResourcesDevice(true, dev.Type, &dev.Major, &dev.Minor, access)
		}
```

**One `deviceNodes` entry yields both a `linux.devices` entry and a
`linux.resources.devices` allow rule.** CDI never touches a cgroup itself; it
edits the spec, and the low-level runtime turns that into `devices.allow` (v1)
or a `BPF_PROG_LOAD` (v2) later.

Missing major/minor are filled in by `fillMissingInfo()`
(`pkg/cdi/container-edits_unix.go`), which `Lstat()`s the **host** path — one
more reason the deviceNodes half is inherently host-flavoured.

**Version note:** containerd 1.7 has CDI but `enable_cdi` defaults **off**;
containerd 2.0 enables it by default; the toggle is deprecated as of 2.2 and
slated for removal in 2.4, after which CDI is always on
(<https://containerd.io/docs/2.1/containerd-2.0/>,
`containerd/RELEASES.md`). `cdi_spec_dirs` defaults to
`["/etc/cdi", "/var/run/cdi"]`.

---

## C) How CDI-injected content reaches the guest

Because injection completes before the shim runs, **the Kata shim receives an
ordinary, already-edited `config.json`.** It needs no CDI awareness for this to
work — though it happens to have plenty (§C.3).

### C.1 Mounts → virtio-fs, automatically

An OCI `mounts[]` entry pointing at a host path is not special-cased in Kata
unless it is a block-device rootfs, a Nydus/EROFS layered image, or a "virtual
volume" for guest-pull. Everything else goes through
`ShareRootFilesystem`/`bindMountContainerRootfs` in
`src/runtime/virtcontainers/fs_share_linux.go`: the host path is bind-mounted
under `/run/kata-containers/shared/sandboxes/<sandbox-id>/`, and a single
`virtiofsd` per VM exports that tree into the guest. `docs/design/architecture/storage.md`
confirms one virtiofsd daemon per VM and that the shared-mount point is how the
workload image reaches the guest.

**So yes: a mounts-only CDI spec does land in the guest via virtio-fs, with no
Kata changes.** `shared_fs` defaults to `virtio-fs` in
`src/runtime/config/configuration-qemu.toml.in`.

**UNVERIFIED, and it is the practical risk in this half of the design:** whether
a versioned `.so` symlink chain (`libcuda.so.1` → `libcuda.so.575.51.03`)
survives the virtio-fs share intact. Nothing found says it does not; nothing
found says it does. **Experiment:** bind-mount a real driver-store directory
into a plain Kata container as an ordinary OCI mount and run `readlink -f
/usr/lib/x86_64-linux-gnu/libcuda.so.1` plus a `dlopen` from inside. This is
cheap and should be run before anything else in [02].

### C.2 Device nodes → the generic device path

Covered in [01 §4(a)](01-vmm-confinement.md): a char device that is neither VFIO
nor block becomes a `GenericDevice`, which contributes a sandbox-cgroup allow
rule on the host and is **not** forwarded to the agent. On the host that is
exactly what we want. Inside the guest it is a liability — those same
`linux.devices` entries carry host major/minor and reach rustjail's
`create_devices`. See [03](03-guest-side-devices.md) for the resolution.

### C.3 Kata's own CDI machinery

Kata is not a passive CDI consumer. It has a two-tier system already, built for
VFIO GPU passthrough:

- **host tier** — `src/runtime/pkg/containerd-shim-v2/device_cold_plug.go`
  resolves allocated device IDs (kubelet Pod Resources API, or `cdi.k8s.io/*`
  annotations for non-Kubernetes clients) against a **host-side** CDI spec
  (`/var/run/cdi/nvidia.yaml`, `kind: nvidia.com/pgpu`) to find the VFIO group.
- **guest tier** — the agent resolves a second, **guest-side** CDI spec against
  the container spec. `src/agent/src/rpc.rs`'s `do_create_container` calls
  `handle_cdi_devices(&sl(), &mut oci, "/var/run/cdi", AGENT_CONFIG.cdi_timeout,
  &visible_cdi_devices)`, with the comment:

  > "In guest-kernel mode some devices need extra handling. Taking the GPU as an
  > example the shim will inject CDI annotations that will be used by the
  > kata-agent to do containerEdits according to the CDI spec coming from a
  > registry that is created on the fly by UDEV or other entities for a specifc
  > device. In Kata we only consider the directory `/var/run/cdi`, `/etc` may be
  > readonly"

That second tier is the whole basis of [03](03-guest-side-devices.md).

---

## D) Hooks: the part that does not survive

NVIDIA's CDI spec carries `createContainer` hooks. The most important is
`update-ldcache`, which resolves the container rootfs from the OCI state on
stdin and runs `ldconfig -r <ROOT>` against it so the freshly-mounted driver
libraries are registered in the container's `/etc/ld.so.cache`. It presupposes
that the container rootfs is a host-visible directory. **Under Kata it is not —
it is inside the guest.**

And Kata's hook handling is, by the maintainers' own account, incomplete.
kata issue **#11169**, "Rethink/rework OCI hooks":

> "Host specified hooks (e.g., via NRI injection of CDI devices) are not
> propagated by Go runtime during `CreateContainerRequest` while other
> `containerEdits` added to the `config.json` are."

That is precisely our case: **mounts, devices and env land; the hook is
silently dropped** on the default Go shim. runtime-rs implements
`createContainer` hooks but runs them in the host VMM namespace, where the
container rootfs still is not. kata-agent implements guest-side hook execution
(`src/libs/kata-sys-util/src/hooks.rs`) but reaches it through the *guest*
CDI path, not from a host-injected hooks array.

There is field evidence of the failure mode too: kata issue **#10672** reports
the NVIDIA toolkit hook failing under Kata with
`write /sys/fs/cgroup/devices/.../devices.allow: operation not permitted` while
the identical `config.json` works under plain runc.

### What to do about it

1. **Do not rely on host-side CDI hooks. Assume they are dropped.**
2. **Replace `update-ldcache` with `LD_LIBRARY_PATH`**, which CDI can set via
   `containerEdits.env` and which *is* propagated. Mount the driver libraries at
   a single known path and point `LD_LIBRARY_PATH` at it. This is less elegant
   than a populated ldcache but it needs nothing from Kata.
3. **Or regenerate the spec in the guest.** If the guest already runs
   `nvidia-ctk cdi generate` for the device half (see [03](03-guest-side-devices.md)),
   its `createContainer` hooks reach the agent's own hook execution path, which
   *is* implemented — at the cost of the toolkit having to see the libraries from
   inside the guest, which it can, since they arrive there over virtio-fs.
   **UNVERIFIED:** whether kata-agent actually executes hooks arriving via the
   guest CDI path. Settle by reading `src/libs/kata-sys-util/src/hooks.rs`'s
   callers in `rustjail`, or empirically with a hook that touches a file.
4. `create-symlinks` matters for the same reason and has the same answer.
   `enable-cuda-compat` and `update-application-profile` are optional for
   compute-only workloads; `disable-device-node-modification` is a host-side
   safety hook with no meaning here.

---

## Recommendation

**Split the host CDI spec. Take its `mounts`; do not use its `deviceNodes` for
the container; assume its `hooks` are dropped.**

Concretely, two CDI kinds:

| kind | lives on | requested by | provides |
|---|---|---|---|
| `nvkvm.io/vmm` (new) | the **host**, `/etc/cdi` | the pod sandbox | host `deviceNodes` — solely to put the NVIDIA nodes in the sandbox device cgroup so the VMM can open them ([01 §4(a)](01-vmm-confinement.md)). Also carries the driver-library `mounts`, which become virtio-fs shares. |
| `nvidia.com/gpu` (existing) | the **guest**, `/var/run/cdi` | the workload container | guest `deviceNodes` + `env`, resolved by kata-agent ([03](03-guest-side-devices.md)) |

The host kind is derived mechanically from `nvidia-ctk cdi generate` output —
that is what `scripts/split-cdi-spec.sh` would do. The guest kind is generated
in the guest by the toolkit itself, against the nodes `nvkvm-guest.ko` created.

Requesting the host kind on the **pod sandbox** rather than the workload
container is what keeps host major/minor out of the container's spec.
**UNVERIFIED:** whether a sandbox-level CDI request reaches
`createResourceController` — `handle_cdi_devices` explicitly returns early for
`container_type == "pod_sandbox"` (`src/agent/src/device/mod.rs`), which is the
behaviour we want in the guest, but it does not tell us what the host side does.
This is experiment (2) in [01](01-vmm-confinement.md). If it does not work, the
fallback is to request the host kind on the workload container and strip the
host `deviceNodes` from the spec before it reaches the agent — which *would*
need a Kata change, and is a good reason to try the sandbox route first.
