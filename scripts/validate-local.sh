#!/bin/sh
# Offline chart/security tests. Deliberately uses a nonexistent test image.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cat > "$work/values.yaml" <<'VALUES'
image:
  repository: invalid.example/tor-relay-validation-only
  digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
relay:
  publicIPv4: 192.0.2.1
  contactInfo: validation@example.invalid
storage:
  className: microk8s-hostpath
VALUES
helm lint charts/tor-relay --namespace tor-relay --strict -f "$work/values.yaml"
helm template tor-relay charts/tor-relay --namespace tor-relay -f "$work/values.yaml" > "$work/rendered.yaml"
ruby tests/check-manifests.rb "$work/rendered.yaml" "$work/torrc"
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_safety.py "$work/torrc"
# Required values and config injection must fail, rather than render a workload.
if helm template tor-relay charts/tor-relay -n tor-relay > /dev/null 2>&1; then
  echo 'ERROR: missing required values rendered' >&2; exit 1
fi
if helm template tor-relay charts/tor-relay -n tor-relay -f "$work/values.yaml" --set-string 'relay.contactInfo=unsafe#comment' > /dev/null 2>&1; then
  echo 'ERROR: unsafe contact rendered' >&2; exit 1
fi
helm template tor-relay charts/tor-relay -n tor-relay -f "$work/values.yaml" --set-string "relay.contactInfo=Operator O'Reilly <contact@example.invalid>" > "$work/quoted.yaml"
ruby tests/check-manifests.rb "$work/quoted.yaml" "$work/quoted-torrc"
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_safety.py "$work/quoted-torrc"
helm template tor-relay charts/tor-relay -n tor-relay -f "$work/values.yaml" --set relay.accounting.enabled=true > "$work/accounting.yaml"
ruby tests/check-manifests.rb "$work/accounting.yaml" "$work/torrc"
for mode in backup restore; do
  ./scripts/render-maintenance.sh "$mode" "$work/values.yaml" > "$work/$mode.yaml"
  ruby -ryaml -e '
    d=YAML.load_stream(File.read(ARGV[0])).compact
    pod=d.find { |x| x["kind"]=="Pod" }
    c=pod["spec"]["containers"][0]
    raise "maintenance mount permission" unless c["volumeMounts"][0]["readOnly"]==(ARGV[1]=="backup")
    raise "maintenance root" unless pod["spec"]["securityContext"]["runAsNonRoot"]
    raise "maintenance token" unless pod["spec"]["automountServiceAccountToken"]==false
    p=d.find { |x| x["kind"]=="NetworkPolicy" }["spec"]
    raise "maintenance networking" unless p["ingress"]==[] && p["egress"]==[]
  ' "$work/$mode.yaml" "$mode"
done
printf '%s\n' 'Offline validation passed. Image execution, API schema/admission, CNI, storage, and network participation still require verification.'
