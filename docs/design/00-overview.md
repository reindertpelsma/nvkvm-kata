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
PCIe passthrough**, while the host keeps using the card.

(The original framing continued "…and so that the VMM is confined by the
container platform rather than by nvkvm's own tooling". That half has been
measured and largely does not hold — see reason 2 below and
"What nvkvm brings that Kata's QEMU path lacks".)

Two things make it worth doing:

1. **No passthrough.** The GPU is never unbound from the host driver, never
   rebound to `vfio-pci`, never reset. The host keeps it; several sandboxes can
   share it; consumer GeForce hardware works with no vGPU licence. Kata's
   existing NVIDIA support cannot do any of that — it is VFIO cold-plug, one
   whole GPU per VM, host loses the card.
2. ~~**The VMM gets confined by the platform.**~~ **This was reason 2, and
   measurement has largely taken it away — read the correction, it changes the
   project's positioning.** The claim was that under Kata the VMM lands in the
   pod network namespace, a cgroup the shim manages and possibly an SELinux
   domain, and that this is more confinement than nvkvm arranges for itself.
   What is actually there: the pod netns (real), a cgroup that on cgroup v2
   **carries no device policy at all** ([01 §1.6](01-vmm-confinement.md)), no
   SELinux on either host tested, and — because Kata jails Firecracker but not
   QEMU — no seccomp, no chroot and no uid drop ([01 §3](01-vmm-confinement.md)).
   Since nvkvm is QEMU-only, it is pinned to the one Kata configuration with the
   largest VMM attack surface and the least VMM confinement.
   **The honest version of reason 2 is the reverse**, and it is a better reason:
   nvkvm's architecture already assumes an untrusted VMM, so this project is
   positioned to *contribute* the VMM confinement Kata's QEMU path lacks rather
   than to consume it. See "What nvkvm brings that Kata's QEMU path lacks"
   below.

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

## What nvkvm brings that Kata's QEMU path lacks

This section exists because reason 2 above was **wrong in the direction that
matters**, and correcting it inverts the relationship between the two projects
on one axis.

### The problem, stated once

Most QEMU exploits give code execution in the **VMM's host userspace**, not in
the KVM kernel module. Once that happens, "there is a VM boundary" has stopped
being a mitigation: the boundary is the process that was just compromised. What
matters is what still confines that process.

Kata knows this, and its answer for the QEMU path is to have no answer. Measured
and cited in [01 §3](01-vmm-confinement.md): `fc.go` runs Firecracker under the
**jailer** (chroot, netns, cgroups, Firecracker's own seccomp; `jailer_path` set
in the shipped config), `clh.go` turns on Cloud Hypervisor's **own seccomp by
default**, and `qemu.go` contains nothing but three lines plumbing QEMU's
`-sandbox` — which ships **empty**. Upstream's own hypervisor comparison rates
QEMU "Good" on security isolation against "Excellent" for the other three and
omits it from the "maximum security isolation" row. The strategy is legible and
coherent: **make the VMM small, do not confine the big one.** All three
alternatives are Rust.

**nvkvm cannot take that exit**, because nvkvm *is* a QEMU device
([05 §2](05-caveats-and-scope.md)). So nvkvm-kata necessarily runs in the one
Kata configuration with the largest VMM attack surface and the least VMM
confinement. Combined with the measured cgroup v2 device-policy gap
([01 §1.6](01-vmm-confinement.md)), a QEMU RCE here today is **a full host
compromise**: root, no seccomp, no device cgroup, host PID namespace, and a
`/dev/mem` handle available. That is stated plainly in
[05 §2a](05-caveats-and-scope.md) and should not be softened anywhere.

### The inversion: nvkvm already assumes the VMM is untrusted

Kata's QEMU driver treats the VMM as trusted. **nvkvm does not**, and has not
for two components that already exist:

