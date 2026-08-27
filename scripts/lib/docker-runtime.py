#!/usr/bin/env python3
"""docker-runtime.py -- add/remove one named runtime in /etc/docker/daemon.json.

Docker >= 23.0 can map a named runtime onto a containerd shim, WITH OPTIONS:

    "runtimes": {
      "nvkvm-kata": {
        "runtimeType": "io.containerd.nvkvm-kata.v2",
        "options": { "ConfigPath": "/etc/kata-containers/configuration-nvkvm.toml" }
      }
    }

which is what makes `runtime: nvkvm-kata` work in a compose file.  Older Docker
only understands {"path": ...} OCI runtimes and cannot express this; the caller
checks the version.

`options.ConfigPath` is the load-bearing half, not a nicety.  Docker passes it
to the shim as containerd's CRI runtime options, and Kata's shim reads it
FIRST -- ahead of the KATA_CONF_FILE environment variable -- in
`loadRuntimeConfig` (src/runtime/pkg/containerd-shim-v2/create.go:273).  On
Kata 4.1.0 the environment route no longer works for a second configuration at
all: `isShippedKataConfigPath` (same file, :325) accepts only the two hardcoded
default paths and rejects anything else with "invalid KATA_CONF_FILE ...: only
shipped Kata configuration files are accepted".  MEASURED.

Exit status is the contract:
    0  the file was CHANGED
    1  nothing to do (already in the wanted state)
    2  error
Nothing else in daemon.json is touched, and the file keeps its formatting style
(2-space indent) so a human diff stays readable.
"""
import argparse, json, os, sys

PATH = '/etc/docker/daemon.json'


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path) as f:
        try:
            return json.load(f)
        except json.JSONDecodeError as e:
            # exit 2, never 1: exit 1 means "nothing to do" to the caller.
            print("docker-runtime: %s is not valid JSON (%s) -- fix it by hand first"
                  % (path, e), file=sys.stderr)
            sys.exit(2)


def save(path, cfg):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.nvkvm.tmp'
    with open(tmp, 'w') as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
        f.write('\n')
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('action', choices=['add', 'remove'])
    ap.add_argument('--name', required=True)
    ap.add_argument('--type', default='')
    ap.add_argument('--config-path', default='')
    ap.add_argument('--file', default=PATH)
    a = ap.parse_args()

    cfg = load(a.file)
    runtimes = cfg.get('runtimes', {})

    if a.action == 'add':
        want = {'runtimeType': a.type}
        if a.config_path:
            want['options'] = {'ConfigPath': a.config_path}
        if runtimes.get(a.name) == want:
            return 1
        runtimes[a.name] = want
        cfg['runtimes'] = runtimes
        save(a.file, cfg)
        return 0

    if a.name not in runtimes:
        return 1
    del runtimes[a.name]
    if runtimes:
        cfg['runtimes'] = runtimes
    else:
        cfg.pop('runtimes', None)
    # An empty daemon.json is not the same as no daemon.json, but it is
    # harmless and it is what "we removed our key" honestly looks like.
    save(a.file, cfg)
    return 0


if __name__ == '__main__':
    sys.exit(main())
