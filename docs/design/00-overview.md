# 00 — Overview and build plan

**Status: design only.** Nothing in this repository is runnable.

Upstream citations throughout the design docs are pinned to
`kata-containers/kata-containers` @ **`f62ecce`**,
`cncf-tags/container-device-interface` @ **`23b69d2`**,
`opencontainers/runc` @ **`9674194`**,
`NVIDIA/nvidia-container-toolkit` @ **`b5a4721`**, all shallow-cloned
2026-08-27.

---

## The idea

Run [nvkvm](../../../nvkvm-pv) inside Kata Containers, so that an OCI or
Kubernetes workload gets a real NVIDIA GPU behind a real VM boundary, **without
PCIe passthrough**, while the host keeps using the card — and so that the VMM is
confined by the container platform rather than by nvkvm's own tooling.

Two things make it worth doing:

1. **No passthrough.** The GPU is never unbound from the host driver, never
   rebound to `vfio-pci`, never reset. The host keeps it; several sandboxes can
   share it; consumer GeForce hardware works with no vGPU licence. Kata's
   existing NVIDIA support cannot do any of that — it is VFIO cold-plug, one
   whole GPU per VM, host loses the card.
2. **The VMM gets confined by the platform.** On a workstation nvkvm's QEMU is
   just a process. Under Kata it lands in the pod network namespace, in a cgroup
   the shim manages, potentially under an SELinux domain. That is more
   confinement than nvkvm arranges for itself, and it comes free.

Scope is deliberately narrow: **compute and headless graphics only.** No display
path, no display broker, no audio, no clipboard, no input.

---

## The architecture

```
 ┌─ HOST ─────────────────────────────────────────────────────────────────────┐
 │                                                                            │
 │  kubelet ──► containerd ──► CDI injection (host spec: mounts + deviceNodes) │
 │                    │                                                       │
 │                    ▼                                                       │
 │           containerd-shim-kata-v2                                          │
 │              ├── sandbox cgroup  ◄── must allow /dev/nvidia*  [DOC 01]      │
 │              ├── pod netns                                                 │
 │              ├── virtiofsd  ──► shares host driver libs        [DOC 02]     │
 │              └── QEMU (nvkvm-patched)                                       │
 │                     ├── virtio-nvgpu device                                │
 │                     └── one isolate per guest process ──► NVIDIA driver ──► GPU
 │                                                                     ▲      │
 └─────────────────────────────────────────────────────────────────────┼──────┘
                                    │ virtio                           │
 ┌─ GUEST VM ─────────────────────────────────────────────────────────┼──────┐
 │                                                                    │      │
 │  nvkvm-guest.ko  ──────────────────────────────────────────────────┘      │
 │    creates /dev/nvidiactl, /dev/nvidia0.., /dev/nvidia-uvm, renderD128     │
 │    loaded via kata's `kernel_modules = ["nvkvm-guest"]`         [DOC 04]   │
 │       │                                                                    │
 │  nvidia-ctk cdi generate  ──►  /var/run/cdi/nvidia.yaml (deviceNodes)      │
 │       │                                                                    │
 │  kata-agent: handle_cdi_devices() ──► containerEdits into the OCI spec     │
 │       │        adds linux.devices + linux.resources.devices     [DOC 03]   │
 │       ▼                                                                    │
 │  ┌─ CONTAINER ────────────────────────────────────────────────────────┐   │
 │  │  device nodes bound/mknod'd from the guest's /dev                  │   │
 │  │  host driver libs, arriving over virtio-fs           [DOC 02]      │   │
 │  │  stock libcuda / PyTorch / Vulkan                                  │   │
 │  └────────────────────────────────────────────────────────────────────┘   │
 └───────────────────────────────────────────────────────────────────────────┘
```

### The layering rule that organises the whole design

**Libraries traverse nothing. Device nodes traverse everything.**

CUDA userspace only ever needs to exist in the **container**. Not in the VMM
sandbox, not in the Kata guest rootfs. It goes host → container in one hop, as
virtio-fs-backed CDI mounts. That is why the guest image can stay small and
carry no CUDA at all.

Device files must exist at **every** layer, because each layer's existence
depends on the one below:

| layer | needs | created by |
|---|---|---|
| VMM (host process) | host `/dev/nvidiactl`, `/dev/nvidia*`, `/dev/nvidia-uvm` | the host NVIDIA driver |
| guest root | guest `/dev/nvidia*` | `nvkvm-guest.ko` |
| container | the same, in its own `/dev` | kata-agent |

A host-generated CDI spec therefore has to be **split**: its `mounts` are
portable and wanted; its `deviceNodes` describe host nodes and belong on the
host side only ([01 §4a](01-vmm-confinement.md), [02](02-libraries-via-cdi.md)).

### A benefit that falls out for free

