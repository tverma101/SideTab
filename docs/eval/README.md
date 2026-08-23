# Runtime evaluation receipts

The dated JSON receipt in this directory is the machine-readable provenance
for an installed evaluation run. It records the source snapshot commit, the
Mac bundle identity/CDHash, the Android APK SHA-256 and installed package,
local test results, and the hardware run boundary.

Build outputs (`SideScreen.app`, DMGs, APKs, and `.build`) are intentionally
not committed. A receipt may be added in a follow-up commit after the source
snapshot is built and installed; `snapshot_commit_sha` is the commit that
produced both binaries, while `receipt_commit_sha` identifies the commit that
published the evidence record.

For macOS launch diagnostics, use the installed executable directly with
`--headless`; this keeps the test process from taking focus or presenting the
Settings window. A normal Finder/DMG launch remains the user-facing path.
