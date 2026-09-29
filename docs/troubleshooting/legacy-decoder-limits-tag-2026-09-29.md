# Old Android build stalls against a new Mac host (legacy tag 11)

## Symptom

After the Mac host was updated, the tablet running the **older** installed APK
would not stream. It connected, showed nothing, dropped, and reconnected about
every 20 seconds. A freshly built APK did not show this.

## Evidence

`~/Library/Logs/SideScreen/sidescreen.log` on 2026-09-29, for every attempt
from the old APK (the installed APK's provenance hash began `6c93e2bf`):

```
Client connected via loopback (usb) — skipping auth
Starting input receive loop... (touch=on)
Unknown client input type: 11
Unknown client input type: 192
Unknown client input type: 128
Unknown client input type: 192
Unknown client input type: 128
...
Connection ready for frames (metadata=off, codec=hevc)
...
Control receive EOF — closing
Control socket closed with no live video — ending session
```

That is a five-byte message: tag `11` followed by `C0 80 C0 80`, which is the
old client's decoder-limits payload (8192×8192, as 7-bit halves with the high
bit set). The byte-at-a-time skipper consumed all five bytes as five unknown
types.

A fresh APK on the same host logs `Client decoder limit: 8192x4096` instead,
because it sends the same message under tag `15`.

## Root cause

Tag 11 used to mean two things: server-to-client `bright`, and client-to-server
decoder limits. The CHANGELOG entry "Two wire messages shared tag 11" moved
decoder limits to tag 15 on **both** sides, which is correct for new pairs.
Nothing on the host accepted the old tag, though, so an APK built before the
move could no longer negotiate against a new host.

The log proves only that the host never received the limits. It does not
explain why the old client then got no usable video, and the old APK is no
longer installed to test. The back-compat below removes the one proven
protocol difference.

## Fix

`StreamingServer` accepts `WireMessage.legacyClientDecoderLimits` (11)
inbound, alongside `clientDecoderLimits` (15):

- The tag is **inbound-only** and deliberately not listed in `WireMessage.all`,
  so the one-tag-per-message invariant (`testEveryWireTagIsUnique`) still holds.
  The host never sends 11 to the client other than as `bright`, on the control
  channel.
- The payload is validated by `StreamingServer.decodeClientDecoderLimits`: four
  bytes, each with the marker bit set. A malformed payload is ignored rather than
  applied.
- A legacy-tag arrival logs `Client sent decoder limits under legacy tag 11 —
  outdated Android build`, so the next occurrence is self-diagnosing.

Both devices were also reinstalled from the integrated stack on 2026-09-29. The
tablet's installed APK hash matches the fresh build.

## Validation

- `StreamingServerWireTests`: the legacy tag stays out of the tag table; the
  exact legacy payload decodes to 8192×8192; `9E 80 90 F0` decodes to 3840×2160;
  a missing marker bit or a short payload is rejected.
- `swift test --package-path MacHost`: all pass on the integrated tree.

## Residual gaps and revalidation triggers

- **No end-to-end streaming session was observed on the new builds** in this
  pass. The server is not auto-started, and starting it needs a click on the
  Mac. Revalidate with a USB session. Also confirm that an old APK, if one is
  ever reinstalled, now logs the legacy-tag line and streams.
- `swift test` writes to the same `~/Library/Logs/SideScreen/sidescreen.log` as
  the live host. The `Dirty-rect gate`, `test-hang` and `Annex-B walk` lines
  interleaved with real sessions came from test runs, not from the app. Filter
  on them or run the tests elsewhere before reading that log as evidence.
- Any future tag move needs the same treatment: keep accepting the old inbound
  tag for at least one release, because a tablet and a Mac are updated
  independently.
