# SideScreen Protocol V2 session contract

Tracks #34. This document is the implementation boundary for agents working on Android↔macOS communication hardening.

## Non-negotiable invariants

1. Video and control may use separate sockets, but they belong to exactly one logical session.
2. Every logical session has a fresh cryptographically random session ID.
3. A control socket cannot affect the Mac until it proves membership in the active video session.
4. A new video session invalidates every old control credential.
5. Wireless uses authenticated encryption and pins the intended Mac identity.
6. The long-lived pairing secret is never sent in plaintext.
7. USB and wireless share the same V2 parser/state machine; transport policy may differ.
8. Control failure degrades control only; video remains authoritative until video transport is lost.
9. Stale generation callbacks cannot mutate active-session state on either platform.
10. New V2 messages are length-framed and bounded before allocation.

## Proposed logical handshake

### Video channel

ClientHelloV2:
- protocol version range
- client nonce
- device/client ID
- codec capabilities
- max decode dimensions
- trace/timestamp capabilities
- brightness/touch capabilities
- maximum accepted payload sizes

ServerHelloV2:
- selected protocol version
- server nonce
- session ID
- selected codec/stream parameters
- short-lived control ticket or equivalent proof material

Wireless performs this inside TLS after Android verifies the pinned Mac identity. Pairing proof should be challenge-response based rather than retransmitting the raw long-lived secret.

### Control channel

A newly connected control socket is only a contender until ControlHelloV2 verifies:
- protocol version
- session ID
- fresh reconnect/client nonce
- control ticket/proof

The existing healthy control socket must remain untouched until verification succeeds.

## Framing goals

Use a compact binary frame with explicit length and session identity. Exact field widths are implementation/benchmark decisions, but every V2 parser must be able to:
- reject invalid/oversized payloads before allocation;
- handle any TCP fragmentation boundary;
- process several coalesced messages;
- skip unknown V2 types using payload length when policy permits;
- reject stale/wrong session IDs before side effects;
- survive fuzz/truncation without stream desynchronization.

## Session lifecycle

```text
Idle
 -> Connecting
 -> SecureTransportEstablished (wireless)
 -> NegotiatingV2
 -> SessionReady
 -> Streaming
 -> DegradedControl / ReconnectingControl (optional)
 -> Stopping
 -> Idle
```

A new video connection always creates a new session identity. Control reconnects attach to the existing active session only after proof.

## Side-effect rule

Touch, brightness, keyframe requests, clock-sync data, codec changes and future framebuffer patch commands must be session-bound. Do not accept a command merely because it arrived on the expected TCP port.

## Migration

Keep V1 behind a narrow compatibility adapter. New features should land on V2 only. V1 compatibility must not force V2 to preserve byte-ordering hacks or message-type collisions.

## Required tests

- parser fragmented at every byte boundary
- multiple messages coalesced
- unknown-type skip
- zero/huge length rejection
- stale session ID rejection
- old control reconnect after new video session
- random control contender cannot evict live control
- control loss/reconnect while video continues
- video loss invalidates control session
- connect/disconnect/connect stress
- Android Activity recreation/process death
- Mac restart
- ADB restart/cable replug
- USB↔wireless transition
- TLS pin mismatch
- old handshake replay rejection

## Performance receipts

Every hardening phase must compare against the current eval snapshot for:
- connect/handshake latency
- control RTT p50/p95/p99
- touch parse→Mac event-post latency
- max sustainable video throughput
- host/client CPU
- capture→render latency
- control reconnect recovery time

No hosted GitHub Actions are required; preserve local runtime receipts instead.
