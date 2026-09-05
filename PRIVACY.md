# Privacy

Effective date: 2026-09-05

This document describes the data boundary of the Side Screen source release.
It is a project disclosure, not legal advice or a guarantee about software,
operating-system, network, hosting, or third-party-provider behavior.

## Location data

Side Screen does not request, read, derive, store, or transmit device location.

- The Android manifest does not declare `ACCESS_FINE_LOCATION`,
  `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, or
  `ACCESS_MEDIA_LOCATION`.
- The source contains no Android location APIs, iOS/macOS Core Location APIs,
  GPS handling, geocoding, latitude/longitude fields, or location SDK.
- The macOS host may use a peer IP address and device name as connection
  parameters for the local USB or Wi-Fi transport. It does not use them to
  infer physical location. Network providers and GitHub may retain their own
  connection records under their policies.

## Other data processed

- The macOS host captures the selected display and sends frames to the paired
  Android client.
- The Android client sends touch, connection, and optional brightness-control
  messages to the Mac host.
- The QR scanner uses the camera locally to read pairing data. Camera frames
  are not intentionally uploaded to a Side Screen service.
- Pairing tokens, device names, settings, and diagnostic messages may be held
  locally or exchanged with the paired peer as required for the connection.
- The source contains no first-party analytics, advertising, user account, or
  cloud telemetry service.

## GitHub Actions

The repository build workflows check out source, install the required build
toolchain, run tests, and build artifacts. They have `contents: read` workflow
permissions and do not request device location or upload application data.

## User responsibility

Use screen capture, camera, USB debugging, and network access only with the
necessary permissions. Do not publish pairing tokens, private logs, or
screenshots containing personal or confidential information.

Third-party operating systems, libraries, GitHub, hosting providers, and
network equipment have their own data practices and terms.