- **Per-guest-process isolates.** nvkvm does not run the NVIDIA ioctls in QEMU.
  It spawns one **isolate process per guest process** and sandboxes it on a
  degradation ladder — `namespace` (namespaces + `pivot_root` + seccomp) →
  `uid` (unique high UID/GID + seccomp) → `uid+chroot` → `seccomp` → `none`,
  which refuses to start without an explicit acknowledgement
  (`nvkvm-pv/docs/internal/isolate-model.md`, "Isolation modes"). The device
  nodes that matter — `/dev/nvidiactl`, `/dev/nvidiaN`, `/dev/dri/renderD128`,
  `/dev/nvidia-modeset` — are opened **inside the isolate**, not by QEMU
  (*ibid.*, "Who opens what"), so QEMU itself holds only `/dev/nvidia-uvm`.
- **The display broker.** A separate privileged process owns the window, the
  input and the clipboard specifically so the VMM never holds a display-server
  connection: *"QEMU hands it finished frames over a unix socket and holds no
  connection to your display server at all"*, and its test harness has
  `--bad-*` options enumerating *"the ways a hostile VMM can lie"*
  (`nvkvm-pv/src/broker/README.md`). The broker's own README says the design is
  pointless unless the VMM is sandboxed — i.e. it was built for exactly the
  threat model Kata's QEMU path does not have.

So on **this specific axis** — is the VMM treated as a thing that might be
compromised — nvkvm is **ahead** of Kata's QEMU path, not behind it.

Two honest limits on that claim, because it is easy to overstate:

- It is one axis. On the axis that [05 §3](05-caveats-and-scope.md) is about —
  is the *guest→host ioctl surface* a boundary you can trust — nvkvm's own
  SECURITY.md says no. Being ahead on VMM confinement does not make the project
  ready for untrusted tenants, and these two facts must be quoted together or
  neither.
- The broker is **explicitly out of scope** for this design
  ([05 §4](05-caveats-and-scope.md)), so the second bullet is evidence about
  nvkvm's architecture and posture, not a component nvkvm-kata ships.

### So this project can contribute, not only consume

The original pitch was that nvkvm-kata takes Kata's confinement for free. On the
device-cgroup and VMM-sandboxing axes it takes very little, and it is positioned
to **supply** what is missing. Three candidate contributions, cheapest first,
with an honest read on whether upstream would take them:

**1. Fix the cgroup v2 device gap.** `containerd/cgroups` `v2.ToResources()`
never assigns `Resources.Devices`, so Kata's whole sandbox device allowlist is
discarded on every cgroup v2 host ([01 §1.6](01-vmm-confinement.md)).
*Plausibility: high.* It is a real bug with a measured reproducer, it is
security-relevant, and it is not an nvkvm feature request — anyone running Kata
on a modern distro is affected. **This should be reported regardless of whether
nvkvm-kata ever ships.** Caveat: fixing it is what *creates* our device-access
problem, so route (a) — the host CDI spec — has to exist first
([01 §4a](01-vmm-confinement.md)).

**2. Plumb QEMU's own `-run-with chroot=…,user=…`.** QEMU already supports a
chroot and a uid/gid drop natively: `-run-with [async-teardown=on|off]
[,chroot=dir][,exit-with-parent=on|off][,user=username|uid:gid]`, verified
present in the QEMU Kata ships (4.1.0 release binary). **Kata does not plumb it
at all** — zero matches for `run-with`/`RunWith` in `src/runtime` outside vendor.
The work is the same shape as the existing `seccompsandbox` plumbing, which is
three lines in `qemu.go` plus a govmm `append` plus a config key
(`katautils/config.go:107`, `govmm/qemu/qemu.go:3121-3125`).
*Plausibility: moderate-to-high.* It is small, additive, opt-in, off by default,
and uses a QEMU feature rather than inventing machinery. It would close the
chroot and uid-drop half of the gap for **every** Kata QEMU user, not just us.
**UNVERIFIED:** whether nvkvm survives it — a chroot changes what the isolate
spawn path can reach, and nvkvm's own `uid+chroot` rung already does
`chroot("/dev")` for the isolate, so the interaction needs measuring, not
assuming.

