#!/bin/sh
# Offline integration tests. Requires a locally built image; never contacts Tor.
set -eu
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/test-container.sh LOCAL_IMAGE' >&2
  exit 1
fi
image=$1
cd "$(dirname "$0")/.."
work=$(mktemp -d)
# Docker daemon must be local to the filesystem used for bind mounts.
work=$(cd "$work" && pwd -P)
name="tor-relay-test-$(basename "$work" | tr '[:upper:].' '[:lower:]-')"
volume="$name-data"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || :
  docker volume rm "$volume" >/dev/null 2>&1 || :
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
# Deliberately synthetic values. The network namespace is isolated regardless
# of what the daemon attempts; no test descriptor can reach the public network.
cat > "$work/values.yaml" <<'VALUES'
image:
  repository: invalid.example/offline-test
  digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
relay:
  publicIPv4: 192.0.2.1
  contactInfo: offline-test@example.invalid
storage:
  className: test-storage
VALUES
helm template tor-relay charts/tor-relay -n tor-relay -f "$work/values.yaml" > "$work/rendered.yaml"
ruby -ryaml -e 'd=YAML.load_stream(File.read(ARGV[0])).compact; File.write(ARGV[1],d.find{|x| x["kind"]=="ConfigMap"}.fetch("data").fetch("torrc"))' "$work/rendered.yaml" "$work/torrc"
# Root-owned/GID-writable tmpfs simulates Kubernetes fsGroup volume ownership.
start() {
  docker run -d --name "$name" --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges --user 10001:10001 \
    --memory 1g --cpus 1 \
    --mount "type=volume,src=$volume,dst=/var/lib/tor" \
    --tmpfs /run/tor:uid=0,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=0700 \
    --mount "type=bind,src=$work/torrc,dst=/etc/tor/torrc,readonly" \
    "$image" >/dev/null
}
wait_live() {
  attempt=0
  until docker exec "$name" /usr/local/bin/tor-health live >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ] || [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
      docker logs "$name"
      echo 'Offline container did not become locally healthy' >&2
      exit 1
    fi
    sleep 1
  done
}
start
wait_live
# Authenticated status must work; readiness must stay false without a network.
docker exec "$name" /usr/local/bin/tor-health status > "$work/status.json"
python3 - "$work/status.json" <<'PY'
import json, sys
s=json.load(open(sys.argv[1]))
assert s['version'] and s['fingerprint']
c=s['configuration']
for expected in ('ExitRelay=0', 'IPv6Exit=0', 'SocksPort=0', 'ControlPort=0'):
    assert expected in c, (expected, c)
assert 'ExitPolicy=reject *:*' in c, c
assert 'PROGRESS=100' not in s['status/bootstrap-phase']
PY
if docker exec "$name" /usr/local/bin/tor-health ready >/dev/null 2>&1; then
  echo 'Offline relay unexpectedly became ready' >&2; exit 1
fi
docker exec "$name" /usr/bin/python3 -c '
import os, stat
from pathlib import Path
assert os.getuid()==10001
for name in ("/var/lib/tor/data", "/var/lib/tor/data/keys", "/run/tor/private"):
 s=Path(name).stat()
 assert s.st_uid==10001 and stat.S_IMODE(s.st_mode)==0o700, name
s=Path("/run/tor/private/control.authcookie").stat()
assert stat.S_IMODE(s.st_mode)==0o600
'
first=$(docker exec "$name" cat /var/lib/tor/data/fingerprint)
docker stop --time 45 "$name" >/dev/null
test "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 0
docker rm "$name" >/dev/null
start
wait_live
second=$(docker exec "$name" cat /var/lib/tor/data/fingerprint)
test "$first" = "$second"
docker stop --time 45 "$name" >/dev/null
docker rm "$name" >/dev/null
# An unsafe startup must terminate, never silently expose a proxy or exit.
cp "$work/torrc" "$work/safe-torrc"
for mutation in exit socks control; do
  python3 - "$work/safe-torrc" "$work/torrc" "$mutation" <<'PY'
from pathlib import Path
import sys
old,new={'exit':('ExitRelay 0','ExitRelay 1'),
         'socks':('SocksPort 0','SocksPort 9050'),
         'control':('ControlPort 0','ControlPort 9051')}[sys.argv[3]]
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace(old,new))
PY
  start
  attempt=0
  while [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 10 ]; then
      echo "Unsafe $mutation configuration did not exit" >&2; exit 1
    fi
    sleep 1
  done
  test "$(docker inspect -f '{{.State.ExitCode}}' "$name")" != 0
  docker logs "$name" 2>&1 | grep -q 'Tor startup refused'
  docker rm "$name" >/dev/null
done
printf '%s\n' 'Offline image integration passed: startup, control auth, non-exit config, permissions, signal shutdown, persisted identity and unsafe-config rejection.'
