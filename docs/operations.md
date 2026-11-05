# Operations guide

Use `export KUBE_CONTEXT=your-context` with all commands below. Replace placeholders with your own values and keep operator configuration outside Git. The project has no dependency on a particular ISP, router vendor, or home location.

## Architecture

```text
Tor peers → public IPv4 TCP 9001 → router port forward
          → node LAN TCP 30001 → NodePort service TCP 9001
          → tor-relay-0 TCP 9001
              /var/lib/tor → retained 1Gi ReadWriteOnce PVC
                data/keys → private persistent relay identity
              /run/tor/private → ephemeral cookie-authenticated Unix control socket
```

Helm manages the namespace, ConfigMap, StatefulSet (one replica), PVC, NodePort, governing headless Service, and optional NetworkPolicy. There is no Ingress, public control port, metrics Service, or SOCKS listener. The extra headless Service is internal and exposes only the ORPort. The relay needs outbound TCP to public relays on arbitrary ports, plus DNS. Kubernetes responses to allowed inbound connections are permitted by stateful network policy.

**“Middle” means non-exit here.** Tor authorities may eventually assign a Guard flag. There is no supported operator setting that guarantees use only in the middle position. `ExitRelay 0`, `IPv6Exit 0`, `ExitPolicy reject *:*`, and the startup safety gate enforce non-exit configuration; `SocksPort 0` prevents proxy service. If strict middle-position-only behavior is mandatory, resolve that constraint before deploying.

## Files

- `charts/tor-relay/`: Helm chart, configurable bandwidth/resources/storage, strict values schema.
- `image/`: minimal Debian-packaged Tor image, configuration safety gate, authenticated probes/status client.
- `values.example.yaml`: local configuration starting point.
- `scripts/preflight.sh`: read-only cluster inventory.
- `scripts/validate-local.sh`, `tests/`: offline chart and security regression checks.
- `scripts/status.sh`: read-only live diagnostics after deployment.
- `scripts/render-maintenance.sh`: render isolated backup/restore pods for review; never applies them.

## Before deployment

Run from a machine that can reach the cluster. Select it explicitly:

```sh
export KUBE_CONTEXT=your-context
./scripts/preflight.sh
kubectl --context "$KUBE_CONTEXT" get storageclass -o yaml
kubectl --context "$KUBE_CONTEXT" get nodes --show-labels
kubectl --context "$KUBE_CONTEXT" get services -A -o wide
```

Confirm:

1. Exactly the intended node and CPU architecture; stable node LAN address via DHCP reservation. Check that `30001/TCP` is unallocated and allowed through the node firewall from the router. NodePort normally binds all node interfaces, subject to kube-proxy's nodePortAddresses setting. Check IPv6 and other interface firewall behavior too.
2. A suitable storage class. `microk8s-hostpath` is common, but deliberately not assumed. Confirm its provisioner, reclaim policy, volume permissions, expansion support and node affinity. Verify disk capacity and backups. The pod cannot repair root-only volume permissions; the storage driver must permit UID/GID 10001 to create a private child directory. Inspect failed mount/permission events instead of adding a privileged root init container.
3. CNI NetworkPolicy enforcement (often Calico on MicroK8s), actual service/pod CIDRs, DNS path, and hairpin/NAT behavior. Test ingress and egress enforcement with your usual cluster tooling after approval. Extend excluded CIDRs if the LAN/cluster uses other private or publicly numbered local ranges. Policies are additive: broader policies can weaken this one. Node traffic can bypass pod policies depending on CNI; enforce the WAN boundary at the router/node firewall too.
4. At least 512Mi available RAM and CPU/disk headroom alongside other apps. Check runtime soft/hard `nofile` limits on the node and later `/proc/1/limits` in the pod; target at least 16384 descriptors for thousands of connections. Kubernetes has no portable pod ulimit setting. If needed, change the MicroK8s/containerd service limits through your established node-management process, with approval. Watch node conntrack capacity, not just pod CPU.
5. Public IPv4: compare router's WAN IPv4 with an external lookup from **inside the home network**, for example `curl -4 https://api.ipify.org`. A private WAN address, `100.64.0.0/10`, or differing addresses suggests CGNAT/double NAT. Resolve with your ISP/upstream NAT before deployment. Do not infer the home's public address from a remote build machine. Confirm the service plan's bandwidth/usage terms.

