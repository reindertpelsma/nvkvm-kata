#!/usr/bin/env bash
# STUB — NOT IMPLEMENTED. This script does nothing and exits non-zero.
#
# Intent (see docs/design/01-vmm-confinement.md, "The experiment that settles it"):
#   On a node running a Kata pod, locate the hypervisor process, then report
#     - its namespaces          (readlink /proc/<pid>/ns/*, compare against PID 1)
#     - its cgroup              (cat /proc/<pid>/cgroup)
#     - the device rules on that cgroup
#         v1: /sys/fs/cgroup/devices/<path>/devices.list
#         v2: bpftool cgroup show <cgroup path>   (device filters are eBPF)
#     - whether it can actually open the host NVIDIA nodes, by attempting it
#       from inside its own cgroup/namespace set rather than by inference
#   and print the answer for both sandbox_cgroup_only=true and =false.
#
# It is written as an experiment, not a check, because 01 marks the device-cgroup
# answer UNVERIFIED and this is what would settle it.
echo "nvkvm-kata: stub, not implemented. See docs/design/01-vmm-confinement.md" >&2
exit 64
