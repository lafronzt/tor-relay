#!/bin/sh
# Read-only cluster inventory. No apply, exec, or router changes.
set -eu
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the intended Kubernetes context}"
k() { kubectl --context "$KUBE_CONTEXT" --request-timeout=10s "$@"; }
k get nodes -o wide
k get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,KERNEL:.status.nodeInfo.kernelVersion
k get storageclasses -o wide
k get services -A -o wide
k -n kube-system get daemonsets,deployments -o wide
k get networkpolicies -A
k top nodes
printf '%s\n' 'Verify NodePort 30001 is unused, storage permissions, CNI policy enforcement, disk headroom, runtime nofile >= 16384, and at least 512Mi RAM available.'