## Image provenance and build

No official production relay image was established from the reviewed Tor sources. The Tor onion-service container documentation describes its images as experimental. Rather than adopt an unverified third-party relay image, this repository builds from the Docker Official Debian `trixie-slim` image and Debian's maintained security package.

Dependency metadata reviewed 2026-11-05; recheck advisories before each release:

- Debian stable `tor` security package: **`0.4.9.15-0+deb13u1`** (amd64 and arm64 supported).
- Base multi-architecture OCI index: **`sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`**, verified from Docker Hub tag metadata.
- Debian's manpage currently documents an older patch release than the package page. Runtime verification below is required against the built package.

The Dockerfile pins the base digest and Tor/GeoIP package versions. Transitive OS packages come from signed Debian repositories at build time; builds are not fully bit-reproducible snapshots. The final deployed image must be digest-pinned. Package removal/supersession should fail the build: review a supported replacement version rather than silently removing the pin. Tor's tutorial prefers its own repository; this implementation uses a maintained distribution package. Check current Tor advisories and supported relay versions again when building.

On a trusted build host, using your chosen registry (do not put registry credentials in Git):

```sh
# Replace registry, tag, and platform with your own values.
export RELAY_IMAGE=ghcr.io/YOUR_ACCOUNT/tor-relay
# --push writes to your registry; run when ready to publish the tested image.
docker buildx build --pull --no-cache --platform linux/amd64 \
  -f image/Dockerfile -t "$RELAY_IMAGE:0.4.9.15-1" --load .
docker run --rm --entrypoint /usr/bin/tor "$RELAY_IMAGE:0.4.9.15-1" --version
# Scan using your usual image scanner before push (for example Trivy).
trivy image --exit-code 1 --severity HIGH,CRITICAL "$RELAY_IMAGE:0.4.9.15-1"
docker push "$RELAY_IMAGE:0.4.9.15-1"
docker buildx imagetools inspect "$RELAY_IMAGE:0.4.9.15-1"
```

Use `linux/arm64` if that is the verified node architecture, or publish/test a multiarch image. Record the registry's **final image/index digest**, not the Debian base digest, in `image.digest`. Authenticate separately on MicroK8s or reference an existing namespace-local imagePullSecret if the registry is private. The chart intentionally rejects a missing digest.

Before pushing or deploying, run the actual image through the automated offline tests:

```sh
./scripts/test-container.sh "$RELAY_IMAGE:0.4.9.15-1"
```

This uses synthetic values and no network or published ports. It checks the complete entrypoint under a read-only filesystem, root-owned/fsGroup-writable runtime mount, non-root UID, dropped capabilities, and private control authentication. It also checks shutdown, identity persistence across recreation, failed offline readiness, and rejection of unsafe exit/proxy/control settings. Run it **before** the `docker push` command above. A version-specific safety-gate failure must be investigated; never disable the restrictions merely to pass a test.

## Render and deploy

Fill in `values.local.yaml`; contact information and public IPv4 will be published. Default bandwidth is `2 MB`/`4 MB`. Use release `tor-relay` and namespace `tor-relay`; the namespace is enforced and fixed resource names prevent multiple independent releases.

```sh
./scripts/validate-local.sh
helm lint charts/tor-relay --strict -n tor-relay -f values.local.yaml
helm template tor-relay charts/tor-relay -n tor-relay -f values.local.yaml > rendered.yaml
# Inspect the rendered file. Once the namespace exists, validate against the API:
# kubectl --context "$KUBE_CONTEXT" apply --dry-run=server -f rendered.yaml
```

The dry-run above needs an existing namespace for namespaced admission; a dry-run Namespace does not persist one. It is a read-only validation request, not a substitute for reviewing the rendered manifests.

**The following command changes your selected cluster. Review the rendered manifests first.**

```sh
# Helm creates the namespace from the chart. Do not use --create-namespace:
# it would create a namespace without the chart's security labels/ownership.
helm upgrade --install tor-relay charts/tor-relay --kube-context "$KUBE_CONTEXT" \
  --namespace tor-relay -f values.local.yaml --wait --timeout 15m
kubectl --context "$KUBE_CONTEXT" -n tor-relay rollout status statefulset/tor-relay --timeout=15m
```

