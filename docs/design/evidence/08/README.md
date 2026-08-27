# evidence/08 — the installer, on real hardware

Raw output behind [`docs/install.md`](../../install.md). Everything here was
produced on the host in [§Measured on](../../install.md#measured-on),
2026-08-27/28, by the committed scripts.

| file | what it shows |
|---|---|
| `install-cold-host.log` | the first run, on a host with **no Kata, no QEMU, no guest kernel**: every stage from source to installed. Ends in a FAILURE — the `KATA_CONF_FILE` rejection that `installed-state.log` and `install.md §5d` explain. |
| `install-final.log` | the run that passes: all nine stages, `--containerd-cri`, five verify PASSes ending in `VECADD OK`. |
| `per-container-selection.log` | the point of the whole thing: the same compose file, one service on `runtime: nvkvm-kata` computing on an RTX 3090 and one on the host's default runtime with no GPU; plus `docker run`, `ctr`, the deliberate loud failure when no `ConfigPath` is passed, stock Kata still working, and the host still holding the card. |
| `stdin-attach-control.log`, `.sh` | the control matrix showing `docker run -i` fails for **stock Kata too** — so the `docker compose run` limitation is not nvkvm's. |
| `installed-state.log` | exactly what the installer put on the host: the 4-key diff against the stock `configuration.toml`, `daemon.json`, the containerd CRI block, the shim wrapper, `shim.env`, the install manifest and the backup set the uninstaller reverts from. |

Not captured here, but run and reported in the same session: uninstall →
reinstall → uninstall, with `/etc/containerd/config.toml` byte-identical to its
pre-install content afterwards (`diff` → no output), and a third consecutive
install run producing **zero** `CHANGED` lines.
