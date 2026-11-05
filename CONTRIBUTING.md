# Contributing

Use synthetic addresses from RFC 5737 and `example.invalid` contacts in examples and tests. Never submit operator values, kubeconfigs, Tor state/keys, control cookies, real relay fingerprints, or unsanitized cluster logs.

Run `./scripts/validate-local.sh` for chart/safety tests. Changes to the image, entrypoint, probes or torrc must also pass `./scripts/test-container.sh IMAGE` after building the Dockerfile. Tests must stay offline and must not publish descriptors or contact the Tor network.

Preserve non-exit defaults, disabled proxy/public control ports, UID 10001, private persistent identity, and digest-pinned deployments. Explain compatibility and security tradeoffs in pull requests. Never weaken a configuration check merely to make an image smoke test pass.

Dependency updates should include advisory/support review, the base digest and Tor package pin, Chart appVersion, and results from both architecture jobs. Transitive Debian packages are resolved at build time, so rebuild and scan images regularly. Use the release checklist before tagging a version.