Check your Helm version's namespace bootstrap behavior in a staging cluster before first install; this chart includes a Namespace resource. If the namespace already exists, reconcile its labels and Helm ownership intentionally before installing, rather than blindly adopting unrelated resources. No install command is run by the validation scripts. No automatic rollback/delete flags are used to avoid masking a failed first install or risking storage.

## Router networking (manual)

In your router's port-forwarding settings (menu names vary by version), create exactly:

| Setting | Value |
| --- | --- |
| Protocol | TCP only |
| WAN / public port | 9001 |
| Forward IP | Verified MicroK8s node **LAN IPv4**, with DHCP reservation |
| Forward port | 30001 |
| Source | Any (Tor peers are global) |

Flow: **WAN TCP 9001 → node LAN TCP 30001 → pod TCP 9001**. Do not forward WAN 30001, SOCKS, control, DNS, DirPort, or metrics. No HTTP Ingress, Cloudflare proxy, VPN routing, hostPort, host networking, or UPnP is used. Keep other WAN rules unchanged. Restrict unrelated WAN-to-node traffic; NodePort is also reachable from the LAN unless a firewall restricts it.

Set `relay.publicIPv4` to that same public WAN address. NAT changes only the service path; Tor advertises `publicIPv4:9001`, never `30001`. There is no IPv6 OR listener in this chart. If public IPv4 changes, update the value and roll out promptly; a stable address is preferable. Do not blindly automate a lookup from an unrelated network.

After cluster and forwarding approval, test from a genuinely external IPv4 network (remote VPS or cellular with Wi-Fi/VPN disabled):

```sh
nc -4 -vz -w 5 PUBLIC_IPV4 9001
openssl s_client -connect PUBLIC_IPV4:9001 -brief </dev/null
```

A successful TCP/TLS connection only proves part of the path. Confirm Tor's own ORPort self-test/reachability log and directory listing as described below. A test from home may rely on NAT hairpinning and is insufficient. If testing fails, inspect router WAN/firewall counters and node packets (`sudo tcpdump -ni any tcp port 30001` on the node) to distinguish ISP filtering from NAT/firewall/CNI errors. Capture only what is necessary; avoid saving relay traffic. No ISP blocking or public reachability has yet been verified.

## Resources and bandwidth

Defaults: 250m CPU/512Mi RAM requested, 1 CPU/1Gi RAM limited; 1Gi PVC; 128Mi ephemeral storage limit. Tor uses one onionskin worker and a 256 MB queue threshold. That threshold is **not** a total memory cap. Watch RSS, CPU throttling and OOM events; raise memory/request/limit together if needed. A PVC request may not enforce a disk quota with MicroK8s hostpath. Monitor underlying node disk and kubelet pressure.

Tor interprets `MB` as 2^20 bytes. At 2 MB/s continuously over 30 days:

- Each direction: 5,435,817,984,000 bytes ≈ **5.44 TB / 4.94 TiB**.
- Receive + transmit: ≈ **10.87 TB / 9.89 TiB** (31 days ≈ 11.23 TB combined).
- Rate is about **16.8 Mbit/s in each direction**, with separate 4 MiB burst buckets. A burst value is bucket capacity, not an independent sustained rate.

These are full-utilization estimates, not predictions or hard ISP caps. New relays ramp up gradually. RelayBandwidthRate covers relayed traffic; directory fetches and protocol/link overhead can add traffic. Node/router counters are the source of truth for ISP usage. `CountPrivateBandwidth 1` ensures Kubernetes SNAT/private sources do not evade relay shaping.

Leave substantial upload/download headroom for home services. Measure WAN capacity and latency under load; a practical starting point is to keep total shaped demand below 70–80% of measured capacity. Consider router smart queues/QoS and lower-priority treatment for this node/flow, accounting for router throughput costs. Node-wide limits also affect your other self-hosted apps. Classifying only port 9001 will miss relay-initiated outbound TCP connections. Verify actual rules/counters rather than assuming a port rule shapes all Tor traffic. Monitor concurrent sessions and conntrack load; low bandwidth does not ensure a small connection table.

