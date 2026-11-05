# Publishing a release

The project ships source and build instructions. A green workflow run for the exact release commit, plus deployment evidence from a controlled test cluster, is required before claiming a tested production deployment. Offline container tests cannot validate a home's WAN, CNI or Tor directory listing.

## Source and privacy review

1. Keep operator configuration outside the repository, or in ignored `values.local.yaml` for local use only. Do not put real addresses, contacts, cluster contexts, hostnames, fingerprints, deployment inventories or troubleshooting logs in examples, issues, screenshots, release notes or CI inputs.
2. Run `gitleaks dir . --redact --no-banner`. When a Git repository exists, also run `gitleaks git . --redact --no-banner --log-opts="--all"`. A scanner is a useful check, not proof that every identifying detail has been removed. Manually inspect `git ls-files` and the proposed diff.
3. Ignoring a file does not remove it from existing commits. If a secret ever entered history, rotate/revoke it and remove it from history before publishing; consider copies/forks unrecoverable. For a new repository, establish a clean first commit from the audited source. For an existing repository, review every branch and tag before publication.
4. Review Git author/committer names and emails before committing. Use the GitHub-provided noreply email from your account's email settings if you want email privacy. Choose an appropriate public display name. GitHub repository ownership and public contributions still identify the publishing account.
5. Build a curated archive with `python3 scripts/package-release.py --output /tmp/tor-relay-source.tar.gz`. It includes only approved source directories/files; no Git history or operator values. It rejects symlinks, likely private artifacts and personal home paths, and normalizes archive ownership/timestamps. Inspect `tar -tzf /tmp/tor-relay-source.tar.gz` before attaching it. Output paths must not already exist.

The Docker build context is independently restricted by `.dockerignore` to the three required image files. Never add operator configuration or relay data to the image sources. Helm packages contain only the chart directory; do not place live values there.

## Verification gates

```sh
./scripts/validate-local.sh
docker build --pull --no-cache -f image/Dockerfile -t tor-relay:test .
./scripts/test-container.sh tor-relay:test
gitleaks dir . --redact --no-banner
# After initializing Git:
gitleaks git . --redact --no-banner --log-opts="--all"
```

Inspect all `Verify` jobs on both architectures. CI has read-only permissions, no deployment/registry credentials, and never publishes images, opens router ports or contacts the Tor network during smoke tests. Do not grant secrets to pull requests, switch to `pull_request_target` for untrusted code, or add real operator values to CI.

Also scan the final image with a current scanner (for example `trivy image --exit-code 1 --severity HIGH,CRITICAL tor-relay:test`). Investigate findings rather than ignoring a failed gate. Review licenses/source obligations for Debian/Tor packages if distributing an image. At present there is no automated image publication or license-source distribution pipeline.

For a release claiming Kubernetes support, run the operations checklist on a disposable test cluster with approved public connectivity: admission, PVC ownership and persistence across restart, enforced NetworkPolicy, live bootstrap, external OR reachability, non-exit descriptor, and sustained resource use. Record sanitized results, Kubernetes/CNI/storage versions and the exact image digest. Never include keys, cookies, public operator IP/contact or kubeconfig in the evidence. If this has not happened, label the release experimental and state the unverified items.

## GitHub setup

Create the repository in the intended account/organization. Inspect its public name, description, license and contents before making it public. Avoid importing any unrelated personal repository/history.

Before the first release:

- Enable secret scanning/push protection where available, private vulnerability reporting, Dependabot alerts, and branch protection requiring all `Verify` jobs. These settings are configured on GitHub; workflow files alone do not enable them.
- Keep Actions workflow permissions read-only and require review for fork workflow runs. Do not store cluster/router/registry credentials in this repository's CI.
- Review the remote and exact commit: `git remote -v`, `git status --short`, `git show --stat HEAD`, `git log --format=fuller`. Source packaging strips filesystem owners; Git commits retain their author metadata by design.
- Replace the Unreleased changelog entry with a version and date; update Chart version/appVersion only as appropriate. The project is MIT licensed; upstream packages retain their own licenses.
- Tag only the verified commit, attach the inspected source archive, and describe verification scope and remaining deployment prerequisites. Do not claim a working public relay based only on chart lint or an open port.

Publishing commands depend on your chosen account/repository. Use the GitHub UI or an authenticated GitHub CLI after the source review. Do not paste personal access tokens into shell commands, issues or project files.