Because CDI supplies **the host's own driver libraries** into the container, and
the host kernel driver is the one servicing every forwarded ioctl, **the
container's driver userspace matches the servicing kernel driver by
construction.** On other nvkvm deployments this matching is a real piece of
machinery (`make_host_bundle.sh`, `stage_guest_libs.sh`, and a silent
`cuInit` → 803 when it is wrong). Under Kata it disappears entirely. This is a
genuine architectural advantage of running nvkvm inside an OCI platform, not a
convenience.

---

## What the research found, in one table

| question | answer | doc |
|---|---|---|
| What confines the VMM? | Only the network namespace, plus a cgroup whose **device policy Kata builds itself** as a targeted allowlist that does **not** include the NVIDIA nodes. Root, no seccomp, no AppArmor, SELinux only if the distro ships `container-selinux`. | [01](01-vmm-confinement.md) |
| Can the VMM open `/dev/nvidia*`? | **Not by default.** Needs explicit grant. Best route is a host CDI spec whose `deviceNodes` land in the sandbox cgroup — no Kata patch. | [01](01-vmm-confinement.md) |
| How do host libraries reach the container? | CDI `mounts` → ordinary OCI mounts → virtio-fs. Works today. CDI **hooks are silently dropped** by Kata's Go shim (kata #11169), so `update-ldcache` must be replaced by `LD_LIBRARY_PATH` or regenerated in the guest. | [02](02-libraries-via-cdi.md) |
| How do guest-created nodes reach the container? | kata-agent **already** applies CDI specs found in the guest's `/var/run/cdi` (`handle_cdi_devices`), and the CDI library emits the cgroup allow rule from the deviceNodes entry. This was expected to be novel; it is not. | [03](03-guest-side-devices.md) |
| Bind or mknod in the guest? | rustjail has `bind_dev`, but only on the user-namespace path and with no `EPERM` fallback (runc has both). mknod works today; bind is better and is a ~6-line change. | [03](03-guest-side-devices.md) |
| How does `nvkvm-guest.ko` get into the guest? | Mirror `build-kernel.sh -g nvidia`, which already builds an out-of-tree NVIDIA module against Kata's kernel and `modules_install`s it. Ship via `KERNEL_MODULES_DIR`, load via `kernel_modules = [...]`. **Kata's stock kernel has no `CONFIG_MODULES`** and no `CONFIG_DRM`. | [04](04-guest-kernel.md) |
| What are the deal-breakers? | Boot time (rules out FaaS), QEMU-only (Firecracker and Cloud Hypervisor cannot work), and nvkvm's own statement that it is not a hardened multi-tenant boundary — which is Kata's whole audience. | [05](05-caveats-and-scope.md) |

---

## The asymmetry that drives the plan

**The guest half is largely proven. The host half is the unknown.**

On the guest side, three independent pieces of evidence say the mechanism
already works:

1. `nvidia-container-toolkit` has been **tested inside an nvkvm guest and
   works** — `docker run --gpus all` gives a container GPU access, and
   `nvidia-smi` process enumeration is namespace-correct
   (`nvkvm-pv/README.md`, "Containers"). The cgroup gating is therefore proven
   against nvkvm's nodes, with no driver involvement at that layer.
2. kata-agent **already resolves CDI specs that exist only in the guest**, and
   the CDI library emits `linux.resources.devices` allow rules from
   `deviceNodes` entries automatically.
3. Kata ships an end-to-end guest-side GPU CDI flow (NVRC + `nvidia-ctk cdi
   generate` in the guest + `handle_cdi_devices`) as a supported feature. Only
   the thing that makes the GPU appear differs.

On the host side, nothing is proven. Kata's shim builds the sandbox device
cgroup from a fixed list plus the OCI spec, and `/dev/nvidia*` is not on that
list. Whether the proposed fix works depends on facts nobody has measured:
which cgroup the QEMU main thread ends up in for each `sandbox_cgroup_only`
value, whether the overhead cgroup is device-unrestricted, and which OCI spec
feeds `createResourceController`.

**So the riskiest unknown is: can the Kata hypervisor process open the host's
`/dev/nvidiactl` and `/dev/nvidia*` under containerd/Kubernetes, and by what
supported configuration?** Everything else is downstream of it, and it is
cheap to answer.

---

## Build plan, riskiest first

### Phase 0 — settle the host device-cgroup question (days)

Nothing else is worth starting until this is known.

1. Stand up a node with containerd + Kata + QEMU + an NVIDIA driver. Run a
   plain Kata pod. Find the QEMU pid, dump `/proc/<pid>/cgroup`, and dump the
   device policy — `devices.list` on v1, `bpftool cgroup show` + `prog dump
   xlated` on v2 — for **both** `sandbox_cgroup_only` values. Then attempt the
   open from that cgroup. (`scripts/check-vmm-device-access.sh` is the stub.)