For a volume budget, enable `relay.accounting.enabled` with `rule: sum`, `max: "1 TB"`, `start: "month 1 00:00"`. Here 1 TB means **1 TiB total in + out**, not a decimal ISP terabyte. Tor hibernates near exhaustion and may wake at a randomized point in the next UTC accounting interval. Readiness fails while hibernating, but liveness stays healthy, avoiding a restart loop. Budget below ISP allowance for other apps and overhead. Continuous uptime is preferable on unmetered service; accounting is suitable for a real monthly cap. `rule: max` permits up to roughly twice the configured amount combined; do not use it for a combined ISP cap.

## Security review

- UID/GID 10001, no root init container, no privilege escalation, all capabilities dropped, RuntimeDefault seccomp, read-only root, no service-account token or host mounts. Writable volumes are the PVC, bounded `/run/tor` tmpfs, and bounded `/tmp`.
- PVC root may be root-owned/fsGroup-writable. The application creates **`/var/lib/tor/data`** itself, owned by UID 10001, mode 0700. Keys live under `data/keys`, never in the ConfigMap. `/run/tor/private` is similarly user-owned and 0700 despite the volume root being root-owned. Umask 077; private cookie, no group control access. Host administrators and Kubernetes exec/volume privileges still grant access: restrict RBAC and host access; hostpath is normally unencrypted.
- Entrypoint verifies Tor's config and checks its effective dump for non-exit, disabled proxy/TCP control, exact OR listener, private cookie control and persistent data path. No arbitrary torrc injection value exists; the schema rejects line breaks/comment injection in public contact data. The gate runs on start, not continuously: trusted cluster admins with exec access can still alter the running daemon. Restrict access accordingly.
- Probes authenticate over a local Unix socket. Neither cookie nor private key contents are printed. No unauthenticated TCP control interface is created. Status output includes public fingerprint and aggregate byte counts.
- NetworkPolicy permits ingress only to TCP 9001 and restricts TCP egress to public IPv4, excluding private/reserved ranges. DNS is deliberately allowed on UDP/TCP 53 to any destination for compatibility with unverified cluster/NodeLocal DNS; narrow to the verified resolver if possible. This DNS exception permits private TCP 53 too. Cluster policy cannot replace the Tor non-exit settings or the router firewall.
- No elevated settings are required for the selected image. Debian's default service wrapper/systemd, package user `debian-tor`, and automatic service startup are bypassed: direct foreground `/usr/bin/tor` runs as UID 10001. Do not add `User debian-tor` to torrc or reuse an image that requires root/chown on startup. Port 9001 needs no bind capability. Kubernetes seccomp applies; Tor's separate `Sandbox` feature is left at its default, not assumed compatible without a runtime test.
- Namespace enforces Restricted Pod Security. `enforce-version: latest` follows cluster upgrades; revalidate admission before upgrades. It protects future namespace workloads but does not make the homelab node a hardened security boundary.
- Running a public relay publishes your home IP/contact and may affect IP reputation even for a non-exit relay. Tor's relay-types documentation discusses bridges/Snowflake if that is unsuitable. Keep this single relay available; declare a Tor family if operating additional relays in the future.

## Monitoring and validation

```sh
./scripts/status.sh
kubectl --context "$KUBE_CONTEXT" -n tor-relay logs tor-relay-0 --tail=200
kubectl --context "$KUBE_CONTEXT" -n tor-relay logs tor-relay-0 --previous --tail=200
kubectl --context "$KUBE_CONTEXT" -n tor-relay describe pod tor-relay-0
kubectl --context "$KUBE_CONTEXT" -n tor-relay get events --sort-by=.lastTimestamp
kubectl --context "$KUBE_CONTEXT" -n tor-relay top pod tor-relay-0 --containers
kubectl --context "$KUBE_CONTEXT" -n tor-relay exec tor-relay-0 -- /usr/local/bin/tor-health status
```

Startup and liveness check authenticated local responsiveness, not Internet availability. Startup allows five minutes for control readiness; readiness waits for bootstrap 100%, an OR listener and non-hibernating accounting state. Liveness deliberately does not require connectivity/consensus/reachability, so WAN outages do not restart a healthy daemon. Readiness **does not prove reachability or network participation**. Notice-level stdout includes bootstrap, reachability warnings and hourly heartbeat aggregate bytes/circuits. Configure existing cluster log retention/rotation so logs cannot fill the host disk; do not enable debug traffic logging routinely.

