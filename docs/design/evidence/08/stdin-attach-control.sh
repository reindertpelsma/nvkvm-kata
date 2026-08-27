#!/bin/bash
# Is "container start hangs when stdin is attached" nvkvm-specific or Kata-generic?
cleanup() {
  for c in $(docker ps -aq); do timeout 15 docker rm -f "$c" >/dev/null 2>&1; done
  pids=$(ps -eo pid,comm | awk '$2 ~ /^qemu-system|^containerd-shim|^virtiofsd/ {print $1}')
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  sleep 3
  for c in $(docker ps -aq); do timeout 15 docker rm -f "$c" >/dev/null 2>&1; done
}
# register a stock-kata docker runtime alongside, for the control
python3 - <<'PY'
import json
p='/etc/docker/daemon.json'; c=json.load(open(p))
c['runtimes']['kata-stock']={'runtimeType':'io.containerd.kata.v2'}
json.dump(c,open(p,'w'),indent=2)
PY
systemctl reload docker; sleep 4
run() { echo "=== $1 ==="; shift; timeout 100 "$@" 2>&1 | tail -3; echo "RC=$?"; cleanup; }
run "A nvkvm, no stdin"      docker run --rm --runtime nvkvm-kata ubuntu:24.04 uname -r
run "B nvkvm, -i"            docker run --rm -i --runtime nvkvm-kata ubuntu:24.04 uname -r
run "C stock kata, no stdin" docker run --rm --runtime kata-stock ubuntu:24.04 uname -r
run "D stock kata, -i"       docker run --rm -i --runtime kata-stock ubuntu:24.04 uname -r
run "E runc, -i"             docker run --rm -i ubuntu:24.04 uname -r
echo "=== F compose up ==="
cd /root/nvkvm-kata && timeout 150 docker compose -f examples/docker-compose.yml up --abort-on-container-exit cuda 2>&1 | tail -6; echo "RC=$?"
cleanup
# put daemon.json back
python3 - <<'PY'
import json
p='/etc/docker/daemon.json'; c=json.load(open(p))
c['runtimes'].pop('kata-stock',None)
json.dump(c,open(p,'w'),indent=2)
PY
systemctl reload docker
echo DONE
