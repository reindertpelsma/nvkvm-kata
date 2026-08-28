# evidence/09 — `--gpus all`, and nothing else

Raw output behind [09 — `--gpus all`, and nothing else](../09-gpu-libraries-automatically.md).
Host: vast.ai KVM instance, RTX 4070 Ti SUPER, driver 575.51.03, Ubuntu 22.04,
cgroup v2, containerd 1.7.27, Docker 28.1.1, Kata 4.1.0, guest kernel
6.18.35-nvkvm. 2026-08-28.

| file | what it settles |
|---|---|
| [`acceptance.log`](acceptance.log) | **the acceptance test, verbatim**, plus CUDA compute in the same container, `nvcc` on a driver-matched image, the resolution state the user never arranged, the stock-`runc` control, the `--gpus 2` failure mode, and the negative controls |
| [`guest-cdi-hooks.log`](guest-cdi-hooks.log) | **the pivotal measurement**: kata-agent executes `createContainer` hooks from a guest-resident CDI spec. Includes what the guest rootfs has to run them with |
| [`ldcache-ablation.log`](ldcache-ablation.log) | SONAME mounts alone / ldconfig hook alone / both. Answers "does `updateLdCache` alone suffice" — yes — and shows why the cache is not cosmetic |
| [`shim-bundle-probe.log`](shim-bundle-probe.log) | where the host can still edit the OCI spec (`config.json` is in the bundle at `shim start`), what Docker's `--gpus all` puts in it, and the prestart hook that made `--gpus` fail outright before this change |
| [`toolkit-under-runc.log`](toolkit-under-runc.log) | the owner's four-point analysis, confirmed: `mount` and `ls -la /usr/lib/x86_64-linux-gnu` inside `docker run --gpus all ubuntu`. Versioned files are bind mounts; the SONAME links are dated *now*, in the writable layer |
| [`nvidia-ctk-cdi-generate.json`](nvidia-ctk-cdi-generate.json) | a literal `nvidia-ctk cdi generate` spec from a real driver host — the fixture [02 §A](../02-libraries-via-cdi.md) asked for. Note that `create-symlinks` carries no SONAME links |
| [`gpu-mounts.json`](gpu-mounts.json) | the manifest `gpu-cdi.py discover` distils out of it: 76 mounts, each tagged with `why` |
| [`docker-gpus-forms.log`](docker-gpus-forms.log) | `--gpus all` / `1` / `"device=0"` / `"device=GPU-<uuid>"` / `capabilities=…`, the negative controls, and the cost of the 76 mounts on sandbox start |
| [`clean-install.log`](clean-install.log) | a full uninstall → reinstall → 5/5 PASS on a host that had the old stage 7 |
| [`injector.log`](injector.log) | the injector's own log, one line per GPU container started |