Use `traffic/read`/`traffic/written` from the status command for per-process cumulative counters; sample deltas over time, allowing for resets at restart. Tor state/accounting and router WAN counters help with monthly usage. Save aggregate monitoring data using existing infrastructure, not private keys/cookies. No exporter dependency is required. If Prometheus already collects kubelet/cAdvisor and kube-state-metrics, useful expressions include:

```promql
increase(kube_pod_container_status_restarts_total{namespace="tor-relay",container="tor"}[1h]) > 0
kube_statefulset_status_replicas_ready{namespace="tor-relay",statefulset="tor-relay"} < 1
rate(container_cpu_usage_seconds_total{namespace="tor-relay",container="tor"}[5m])
container_memory_working_set_bytes{namespace="tor-relay",container="tor"}
rate(container_network_receive_bytes_total{namespace="tor-relay",interface="eth0"}[5m])
rate(container_network_transmit_bytes_total{namespace="tor-relay",interface="eth0"}[5m])
```

Adapt metric labels to the existing collectors; pod network stats may have multiple series, so avoid double counting. Alert on sustained not-ready (e.g. 15 minutes), restarts/OOM, memory above 80% of the limit, persistent CPU throttling, node disk/conntrack pressure, and public reachability loss. Suppress readiness alerts during intentional accounting hibernation. Public connectivity needs an independent off-LAN TCP/TLS monitor plus Tor status verification. If an exporter is added later, use the existing private Unix socket/cookie with minimal permissions and an internal, policy-restricted scrape endpoint; never forward a control or metrics port.

After deployment, complete all of these on your own cluster:

- [ ] Pod starts and stays healthy; effective config accepted; no unsafe-config error, crash loop, OOM, or permission warning. Review bootstrap logs, startup/readiness probes and events.
- [ ] PVC is Bound, mounted at `/var/lib/tor`; `data` and `data/keys` owned by 10001 with 0700 permissions; inspect `df`, `stat` (the status script does this). Never cat private keys.
- [ ] Record **public** fingerprint: `kubectl --context "$KUBE_CONTEXT" -n tor-relay exec tor-relay-0 -- cat /var/lib/tor/data/fingerprint`. After approval, `kubectl --context "$KUBE_CONTEXT" -n tor-relay delete pod tor-relay-0`; wait for readiness and compare the fingerprint exactly. Confirm PVC/PV unchanged. Do the same during an approved node reboot/maintenance window; local storage must survive node reboot.
- [ ] Remote TCP/TLS probe succeeds through WAN 9001 to NodePort 30001; Tor logs report ORPort reachable, and control status `status/reachability-succeeded` reports `OR=1`. IPv4-only setup needs no DirPort. Investigate a persistent `OR=0`, even if bootstrap is 100%.
- [ ] Live status shows `ExitRelay=0`, reject-all ExitPolicy, `IPv6Exit=0`, `SocksPort=0`, `ControlPort=0`, and only the expected OR listener. `tor --dump-config full` can be inspected locally, but do not paste logs or entire state indiscriminately.
- [ ] Search the **fingerprint** at `https://metrics.torproject.org/rs.html#search/FINGERPRINT` (not just the non-unique nickname). Verify advertised public `IPv4:9001`, Running/Valid flags, **no Exit flag**, and reject-all policy. Inspect descriptor publication/acceptance logs and growing relayed byte/circuit counts. Bootstrap alone proves only directory connectivity, not successful relay service.
- [ ] Observe sustained behavior over 24–72 hours: traffic ramp-up, resources, latency of home apps, router sessions and node pressure. Metrics/listing commonly takes hours; bandwidth measurement and flags can take days to weeks. Guard/Stable eligibility is authority-controlled; no promised time or traffic amount.
- [ ] Services list contains only NodePort 30001/ORPort 9001 and the internal headless ORPort service. Verify no Ingress/LoadBalancer, hostPort, SOCKS, TCP control, IPv6 OR, or metrics listener. Review actual router rules and test non-OR ports externally on your own address; use `ss -lnt` on the node to inspect unintended host listeners.
- [ ] Test NetworkPolicy with your CNI tooling: public relay egress allowed; private LAN TCP (except documented DNS) and non-OR pod ingress denied. Confirm outbound arbitrary TCP connectivity and DNS still work.

