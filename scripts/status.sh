#!/bin/sh
# Read-only: no restart, delete, or configuration changes.
set -eu
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the intended Kubernetes context}"
k() { kubectl --context "$KUBE_CONTEXT" --namespace tor-relay --request-timeout=10s "$@"; }
k get statefulsets,pods,pvc,services,networkpolicies -o wide
k exec tor-relay-0 -- /usr/local/bin/tor-health status
k exec tor-relay-0 -- sh -c 'id; df -h /var/lib/tor; stat -c "%a %u:%g %n" /var/lib/tor/data /var/lib/tor/data/keys /run/tor/private; cat /proc/1/limits'
k top pod tor-relay-0 --containers