**3. A jailer-equivalent for the QEMU driver.** `fc.go` already contains the
machinery — `chrootBaseDir`/`jailerRoot` (`:151-152`, `:240-243`), resource
copying into the jail (`fcJailResource`), a remount-with-exec step
(`fcRemountJailerRootWithExec`, `:531-541`), and teardown that unmounts the
jail root (`:925-929`). *Plausibility: low as a straight reuse*, because that
code drives the **Firecracker** `jailer` binary with Firecracker-specific
arguments (`--exec-file`, `--api-sock`), so what transfers is the pattern, not
the code. It is also worth noting that Kata does **not** drop uid even for
Firecracker: `fc.go:382-383` passes `--uid 0 --gid 0`, citing
kata-containers/runtime#1869. So "port the jailer" is a larger and less
obviously welcome change than (2), and (2) delivers most of the same value.

The immediate, no-patch action while any of that is discussed is
[01 §3.3](01-vmm-confinement.md): **set `seccompsandbox`.** Measured values,
traps and the nvkvm conflict are there.

---

## What the research found, in one table

| question | answer | doc |
|---|---|---|
| What confines the VMM? | The network namespace, the shim's mount namespace, and a cgroup whose **device policy Kata builds itself** as a targeted allowlist that does **not** include the NVIDIA nodes — except that **on cgroup v2 that policy is never installed** (MEASURED). Root, no seccomp, no AppArmor, SELinux only if the distro ships `container-selinux` (measured absent on Ubuntu). | [01](01-vmm-confinement.md) |
| Can the VMM open `/dev/nvidia*`? | **MEASURED: yes, on cgroup v2, unconfigured, for both `sandbox_cgroup_only` values** — confirmed on a real RTX 3060 with driver 575.51.03, for both the Go and Rust runtimes. Not because Kata allows it: because `containerd/cgroups` `v2.ToResources()` drops the device list, so nothing is enforced (`/dev/mem` opens too). Expect this to be fixed; build route (a) — a host CDI spec whose `deviceNodes` land in the sandbox cgroup — anyway. | [01](01-vmm-confinement.md) |
| How do host libraries reach the container? | CDI `mounts` → ordinary OCI mounts → virtio-fs. Works today. CDI **hooks are silently dropped** by Kata's Go shim (kata #11169), so `update-ldcache` must be replaced by `LD_LIBRARY_PATH` or regenerated in the guest. | [02](02-libraries-via-cdi.md) |
| How do guest-created nodes reach the container? | kata-agent **already** applies CDI specs found in the guest's `/var/run/cdi` (`handle_cdi_devices`), and the CDI library emits the cgroup allow rule from the deviceNodes entry. This was expected to be novel; it is not. | [03](03-guest-side-devices.md) |
| Bind or mknod in the guest? | rustjail has `bind_dev`, but only on the user-namespace path and with no `EPERM` fallback (runc has both). mknod works today; bind is better and is a ~6-line change. | [03](03-guest-side-devices.md) |
| How does `nvkvm-guest.ko` get into the guest? | Mirror `build-kernel.sh -g nvidia`, which already builds an out-of-tree NVIDIA module against Kata's kernel and `modules_install`s it. Ship via `KERNEL_MODULES_DIR`, load via `kernel_modules = [...]`. **Kata's stock kernel has no `CONFIG_MODULES`** and no `CONFIG_DRM`. | [04](04-guest-kernel.md) |
| What confines the VMM *process*, if it is exploited? | **Almost nothing, and by design.** Kata jails Firecracker (`fc.go`, 46 jailer/seccomp/chroot matches) and enables Cloud Hypervisor's seccomp by default, but the QEMU driver has 3 matches, all plumbing for QEMU's `-sandbox`, which ships empty. A QEMU RCE here is a full host compromise today. Mitigation that needs no patch: set `seccompsandbox`. | [01 §3](01-vmm-confinement.md), [05 §2a](05-caveats-and-scope.md) |
| What are the deal-breakers? | Boot time (rules out FaaS), QEMU-only (Firecracker and Cloud Hypervisor cannot work) — which also pins us to the least-confined VMM — and nvkvm's own statement that it is not a hardened multi-tenant boundary, which is Kata's whole audience. | [05](05-caveats-and-scope.md) |

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

