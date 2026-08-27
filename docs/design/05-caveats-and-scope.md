# 05 — Caveats and scope

The things that would make this a bad idea for a given deployment. Read this
before [00](00-overview.md)'s build plan, not after.

---

## 1. Boot time rules out the fastest half of Kata's market

Kata sells sub-second sandbox starts. This design does not deliver them.

The added cost, in order:

- **Loading `nvkvm-guest.ko`.** It registers character devices, a DRM device and
  a virtual KMS head, probes virtio and negotiates the config feature bits with
  QEMU.
- **Bringing up NVIDIA userspace.** `cuInit` in the container walks
  `/proc/driver/nvidia/params`, `/sys/module/nvidia/initstate` and friends —
  which under nvkvm are *forwarded to the host* over
  `NVKVM_REQ_READ_HOST_FILE` (`nvkvm-pv/src/guest/nvkvm_hostfile.c`) — then
  allocates an RM client, which spawns an isolate process on the host.
- **Guest-side CDI generation**, if `nvidia-ctk cdi generate` runs at boot
  ([03](03-guest-side-devices.md)). This is a fork/exec plus device enumeration.
- **`handle_cdi_devices`' retry loop**, which waits up to `cdi_timeout` seconds
  (default 100) for the spec to appear. In the happy case it costs nothing; in
  the unhappy case it is the thing that makes a slow start look like a hang.

**UNVERIFIED, and it should be measured before anything is promised.** I have
no number for any of these under Kata. nvkvm's own README claims a guest can
"attach to a GPU in under a second — no driver re-initialisation, no device
reset, no `vfio-pci` rebind", and that is a real advantage over passthrough,
but it is about *attach*, not about a container's first CUDA call.
**Experiment:** instrument three timestamps — kata-agent's `create_sandbox`
return, the module's `module_init` completion in the guest dmesg, and the first
successful `cuInit` in the container — on an otherwise-warm node. Report the
deltas, not a single number.

**What this rules out:** FaaS and anything with per-request sandbox creation.
If your workload is "spin a VM, run 200 ms of inference, tear it down", the GPU
bring-up dominates and this design is the wrong tool. What it is *right* for is
the long-lived case: a training job, a model server, a notebook, a CI runner —
anything where the sandbox lives for minutes to days and start latency is
amortised to nothing.

This is not a defect to be fixed later. It is intrinsic: a real NVIDIA driver
stack has to initialise, and it is the same cost bare metal pays.

---

## 2. QEMU only. Firecracker and Cloud Hypervisor cannot work.

nvkvm is **a QEMU device**, not a protocol another VMM could implement cheaply.
`src/qemu/` is ~11 kLoC built into QEMU; it owns the handle table, every
allowlist, the guest-physical address windows, **the KVM memory slots**, and the
isolate processes. The isolate stub is *embedded in the QEMU binary* as a byte
array and launched from an anonymous memfd (`src/stub/Makefile:32-34`,
`src/qemu/nvkvm_isolate.c:803-864`).