## Upgrades and maintenance

Subscribe to Tor release/security announcements and check Debian security updates regularly (at least weekly; urgent advisories promptly). Containers do not update themselves. Rebuilding is necessary; restarting an old digest does not patch it.

1. Check Tor's supported relay versions, Debian security package availability, base image metadata, and release notes. Update the Dockerfile's base digest/Tor package pin and Chart appVersion together. Never downgrade to an unsupported/insecure version.
2. Build, scan and run the isolated smoke test above; run `./scripts/validate-local.sh`. Test the chart against the current cluster API/admission in your normal staging workflow.
3. Make an encrypted identity backup. Update only `image.repository`/`image.digest` and intended chart values; review `helm template`/`helm diff` if already installed. ConfigMap checksum changes also trigger a rolling restart; subPath mounts do not hot-reload configs.
4. After approval, run the same `helm upgrade --install` command; verify fingerprint, config, bootstrap, reachability, directory policy, restarts, and resource usage. A single replica has an unavoidable outage during node/pod maintenance. No PDB is imposed on this single-node service.
5. Roll back only to a still-supported, known-safe image/config with `helm rollback tor-relay REVISION --kube-context "$KUBE_CONTEXT" -n tor-relay --wait --timeout 15m` after approval. Do not delete the PVC to fix an upgrade.

Tor is PID 1. The preStop hook sends SIGINT and waits 35 seconds, allowing Tor's 30-second circuit drain within a 90-second Kubernetes grace period. Docker STOPSIGNAL is also SIGINT; the hook handles runtimes that use SIGTERM. Forced deletion, power loss, OOM and hard node failure cannot drain; a UPS benefits this home setup.

## Identity backup and recovery

The complete `/var/lib/tor/data` directory contains private long-term keys, descriptors and accounting state. PVC retention is not a backup. MicroK8s hostpath generally ties data to the node; disk loss destroys it, and deleting a PVC may invoke a Delete reclaim policy. Keep encrypted off-node backups with restrictive access, record Tor version/fingerprint, and test recovery. Never run two active relays with the same keys.

Render the temporary resources locally and review them first:

```sh
./scripts/render-maintenance.sh backup values.local.yaml > /tmp/tor-backup.yaml
./scripts/render-maintenance.sh restore values.local.yaml > /tmp/tor-restore.yaml
```

These use the same pinned image, no API token/capabilities, a read-only root, no Service, and a separate deny-all NetworkPolicy. The backup PVC mount is read-only; the restore mount is writable. Network isolation depends on the verified CNI. After approval, scale the StatefulSet to zero (`kubectl --context "$KUBE_CONTEXT" -n tor-relay scale statefulset/tor-relay --replicas=0`), wait for pod termination, and apply only the needed temporary file. After finishing, delete its pod/policy with `kubectl --context "$KUBE_CONTEXT" delete -f /tmp/tor-backup.yaml` (or the restore file), then scale back to one. Never apply both together or while Tor is running.

For a consistent backup, use a maintenance window: stop Tor gracefully by scaling to zero, wait for the pod to terminate, then attach the existing PVC to a temporary **non-root, tokenless, Restricted-compatible** backup pod with the same UID/GID 10001. This is live mutation and requires approval. A backup pod should use the same pinned image with its entrypoint overridden to `sleep`, mount only the PVC **read-only**, and have no Service. Use `kubectl exec` to stream a tar archive directly into your existing encryption tool:

```sh
# After an approved backup pod named tor-relay-backup is mounted and ready:
# Run locally; replace AGE_RECIPIENT with your real encryption recipient.
set -o pipefail
umask 077
mkdir -p backups
kubectl --context "$KUBE_CONTEXT" -n tor-relay exec tor-relay-backup -- \
  tar -C /var/lib/tor -czf - data | age -r AGE_RECIPIENT -o backups/tor-identity.tar.gz.age
# Check both pipeline statuses and test decryption/archive listing privately.
```