**ANSWERED, 2026-08-27 — see [01 §1.4](01-vmm-confinement.md).** On cgroup v2 it
can, unconfigured, for both `sandbox_cgroup_only` values, on both Kata runtimes,
verified against a real GPU and driver. The device policy Kata computes is
discarded by `containerd/cgroups` `v2.ToResources()` and never attached, so the
sandbox cgroup restricts nothing at all (`/dev/mem` opens from it). **Phase 0 is
therefore not blocking, and phases 1 and 2 can start now** — but the gate is
open by accident, a counterfactual run shows Kata's intended policy would deny
these exact nodes, and route (a) should still be built because it is the only
answer that is correct on cgroup v1 and survives the eventual fix.

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

**Exit criterion — MET for cgroup v2.** `scripts/check-vmm-device-access.sh`
is the documented, reproducible experiment, and on a cgroup v2 host the answer
is that no configuration is needed at all. Steps 1 and (partly) 3 above are
done; step 2 — proving the CDI route actually reaches the sandbox cgroup —
has **not** been run and is now the remaining Phase 0 work, together with a
cgroup v1 host. Original wording follows.

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
15. ~~The NVIDIA nodes in `sandboxDevices()`~~ — **phase 0 concluded no.** On
    cgroup v2 that patch is inert, because the list it appends to is discarded
    ([01 §1.6](01-vmm-confinement.md)). It only becomes meaningful after 16.
16. **The cgroup v2 device gap** — `containerd/cgroups` `v2.ToResources()` never
    assigns `Resources.Devices`, so Kata's sandbox device allowlist is silently
    dropped on every cgroup v2 host. **Report this regardless of whether
    nvkvm-kata ships**; it is a security-relevant bug affecting all Kata users,
    with a measured reproducer in `scripts/check-vmm-device-access.sh`.
17. **Plumb QEMU's `-run-with chroot=…,user=…`** into the QEMU driver, mirroring
    the existing `seccompsandbox` plumbing — the chroot and uid-drop QEMU
    already supports and Kata does not expose. See "What nvkvm brings that
    Kata's QEMU path lacks" above.

Note the ordering: **nothing upstream is attempted until phases 0–2 have shown
the design works with shipped code** — with one exception, item 16, which is a
bug report rather than a feature and should not wait. On current evidence the
rest can.

Note also that 16 and route (a) are **coupled in the other direction**: fixing
16 is what re-closes the device gate we currently walk through, so the host CDI
spec has to exist before, or with, the report.

---

## Does this need an upstream Kata patch?

**Probably not to work; probably yes to be good.**

The whole guest-side path — in-guest CDI resolution, cgroup allow rules, device
node creation, module loading — is shipped Kata functionality reachable from
`configuration.toml`, kernel parameters and one container environment variable.
The host-side path *may* be reachable through a CDI spec alone; phase 0 decides.

Patches are wanted for bind-instead-of-mknod, for orchestrator-driven device
requests, for the **cgroup v2 device gap** (a plain bug, and the one item that
should not wait for a prototype), and for **plumbing QEMU's own `-run-with
chroot=…,user=…`**, which is the smallest credible answer to Kata leaving its
QEMU driver unconfined while jailing Firecracker. All are small and land in code
Kata already maintains. None of them gates a working prototype.

`sandboxDevices()` has been **removed** from that list: phase 0 measured that on
cgroup v2 it would change nothing.

The last two are the interesting ones, because they are not nvkvm features —
they are gaps that affect every Kata QEMU user, and this project is simply the
thing that found them.

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
  phase 1, not after phase 4. **This got harder, not easier, after measurement:**
  the "confined by the platform" half of the pitch is largely gone
  ([01 §3](01-vmm-confinement.md)), and being QEMU-only pins the project to the
  one VMM Kata does not confine ([05 §2a](05-caveats-and-scope.md)). The
  remaining honest version — that nvkvm is *ahead* of Kata's QEMU path on VMM
  confinement and can contribute to it — is a better story but a harder sell,
  because it asks the reader to accept a criticism of the platform first.
- **Boot time turns out to be tens of seconds** rather than a few, narrowing the
  workload set to the point where a plain VM would do.
- **Kata's QEMU version drifts far from 9.2.0**, turning the patch rebase into
  ongoing work with no natural end.
