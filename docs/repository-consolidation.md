# Repository consolidation

Updated 2026-09-27.

## Canonical repository

The canonical public repository is [tverma101/SideTab](https://github.com/tverma101/SideTab), renamed from `tverma101/SideScreen`. GitHub retains the repository's branches, issues, pull requests, and releases when its name changes. The existing SideScreen issues therefore remain attached to SideTab.

`tverma101/TabletBridge` had no issues, but it did have an open 30-commit pull request (#1) with a 15-file runtime-efficiency patch. Its source history is independent of SideScreen's history and is based on an older code snapshot. To preserve it without rolling back newer session and transport hardening, the complete PR head is kept on the public archive branch `archive/tabletbridge-pr-1-pre-consolidation` at commit `686454e465bb146298b8c8bd0e59c446dbfc3c14`. The archive branch is not part of the live implementation; review individual changes before porting them.

Deleting the TabletBridge repository closes its open pull request. The archive branch retains its commits and source tree, but not the pull request's review discussion or metadata.

## Compatibility identities

The user-facing product name is SideTab. The following existing identifiers remain unchanged so this rename does not create a new app identity or wire protocol:

- macOS bundle identifier: `com.sidescreen.app`
- legacy macOS `CFBundleName` and designated signing requirement, retained for Screen Recording permission continuity; the visible bundle name is SideTab
- Android application ID and namespace: `com.sidescreen.app`
- QR pairing scheme: `sidescreen://`
- Bonjour service type: `_sidescreen._tcp`
- existing preference keys, executable name, and `SideScreen.app` install path

The legacy website domain `sidescreen.dev` also remains in use.