2. Write a minimal host CDI spec, `kind: nvkvm.io/vmm`, whose `deviceNodes` are
   the NVIDIA nodes and whose `mounts` are the driver libraries. Request it on a
   pod. Re-dump. Determine whether the rules reached the sandbox cgroup, and
   whether requesting it on the **pod sandbox** vs the workload container
   changes the answer.
3. Check `/proc/<qemu-pid>/attr/current` and `semodule -l | grep container`.
   Decide whether SELinux is a second gate.

**Exit criterion:** a documented, reproducible configuration in which a Kata
QEMU process successfully `open()`s `/dev/nvidiactl`. If none exists without a
Kata patch, the fallback is the two-line addition to `sandboxDevices()` — and
that decision, made here, determines whether this project needs upstream work at
all.

### Phase 1 — nvkvm in a Kata-shaped QEMU, by hand (1–2 weeks)

Still no Kata involved; de-risk the packaging.

4. `make -C nvkvm-pv/src/guest KDIR=<kata kernel build dir>` — does the module
   even build against Kata's current kernel? Cheapest possible test.
5. `git apply --check nvkvm-pv/patches/*` against the QEMU version Kata packages
   (`versions.yaml` `.assets.hypervisor.qemu.version`). If they do not apply,
   scope the rebase now rather than in phase 3.
6. Build a Kata guest kernel with a `CONFIG_MODULES` + `CONFIG_DRM` fragment and
   the module built out-of-tree, per [04](04-guest-kernel.md) option 2. Boot it
   under a hand-rolled QEMU command line with `-device virtio-nvgpu-pci` and
   confirm `/dev/nvidia*` appears. `depmod` is the trap here.

### Phase 2 — the guest half, end to end (1–2 weeks)

7. In that guest, run `nvidia-ctk cdi generate` and see what it emits on a
   system with device nodes but **no** driver libraries. This decides how much
   post-processing the guest spec needs.
8. Bring the real Kata stack up with `kernel_modules = ["nvkvm-guest"]` and
   `agent.visible_cdi_devices=true` via `kernel_params`, and run a container
   with `VISIBLE_CDI_DEVICES=nvidia.com/gpu=0`. Verify the container's device
   cgroup and `/dev` contents in the guest.
9. Verify the library half: driver libs shared over virtio-fs, `LD_LIBRARY_PATH`
   set from CDI `env`. Check that a versioned `.so` symlink chain survives
   virtio-fs — the one unverified risk in [02](02-libraries-via-cdi.md).

**Exit criterion:** `nvidia-smi` inside an OCI container inside a Kata VM.

### Phase 3 — packaging (2–4 weeks)

10. Kata QEMU with the nvkvm patches, as a build variant.
11. `build-kernel.sh` fragment + out-of-tree module step; `KERNEL_MODULES_DIR`
    into the rootfs; a `configuration-qemu-nvkvm.toml` profile.
12. The `nvkvm.io/vmm` host CDI spec, generated from
    `nvidia-ctk cdi generate` output — `scripts/split-cdi-spec.sh`.

### Phase 4 — upstream, if warranted (open-ended)

13. Port runc's `EPERM` → bind fallback into rustjail's `create_devices`
    ([03](03-guest-side-devices.md)). Small, framed as an alignment fix.
14. A second annotation source next to `annotateContainerWithVFIOMetadata`, so
    GPU requests are orchestrator-driven rather than container-driven.
15. The NVIDIA nodes in `sandboxDevices()`, if phase 0 concluded they are needed
    there.

Note the ordering: **nothing upstream is attempted until phases 0–2 have shown
the design works with shipped code.** On current evidence it can.

---

## Does this need an upstream Kata patch?

**Probably not to work; probably yes to be good.**

The whole guest-side path — in-guest CDI resolution, cgroup allow rules, device
node creation, module loading — is shipped Kata functionality reachable from
`configuration.toml`, kernel parameters and one container environment variable.
The host-side path *may* be reachable through a CDI spec alone; phase 0 decides.

Patches are wanted for bind-instead-of-mknod, for orchestrator-driven device
requests, and possibly for `sandboxDevices()`. All three are small and land in
code Kata already maintains for NVIDIA GPUs. None of them gates a working
prototype.

---

## What would kill this project

In rough order of likelihood:

- **Phase 0 finds no supported configuration** that lets the VMM open the nodes,
  and the `sandboxDevices()` patch is rejected upstream. This is survivable via
  a fork but stops being "confined by the platform" and starts being "a fork of
  the platform".
- **The security framing does not hold.** If the intended audience is untrusted
  multi-tenancy, [05 §3](05-caveats-and-scope.md) says do not ship. That is a
  positioning decision, not an engineering one, and it should be made before
  phase 1, not after phase 4.
- **Boot time turns out to be tens of seconds** rather than a few, narrowing the
  workload set to the point where a plain VM would do.
- **Kata's QEMU version drifts far from 9.2.0**, turning the patch rebase into
  ongoing work with no natural end.
