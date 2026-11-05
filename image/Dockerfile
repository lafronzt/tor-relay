# Docker Official Image index digest verified 2026-11-05 (amd64 and arm64).
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG TOR_VERSION=0.4.9.15-0+deb13u1
LABEL org.opencontainers.image.title="CloudRelay Tor non-exit relay" \
    org.opencontainers.image.description="Debian security-maintained Tor; no public proxy or control port"
# Suppress Debian service autostart; do not run systemd, cron, or logrotate.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    tor="${TOR_VERSION}" tor-geoipdb="${TOR_VERSION}" python3-minimal ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 relay \
    && useradd --uid 10001 --gid 10001 --home-dir /var/lib/tor --no-create-home --shell /usr/sbin/nologin relay \
    && install -d -o 10001 -g 10001 -m 0700 /var/lib/tor /run/tor
COPY --chmod=0555 image/entrypoint.py /usr/local/bin/tor-entrypoint
COPY --chmod=0555 image/health.py /usr/local/bin/tor-health
USER 10001:10001
EXPOSE 9001/tcp
STOPSIGNAL SIGINT
ENTRYPOINT ["/usr/local/bin/tor-entrypoint"]
