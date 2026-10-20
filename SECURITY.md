# Security Policy

## Do not commit secrets

This repository must never contain:

- `.cache/clash-config.yaml`, `.cache/ss-node.json`, or any real SS node password;
- Tailscale auth keys, SSH keys, tokens, signing materials;
- personal IP addresses, device serial numbers, or home directory paths.

`.cache/` and `third_party/` are gitignored. If you find a secret in the repo or its history, please report it privately rather than opening a public issue.

## Reporting a vulnerability

Open a private security advisory on the hosting platform, or contact the maintainers through the repository profile. Please include:

- affected version/commit;
- reproduction steps;
- impact (privacy, credential leak, VPN bypass, etc.);
- whether the issue is in the app, the Go engine, or a third-party dependency.

## Scope

- The app stores SS node configuration in its private sandbox; logs must not contain passwords.
- The SS client is intended only for the Tailscale control plane/DERP; it is not a general-purpose proxy.
- Third-party dependencies are listed in `THIRD_PARTY_NOTICES.md`; report upstream issues upstream.
