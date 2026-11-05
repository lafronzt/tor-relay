# Security policy

This project is pre-release. There is no promise of long-term security support for a historical chart or image pin. Operators must keep Tor and the base distribution supported and rebuild promptly for security advisories.

Report vulnerabilities privately using GitHub's **Security → Report a vulnerability** on the published repository. Maintainers should enable private vulnerability reporting before public release. If it is unavailable, request a private reporting channel without posting exploit details or credentials in a public issue.

Never include relay identity keys, control authentication cookies, kubeconfigs, registry tokens, operator values, home IP addresses or unredacted logs. If credentials have already been published, revoke/rotate them immediately; deleting a file or rewriting history cannot revoke access. A compromised Tor identity may require retirement rather than simple credential rotation.

The configuration guard protects against accidental unsafe startup settings. Administrators with node, volume or pod-exec access can read keys or change a running daemon; Kubernetes RBAC, host security and encrypted off-node backups remain operator responsibilities. NetworkPolicy requires an enforcing CNI and is not an alternative to the non-exit policy or a WAN firewall.
