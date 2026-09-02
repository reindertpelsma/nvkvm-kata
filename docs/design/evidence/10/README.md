# evidence/10 — fresh hosts, three distro families, and the toolkit floor

Everything here was produced by installing from nothing on a **rented host that
had never seen this project**, not by re-running on a development box.
2026-08-28.

| file | what it shows |
|---|---|
| [`install-ubuntu2204.log`](install-ubuntu2204.log) | full install on Ubuntu 22.04, **driver 580.173.02 (open kernel module), toolkit 1.20.0, Docker 29.0.3 + containerd 2.1.5** — a different stack from the original host in [evidence/09](../09/). 5/5 PASS ending in a CUDA vector-add |
| [`install-rhel95.log`](install-rhel95.log) | full install on **RHEL 9.5 with SELinux enforcing**, driver 560.35.03 (Ampere/RTX 3090), toolkit 1.17.1, `dnf`. 5/5 PASS |
| [`arch-partial.log`](arch-partial.log) | Arch: distro detection, the whole `pacman` dependency path, Kata install, the nvkvm QEMU build and the guest kernel + `nvkvm-guest.ko` build with `depmod` — all pass. Stage 4 fails on loop-device partition scanning, which a container cannot do; that is the limit of what Arch could be tested in, and why Arch is reported as **partial** |
| [`toolkit-versions.log`](toolkit-versions.log) | the minimum-toolkit determination: every version from 1.13.5 to 1.20.0 installed and run. 1.13.5's package set will not install; 1.14.6 is the oldest that works, and was taken end to end |
| [`readme-commands.log`](readme-commands.log) | **every command in the README, executed verbatim** — the installer, the `docker run` one-liner, the compose file, the Docker-less `ctr` form, and `--gpus 1` / `"device=0"` / `"device=<uuid>"`. These were the README of 2026-08-28; the compose and `ctr` forms have since moved to [`examples/docker-compose.yml`](../../../../examples/docker-compose.yml) and [install §6a](../../../install.md#6a-containerd-bare--one-flag-no-configuration), so this log now covers a superset of the README's own commands |

## Why Arch is not a full row

vast.ai publishes no Arch KVM image (`vastai/kvm` has `ubuntu_*` and
`rhel_terminal` and nothing else), so no Arch **host** with a GPU and `/dev/kvm`
was obtainable. The Arch run above is in a privileged Arch container on a GPU
host, which covers every stage whose behaviour is distro-specific and none of
the stages that need loop devices or systemd. That is stated as a limit rather
than papered over.

## The RHEL host needed one thing done to it that an operator would not

The vast RHEL 9.5 image is **registered but unsubscribed**, so BaseOS and
AppStream are unavailable and even `dnf install bc` fails. Rocky Linux 9 repos
(binary-compatible with RHEL 9) were added to the test box to give it the base
packages an entitled RHEL host already has. That is a property of the rental,
not of the installer — but it means the RHEL row was produced on a
RHEL-plus-Rocky-repos host, and it is recorded here rather than glossed.
