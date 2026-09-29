# Security policy

## Supported code

Security fixes target the current `main` branch. Historical releases and old evaluation branches may contain known issues that have already been changed or superseded on `main`.

When reporting a vulnerability, include the exact commit SHA or app version you tested.

## Reporting a vulnerability

Please do not publish pairing secrets, signing credentials, private network data, or a complete weaponized exploit in a public issue.

If GitHub Private Vulnerability Reporting is enabled for this repository, use it for security-sensitive reports. If a private reporting channel is not available, open a public issue containing only a minimal non-sensitive summary and request a private contact path before sharing sensitive reproduction material.

A useful report includes:

- affected Side Screen commit/version;
- macOS and Android versions;
- USB or wireless mode;
- attacker position or prerequisites;
- reproducible impact;
- whether credentials, screen contents, input control, or local system settings are affected;
- a minimal proof of concept when it can be shared safely.

## Current security boundary

Side Screen is primarily a local display application. It captures desktop pixels on the Mac and sends them to an Android client, while the Android client can send input/control messages back to the Mac.

### USB

USB mode uses ADB reverse port forwarding. Treat ADB authorization as a privileged trust relationship: only authorize Android devices you control, and revoke unknown debugging authorizations.

### Wireless

Wireless mode is **not yet an end-to-end encrypted transport**. Current pairing and control-channel hardening reduce some risks, but video traffic remains cleartext and the planned Protocol V2/TLS work is not complete.

Until that work lands:

- use wireless mode only on a trusted local network;
- do not expose Side Screen ports directly to the public Internet;
- do not treat the pairing token as a substitute for transport encryption;
- assume a network attacker with suitable visibility may be able to observe unencrypted traffic.

The active security/session work is tracked in issues #8, #12, #13, and #34.

## Secrets and release signing

Android release signing is intentionally configured through external environment variables. Never commit keystores, signing passwords, pairing tokens, or other credentials to the repository.

Diagnostic logs and bug reports should be reviewed before publication. Remove secrets, private host information, and confidential screen contents that are not needed to reproduce the issue.

## Scope notes

Reports about stale experimental branches are still useful when the same behavior exists on current `main`, but old branch behavior alone may already be superseded. Please reproduce on current `main` when practical.

Performance limitations, ordinary crashes without a security boundary impact, and feature requests belong in the normal issue tracker rather than the vulnerability channel.