The mmap path is the reason this is not portable by accident. A GPU mapping is
established in three places at once — a host `mmap` of the real device fd, a KVM
memory slot exposing those exact physical pages at a guest-physical address, and
a guest `remap_pfn_range` installing that GPA into the calling process's VMA,
with no copy anywhere (`nvkvm-pv/ARCHITECTURE.md`, "Problem 1: the mmap
problem"). Any VMM hosting this has to own its KVM memslots and let a device
model install them dynamically.

Consequences, stated plainly:

- **Firecracker: no.** It does not accept out-of-tree device models, and its
  whole value proposition is the minimal device set nvkvm would have to add to.
- **Cloud Hypervisor: no**, not without a full reimplementation in Rust of
  `src/qemu/` and a second copy of every allowlist. That is not a port.
- **Dragonball: no**, same reason.
- **StratoVirt / others: no.**

So this design is pinned to `hypervisor = qemu` in `configuration.toml`, and
specifically to a **QEMU built with nvkvm's ten patches applied**
(`nvkvm-pv/scripts/build_qemu.sh`, QEMU 9.2.0). Kata ships its own QEMU
(`tools/packaging/qemu`), so the packaging work is "produce a Kata QEMU with the
nvkvm patches" — additive, but a fork of a component Kata builds, which is a
maintenance commitment. It also pins the QEMU version: nvkvm's patches target
9.2.0 and Kata's QEMU version moves independently.

**UNVERIFIED:** whether nvkvm's patches apply cleanly to whichever QEMU version
Kata currently packages. Settle by checking `versions.yaml` `.assets.hypervisor.qemu.version`
against `git apply --check` of `nvkvm-pv/patches/`.

**x86-64 only**, additionally: the isolate stub uses x86-64 assembly, x86-64
syscall numbers, an `AUDIT_ARCH_X86_64` seccomp filter and a CPUID-based
MAXPHYADDR probe (`nvkvm-pv/scripts/build_qemu.sh`). Kata's arm64 and s390x
support is irrelevant here.

### 2a. And QEMU-only means the *least-confined* VMM, not just the biggest one

This is a consequence of §2 that deserves its own statement, because it turns a
compatibility constraint into a security one.

**Most QEMU exploits give code execution in the VMM's host userspace, not in the
KVM kernel module.** A heap overflow in a virtio backend or a use-after-free in
a device reset path lands the attacker inside `qemu-system-x86_64`. At that
moment "there is a VM boundary" has stopped being a mitigation, because the
boundary is the process that was just compromised. Everything then depends on
what confines that process — and for Kata's QEMU driver, measured in
[01 §3](01-vmm-confinement.md), the answer is close to nothing:

- `fc.go` has **46** matches for `jailer|seccomp|chroot` and runs Firecracker
  under the jailer — chroot, netns, cgroups, Firecracker's own seccomp — with
  `jailer_path` set in the shipped `configuration-fc.toml`.
- `clh.go` has **3**, all Cloud Hypervisor's own `--seccomp`, **on by default**.
- `qemu.go` has **3**, all of them plumbing for QEMU's own `-sandbox`, which the
  shipped `configuration-qemu.toml` leaves **empty**.

Upstream's own `docs/design/virtualization.md` scores QEMU "Good" on Security
Isolation against "Excellent" for the other three, and leaves QEMU out of its
"Maximum security isolation" row. Its answer to VMM attack surface is the three
Rust VMMs it offers instead: **make the VMM small, rather than confine the big
one.**

**nvkvm cannot take that exit.** §2 above establishes that nvkvm is a QEMU
device and cannot be ported to Firecracker, Cloud Hypervisor or Dragonball
without a full reimplementation. So:

> **nvkvm-kata necessarily runs in the one Kata configuration with the largest
> VMM attack surface and the least VMM confinement.** It is not a tunable. It is
> the intersection of "nvkvm is a QEMU device" and "Kata confines every VMM
> except QEMU".

Combined with the cgroup v2 device-policy gap measured in
[01 §1.4/§1.6](01-vmm-confinement.md), a QEMU RCE under nvkvm-kata **today**
yields: uid 0, no seccomp, no AppArmor or SELinux, **no device cgroup at all**
(so every host device node opens, `/dev/mem` included), no chroot, the host PID
namespace, and the containerd shim's mount namespace — a copy of the host tree.
The pod network namespace is the only real restriction, and a `/dev/mem` handle
is a route out of that too.

**Call it what it is: a QEMU RCE here is a full host compromise.** Not a
contained one, not "reduced blast radius". That sentence should survive into any
README or deployment guide this project produces.

Three things follow, and none of them is "do not do this":

1. **Set `seccompsandbox`** ([01 §3.3](01-vmm-confinement.md)). It is one config
   line, needs no patch, and is the only lever upstream built for this path.
   The value needs care — Kata's own recommended string contains `spawn=deny`
   and `elevateprivileges=deny`, which are expected to break nvkvm's isolate
   spawn and its `uid` rung.
2. **Do not claim platform confinement the platform does not provide.** The
   original framing of this project — "the VMM gets confined by the container
   platform rather than by nvkvm's own tooling"
   ([00](00-overview.md)) — is **half wrong** for the QEMU path and has been
   corrected there. Kata contributes the pod netns and a cgroup hierarchy; it
   does not contribute VMM sandboxing.
3. **This is the contribution opportunity**, not just the caveat — see
   [00](00-overview.md), "What nvkvm brings that Kata's QEMU path lacks".
   nvkvm's architecture already assumes an untrusted VMM, which is more than
   Kata's QEMU driver assumes.

**UNVERIFIED:** no QEMU CVE was reproduced, and none of this is a claim about
how *often* QEMU device-model bugs occur or how exploitable they are. The claim
is only the conditional one: *if* an attacker achieves code execution in the
VMM, the measured configuration above is what they land in.

---

## 3. nvkvm is not a hardened multi-tenant boundary — and multi-tenancy is Kata's audience

This is the most serious caveat in the document, because it is a direct conflict
between what the technology currently is and what the platform it is being put
into is *for*.

nvkvm says so itself. `nvkvm-pv/SECURITY.md`:

> "**Do not put untrusted tenants behind nvkvm.** It is experimental. The
> guest→host boundary is not yet a security boundary you should rely on, and an
> unprivileged process inside the guest can currently hang the whole VMM.
>
> Run it where you would be comfortable running the guest's workload on the host
> anyway: your own VMs, your own CI, your own experiments. Not multi-tenant
> hosting, not a public sandbox, not anything where the guest is the adversary."

and `nvkvm-pv/README.md`, "What it is not":

> "**Not a hardened multi-tenant sandbox.** The guest/host boundary is not yet a
> security boundary you should rely on … **Do not put untrusted tenants behind
> it.**"

The project publishes its own audits rather than hiding them: a pointer audit
(14 unenforced paths against one invariant, 5 since fixed) and a boundary audit
(19 findings across three trust boundaries, 15 fixed, 4 named as open).

**Kata Containers exists to give untrusted tenants a VM boundary.** That is its
entire pitch. So the honest framing of this project is uncomfortable and should
be said in the README rather than buried:

> Kata's VM boundary is not weakened by nvkvm — the guest still gets no BAR, no
> MMIO window and no DMA path to host memory, which is a *stronger* position
> than PCIe passthrough, where the card retains DMA access to host RAM. What
> nvkvm adds is a **new, wide, ioctl-shaped hole through that boundary**, which
> nine allowlists and a per-process isolate try to hold, and which its own
> authors say is not yet trustworthy against an adversarial guest.

### What that means in practice

- **Do not deploy this as a way to give untrusted Kubernetes tenants a GPU.**
  That is the obvious use and it is the wrong one, today.
- **It is legitimate today for**: a trusted-workload cluster that wants OCI/K8s
  ergonomics and VM-level *fault* isolation rather than VM-level *security*
  isolation; internal CI with GPU; multi-team clusters where the teams are not
  adversaries; and giving a GPU to a workload whose *kernel* you do not trust
  but whose operator you do.
- **The blast radius has NOT moved as much as this document originally claimed
  — corrected after measurement.** The original text said the VMM "is confined
  by the platform: pod network namespace, a cgroup the shim manages, possibly
  `container_kvm_t`", and called that one of the two honest reasons to do the
  project. Measured ([01 §1.4, §2, §3](01-vmm-confinement.md)): the pod network
  namespace is real; the cgroup is real but on cgroup v2 **carries no device
  policy at all**; `container_kvm_t` was absent on both hosts tested; and Kata
  applies no seccomp, no chroot and no uid drop to QEMU, unlike Firecracker
  (§2a). So Kata contributes **one** namespace and a cgroup hierarchy, not a
  sandbox. It still bounds *some* of what a VMM compromise reaches next — the
  netns is not nothing — but "confined by the platform" was too strong and is
  now stated accurately in [00](00-overview.md). Set `seccompsandbox`
  ([01 §3.3](01-vmm-confinement.md)) and the claim gets closer to true.
- **The isolate rung matters and must be asserted, not assumed.** nvkvm's
  isolate sandbox degrades from `namespace` → `uid+chroot` → `uid` → `seccomp`,
  and **`seccomp` alone does not separate isolates from each other**
  (`nvkvm-pv/docs/internal/isolate-model.md`). Under Kata, QEMU is root with no
  seccomp or AppArmor applied by Kata, so `namespace` should be reachable — but
  the project's own guidance is that the only correct test is to attempt the
  `clone()`. Monitor the `isolate-mode-active` QOM property; do not infer it.

---

## 4. Smaller caveats worth stating

- **Scope is compute and headless graphics.** No display path, no display
  broker, no audio, no clipboard, no input. nvkvm's broker
  (`nvkvm-pv/src/broker/`) is explicitly out of scope, which is a simplification
  — it is the one nvkvm component that is not part of the VMM and would need its
  own confinement story under Kata.
- **Pinned host memory is ~40× slower than native** (250–350 MB/s against
  12–17 GB/s) and a single registration is capped at 2 GiB
  (`nvkvm-pv/README.md`). Workloads that pin large host buffers will feel it.
- **Turing or newer.** Pascal enumerates but `cuInit` fails.
- **Guest kernel range 5.15–7.0**, with only 6.8 and 6.1 actually run-tested
  (28/28 on both). Kata's current kernel is well inside the *build* range but
  Kata bumps kernels on its own schedule
  (`versions.yaml` `.assets.kernel.version`), so every bump is a
  build-and-run event for the module, not a no-op.
  **UNVERIFIED:** whether `nvkvm-guest.ko` builds against Kata's current kernel.
  Settle with `make -C nvkvm-pv/src/guest KDIR=<kata kernel build dir>`. This is
  cheap and should be the very first thing tried.
- **Kata's guest kernel has no `CONFIG_MODULES` by default** — see
  [04](04-guest-kernel.md). A stock Kata kernel cannot load this module at all.
- **Multi-GPU** works in nvkvm (`num_gpus` module parameter, clamped to 16) but
  there is no scheduler integration here: [03](03-guest-side-devices.md)'s
  starting mechanism is a container-set environment variable, not a device
  plugin. Capacity accounting is out of scope for the design and would be the
  next thing after it works.
- ~~**The `sandbox_cgroup_only` inversion**~~ — **MEASURED AND DISPROVEN**
  ([01 §1.4.3](01-vmm-confinement.md)). There is no inversion. On cgroup v2 both
  values put QEMU in the same sandbox cgroup, because `AddThread` is
  process-granular there, and that cgroup has no device policy either way. Set
  `sandbox_cgroup_only = true` for the cgroup-leak reason Kata's NVIDIA profile
  gives, not for device reasons. **What replaced it as the live tension** is
  §2a: nvkvm is pinned to the one VMM Kata does not confine.