Do not use `kubectl cp` to an unencrypted shared directory, print keys, or store private state in Git/ConfigMaps. Prepare your encryption credentials and review/test the generated maintenance manifest and recovery process before first deployment. Remove the backup pod before scaling back to one. Ensure future Helm upgrades do not unexpectedly restart the relay while maintenance is in progress.

Recovery: stop/remove the active pod, provision a compatible PVC on the target node, then use a reviewed temporary restore pod running as 10001 with the data PVC writable. Verify the archive's origin and safe paths, decrypt locally and stream into `tar -C /var/lib/tor -xzf -` (no plaintext file on disk). Restore `data/` ownership to 10001 and private directory/file modes with the same UID; root escalation should not be needed. Remove the restore pod, start the single StatefulSet, verify the original fingerprint and all validation checks. If moving between nodes, do not assume a local PV can be rescheduled automatically. Preserve accounting state to avoid resetting a monthly budget.

## Troubleshooting

| Symptom | Inspect / action |
| --- | --- |
| Pending PVC/pod | Storage class, provisioner, node affinity, free disk, events, image pull/architecture. |
| Data/run permission error | Private child ownership, fsGroup support and writable volume root; restore correct modes through storage management, not a privileged app container. |
| Startup refused | Built Tor version/effective-config formatting and accidental config drift. Do not weaken the reject-all/control restrictions. |
| Bootstrapping stalls | DNS/public TCP egress, system clock/NTP on node, Tor warnings; check policy destinations and memory pressure. |
| ORPort unreachable | Correct public IPv4 and advertised 9001; WAN→LAN 30001 rule, public IPv4/double NAT, node firewall, service endpoints, CNI and external probe; bootstrap is insufficient. |
| Ready but no relay traffic | Reachability self-test, descriptor accepted, Running/Valid listing, authority ramp-up/measurement; nickname is non-unique. |
| Unexpected non-ready | Control status/bootstrap, accounting hibernation, socket permissions; WAN outage should not cause a liveness restart. |
| OOM/restarts/latency | `describe`, previous logs, `top`, CPU throttling, queue limit, node pressure and router conntrack. Reserve headroom or reduce rate. |
| New identity | Wrong/new claim, path, empty data directory or restored permissions. Stop and recover the original backup; do not create multiple copies in service. |
| Graceful shutdown failed | Grace period/preStop events and runtime signal handling; hard kill/power loss cannot drain. |

## Uninstallation

Remove the router forward first to close the public entry point, then:

```sh
helm uninstall tor-relay --kube-context "$KUBE_CONTEXT" -n tor-relay --wait --timeout 5m
kubectl --context "$KUBE_CONTEXT" -n tor-relay get pvc
```

The namespace and PVC carry `helm.sh/resource-policy: keep` and are intentionally retained; verify retention with your installed Helm version before relying on it. Take and verify a backup before uninstalling. To reinstall, use the same release/namespace/PVC and verify Helm ownership annotations/labels on retained resources; do not blindly force adoption or replacement. Full cleanup is a separate destructive action: delete PVC only after explicit approval and verified backup, inspect the PV reclaim policy first, then delete the namespace. Deleting the namespace deletes its PVC regardless of Helm keep annotations. Retiring a public listing takes time to propagate.

## References checked 2026-11-05

- [Tor official Debian/Ubuntu non-exit setup](https://community.torproject.org/relay/setup/guard/debian-ubuntu/)
- [Tor relay requirements](https://community.torproject.org/relay/relays-requirements/)
- [Tor post-install practices](https://community.torproject.org/relay/setup/post-install/)
- [Tor relay types and home-IP considerations](https://community.torproject.org/relay/types-of-relays/)
- [Tor bandwidth shaping](https://support.torproject.org/relays/performance/bandwidth-shaping/)
- [Tor accounting/bandwidth limits](https://support.torproject.org/relays/performance/bandwidth-limits/)
- [Tor control protocol](https://spec.torproject.org/control-spec/)
- [Debian Tor package/security version](https://packages.debian.org/trixie/tor)
- [Debian Tor manual: ORPort, bandwidth, accounting, control, shutdown](https://manpages.debian.org/trixie/tor/tor.1.en.html)
- [Docker Official Debian tag metadata](https://hub.docker.com/v2/repositories/library/debian/tags/trixie-slim)
- [Tor onion-service container caveats](https://onionservices.torproject.org/apps/base/containers/)
