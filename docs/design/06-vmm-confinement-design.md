# 06 — Confining the QEMU VMM: options, capability analysis, and a recommendation

[01](01-vmm-confinement.md) measured what Kata does to the QEMU process today
and found the answer is close to nothing. [05 §2a](05-caveats-and-scope.md)
established that nvkvm cannot escape into a smaller VMM, because nvkvm *is* a
QEMU device. This document decides what to do about it.

**It is a decision document, not an implementation.** Everything in it that says
MEASURED was run on 2026-08-27 on the test host described in
[§8](#8-reproduction); everything else is marked UNVERIFIED with the experiment
that would settle it.

---

## 0. The recommendation, up front

> **Ship a small PID-preserving wrapper binary at `hypervisor.qemu.path` that
> puts QEMU in a *user namespace* — mapping a per-sandbox window of unprivileged
> host uids — and then `exec()`s the real `qemu-system-x86_64`.** No Kata patch,
> no upstream negotiation, no change to how Kata waits on, cgroups, or kills the
> VMM. Combine it with `seccompsandbox = "on,obsolete=deny,resourcecontrol=deny"`
> and leave `NVKVM_ISOLATE_MODE=auto`.

**The SETUID tension dissolves rather than being traded off.** Inside that user
namespace QEMU holds `CAP_SETUID`, `CAP_SETGID`, `CAP_SETPCAP` and
`CAP_SYS_CHROOT` — the exact four the steamos compose grants
(`nvkvm-steamos/docker-compose.yml:153`) — with a **full** capability set, so
every nvkvm isolate rung including `namespace` is available; and an attacker who
reaches `setuid(0)` from a QEMU RCE lands on namespace-uid 0, which is an
*unprivileged host uid* that owns nothing. Measured end to end
([§4.3](#43-option-2--a-wrapper-binary-at-hypervisorqemupath--recommended)).

**The single biggest risk** is not the confinement mechanism, it is whether
nvkvm's GPU path still works when QEMU is no longer host-root: the NVIDIA
driver's own privilege checks, `RLIMIT_MEMLOCK` on pinned host memory, and the
handful of absolute host paths Kata hands QEMU by *name* rather than by *fd*.
That is Phase-1 work and is named as such in [§7](#7-risks-and-open-questions).

---

## 1. What this document adds to 01

Ten things were measured this round that 01 did not have. They are listed here
because several of them change the answer.

| # | finding | where |
|---|---|---|
| 1 | nvkvm's `namespace` rung needs **no `CAP_SETUID`**. At uid 0 the minimal effective set is exactly **{`CAP_SYS_ADMIN`, `CAP_SETFCAP`}** | [§3.2](#32-what-each-rung-actually-requires--measured) |
| 2 | `CAP_SETFCAP` is required *only because QEMU is uid 0* — it is the Linux-5.12 rule in `user_namespaces(7)` about mapping parent-UID 0 | [§3.2](#32-what-each-rung-actually-requires--measured) |
| 3 | With **`CAP_SYS_ADMIN` but not `CAP_SETFCAP`**, nvkvm's `auto` probe reports `namespace` AVAILABLE and every real isolate spawn then fails. A **fail-open gap in the probe** | [§3.3](#33-a-probe-gap-in-nvkvm-fail-open-in-one-narrow-configuration) |
| 4 | uid 0 with an **empty capability set and empty bounding set** can still write `/etc/shadow`, `/etc/passwd`, `/etc/ld.so.preload` and `/etc/cron.d/` | [§3.5](#35-quantifying-uid-0-with-a-restricted-bounding-set--measured) |
| 5 | Therefore, at uid 0, granting `CAP_SETUID` gives an attacker **almost nothing they did not already have** — the tension as posed is largely a false one | [§3.6](#36-resolving-the-setuid-tension) |
| 6 | QEMU's `spawn=deny` blocks `clone(CLONE_NEWUSER)` **by flag**, `clone3` with `ENOSYS`, and `execveat` with `SCMP_ACT_KILL`. It is incompatible with **every** nvkvm rung, not just the uid ones | [§4.1](#41-option-0--qemus-own--sandbox-seccompsandbox) |
| 7 | `elevateprivileges` uses `SCMP_ACT_TRAP` (SIGSYS), not `EPERM`; and `children` is no weaker than `deny` in the filter | [§4.1](#41-option-0--qemus-own--sandbox-seccompsandbox) |
| 8 | The `elevateprivileges=children` failure 01 measured is an **upstream QEMU bug**, reproduced under `strace`, with a one-line fix | [§4.1](#41-option-0--qemus-own--sandbox-seccompsandbox) |
| 9 | `-run-with chroot=` works on Kata's shipped QEMU; **`-run-with user=` segfaults it**, because Kata builds QEMU `static-pie` and `os_set_runas()` always calls `getpwnam()` | [§4.2](#42-option-1--qemus-own--run-with-chroot--user) |
| 10 | A seccomp filter of QEMU's shape costs **≈ +61 ns per syscall (+28 % on a trivial `ioctl`)** with the BPF JIT on | [§4.1](#41-option-0--qemus-own--sandbox-seccompsandbox) |

---

## 2. The threat model, in one paragraph

A guest-triggered bug in a QEMU device model gives the attacker code execution
*inside the `qemu-system-x86_64` process on the host*. The VM boundary is gone
at that instant, because the boundary is the process that was compromised. Under
Kata today that process is uid 0, unconfined by AppArmor/SELinux, in the host
PID namespace, in the containerd shim's copy of the host mount tree, with no
seccomp filter and — on cgroup v2 — **no device policy at all**
([01 §1.4, §3.2](01-vmm-confinement.md)). The question this document answers is:
what is the cheapest change that makes that outcome *not* a full host
compromise, without breaking nvkvm.

Two nvkvm-specific aggravations, both from
[`isolate-model.md`](../../../nvkvm-pv/docs/internal/isolate-model.md):

- QEMU itself holds `/dev/nvidia-uvm` open ("Who opens what"), and UVM ioctls
  execute in QEMU's process rather than in an isolate. A QEMU RCE inherits that
  fd and does **not** pass the UVM schema allowlist.
- QEMU holds the KVM vm fd and every memory-backend fd. This is why nvkvm closes
  them before `exec`ing a stub (`nvkvm-pv/src/qemu/nvkvm_isolate.c:423-429`:
  "turning any stub RCE into 'set arbitrary host memory region visible to the
  guest' via `KVM_SET_USER_MEMORY_REGION`"). The same logic applies one level up:
  whatever confines QEMU must assume QEMU's fds are the attacker's fds.

---

## 3. The capability analysis, and the SETUID tension

### 3.1 nvkvm's isolate ladder, enumerated

From `nvkvm-pv/docs/internal/isolate-model.md:181-186` and the source
(`src/qemu/nvkvm_isolate_uid.h`, `src/qemu/nvkvm_isolate.c`), nvkvm-pv @
`084df49`:

| rung | layers applied to the isolate | documented requirement |
|---|---|---|
| `auto` (default) | probes the ladder, never selects `none` | nothing |
| `namespace` | `CLONE_NEWUSER\|NEWPID\|NEWNET\|NEWIPC\|NEWUTS\|NEWNS`, tmpfs root holding only `/dev/nvidia*`, `pivot_root`, RO remount, cap teardown, fd close, seccomp | "`CAP_SYS_ADMIN`, **or** a userns not blocked by seccomp/AppArmor" (`:182`) |
| `uid` | unique host uid/gid per isolate + cap teardown + fd close + seccomp | `CAP_SETUID` + `CAP_SETGID` (`:183`) |
| `uid+chroot` | as `uid`, plus `chroot("/dev")` and a post-chroot dirfd | the above + `CAP_SYS_CHROOT` (`:184`) |
| `seccomp` | the 20-syscall TSYNC allowlist only | nothing (`:185`) |
| `none` | nothing | explicit acknowledgement (`:186`) |

The clone flags are at `src/qemu/nvkvm_isolate.c:260`; the rootless map the
parent writes is `"0 %u 1\n"` of its own euid at `:193`/`:201`, with
`setgroups: deny` first at `:186`. The uid window is 4096 slots
(`NVKVM_ISO_UID_SLOTS`, `src/qemu/nvkvm_isolate_uid.h:188`).

**Per-guest-process boundary each rung yields** — the honest comparison is
already written up at `isolate-model.md:305-330` and is not repeated here. The
one row that decides deployments: `seccomp` alone **does not separate isolates
from each other** (same uid, same namespaces, same filesystem), so it is not an
acceptable resting place for a multi-guest-process workload.

### 3.2 What each rung actually requires — MEASURED

`isolate-model.md:182` says `namespace` requires "`CAP_SYS_ADMIN`, or a userns
not blocked by seccomp/AppArmor". That is right but under-specified, and the
under-specification matters, because the obvious jail design ("keep four caps,
drop the rest") is decided by it.

A C program replicating `nvkvm_iso_probe_namespaces()`
(`src/qemu/nvkvm_isolate_uid.h:428`) **and** the real spawn's parent-side map
write was run at uid 0 under `capsh` with various effective/bounding sets, on the
host in [§8](#8-reproduction) (kernel `7.0.0-29-generic`,
`kernel.apparmor_restrict_unprivileged_userns = 1`):

| effective capabilities (uid 0) | `auto` probe says | real spawn (clone + `uid_map` write + tmpfs mount) |
|---|---|---|
| full set | AVAILABLE | **OK** |
| **`CAP_SYS_ADMIN` + `CAP_SETFCAP`** | AVAILABLE | **OK** |
| `CAP_SYS_ADMIN` only | AVAILABLE | **FAILS — `uid_map` write: `EPERM`** |
| `CAP_SETUID,CAP_SETGID,CAP_SYS_CHROOT` | unavailable | FAILS |
| **none** (`CapEff=0`, `CapBnd=0`) | unavailable | FAILS (`uid_map` write: `EPERM`) |
| non-root (uid 65534) | unavailable | FAILS (mount: `EACCES`) |

Three conclusions, and the first is the one that reframes the whole task:

1. **`namespace` mode needs no `CAP_SETUID`, no `CAP_SETGID`, no
   `CAP_SYS_CHROOT`.** The row that works carries none of them.
2. **`CAP_SETFCAP` is required, and only because QEMU is uid 0.** The rootless
   map nvkvm writes is `0 <euid> 1` (`nvkvm_isolate.c:193`); with `euid == 0`
   that maps UID 0 in the parent namespace, which since Linux 5.12 requires
   `CAP_SETFCAP` in the parent namespace — `user_namespaces(7)`, "In order for a
   process to write to the `/proc/pid/uid_map` file … If updating
   `/proc/pid/uid_map` to create a mapping that maps UID 0 in the parent
   namespace, then … (a) if writing process is in the parent user namespace,
   then it must have the `CAP_SETFCAP` capability in that user namespace". The
   measurement and the man page agree exactly. If QEMU runs as a **non-root**
   uid the requirement disappears, because the map no longer names parent-UID 0.
3. **"Drop all capabilities and rely on unprivileged userns" does not work on a
   modern Ubuntu host.** With `CapEff = 0` the `clone()` still succeeds and
   everything after it is refused. The kernel audit log names the mechanism
   directly:

   ```
   apparmor="AUDIT"  operation="userns_create" class="namespace"
     info="Userns create - transitioning profile" profile="unconfined"
     target="unprivileged_userns"
   apparmor="DENIED" operation="mount" class="mount"
     info="failed mntpnt match" error=-13 profile="unprivileged_userns" name="/"
   ```

   This is Ubuntu's `kernel.apparmor_restrict_unprivileged_userns=1`, default on
   since 23.10. It is *not* visible in `kernel.unprivileged_userns_clone` (reads
   `1` on this host) or `user.max_user_namespaces` (reads `57168`) — the same
   "the sysctls lie" failure `isolate-model.md:140-159` documents for Docker,
   with a different cause.

**How common is that on a GPU host likely to run Kata?** Partly UNVERIFIED, but
the shape is clear:

- Ubuntu 23.10+ (including 24.04 LTS, the most common NVIDIA-driver host):
  restricted by default. **Measured** here.
- Debian: `kernel.unprivileged_userns_clone` was historically `0`; Debian 12
  ships it enabled. **UNVERIFIED** — settle by running
  `scripts/check-vmm-device-access.sh` plus the §8 probe on a Debian 12 node.
- RHEL 7: `user.max_user_namespaces = 0` by default; RHEL 8/9 enable it.
  **UNVERIFIED** — same experiment on a RHEL 9 / OpenShift node, which is also
  the box that would answer 01's open `container_kvm_t` question.

The important design consequence is that **this whole class of risk is
irrelevant to the recommended option**, because there the user namespace is
created by a process that is still host-root, and the AppArmor restriction
applies to *unprivileged* userns creation. A jail that relies on QEMU creating
its own userns after dropping privilege is betting on a distro default that is
already false on the most likely host.

### 3.3 A probe gap in nvkvm: fail-open in one narrow configuration

Row 3 of the table above is a bug report, not a design note.
`nvkvm_iso_probe_namespaces()` clones with the production flags and, in the
child, attempts `mount(NULL, "/", NULL, MS_REC|MS_PRIVATE, NULL)`
(`src/qemu/nvkvm_isolate_uid.h:428-473`). It never exercises the **parent-side
`uid_map` write**, which is the step that `CAP_SETFCAP` gates. So with
`CAP_SYS_ADMIN` present and `CAP_SETFCAP` absent the probe returns "namespace
available", `auto` pins the strongest rung, and every isolate spawn afterwards
dies at `nvkvm_map_child_userns()` (`src/qemu/nvkvm_isolate.c:160`), whose
failure path is fail-closed — so the guest gets no GPU at all rather than a
weaker sandbox.

This is precisely the failure mode the probe design exists to prevent, one
syscall further along. It is narrow (it needs a capability set that has
`SYS_ADMIN` without `SETFCAP` — unusual, but `--cap-drop=SETFCAP` alone produces
it, and so would a hand-written jailer), and the fix is small: have the probe's
parent write `0 <euid> 1` to the probe child's `uid_map` before releasing it,
i.e. exercise the same call the real spawn makes.

**Recommend reporting this upstream to nvkvm-pv regardless of what nvkvm-kata
does**, and note that the probe is otherwise honest — in every other measured
row the probe's answer matched the real spawn's.

### 3.4 Where the steamos capability grant comes from, and why it is right *there*

`nvkvm-steamos/docker-compose.yml:150-153` is `cap_drop: [ALL]` plus
`cap_add: [SETUID, SETGID, SETPCAP, SYS_CHROOT]`, with
`NVKVM_ISOLATE_MODE: uid+chroot` pinned at `:176`. The measurement above shows
why that set is what it is: it is exactly the set that buys `uid+chroot` and
**cannot** buy `namespace` (row 4 of the table). Under Docker the userns route is
closed by the default seccomp/AppArmor profiles (`isolate-model.md:140-159`), so
`uid+chroot` is the best rung reachable, and those four capabilities are the
price.

That grant is defensible in the compose file for a reason that does *not*
transfer to Kata: **the Docker container is already the boundary.** The VMM
service is `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, with a
private mount namespace, no host X11/Wayland socket, no `/dev/nvidia-uvm`
exposure beyond what it needs, and a `tmpfs` `/tmp`. `CAP_SETUID` inside that
container lets the isolate reach uid 0 *of the container*, which owns the
container's own image and nothing of the host's.

Under Kata there is no such container. QEMU sits in the shim's copy of the host
mount tree ([01 §2](01-vmm-confinement.md)). Copying the compose's four
capabilities into a Kata jail without also copying the container is the error
this document exists to avoid.

### 3.5 Quantifying uid 0 with a restricted bounding set — MEASURED

The premise behind "retain those four capabilities and drop the rest" is that a
restricted bounding set meaningfully contains uid 0. **It does not.** Run at
uid 0 with `CapEff = 0000000000000000` and `CapBnd = 0000000000000000` — i.e.
every capability gone, permanently, unrecoverable across `exec`:

```
uid=0 euid=0   CapEff=0  CapBnd=0
  /etc/shadow mode=0640 uid=0 gid=42
  read  /etc/shadow          OK
  WRITE /etc/shadow          OK
  WRITE /etc/passwd          OK
  CREATE /etc/ld.so.preload  OK
  CREATE /etc/cron.d/pwn     OK
  WRITE /usr/bin/ls          Text file busy      <- ETXTBSY, not a denial
  open  /dev/mem             Operation not permitted
  open  /dev/kvm             OK
  read  /proc/1/mem          Permission denied
  ptrace ATTACH <root pid>   Operation not permitted
  kill(0) <root pid>         OK
```

and the control, at uid 65534, denies every single one of those.

The reason is not subtle once stated: **root's power over a Linux filesystem is
DAC ownership, not capability.** `/etc/shadow` is `0640 root:shadow` — owner
`root`, owner bits `rw`. A uid-0 process needs no `CAP_DAC_OVERRIDE` to write
it; it needs no capability at all. Same for `/etc/passwd`, for creating
`/etc/ld.so.preload` (arbitrary code injection into every dynamically linked
binary subsequently executed on the host) and for dropping a file in
`/etc/cron.d/` (root command execution on the next minute boundary). Signalling
any other root process needs no `CAP_KILL`, because the same-uid rule already
permits it.

What the empty capability set *did* stop is worth recording too, because it is
the honest other half: `/dev/mem` is refused (the driver's `open()` checks
`CAP_SYS_RAWIO` independently of DAC), `ptrace` of a non-descendant root process
is refused — but by **Yama** (`kernel.yama.ptrace_scope = 1` on this host), not
by capabilities; at `ptrace_scope = 0` the same-uid rule would permit it and
`CAP_SYS_PTRACE` would not be needed.

One nuance in the other direction, also measured: at uid 0, `CAP_SETUID` is a
*partial* substitute for `CAP_DAC_OVERRIDE`. A uid-0 process with an empty
capability set could not open a `0600` file owned by uid 1000; with `CAP_SETUID`
present it called `setuid(1000)` and read it. So the capability is not literally
free — it is just very far from being the thing that decides whether the host is
compromised.

### 3.6 Resolving the SETUID tension

The tension as posed — "`CAP_SETUID` is exactly what an attacker would use to
`setuid(0)`, so retaining it hands back most of what the jail took away" — is
**true in exactly one of three regimes**, and that regime is not the one Kata is
in today.

| regime | does retaining `CAP_SETUID` help the attacker? | is nvkvm's `uid` rung worth buying? |
|---|---|---|
| **A. QEMU at host uid 0** (Kata's default today) | Barely. The attacker is *already* uid 0 and, per §3.5, already owns the host filesystem. `CAP_SETUID` adds "become any other user", which is a real but marginal increment over "own everything root owns". | **Yes** — it is pure gain. It separates isolates from each other and costs the attacker essentially nothing they lacked. |
| **B. QEMU dropped to an unprivileged *host* uid, capabilities retained** | **Yes, catastrophically.** Here `setuid(0)` is the whole escape: it converts a contained process into the §3.5 process. This is the regime the tension describes, and in it the tension is correct. | **No.** Buying `uid` costs the capability that undoes the jail. Take `namespace` or `seccomp` instead. |
| **C. QEMU as namespace-root inside a user namespace** | **No.** `CAP_SETUID` is namespaced. `setuid(0)` reaches namespace-uid 0, which *is* an unprivileged host uid. Measured: the process holds `CapEff = 000001ffffffffff` and still cannot read `/etc/shadow`, create `/etc/ld.so.preload`, open `/dev/mem`, or signal a host-root process. | **Yes**, and `namespace` is available too. Nothing is traded. |

**The recommendation puts nvkvm-kata in regime C**, which is why the tension
dissolves rather than being resolved by choosing a side. The privileged-helper
alternative the task asked about (a small setuid-root broker that creates
isolates on request while QEMU stays unprivileged) is regime B with a narrow
door cut in it; it is discussed and rejected in
[§4.3.4](#434-the-alternative-not-taken-a-privileged-isolate-helper).

### 3.7 The ladder-ordering question: confirmed, conditionally

The coordinator's proposal is that under a jail the ladder should degrade
`namespace → seccomp`, **skipping `uid`**, because `auto`'s current order
(`namespace → uid(+chroot) → seccomp`,
`nvkvm_iso_auto_select`, `src/qemu/nvkvm_isolate_uid.h:538-590`) was tuned for
Docker, which hands you `CAP_SETUID` free and denies the userns.

**Confirmed for regime B, refuted for regimes A and C.** The order is not wrong
in general; it is wrong exactly when the uid drop can be undone by the attacker.
That condition is expressible precisely, and nvkvm already computes the two
inputs:

```
skip the `uid` rung when   nvkvm_uidmap_get(&m) reports m.identity == true
                     and   geteuid() != 0
```

`struct nvkvm_uidmap.identity` (`nvkvm-pv/src/common/nvkvm_uidmap.h:32-95`) is
already `true` iff the process is not in a user namespace at all — it is
computed by parsing `/proc/self/uid_map` and checking for the single
`0 0 4294967295` extent. So the rule is a three-line change in
`nvkvm_iso_auto_select`, needs no new syscalls, and is exactly right:

- identity map **and** euid 0 → regime A → keep `uid`, it costs nothing.
- identity map **and** euid ≠ 0 → regime B → **skip `uid`**; taking it would
  require a `CAP_SETUID` that also grants `setuid(0)`.
- non-identity map → regime C → keep `uid`; `setuid(0)` is namespaced.

This is worth proposing to nvkvm-pv independently of nvkvm-kata: it makes the
ladder correct under libvirt's non-root QEMU too, which is the other common
regime-B deployment.

---

## 4. The options, cheapest first

### 4.1 Option 0 — QEMU's own `-sandbox` (`seccompsandbox`)

01 §3.3 established the key, the plumbing, the default, and five measured
values. This section adds what it left open: the **exact** compatibility matrix
against nvkvm's rungs, from the filter source rather than from the help text.

`qemu/system/qemu-seccomp.c` @ `v9.2.0` (`ae35f033b874`) — the same structure is
present in Kata's 11.0.1 build, verified against its `--help` output:

**`spawn=deny` (`QEMU_SECCOMP_SET_SPAWN`)** — `:216-255`:

| syscall | action |
|---|---|
| `fork`, `vfork`, `execve` | `SCMP_ACT_ERRNO(EPERM)` (`:216-221`) |
| `clone` with no flags but `CSIGNAL` | `SCMP_ACT_ERRNO(EPERM)` (`:222-223`, rule `clone_arg_none` at `:79-84`) |
| `clone` with **`CLONE_NEWUSER`**, and separately `CLONE_NEWNS`, `CLONE_NEWPID`, `CLONE_NEWNET`, `CLONE_NEWIPC`, `CLONE_NEWUTS`, `CLONE_VFORK`, `CLONE_PARENT`, … | `SCMP_ACT_ERRNO(EPERM)` (`RULE_CLONE_FLAG`, `:75-77`, instantiated `:224-246`) |
| `clone3` | `SCMP_ACT_ERRNO(ENOSYS)` (`:247-250`) |
| `execveat`, `setns`, `unshare` | action field omitted → **`SCMP_ACT_KILL`** (`:251-255`) |

**This is categorical: `spawn=deny` is incompatible with every nvkvm rung.**
Not just the uid ones. `namespace` mode's
`clone(CLONE_NEWUSER|CLONE_NEWPID|…)` (`nvkvm_isolate.c:260`) is denied by flag;
the plain-`fork` path used by the weaker rungs is denied outright; and even if a
child existed, nvkvm launches the stub with `fexecve` on an anonymous memfd
(`nvkvm_isolate.c:1789-1800`), which is `execveat` — **killed**, not refused. 01's
statement that `spawn=deny` "blocks the fork/execve the isolate spawn path is
built on" is right and can now be made without the hedge.

**`elevateprivileges=deny` (`QEMU_SECCOMP_SET_PRIVILEGED`)** — `:194-213`:
`setuid`, `setgid`, `setpgid`, `setsid`, `setreuid`, `setregid`, `setresuid`,
`setresgid`, `setfsuid`, `setfsgid`, all with **`SCMP_ACT_TRAP`** — a `SIGSYS`
that kills the process, not an `EPERM` the caller can handle. `setgroups` is
**not** in the set, so nvkvm's `setgroups(0, NULL)` survives.

Two corrections to the received wisdom fall out:

- **`elevateprivileges=children` is not more permissive than `deny` in the
  filter.** Both take the same `seccomp_opts |= QEMU_SECCOMP_SET_PRIVILEGED`
  branch (`:383-397`); `children` merely adds a `PR_SET_NO_NEW_PRIVS`. Since
  seccomp filters are inherited across `fork` and `execve`, the "will allow
  forks and execves to run unprivileged" in QEMU's help text does not mean the
  child may call `set*uid`. **It may not.** So no value of `elevateprivileges`
  other than `allow` leaves nvkvm's `uid` rung working.
- **The `elevateprivileges=children` failure 01 measured is an upstream QEMU
  bug**, and it is a one-liner. Reproduced under `strace` on Kata's shipped
  binary:

  ```
  $ strace -e trace=prctl /opt/kata/bin/qemu-system-x86_64 -machine none \
      -display none -sandbox on,obsolete=deny,elevateprivileges=children,resourcecontrol=deny
  prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0xffffff00, 0xaaaaaaab) = -1 EINVAL
  qemu-system-x86_64: ...: failed to set no_new_privs aborting
  ```

  `system/qemu-seccomp.c:392` calls `prctl(PR_SET_NO_NEW_PRIVS, 1)` with two
  arguments. `prctl(2)` is variadic; arguments 3–5 are whatever was on the
  stack, and the kernel requires them to be zero for this command. The fix is
  `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`. This is worth sending upstream on
  its own merits — it is an unconditional failure of a documented option, and
  nothing about nvkvm is needed to see it.

**The resulting compatibility matrix:**

| `-sandbox` value | `namespace` | `uid` / `uid+chroot` | `seccomp` |
|---|---|---|---|
| `on` | ✅ | ✅ | ✅ |
| `on,obsolete=deny,resourcecontrol=deny` | ✅ | ✅ | ✅ |
| `…,elevateprivileges=deny` | ✅ *(no `set*uid` in the namespace path)* | ❌ SIGSYS | ✅ |
| `…,elevateprivileges=children` | ❌ QEMU exits 1 today (the bug above) | ❌ | ❌ |
| `…,spawn=deny` | ❌ | ❌ | ❌ |
| Kata's own recommended string | ❌ | ❌ | ❌ |

So the "pleasing possibility" the coordinator raised is **half true**: if the
ladder drops `uid` (§3.7), `elevateprivileges=deny` becomes compatible and is a
strictly stronger sandbox. But `spawn=deny` never becomes compatible, so Kata's
full recommended string stays out of reach, and the ceiling for nvkvm is
`"on,obsolete=deny,elevateprivileges=deny,resourcecontrol=deny"`.

**Recommended value, unchanged from 01 for phase 0** —
`seccompsandbox = "on,obsolete=deny,resourcecontrol=deny"` — with a documented
upgrade to add `elevateprivileges=deny` once the isolate rung is pinned to
`namespace` (which the recommendation in §4.3 guarantees). All of it is
**UNVERIFIED against an nvkvm-patched QEMU**; settle by running
`nvkvm-pv/tests/validate.sh` under each value.

**The performance cost, which 01 left as "no number exists anywhere".** A
proxy was measured: a libseccomp filter with 45 deny rules over a default-allow
policy — roughly the shape and size of QEMU's `DEFAULT|OBSOLETE|RESOURCECTL`
set — timed against a trivial failing `ioctl(2)`, best-of-six, BPF JIT enabled
(`net.core.bpf_jit_enable = 1`):

```
OFF  rules=0   ioctl: 222.4 ns/call
ON   rules=45  ioctl: 283.9 ns/call
```

**≈ +61 ns per syscall, +28 % on a trivial `ioctl`.** Two caveats, both
important: the host is a noisy shared VM (single-run figures ranged 222–447 ns
for the same binary), and this is a *proxy*, not QEMU. What it is good for is
bounding the shape of the answer: the cost is tens of nanoseconds per syscall,
not microseconds, so it is negligible for an ioctl that does real GPU work and
visible only on a path issuing millions of trivial syscalls per second. nvkvm's
forwarding path is syscall-heavy enough that this should still be measured
directly — `nvkvm-pv/tests/perf/` under each `-sandbox` value.

**What `-sandbox` cannot do, restated:** it is a syscall filter and nothing
else. No chroot, no mount namespace, no uid drop, no device policy, and no
narrowing of what an attacker reaches through the fds QEMU legitimately holds —
which under nvkvm includes `/dev/nvidia-uvm` and the KVM vm fd. It reduces
surface; it does not confine. It is phase 0, not the answer.

### 4.2 Option 1 — QEMU's own `-run-with chroot=` / `user=`

QEMU has had process-lifecycle options since the `-runas`/`-chroot` deprecation:

```
-run-with [async-teardown=on|off][,chroot=dir][,exit-with-parent=on|off][,user=username|uid:gid]
```

(`qemu-options.hx:5147-5170` @ v9.2.0; present verbatim in the `--help` of
Kata's shipped `/opt/kata/bin/qemu-system-x86_64`, "QEMU emulator version 11.0.1
(kata-static)".) Kata plumbs **none** of it — zero matches for `run-with` in
`src/runtime` @ `f62ecce`. This looked like the cheapest possible rung 2/3: the
same shape as the existing `seccompsandbox` plumbing, one field in
`katautils/config.go`, one `append` in govmm.

**Two measured findings, one fatal.**

**(a) `-run-with user=` segfaults Kata's shipped QEMU.** Reproduced on
`-machine none` and on `-machine q35,accel=kvm`, with both `user=nobody` and
`user=65534:65534`, with and without `-sandbox`:

```
$ /opt/kata/bin/qemu-system-x86_64 -machine q35,accel=kvm -m 128 -display none \
    -nodefaults -S -run-with user=65534:65534
Segmentation fault (core dumped)          # exit 139, no error message
```

The same option on the **nvkvm** QEMU (9.2.0, dynamically linked) runs to the
timeout normally. The cause is visible in the source and confirmed by the
crash's memory map:

- `os_set_runas()` (`os-posix.c`) calls **`getpwnam(user_id)` unconditionally**,
  before it ever tries to parse the `uid:gid` form (`os-posix.c` @ `v9.2.0`). So even the numeric form
  goes through NSS.
- Kata's QEMU is `ELF 64-bit LSB pie executable, x86-64, **static-pie linked**,
  stripped` (`file`; `ldd` reports "statically linked"). `getpwnam` in a
  statically linked glibc `dlopen`s the host's NSS modules at runtime.
- Under `gdb` the faulting frame is inside
  `/usr/lib/x86_64-linux-gnu/libc.so.6` — the *host's dynamic* libc, mapped into
  a static binary — and under `strace` the last activity before `SIGSEGV` is the
  `mmap`/`mprotect` sequence of a shared object being loaded.

`-run-with chroot=` alone works fine on the same binary (runs to timeout, exits
on SIGTERM). So the chroot half is usable and the uid half is not, **on the
binary Kata ships**. This is a packaging property, not a QEMU-version property,
and it would also have to be re-checked on any Kata QEMU rebuild.
**UNVERIFIED:** whether upstream QEMU considers `getpwnam` in a static build a
bug worth fixing, or whether the fix is "parse `uid:gid` first". Either is a
small patch; neither exists today.

**(b) The ordering is workable but constrains the design.** `os_setup_post()`
— which calls `change_root()` then `change_process_uid()` — is invoked at
`system/vl.c:3757` (@ `v9.2.0`), i.e. at the very **end** of `qemu_init()`, after
`qmp_x_exit_preconfig()` has run machine init and device realize. Consequences
for nvkvm:

- Good: nvkvm's `virtio-nvgpu` realize — which opens `/dev/nvidia-uvm`, resolves
  the isolate mode and probes the ladder — happens **before** the chroot and the
  uid drop, so it sees the real filesystem and the real privilege.
- Bad, and this is a genuine correctness trap: the ladder is therefore probed
  **at pre-drop privilege and used at post-drop privilege**. With `user=` in
  play, `auto` would measure `CAP_SETUID` as present (it is, at realize) and
  then every isolate spawn would fail, because `setuid()` to a non-zero uid
  clears the permitted set. Any design that drops QEMU's privilege *after*
  device realize must pin `NVKVM_ISOLATE_MODE` explicitly rather than trusting
  `auto`. The recommended option in §4.3 avoids this entirely by doing all
  privilege work **before** `exec`, so realize already sees the final state.
- `chroot=dir` after realize also means the chroot must contain everything the
  isolate path resolves by name *later*: `/dev/nvidiactl`, `/dev/nvidia0..N`,
  `/dev/dri/renderD128..` (bind sources for `namespace` mode's tmpfs root,
  `nvkvm_isolate.c:287`) and a `/proc` mount point. Populating those needs
  `mknod` or bind mounts from outside — i.e. something that runs as root before
  QEMU starts, which is a wrapper or a Kata patch. `-run-with chroot=` does not
  save you from building the jail root; it only saves you from calling
  `chroot(2)`.

**Verdict:** `-run-with chroot=` is a real, free, upstream-supported ingredient
and should be used if a chroot is wanted. `-run-with user=` is unusable on
Kata's binary today, and even if fixed it lands the deployment in regime B
(§3.6), which is the one regime where the SETUID tension is real. Not the
recommendation.

### 4.3 Option 2 — a wrapper binary at `hypervisor.qemu.path` — **RECOMMENDED**

#### 4.3.1 Why the seam works

`hypervisor.path` is an ordinary executable path. Kata resolves it with
`ResolvePath()` (`src/runtime/pkg/katautils/utils.go:35-56`), which does
`filepath.Abs` + `filepath.EvalSymlinks` and **nothing else** — no signature
check, no glob check, no ELF inspection. `valid_hypervisor_paths`
(`configuration-qemu.toml:40`) is *not* a constraint on the config file; it is
consulted only when the path arrives via the
`io.katacontainers.config.hypervisor.path` **annotation**
(`src/runtime/pkg/oci/utils.go:670-681`, `checkPathIsInGlobs` at `:301`). So
setting `path = "/usr/libexec/nvkvm-kata/qemu-jail"` in `configuration.toml` is
supported configuration, not a hack. (If the annotation route is also wanted,
add the wrapper to `valid_hypervisor_paths`.)

`exec()` preserves the PID, and every piece of Kata's process handling either
does not care or is actively helped:

| Kata behaviour | file:line @ `f62ecce` | effect on a wrapper that `exec`s |
|---|---|---|
| launches with `exec.CommandContext(path, params...)`, `cmd.Start()` | `pkg/govmm/qemu/qemu.go:3578-3595` | argv is handed to the wrapper; it must pass it through |
| reads QEMU's stderr through `cmd.StderrPipe()` and logs it | `virtcontainers/qemu.go:1772-1779`, `LogAndWait` | fd 2 survives `exec`; unchanged |
| `qemuCmd.Wait()` reaps | `LogAndWait` | reaps the same PID; unchanged |
| **gets the PID from QEMU's own `-pidfile`, not from `cmd.Process.Pid`** | `qemu.go:3613-3631` (`GetPids`), `-pidfile` appended at `pkg/govmm/qemu/qemu.go:3483-3488` | agrees with the exec'd PID by construction |
| `SIGKILL`s that PID on stop | `qemu.go:1894-1910` | unchanged; the shim is host-root and can signal into a child userns |
| moves it into the sandbox cgroup with `AddProc` | `pkg/resourcecontrol/cgroups.go:340-348`, `sandbox.go:2816-2827` | the shim writes `cgroup.procs`; QEMU cannot escape (no cgroupfs write access) |
| joins the pod netns around fork/exec | `network_linux.go` `doNetNS`, `Sandbox.startVM` | inherited by the wrapper and by QEMU; creating a userns does not leave the netns |
| passes the QMP listener as an **fd**, not a path | `qemu.go` `setupEarlyQmpConnection`, rendered as `<type>:fd=N` at `pkg/govmm/qemu/qemu.go` `appendQMPSockets` | fd survives `exec`; **no path fixup needed for QMP** |
| passes `/dev/vhost-net` and the vhost-vsock fd, pre-opened by the shim | `network_linux.go:913-925` `createVhostFds`, `qemu_arch_base.go:593` `VHostFD` | already fd-passed; **no path fixup needed for vhost** |
| sets the SELinux exec label just before launch | `qemu.go:1752-1755` | applies to the wrapper's `execve`; the wrapper's own `execve` of QEMU is **not** labelled. Minor divergence, noted in §7 |

The last two rows are worth dwelling on: Kata already hands QEMU its two most
privilege-sensitive resources — the QMP listener and the vhost devices — as
**file descriptors**. That removes the largest class of DAC problems a
uid-dropping jail normally has, for free.

#### 4.3.2 The design, and the measurement that validates it

The wrapper is exec'd by the shim as host root. It:

1. forks a **transient helper** — *before* any namespace work, so the helper
   keeps host-root credentials in the initial user namespace;
2. calls `unshare(CLONE_NEWUSER)` **in place**, so its own PID is untouched;
3. has the helper write a multi-line map to `/proc/<wrapper-pid>/uid_map` and
   `gid_map` — `0 <BASE> 4096` for uids, and for gids `0 <BASE> 1` / `1 <kvm gid> 1`
   / `2 <BASE+2> 4094`, so namespace-gid 1 is the host's `kvm` group;
4. reaps the helper, sets `setgroups({1})`, `setgid(0)`, `setuid(0)` — becoming
   namespace-root with the full capability set *of that namespace*;
5. `execve`s the real `qemu-system-x86_64` with the argv it was given.

A ~120-line C prototype of exactly this was built and run
(`/tmp/wrap.c`, reproduced in [§8](#8-reproduction)). Measured, with the
prototype's child printing its own state:

```
[wrapper] pid=1250772 preserved=1
uid=0(root) gid=0(root) groups=0(root),1(daemon)      # ns ids; host uid is 500000
pid=1250772                                            # the shell's $$ == the wrapper's pid

  read /etc/shadow           Permission denied
  WRITE /etc/shadow          Permission denied
  CREATE /etc/ld.so.preload  Permission denied
  open /dev/mem              Permission denied
  open /dev/kvm              OK                        # via the kvm gid map

--- nvkvm namespace rung ---
euid=0  probe(namespace)=AVAILABLE
           real spawn   =OK                            # nested userns + tmpfs mount
```

Compare that against the identical probe run without the wrapper (§3.5): every
one of those denials was an `OK`.

Four things are simultaneously true in that output, and they are the whole
argument:

1. **The PID is preserved** — `preserved=1`, and the exec'd shell's `$$` is the
   wrapper's PID. Kata's wait/kill/cgroup handling is untouched.
2. **Host root is gone.** Nothing root-owned on the host is readable or
   writable. `/dev/mem` is refused. Host-root processes cannot be signalled or
   ptraced.
3. **`/dev/kvm` still opens**, because namespace-gid 1 maps to the host's `kvm`
   group (`crw-rw---- root:kvm`, gid 991 here). No `chmod 666` of anything is
   required. The NVIDIA nodes are mode `0666` by installer default — and nvkvm
   already *requires* `/dev/nvidiactl` to be other-rw for its uid rung
   (`nvkvm_iso_probe_uid`, `src/qemu/nvkvm_isolate_uid.h:482-500`) — so they need
   no map entry at all.
4. **nvkvm's strongest rung works.** The nested `CLONE_NEWUSER` succeeds *and is
   usable*, on a host where the same operation is refused to an unprivileged or
   capability-stripped process (§3.2). The jail does not weaken the isolate
   sandbox; it is the thing that makes the strongest rung reliably available.

And, because the map is 4096 uids wide, `NVKVM_ISO_UID_SLOTS` fits exactly
(`src/qemu/nvkvm_isolate_uid.h:188`), so the `uid`/`uid+chroot` rungs remain
available as fallbacks with their `setuid` targets landing on host uids
`BASE+1 … BASE+4095` — all unprivileged. nvkvm's existing map-awareness
(`nvkvm_uidmap_get/fits/place`, `src/common/nvkvm_uidmap.h:47-131`, and its
`--userns-remap`/sysbox rationale at `src/qemu/nvkvm_isolate.c:1331-1345`) means
this configuration is one nvkvm already anticipated and handles.

#### 4.3.3 What it can and cannot confine

**Can:**

- Remove host-root DAC entirely (measured above) — the single largest item in
  01 §3.2's "that is root on the host" table.
- Make `CAP_SETUID` and friends safe to hold, so no isolate rung has to be given
  up (§3.6 regime C).
- Add any of: a mount namespace + `pivot_root` into a purpose-built root; an IPC
  and UTS namespace; a PID namespace (with the caveat below); `no_new_privs`; a
  tightened `RLIMIT` set — all cheap once a userns exists, and all currently
  absent ([01 §2](01-vmm-confinement.md)).
- Chown/relocate the small set of paths QEMU needs to write, as root, *before*
  unsharing — the wrapper is the natural place for it because it can read them
  off the argv it was handed.

**Cannot:**

- **Reduce QEMU's own attack surface.** The device models are unchanged. This
  bounds the blast radius; it does not reduce the probability.
- **Take away the fds QEMU legitimately holds.** The KVM vm fd, the memory
  backends, and `/dev/nvidia-uvm` are exactly as reachable to a QEMU RCE as
  before. That is intrinsic — QEMU needs them — and it is why `-sandbox` (which
  narrows what can be *done* with them) is complementary rather than redundant.
- **Give a PID namespace for free.** Putting QEMU in a `CLONE_NEWPID` makes it
  PID 1 of that namespace, which changes signal-default semantics and reaping.
  Kata kills by the pidfile PID, which is the *host* PID, so `SIGKILL` still
  works — but this needs testing before enabling and is **not** part of the
  minimum recommendation.
- **Protect against a kernel bug reached through KVM.** `/dev/kvm` is still
  open. Nothing in this design touches that.
- **Survive Kata deciding to hand QEMU a resource by path that only root can
  open.** Every Kata release is a re-check. Named in §7.

#### 4.3.4 The alternative not taken: a privileged isolate helper

The task asked whether a small privileged helper could create isolates on
request while QEMU stays unprivileged. It could, and it should not be built.

- nvkvm's isolate spawn is not a service call. The child is `clone()`d from
  QEMU, inherits a socketpair created by QEMU, inherits (and then closes) QEMU's
  fd table, is released through a sync pipe after the parent writes its uid map,
  and `fexecve`s a stub embedded in the QEMU binary and materialised as an
  anonymous memfd (`src/qemu/nvkvm_isolate.c:1644` `nvkvm_isolate_create`, memfd+fexecve at `:398-400`/`:1789-1800`). A helper
  would have to receive the memfd and the socketpair over `SCM_RIGHTS` and
  reimplement the fork/drop/pivot sequence. That is a substantial nvkvm change,
  not a wrapper.
- It would put the deployment in regime B with a privileged door in it. A helper
  that can create a process as an arbitrary uid on request from a compromised
  QEMU is an escalation primitive unless its interface is provably narrow
  (refuse uid 0, refuse uids outside this VM's window, refuse to inherit fds).
  Getting that right is harder than the userns, which the kernel already gets
  right.
- The userns achieves the same end state with no new trusted component and no
  new IPC.

### 4.4 Option 3 — a full chroot jailer

The Firecracker pattern, done properly: a jail root under
`/run/vc/vm/<sandbox-id>/root`, every resource bind-mounted in, every path on
the command line rewritten to its in-jail form.

**Why Kata can do this for Firecracker and not (today) for QEMU.** `fc.go`
rewrites paths because the runtime *knows* about `jailerRoot`
(`fc.go:151-152`, set at `:240-243`). Every asset goes through
`fcJailResource()` (`:547-564`), which bind-mounts `src` to
`filepath.Join(fc.jailerRoot, dst)` and then returns `filepath.Join("/", dst)`
— the in-jail path — for the command line. There is no equivalent in `qemu.go`,
and adding one means touching every place a path is emitted.

**The path inventory a QEMU jailer would have to manage.** Enumerated from
`qemu.go` and `qemu_arch_base.go` @ `f62ecce`; the good news is how much of it
is already fd-passed:

| resource | how Kata hands it over | jailer work |
|---|---|---|
| QMP monitor socket | **fd** (`setupEarlyQmpConnection` → `<type>:fd=N`) | **none** |
| `/dev/vhost-net`, vhost-vsock | **fd** (`createVhostFds`, `VHostFD`) | **none** |
| console socket | path — `/run/vc/vm/<id>/console.sock` (`qemu.go:127`, `:3019` via `utils.BuildSocketPath`) | bind-mount the directory in, or accept it created inside |
| `-pidfile` | path — `/run/vc/vm/<id>/pid` (`qemu.go:1297`) | must be writable by the jailed uid; QEMU creates it |
| virtiofsd socket | path — `vhost-fs.sock` (`qemu.go:130`, `:1101-1135`) | bind-mount; note virtiofsd itself stays root ([rootless doc, limitation 1](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-run-rootless-vmm.md)) |
| kernel, initrd, rootfs image, firmware/pflash | paths, read-only | bind-mount read-only |
| `memory-backend-file` (`MemPath`, `qemu_arch_base.go:473`) | path | bind-mount; hugetlbfs mounts need care |
| the NVIDIA device nodes (this design's addition) | paths, mode 0666 | bind-mount, or `mknod` in the jail root as root |

That is roughly a dozen items and it is genuinely tractable — but every one of
them is a place where a Kata release can change the shape of the command line
underneath you. **A wrapper can do all of this too** (it runs as root, it can
parse its own argv for `-pidfile`, `-chardev socket,path=`, `-drive file=`,
`-kernel`, `-initrd`, `-object memory-backend-file`), which is why §4.3
recommends starting with the userns and adding the mount namespace later, as an
increment, rather than as a precondition.

**Verdict:** the right *destination*, the wrong *starting point*. It is stage 3
of the staged path in §5, and it is worth noting that the userns from stage 2 is
what makes it cheap: inside a userns, `pivot_root` and bind mounts need no host
privilege at all.

### 4.5 Option 4 — a new upstream Kata hypervisor backend (`qemu-nvkvm`)

Fork `qemu.go` into a `qemu-nvkvm` driver that does the confinement Kata does
for Firecracker.

**Maintenance cost: high, and asymmetric.** `qemu.go` is ~3,700 lines and is the
most-churned hypervisor driver in the tree. A fork inherits every change to
device hotplug, memory hotplug, QMP handling, migration, and the arch layer, and
diverges silently when it does not. Kata already carries the cost of *one* QEMU
driver; a second would be paid by whoever maintains nvkvm-kata, forever.

**Upstream plausibility: low, for a reason that is visible in the tree.**
Upstream's stated strategy for VMM attack surface is a smaller VMM, not a
confined one — `docs/design/virtualization.md:238` scores QEMU "Good" on
Security Isolation against "Excellent" for the three Rust VMMs, and its
"Maximum security isolation" row (`:255`) omits QEMU entirely. The QEMU driver
is the one upstream invests in least: the cgroup-v2 device policy is silently
dropped there ([01 §1.6](01-vmm-confinement.md)), and no jailer was ever wired.
A patch series proposing a *second* QEMU driver whose distinguishing feature is
confinement is proposing that upstream reverse a strategy, on the driver they
have chosen not to invest in, on behalf of an out-of-tree device.

**What *is* plausible upstream**, and should be pursued instead, in rough
descending order of independence from nvkvm:

1. **The `prctl(PR_SET_NO_NEW_PRIVS, 1)` fix in QEMU** (§4.1). One line, a
   reproducer, no nvkvm content at all.
2. **The `containerd/cgroups` `ToResources()` device gap**
   ([01 §1.6](01-vmm-confinement.md)). A silent security-relevant divergence
   between cgroup v1 and v2 hosts affecting every Kata user.
3. **`getpwnam` in a static QEMU / `-run-with user=`** (§4.2). Either a QEMU fix
   (parse `uid:gid` before consulting NSS) or a Kata packaging note.
4. **Plumbing `-run-with chroot=` into the QEMU driver**, mirroring the existing
   `seccompsandbox` plumbing exactly. Small, additive, and useful to anyone
   running Kata+QEMU, not just to us.
5. **Only then**, and only with operational experience behind it, a
   `hypervisor.qemu.jailer_path`-shaped hook that generalises what our wrapper
   does. Offering upstream a *hook* is a far easier sell than offering them a
   driver.

**Verdict: do not fork the driver.** The wrapper gets the same confinement with
none of the maintenance, and the upstream contributions above are worth more
than the fork would be.

---

## 5. Recommendation and staged path

**Recommend option 2 — the PID-preserving userns wrapper — reached in stages,
each with an exit criterion that can fail.**

### Stage 0 — configuration only (today, no code)

```toml
[hypervisor.qemu]
seccompsandbox      = "on,obsolete=deny,resourcecontrol=deny"
rootless            = false          # see §7; the wrapper supersedes it
sandbox_cgroup_only = true           # for the cgroup-leak reason, not device reasons
```
plus `NVKVM_ISOLATE_MODE=auto` on the VMM and a deployment check that asserts on
the `isolate-mode-active` QOM property.

*Exit criterion:* `nvkvm-pv/tests/validate.sh` passes under that `-sandbox`
value on an nvkvm-patched QEMU, and `tests/perf/` shows the cost is acceptable.
*If it fails:* fall back to `seccompsandbox = "on"`, then to `""`, and record
which sub-option broke it — that is a publishable result either way.

### Stage 1 — prove nvkvm works at all as a non-host-root process

Before writing the wrapper, settle the question that decides whether it is
possible. Run nvkvm's own test suite with QEMU launched as an unprivileged uid
that has `kvm` and `render` group membership and read access to the NVIDIA nodes
— no Kata, no namespaces, just `setpriv`.

*Exit criterion:* `cuInit`, an allocation, a pinned-host-memory registration and
a GPU kernel all succeed. *If it fails:* the failure names the blocker
(`RLIMIT_MEMLOCK`, an NVIDIA-driver `capable()` check, a device-node mode), and
that blocker is either fixable (grant a group, raise a limit) or it kills the
whole approach and stage 0 is the ceiling. **This is the cheapest experiment in
the document and the one most likely to change the answer. Do it first.**

### Stage 2 — the wrapper, minimum version

~150 lines of C at `/usr/libexec/nvkvm-kata/qemu-jail`, doing exactly §4.3.2 plus
the path fixups it can derive from argv. Set `path =` to it in
`configuration.toml`. Pin `NVKVM_ISOLATE_MODE=namespace` explicitly once
measured, so no probe result is trusted.

Implementation notes that will otherwise cost a day each:

- **Do not use low fd numbers.** Kata passes the QMP listener (and vhost fds) via
  `cmd.ExtraFiles`, which lands them at fd 3 upward. The wrapper's own pipes must
  be `dup2`'d above them and must be `CLOEXEC`. The prototype in §8 does *not*
  do this and would collide.
- **Do not close unknown fds.** Everything above fd 2 may be load-bearing.
- The uid base must be per-sandbox and non-overlapping —
  `isolate-model.md:479-500` requires ≥4096 apart per concurrently running VM.
  Deriving it from the sandbox id in the argv (`-name sandbox-<id>`) is the
  obvious source.
- Map the host `kvm` gid, and `render` if `/dev/dri/renderD*` is not 0666 on the
  target host. Check both at wrapper start and fail loudly, not at first ioctl.

*Exit criterion:* a Kata sandbox starts, runs a CUDA workload, and
`isolate-mode-active` reads `namespace`; `/proc/<qemu-pid>/status` shows a
non-zero host `Uid`; the §3.5 probe run from inside the QEMU process's context
denies everything it previously allowed. *If it fails:* the failure is a path or
a device-node permission, both enumerable; fall back to stage 0 while fixing.

### Stage 3 — add the mount namespace

Inside the userns the wrapper already has `CAP_SYS_ADMIN` in its own namespace,
so `CLONE_NEWNS` + bind mounts + `pivot_root` cost no host privilege. Build the
jail root from the §4.4 inventory. Optionally use `-run-with chroot=` instead for
a cheaper, weaker version.

*Exit criterion:* QEMU's mount namespace contains only the enumerated resources.
*If it fails:* stage 2 is already a large improvement; ship it and iterate.

### Stage 4 — upstream the pieces that are not ours

The five items in §4.5, in that order. None of them blocks stages 0–3.

### What is explicitly **not** recommended

- **Do not fork `qemu.go`** (§4.5).
- **Do not enable `rootless = true`** as the confinement mechanism. It solves
  the file-layout half (random user, `/run/user/<uid>` relocation) but lands in
  regime B: a non-root QEMU in the *initial* user namespace, where nvkvm's
  `namespace` rung is unavailable on an Ubuntu host (§3.2) and its `uid` rung
  requires the one capability that undoes the drop. Its own documentation also
  disclaims device passthrough. Its *file-relocation* logic is however the best
  available reference for the wrapper's path fixups, and should be read as such.
- **Do not use Kata's recommended `seccompsandbox` string.** `spawn=deny` breaks
  every nvkvm rung (§4.1), and this is now established from the filter source,
  not inferred.
- **Do not rely on unprivileged user namespaces being available.** Measured
  false on the most likely host distro (§3.2).

---

## 6. Would a Rust VMM (kayfabe/Cloud Hypervisor) remove the need for a jailer?

The owner's observation is that kayfabe is Rust and targets Cloud Hypervisor, so
a future `kayfabe-kata` would land on a VMM Kata *does* confine
(`clh.go`'s `--seccomp`, on by default, `:1860-1863`) and would be written in a
memory-safe language.

**A jailer is still warranted, for three reasons.**

1. **Memory safety shrinks a bug class, not the attack surface.** Kayfabe's own
   framing is that it emulates an NVIDIA GPU and lets the guest run the real,
   unmodified NVIDIA driver against it (`kayfabe/README.md`) — that is *more*
   guest-reachable parsing than nvkvm's forwarding model, not less: RM
   allocations, page-directory binds, doorbells and pushbuffer methods, all
   attacker-shaped. Rust removes spatial and temporal memory errors. It does not
   remove logic errors in an allowlist, confused-deputy bugs where the VMM does
   the guest's bidding against the host driver, integer/semantic errors that
   produce a valid-but-wrong ioctl, or `unsafe` blocks — and a VMM that mmaps
   device memory and installs KVM memslots has `unsafe` blocks by necessity.
2. **The compromised process still holds the same fds.** Whatever the language,
   the VMM holds the real `/dev/nvidia*` fds, the KVM vm fd and the memory
   backends. A jailer is what decides what those fds are worth to an attacker
   who has the process. That calculus is language-independent.
3. **Cloud Hypervisor's seccomp is the same *category* of mitigation as
   `-sandbox`** — a syscall filter, not a confinement. It is on by default,
   which is better than QEMU's situation, but it is not a chroot, a uid drop or
   a namespace. Kata gives Cloud Hypervisor no jailer either.

The honest version: a Rust VMM would make the *probability* of a VMM compromise
lower and would let the project stop apologising for the default posture. It
would not change the *consequence*, and the consequence is what this document is
about. **Build the wrapper for QEMU now; expect to reuse it, near-unchanged, for
whatever VMM comes next** — it is 150 lines of C that knows nothing about QEMU
beyond "exec argv".

---

## 7. Risks and open questions

**The single biggest risk: nvkvm may not work when QEMU is not host-root.**
Stage 1 exists to settle it. The specific unknowns:

- **`RLIMIT_MEMLOCK` / pinned host memory.** nvkvm's pinned-host-memory path
  (`NV01_MEMORY_SYSTEM_OS_DESCRIPTOR`, pinning the *calling task's* pages —
  `isolate-model.md`, "Why one process per guest process") is exactly the kind
  of operation the kernel gates on `RLIMIT_MEMLOCK` or `CAP_IPC_LOCK`. Whether
  the out-of-tree NVIDIA driver uses `capable()` (initial userns — the wrapper's
  namespaced `CAP_IPC_LOCK` would **not** satisfy it) or an rlimit (which the
  wrapper can raise before dropping) is **UNVERIFIED**. *Experiment:* register
  a >64 MiB pinned host buffer under `setpriv --reuid`, then under the wrapper,
  and compare.
- **`/dev/dri/renderD128` mode.** `0666` on some distros, `0660 root:render` on
  others. The `render` gid must be in the wrapper's gid map on the latter.
  *Experiment:* `stat -c '%a %U:%G' /dev/dri/renderD*` on the target host — one
  command, and it belongs in a preflight check.
- **Host paths Kata hands QEMU by name.** Enumerated in §4.4; the risk is not
  the current list but that it changes. *Mitigation:* the wrapper should fail
  loudly on any argv token it does not recognise as either safe or fixable,
  rather than silently letting QEMU fail on an `EACCES` later.

**Other risks, in descending order:**

- **SELinux label divergence.** `qemu.go:1752-1755` sets the exec label for the
  wrapper's `execve`; the wrapper's own `execve` of QEMU inherits the label
  rather than being re-labelled. Irrelevant on the two hosts 01 measured (both
  `unconfined`) and possibly a real problem on RHEL/OpenShift. **UNVERIFIED.**
  *Experiment:* read `/proc/<qemu-pid>/attr/current` under the wrapper on a
  `container-selinux` host.
- **`user_namespaces(7)` nesting limit.** The kernel caps nesting at 32 levels.
  The wrapper is level 1, each isolate is level 2. No risk today; it would
  become one if the wrapper were combined with a userns-remapping container
  runtime *and* something else nested. Worth a one-line assertion.
- **`sandbox_cgroup_only` and the device cgroup.** Orthogonal to this document,
  but note the interaction: when upstream closes the cgroup-v2 gap
  ([01 §1.6](01-vmm-confinement.md)), the device policy applies to QEMU
  regardless of uid ([01 §1.3](01-vmm-confinement.md), measured), so route (a)
  — the host CDI spec — is still required and is unaffected by anything here.
- **This document's own measurements were made on one host.** Kernel
  `7.0.0-29-generic`, AppArmor enforcing with
  `apparmor_restrict_unprivileged_userns=1`, cgroup v2, no GPU, Yama
  `ptrace_scope=1`. The capability/DAC results (§3.5) are kernel semantics and
  should be host-independent; the userns-availability results (§3.2) are
  explicitly distro policy and **must** be re-run on any target distro. The
  QEMU-binary results (§4.1, §4.2) are properties of Kata's 4.1.0 build and must
  be re-run on every Kata bump.

**Experiments this document creates:**

1. **Stage 1** — does nvkvm work as a non-root uid at all? (§5) — the gating one.
2. Re-run the §3.2 probe matrix on Debian 12, RHEL 9 and a stock Ubuntu 22.04
   GPU node. Quantifies the userns-availability claim properly.
3. Run `nvkvm-pv/tests/validate.sh` under all five `-sandbox` values against an
   nvkvm-patched QEMU, confirming the §4.1 matrix by measurement rather than by
   reading the filter.
4. Measure `-sandbox` cost on nvkvm's own `tests/perf/`, replacing the §4.1
   proxy number.
5. Confirm the §3.3 probe gap against a real nvkvm build
   (`--cap-drop=SETFCAP` with `CAP_SYS_ADMIN` retained) and report it upstream.
6. Reproduce the `-run-with user=` segfault on a second Kata release, to
   establish whether it is the static build in general or this build in
   particular.

---

## 8. Reproduction

**Host** (all measurements 2026-08-27): x86-64, kernel `7.0.0-29-generic`,
cgroup v2 unified, AppArmor enabled and enforcing. Sysctls as read:
`kernel.unprivileged_userns_clone = 1`, `user.max_user_namespaces = 57168`,
**`kernel.apparmor_restrict_unprivileged_userns = 1`**,
`kernel.yama.ptrace_scope = 1`, `net.core.bpf_jit_enable = 1`.
`/dev/kvm` is `crw-rw---- root:kvm` (gid 991); `/etc/shadow` is
`0640 root:shadow`.

**Binaries:**

- `/opt/kata/bin/qemu-system-x86_64` — "QEMU emulator version 11.0.1
  (kata-static)", `ELF … static-pie linked, stripped`, BuildID
  `10220d7928d4a1f9fade1ff244bd94464dc255c2`.
- `/opt/qemu-nvkvm/bin/qemu-system-x86_64` — "QEMU emulator version 9.2.0
  (v9.2.0-dirty)", dynamically linked. The nvkvm target version.

**Commits all citations are against:**

| repo | commit |
|---|---|
| `kata-containers/kata-containers` | `f62eccef79b074a6bf70129e5f96638df53b64ad` (`f62ecce`) |
| `qemu/qemu` | `ae35f033b874c627d81d51070187fbf55f0bf1a7`, tag `v9.2.0` |
| `nvkvm-pv` | `084df49` |
| `nvkvm-steamos` | `63fcc35` |
| `cncf-tags/container-device-interface` | `23b69d2` |
| `opencontainers/runc` | `9674194` |

**Programs used.** Four short C programs were written and run; they are not
committed because they are throwaway, but each is fully specified by what it
does and can be rebuilt in minutes:

- `nsprobe.c` — replicates `nvkvm_iso_probe_namespaces()`
  (`nvkvm_isolate_uid.h:428`) *and* the real spawn (clone with the production
  flags, parent writes `setgroups: deny` + `0 <euid> 1` to the child's
  `uid_map`, child does `MS_REC|MS_PRIVATE` on `/` then mounts a 256 KiB tmpfs
  on `/proc`). Prints both answers. Used for §3.2 and §3.3.
- `dacprobe.c` — opens `/etc/shadow` (r and w), `/etc/passwd` (w), creates
  `/etc/ld.so.preload` and `/etc/cron.d/pwn`, opens `/dev/mem`, `/dev/kvm`,
  `/proc/1/mem`, and `ptrace`/`kill(0)`s a given root PID. Used for §3.5.
- `wrap.c` — the wrapper prototype of §4.3.2. ~60 lines.
- `scbench.c` — libseccomp filter of 45 deny rules over `SCMP_ACT_ALLOW`, timing
  `ioctl()` on an eventfd. Used for §4.1.

**Commands:**

```bash
# §3.2 — which capabilities buy nvkvm's namespace rung, at uid 0
capsh --caps="cap_setpcap,cap_sys_admin=eip" --drop=all --caps="cap_sys_admin=eip" -- -c /tmp/nsprobe
capsh --caps="cap_setpcap,cap_sys_admin,cap_setfcap=eip" --drop=all \
      --caps="cap_sys_admin,cap_setfcap=eip" -- -c /tmp/nsprobe
capsh --drop=all --caps="" -- -c /tmp/nsprobe
setpriv --reuid=65534 --regid=65534 --clear-groups /tmp/nsprobe
dmesg | grep -E 'userns_create|unprivileged_userns'      # the AppArmor mechanism

# §3.5 — what uid 0 with an empty capability set can still do
sleep 600 & capsh --drop=all --caps="" -- -c "/tmp/dacprobe $!"

# §4.1 — the elevateprivileges=children bug
strace -e trace=prctl /opt/kata/bin/qemu-system-x86_64 -machine none -display none \
   -sandbox on,obsolete=deny,elevateprivileges=children,resourcecontrol=deny
#   prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0xffffff00, 0xaaaaaaab) = -1 EINVAL

# §4.2 — -run-with on Kata's QEMU
/opt/kata/bin/qemu-system-x86_64 -machine q35,accel=kvm -m 128 -display none \
   -nodefaults -S -run-with user=65534:65534          # SIGSEGV
/opt/kata/bin/qemu-system-x86_64 -machine none -display none -monitor none \
   -serial none -S -run-with chroot=/tmp/jailroot     # runs
/opt/qemu-nvkvm/bin/qemu-system-x86_64 -machine q35,accel=kvm -m 128 -display none \
   -nodefaults -S -run-with user=65534:65534          # runs (9.2.0, dynamic)

# §4.3 — the wrapper prototype
/tmp/wrap 500000 991 sh -c "id; /tmp/dacprobe <root-pid>; /tmp/nsprobe"
```

The `-sandbox` value table, the `seccompsandbox` plumbing and the cgroup/device
measurements this document builds on are in
[01 §1.4, §1.6, §3.3](01-vmm-confinement.md) and are reproduced by
`scripts/check-vmm-device-access.sh`.
