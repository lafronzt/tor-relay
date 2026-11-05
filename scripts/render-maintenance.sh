#!/bin/sh
# Generate reviewable offline backup/restore resources; NEVER applies them.
set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: scripts/render-maintenance.sh backup|restore values.local.yaml' >&2
  exit 1
fi
mode=$1
values=$2
case "$mode" in backup|restore) ;; *) echo 'Invalid mode' >&2; exit 1 ;; esac
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
helm template tor-relay "$root/charts/tor-relay" -n tor-relay -f "$values" | ruby -ryaml -e '
  mode=ARGV.fetch(0)
  docs=YAML.load_stream(STDIN.read).compact
  spec=docs.find { |d| d["kind"]=="StatefulSet" }.fetch("spec").fetch("template").fetch("spec")
  name="tor-relay-#{mode}"
  container=spec.fetch("containers").first
  pod_spec={"restartPolicy"=>"Never", "automountServiceAccountToken"=>false,
    "enableServiceLinks"=>false,"securityContext"=>spec.fetch("securityContext"),
    "containers"=>[{"name"=>mode,"image"=>container.fetch("image"),
      "command"=>["/bin/sleep","infinity"],"securityContext"=>container.fetch("securityContext"),
      "resources"=>{"requests"=>{"cpu"=>"10m","memory"=>"16Mi"},"limits"=>{"cpu"=>"250m","memory"=>"128Mi"}},
      "volumeMounts"=>[{"name"=>"data","mountPath"=>"/var/lib/tor","readOnly"=>mode=="backup"}]}],
    "volumes"=>[{"name"=>"data","persistentVolumeClaim"=>{"claimName"=>"tor-relay-data"}}]}
  # Backup reads existing UID-owned data; avoid fsGroup altering key permissions.
  if mode=="backup"
    pod_spec["securityContext"].delete("fsGroup")
    pod_spec["securityContext"].delete("fsGroupChangePolicy")
  end
  %w[nodeSelector imagePullSecrets].each { |key| pod_spec[key]=spec[key] if spec.key?(key) }
  label={"app.kubernetes.io/name"=>name}
  puts({"apiVersion"=>"v1","kind"=>"Pod","metadata"=>{"name"=>name,"namespace"=>"tor-relay","labels"=>label},"spec"=>pod_spec}.to_yaml)
  puts({"apiVersion"=>"networking.k8s.io/v1","kind"=>"NetworkPolicy","metadata"=>{"name"=>name,"namespace"=>"tor-relay"},"spec"=>{"podSelector"=>{"matchLabels"=>label},"policyTypes"=>["Ingress","Egress"],"ingress"=>[],"egress"=>[]}}.to_yaml)
' "$mode"
