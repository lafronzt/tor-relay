# Tor Relay for Kubernetes

A resource-conscious Helm deployment for a single **non-exit Tor relay**, designed for MicroK8s and similar small Kubernetes clusters. Includes a minimal Debian-based image, persistent identity, authenticated local health checks, and an operations guide.

This is an independent community project, not an official Tor Project image or chart. “Middle relay” means non-exit: Tor authorities may eventually assign a Guard flag. The project does not guarantee middle-position-only use.

## What it provides

- One StatefulSet replica and a retained 1Gi PVC for Tor identity/state.
- TCP ORPort 9001 exposed by NodePort 30001; no SOCKS proxy or public control/metrics port.
- `ExitRelay 0`, reject-all exit policy, disabled IPv6 exits, and a startup configuration safety check.
- Non-root UID/GID 10001, read-only root, dropped capabilities, RuntimeDefault seccomp, and no Kubernetes API token.
- Startup/liveness/readiness checks through a private cookie-authenticated Unix socket.
- Optional NetworkPolicy, bandwidth/accounting settings, and isolated backup/restore pod templates.

## Prerequisites

- A Linux Kubernetes node, suitable ReadWriteOnce storage, and a CNI that enforces NetworkPolicy if enabled.
- Public IPv4 with inbound TCP reachability, plus roughly 16 Mbit/s upload and download capacity available for Tor.
- At least 512Mi RAM available; defaults request 512Mi and limit memory to 1Gi.
- Helm 3.16+ or Helm 4, kubectl compatible with your cluster, Python 3.9+, Ruby 2.6+ with YAML, and Docker for image tests. CI exercises Helm 3 and 4 with Ruby 3.
- A registry to publish your own digest-pinned image. No prebuilt project image is currently provided.

At full utilization, the default 2 MiB/s rate can use about **10.87 TB combined inbound/outbound per 30 days**, plus overhead. Set accounting limits if needed. Thousands of connections may strain consumer routers. See the [bandwidth and networking guide](docs/operations.md).

## Quick start

First run local checks; they do not access Kubernetes or the public Tor network:

```sh
./scripts/validate-local.sh
# Optional local secret scan (requires gitleaks):
gitleaks dir . --redact --no-banner
```

Build and exercise the actual container before publishing it:

```sh
docker build --pull -f image/Dockerfile -t tor-relay:test .
./scripts/test-container.sh tor-relay:test
```

The container tests use `--network none`, publish no ports, create disposable test identities, check startup/configuration/probes, preserve identity across container recreation, and reject unsafe configurations. They do not prove public relay participation.

Prepare your own operator configuration:

```sh
cp values.example.yaml values.local.yaml
export KUBE_CONTEXT=your-context
./scripts/preflight.sh
# Edit values.local.yaml: your public IPv4, publishable contact, nickname,
# verified storage class, registry repository and pushed image digest.
helm template tor-relay charts/tor-relay -n tor-relay \
  -f values.local.yaml > rendered.yaml
```

Review the [image build, deployment and operations guide](docs/operations.md) before running live commands. Once your image is tested/pushed and configuration reviewed:

```sh
helm upgrade --install tor-relay charts/tor-relay \
  --kube-context "$KUBE_CONTEXT" --namespace tor-relay \
  -f values.local.yaml --wait --timeout 15m
```

Manually configure your router: **WAN TCP 9001 → node LAN IPv4 TCP 30001**. Do not use HTTP Ingress or a web proxy for the ORPort. External reachability, Tor's own reachability test, directory listing, and reject-all exit policy must all be verified. See the [validation checklist](docs/operations.md#monitoring-and-validation).

## Verification and limitations

The CI workflow runs chart/security checks, builds amd64 and arm64 images, and executes isolated container tests. A CI workflow file is not evidence of a successful run: inspect the results for the exact commit you intend to release. A failed image build or smoke test blocks release readiness.

Public IPv4/NAT, storage permissions, CNI enforcement, Kubernetes admission, live bootstrap and Tor directory acceptance depend on each deployment and require the operations checklist. An open port alone does not prove a useful relay. Metrics listing may take hours; flags and bandwidth measurements may take days or weeks.

## Privacy and publishing

The source contains generic defaults and documentation-only example addresses. Keep your real values, kubeconfig, credentials, relay state, keys, control cookies, logs and backups outside the public repository. `.gitignore` helps prevent accidents; it does not remove files already committed. The [release guide](docs/releasing.md) explains secret/history scanning, a source-only release archive, Git author privacy, and GitHub settings.

Operating a public relay inherently publishes its relay IP, nickname and ContactInfo in Tor's directories. Keeping the source repository generic does not hide a running relay's public identity.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [CHANGELOG.md](CHANGELOG.md), and the [release guide](docs/releasing.md). Project code is MIT licensed; bundled distribution software retains its respective upstream licenses. This repository distributes a Dockerfile, not Tor source or binaries. If publishing images, comply with the included packages' license and source-availability requirements.
