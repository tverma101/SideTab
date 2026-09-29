import Foundation
import Network
import os

enum WireMessage {
    static let legacyVideoFrame: UInt8 = 0
    static let displayConfig: UInt8 = 1
    static let touchEvent: UInt8 = 2
    static let ping: UInt8 = 4
    static let pong: UInt8 = 5
    static let videoFrameWithMetadata: UInt8 = 6
    static let keyframeRequest: UInt8 = 7
    /// Client→server, payload-free capability: "I understand the 14-byte frame
    /// header". Old hosts consume this unknown type as one byte, so sending it
    /// unsolicited is safe.
    static let clientSupportsFrameMetadata: UInt8 = 8
    /// Client→server, payload-free (old hosts consume 1 byte safely):
    /// "this device has no HEVC decoder".
    static let clientAvcOnly: UInt8 = 9
    /// Server→client, 1-byte payload (StreamCodec.wireId). Sent ONLY to
    /// clients that sent clientAvcOnly — old clients disconnect on unknown
    /// message types, so this must never be sent unsolicited.
    static let codecSelected: UInt8 = 10
    /// Server→client, 1-byte payload (0..255). Sent ONLY to clients that sent
    /// clientSupportsBrightness — old clients disconnect on unknown types.
    static let bright: UInt8 = 11
    /// Client→server, payload-free capability: "I understand BRIGHT (type 11)".
    /// Old servers log unknown control types and skip — safe unsolicited.
    static let clientSupportsBrightness: UInt8 = 3
    /// Client→server, payload-free capability: "I understand direct stylus
    /// events". Older hosts consume this unknown type as one byte and keep
    /// the legacy touch protocol aligned.
    static let clientSupportsStylus: UInt8 = 12
    /// Server→client, payload-free acknowledgement for clientSupportsStylus.
    /// It is sent only after the client opted in, so older Android clients
    /// never see an unknown server message.
    static let serverSupportsStylus: UInt8 = 13
    /// Client→server, fixed 28-byte direct stylus event.
    static let stylusEvent: UInt8 = 14
    /// Client→server, 4-byte payload: the client's max decode size (issue
    /// #41). It must not share a tag with a server→client message: the client
    /// dispatches on the tag alone, so one value can only ever name one
    /// message per direction. A byte-at-a-time skipper (this host's own
    /// `default` arms) consumes 1 of the 5 bytes and desyncs the rest of the
    /// stream, so "the payload is skipped harmlessly" is not a safe design.
    /// 11 was taken by `bright`; 15 is the next free tag.
    static let clientDecoderLimits: UInt8 = 15
    /// Client→server decoder limits as sent by Android builds from before the
    /// move to 15: the same 4-byte payload under the old tag. Without this an
    /// un-updated tablet's report is skipped a byte at a time and the input
    /// stream desyncs. Inbound only — the host never reads `bright` from a
    /// client — so it deliberately stays out of `all`, which lists one tag per
    /// message.
    static let legacyClientDecoderLimits: UInt8 = 11

    /// Every tag value in use. A duplicate means two messages share one
    /// wire type and the client cannot tell them apart.
    static let all: [UInt8] = [
        legacyVideoFrame, displayConfig, touchEvent, clientSupportsBrightness,
        ping, pong, videoFrameWithMetadata, keyframeRequest,
        clientSupportsFrameMetadata, clientAvcOnly, codecSelected, bright,
        clientSupportsStylus, serverSupportsStylus, stylusEvent,
        clientDecoderLimits
    ]
}

private let controlAuthMagic = Data([0x53, 0x53, 0x57, 0x43]) // "SSWC"

struct StylusEvent {
    let x: Float
    let y: Float
    let action: Int
    let toolType: Int
    let pressure: Float
    let tilt: Float
    let orientation: Float
    let buttonState: UInt32
}

private extension NWEndpoint {
    var isLoopback: Bool {
        switch self {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let v4): return v4.isLoopback
            case .ipv6(let v6): return v6.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default:
            return false
        }
    }
}

class StreamingServer {
    private let port: UInt16
    /// Transport selection belongs to the server session, not to whichever
    /// endpoint happens to arrive first. A USB reverse-forward is loopback at
    /// Network.framework, while wireless is LAN; keeping this explicit also
    /// prevents pressure policy from changing when a probe or contender joins.
    private var transportMode: ConnectionMode = .usb
    private var listener: NWListener?
    private var connection: NWConnection?

    // Dedicated out-of-band control channel (ping/pong + keyframe requests).
    // Pongs are answered on this connection so they never queue behind video
    // frames on the main NWConnection — measured RTT reflects the transport,
    // not the video send/read scheduling.
    private let controlPort: UInt16
    private var controlListener: NWListener?
    private var controlConnection: NWConnection?
    private var controlInputBuffer = Data()
    private var controlAuthenticated = false
    private var controlTouchCount = 0
    private var lastControlTouchNs: UInt64 = 0
    private var maxControlTouchGapMs = 0.0
    private var clientSupportsBrightness = false
    /// Latest requested level. Queue it while the Android client is still
    /// negotiating capabilities so a menu-bar change cannot be lost during
    /// the short connection-startup race.
    private var lastBrightness: UInt8?
    private let controlQueue = DispatchQueue(label: "controlQueue", qos: .userInteractive)
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    /// Fired when a live session is ended because the client went silent past
    /// `SessionLifetimePolicy.defaultDisconnectTimeout` — as opposed to a
    /// socket that actually reported a terminal state. Kept separate from
    /// `onClientDisconnected` because the host tears the whole session down
    /// (server stopped, virtual display destroyed) on a timeout, whereas an
    /// observed disconnect only clears per-client state and leaves the
    /// listener up so the tablet can reconnect on its own.
    var onSessionTimeout: (() -> Void)?
    /// Fired once per connection during protocol startup, BEFORE the display
    /// config is sent, for every outcome (.hevc or .h264) — so the capture
    /// pipeline can also revert to HEVC after an AVC-only client goes away.
    var onCodecNegotiated: ((StreamCodec) -> Void)?
    // Touch callback: (x1, y1, action, pointerCount, x2, y2)
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    /// Direct S Pen callback. Stylus contact bypasses the touch gesture
    /// state-machine so drawing starts on the first pen move.
    var onStylusEvent: ((StylusEvent) -> Void)?
    var onStats: ((Double, Double) -> Void)?
    var onKeyframeRequested: ((Bool) -> Void)?
    // Whether host wants to receive touch events from client. Ping/pong is
    // handled regardless. When false, incoming touch frames are dropped
    // immediately without parsing or dispatching to main queue.
    var touchEnabled: Bool = true

    // Wireless auth: when non-nil, non-loopback connections must present this
    // 32-byte token before being allowed to proceed. nil means wireless mode
    // is inactive — non-loopback connections are rejected immediately.
    var expectedAuthToken: Data? {
        get { sessionState.withLock { $0.expectedAuthToken } }
        set { sessionState.withLock { $0.expectedAuthToken = newValue } }
    }
    var onWirelessClientPaired: ((String) -> Void)?

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "networkQueue", qos: .userInteractive)

    /// Everything both the video and the control socket can observe, plus the
    /// session lifecycle flags. These fields are written by the input parser on
    /// receiveQueue, read by the control parser on controlQueue, by the
    /// startup timer on networkQueue and by the frame sender on frameQueue, so
    /// a plain `sync` on any one of those queues orders nothing. `sessionState`
    /// is a LEAF lock: it is never held across a queue hop, a connection send,
    /// or a callback into the host.
    private struct SessionState {
        var stopped = false
        var receiving = false
        var connectionReady = false
        var clientSupportsFrameMetadata = false
        var clientIsAvcOnly = false
        /// SESSION-scoped, not per-connection: the client advertises it on
        /// whichever socket is up, and a video-socket reconnect must not erase
        /// what the still-live control socket established — otherwise every S
        /// Pen stroke is dropped mid-drag with no client-visible error. Only
        /// a full stop() clears it; nothing is sent to the client on the
        /// strength of it, so a device switch cannot be harmed by a stale true.
        var clientSupportsStylus = false
        var clientDecodeLimits: (width: Int, height: Int)?
        var selectedCodec: StreamCodec?
        var codecSelectedSent = false
        var startupPublished = false
        var publishedMetadataSupport: Bool?
        var publishedDecodeLimits: (width: Int, height: Int)?
        /// Last instant the *client* sent us a byte on either socket. Seeded
        /// when the session goes live so a client that authenticates and then
        /// goes quiet is still ended on schedule. Read by the session watchdog
        /// on networkQueue, written by the video parser on receiveQueue and the
        /// control parser on controlQueue, so it lives in this leaf lock.
        var lastInboundActivity: ContinuousClock.Instant?
        /// Incremented every time a session is installed or ended, so a
        /// watchdog tick that was already queued cannot act on a session it no
        /// longer describes.
        var sessionGeneration: UInt64 = 0
        var displayWidth = 1920
        var displayHeight = 1080
        var rotation = 0
        var flipHorizontal = false
        var flipVertical = false
        /// Snapshot of the pairing token taken when the listener starts. The UI
        /// can rotate the token mid-session, so this is read and written from
        /// both the network queue and the main actor and must stay in the lock.
        var expectedAuthToken: Data?
    }
    private let sessionState = OSAllocatedUnfairLock(initialState: SessionState())

    // Encoded frames are never dropped after VideoToolbox emits them: ordinary
    // H.264/HEVC P-frames may reference earlier P-frames. Instead, the pressure
    // generation below feeds WirelessTransportPressure, and VideoEncoder skips
    // future routine captures before they enter the codec when two sends remain
    // outstanding. This preserves the reference chain and avoids wasted encode.
    private var frameSendGeneration: UInt64 = 0
    private var framePressureGeneration: UInt64 = 0
    private var frameSendConnection: NWConnection?
    private var frameTransportReady = false
    private var frameWaitingForSync = true
    private var frameUsesMetadata = false
    private var frameSendsInFlight = 0

    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastStatsTime = DispatchTime.now()
    private var inputBuffer = Data()

    /// Max decode size reported by the connected client (issue #41).
    var clientDecodeLimits: (width: Int, height: Int)? {
        sessionState.withLock { $0.clientDecodeLimits }
    }

    private var isStopped: Bool { sessionState.withLock { $0.stopped } }
    private var isReceiving: Bool { sessionState.withLock { $0.receiving } }
    private var connectionReady: Bool { sessionState.withLock { $0.connectionReady } }
    private var clientSupportsStylus: Bool { sessionState.withLock { $0.clientSupportsStylus } }

    init(port: UInt16, controlPort: UInt16? = nil) {
        self.port = port
        self.controlPort = controlPort ?? ControlPortResolver.effective(videoPort: port)
    }

    /// Read-only mirror of the control listener's port, for the pairing tests.
    var controlPortNumber: UInt16 { controlPort }

    func start(wireless: Bool = false) {
        sessionState.withLock { $0.stopped = false }
        transportMode = wireless ? .wireless : .usb
        do {
            let params = NWParameters.tcp
            // No allowLocalEndpointReuse: probed on this machine, a second
            // NWListener binds the same port with NO error while the FIRST
            // binder keeps 100% of the connections. With reuse on, a second
            // SideScreen instance prints "server started", renders a QR, and
            // every client goes to the other process. The app never rebinds a
            // port it still holds, so reuse buys nothing and hides the steal.
            // Both transports get .interactiveVideo: .bestEffort is
            // Network.framework's do-not-care class (Apple documents it as the
            // choice when you have no specific need), and the control listener
            // was using the *more* latency-sensitive .responsiveData for a
            // 17-byte pong, which inverts the priority.
            params.serviceClass = .interactiveVideo

            // Optimize TCP for low-latency streaming
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true  // Disable Nagle's algorithm
                // Kernel-level backstop for a half-open socket. A peer whose
                // Wi-Fi association drops sends no FIN or RST, so the
                // application only learns about it once the kernel's own
                // keepalive probes fail. Set well inside the session watchdog's
                // budget so the socket dies before the five-minute deadline.
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 20
                tcpOptions.keepaliveCount = 4
                tcpOptions.keepaliveInterval = 10
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            if let token = expectedAuthToken {
                var service = NWListener.Service(
                    name: WirelessServiceIdentity.name(for: token),
                    type: WirelessServiceIdentity.serviceType
                )
                service.noAutoRename = true
                listener?.service = service
                debugLog("Advertising Bonjour service \(WirelessServiceIdentity.name(for: token)).\(WirelessServiceIdentity.serviceType)")
            }

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    debugLog("TCP Server listening on port \(self.port) [\(self.transportMode.rawValue)]")
                    if self.transportMode == .wireless, LANAddressResolver.primaryHost() == nil {
                        // A pairing URL built with no routable address falls back
                        // to 0.0.0.0, which the client connects to as its OWN
                        // loopback forever. Nothing else reports that state.
                        debugLog("WARNING: no routable LAN address on this Mac — any pairing URL would carry 0.0.0.0 and no tablet can connect")
                    }
                case .failed(let error):
                    debugLog("Server failed: \(error)")
                default:
                    break
                }
            }

            listener?.start(queue: networkQueue)

            startControlListener()
        } catch {
            debugLog("Failed to start server: \(error)")
        }
    }

    /// Dedicated control-channel listener: ping/pong + keyframe requests on
    /// their own connection, so pongs never contend with video frames.
    private func startControlListener() {
        // A control port that collides with the video port makes one of the two
        // listeners a permanent black hole: the client would connect to a port
        // that only ever answers the other protocol.
        if controlPort == port {
            debugLog("Control listener NOT started: control port \(controlPort) equals video port \(port) — set \(ControlPortResolver.defaultsKey) to a different port")
            return
        }
        if Int(controlPort) <= ControlPortResolver.privilegedPortCeiling {
            debugLog("Control listener NOT started: port \(controlPort) is privileged and cannot be bound without root — set \(ControlPortResolver.defaultsKey) above \(ControlPortResolver.privilegedPortCeiling)")
            return
        }
        do {
            let params = NWParameters.tcp
            params.serviceClass = .responsiveData
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                // Same half-open backstop as the video socket, tuned shorter
                // because control is the channel that proves the client is
                // still there.
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 20
                tcpOptions.keepaliveCount = 4
                tcpOptions.keepaliveInterval = 10
            }
            controlListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: controlPort))
            controlListener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleControlConnection(newConnection)
            }
            controlListener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    debugLog("Control listener ready on port \(self.controlPort)")
                case .failed(let error):
                    debugLog("Control listener failed: \(error)")
                default:
                    break
                }
            }
            controlListener?.start(queue: controlQueue)
        } catch {
            debugLog("Failed to start control listener: \(error)")
        }
    }

    private func handleControlConnection(_ newConnection: NWConnection) {
        debugLog("Control connection incoming")
        let mode = transportMode
        let isLoopback = newConnection.endpoint.isLoopback
        if mode == .usb && !isLoopback {
            debugLog("Rejecting LAN control candidate: USB mode is active")
            newConnection.cancel()
            return
        }
        if mode == .wireless && !isLoopback && expectedAuthToken == nil {
            debugLog("Rejecting non-loopback control candidate: wireless auth is unavailable")
            newConnection.cancel()
            return
        }
        let requiresAuth = mode == .wireless && !isLoopback
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                if requiresAuth {
                    debugLog("Control candidate READY — authenticating before promotion")
                    self.authenticateControlCandidate(newConnection)
                } else if self.controlConnection != nil {
                    // A loopback control contender can be a short-lived probe
                    // or another client racing the active session. Inspect its
                    // first message before allowing it to replace control.
                    self.routeLoopbackControlCandidate(newConnection)
                } else {
                    self.installControlConnection(newConnection, initialBuffer: Data(), authenticated: true)
                }
            case .failed(let error):
                debugLog("Control candidate failed: \(error)")
                newConnection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        newConnection.start(queue: controlQueue)
    }

    /// Inspect a loopback control candidate only when a control client is
    /// already active. A readiness probe starts with PING (type 4); answer it
    /// directly and close it. A real client starts with the BRIGHT capability
    /// (type 3), so promote it and preserve the bytes already received.
    private func routeLoopbackControlCandidate(_ candidate: NWConnection) {
        var buffer = Data()
        // The probe window is bounded in both size and time. A ping is 9 bytes
        // and a client opener is 1, so anything past this cap is a flood that
        // would otherwise re-arm this receive loop forever, appending up to 256
        // bytes per completion. Reachable by any local process in USB mode.
        let timeout = DispatchWorkItem { [weak candidate] in
            debugLog("Loopback control probe silent — rejecting, active control untouched")
            candidate?.cancel()
        }
        controlQueue.asyncAfter(deadline: .now() + Self.contenderProofWindow, execute: timeout)
        var receiveNext: (() -> Void)!
        receiveNext = { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            candidate.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, isComplete, error in
                guard error == nil, !isComplete else {
                    timeout.cancel()
                    candidate.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    buffer.append(data)
                }
                guard buffer.count <= Self.loopbackControlProbeMaxBytes else {
                    timeout.cancel()
                    debugLog("Loopback control probe exceeded \(Self.loopbackControlProbeMaxBytes)B without identifying itself — rejecting")
                    candidate.cancel()
                    return
                }
                guard let first = buffer.first else {
                    receiveNext()
                    return
                }

                if first == WireMessage.ping {
                    guard buffer.count >= 9 else {
                        receiveNext()
                        return
                    }
                    timeout.cancel()
                    let clientTimestamp = Data(buffer.dropFirst().prefix(8))
                    var pong = Data(capacity: 17)
                    pong.append(WireMessage.pong)
                    pong.append(clientTimestamp)
                    var serverTimestamp = DispatchTime.now().uptimeNanoseconds
                    withUnsafeBytes(of: &serverTimestamp) { pong.append(contentsOf: $0) }
                    debugLog("Loopback control probe answered without replacing active control")
                    candidate.send(content: pong, completion: .contentProcessed { _ in
                        candidate.cancel()
                    })
                } else {
                    timeout.cancel()
                    debugLog("Loopback control client replacing prior control connection")
                    self.installControlConnection(candidate, initialBuffer: buffer, authenticated: true)
                }
            }
        }
        receiveNext()
    }

    /// Authenticate a wireless contender without evicting the current client.
    /// This prevents unauthenticated LAN connections from suppressing control.
    private func authenticateControlCandidate(_ candidate: NWConnection) {
        guard let expected = expectedAuthToken else {
            candidate.cancel()
            return
        }
        let requiredBytes = controlAuthMagic.count + expected.count
        var buffer = Data()
        let timeout = DispatchWorkItem { candidate.cancel() }
        controlQueue.asyncAfter(deadline: .now() + 5, execute: timeout)

        var receiveNext: (() -> Void)!
        receiveNext = { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            candidate.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, isComplete, error in
                if error != nil || isComplete {
                    timeout.cancel()
                    candidate.cancel()
                    return
                }
                if let data, !data.isEmpty {
                    buffer.append(data)
                }
                guard buffer.count >= requiredBytes else {
                    receiveNext()
                    return
                }
                let magic = Data(buffer.prefix(controlAuthMagic.count))
                let tokenStart = buffer.index(buffer.startIndex, offsetBy: controlAuthMagic.count)
                let tokenEnd = buffer.index(tokenStart, offsetBy: expected.count)
                let token = Data(buffer[tokenStart..<tokenEnd])
                guard magic == controlAuthMagic, WirelessAuth.validate(token, expected: expected) else {
                    debugLog("Control authentication rejected")
                    timeout.cancel()
                    candidate.cancel()
                    return
                }
                timeout.cancel()
                debugLog("Control authentication accepted")
                self.installControlConnection(
                    candidate,
                    initialBuffer: Data(buffer.dropFirst(requiredBytes)),
                    authenticated: true
                )
            }
        }
        receiveNext()
    }

    /// Promote an authenticated connection, replacing the prior client only now.
    /// `authenticated` is the caller's claim, not this function's: the
    /// invariant is local so no future caller can accidentally install an
    /// unauthenticated socket and silence the auth gate below.
    private func installControlConnection(
        _ newConnection: NWConnection,
        initialBuffer: Data,
        authenticated: Bool
    ) {
        // Publish the replacement first. A terminal callback from the old
        // connection is then guaranteed to fail the identity guard below.
        let oldConnection = controlConnection
        controlInputBuffer = initialBuffer  // fresh storage — never keep poisoned inline slices
        controlAuthenticated = authenticated
        controlTouchCount = 0
        lastControlTouchNs = 0
        maxControlTouchGapMs = 0
        clientSupportsBrightness = false
        controlConnection = newConnection
        oldConnection?.cancel()

        let wasAlreadyReady = newConnection.state == .ready
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            // A terminal callback from a cancelled/replaced connection must
            // never clear the newer live connection.
            guard self.controlConnection === newConnection else {
                switch state {
                case .failed, .cancelled:
                    debugLog("Control state STALE terminal callback")
                default:
                    break
                }
                return
            }
            switch state {
            case .ready:
                debugLog("Control connection READY — arming receive")
                self.processControlBuffer(connection: newConnection)
                self.startReceivingControl()
            case .failed(let error):
                debugLog("Control connection failed: \(error)")
                self.markControlDisconnected(newConnection)
            case .cancelled:
                self.markControlDisconnected(newConnection)
            default:
                break
            }
        }

        // A wireless candidate is authenticated from its receive callback after
        // the connection has already reached .ready. Network.framework does not
        // guarantee that assigning a state handler at that point replays the
        // ready transition, so explicitly arm the protocol in that case.
        if wasAlreadyReady {
            controlQueue.async { [weak self, weak newConnection] in
                guard let self, let newConnection,
                      self.controlConnection === newConnection,
                      newConnection.state == .ready else { return }
                debugLog("Control connection already READY — arming receive")
                self.processControlBuffer(connection: newConnection)
                self.startReceivingControl()
            }
        }
    }

    private func startReceivingControl() {
        guard let connection = controlConnection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            // Identity guard: a stale completion from a replaced connection must
            // neither clobber the live connection nor re-arm a receive on it.
            guard let self = self, let current = self.controlConnection, current === connection else {
                debugLog("Control receive STALE completion (connection replaced)")
                return
            }
            if let error = error {
                debugLog("Control receive error: \(error) — closing")
                self.markControlDisconnected(connection)
                return
            }
            if isComplete {
                debugLog("Control receive EOF — closing")
                self.markControlDisconnected(connection)
                return
            }
            if let data = data, !data.isEmpty {
                self.noteInboundActivity()
                self.controlInputBuffer.append(data)
                self.processControlBuffer(connection: connection)
            }
            self.startReceivingControl()
        }
    }

    private func processControlBuffer(connection: NWConnection) {
        if !controlAuthenticated {
            guard let expected = expectedAuthToken else {
                debugLog("Rejecting non-loopback control connection without wireless auth")
                controlConnection = nil
                connection.cancel()
                return
            }
            let requiredBytes = controlAuthMagic.count + expected.count
            guard controlInputBuffer.count >= requiredBytes else { return }
            let magic = Data(controlInputBuffer.prefix(controlAuthMagic.count))
            let tokenStart = controlInputBuffer.index(
                controlInputBuffer.startIndex,
                offsetBy: controlAuthMagic.count
            )
            let token = Data(controlInputBuffer[tokenStart..<controlInputBuffer.index(tokenStart, offsetBy: expected.count)])
            guard magic == controlAuthMagic, WirelessAuth.validate(token, expected: expected) else {
                debugLog("Control authentication rejected")
                controlConnection = nil
                connection.cancel()
                return
            }
            controlInputBuffer = Data(controlInputBuffer.dropFirst(requiredBytes))
            controlAuthenticated = true
            debugLog("Control authentication accepted")
        }

        while let msgType = controlInputBuffer.first {
            switch msgType {
            case WireMessage.touchEvent:
                // Same payload as the legacy in-band path: type, pointer
                // count, normalized points, action. Keeping it on this socket
                // prevents cursor movement from queueing behind video frames.
                guard controlInputBuffer.count >= 2 else { return }
                let pointerCount = Int(controlInputBuffer[controlInputBuffer.index(after: controlInputBuffer.startIndex)])
                guard pointerCount == 1 || pointerCount == 2 else {
                    debugLog("Invalid control touch pointer count: \(pointerCount)")
                    controlInputBuffer = Data(controlInputBuffer.dropFirst())
                    continue
                }
                let expectedSize = 2 + pointerCount * 8 + 4
                guard controlInputBuffer.count >= expectedSize else { return }
                let message = Data(controlInputBuffer.prefix(expectedSize))
                controlInputBuffer = Data(controlInputBuffer.dropFirst(expectedSize))

                let now = DispatchTime.now().uptimeNanoseconds
                let actionOffset = 2 + pointerCount * 8
                let action = message.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: actionOffset, as: Int32.self)
                }
                if action == 0 {
                    controlTouchCount = 0
                    lastControlTouchNs = now
                    maxControlTouchGapMs = 0
                } else if lastControlTouchNs > 0 {
                    let gapMs = Double(now - lastControlTouchNs) / 1_000_000.0
                    maxControlTouchGapMs = max(maxControlTouchGapMs, gapMs)
                    lastControlTouchNs = now
                }
                controlTouchCount += 1
                if controlTouchCount % 120 == 0 {
                    debugLog(String(format: "CTRL touch: count=%d maxGap=%.2fms", controlTouchCount, maxControlTouchGapMs))
                    maxControlTouchGapMs = 0
                }

                if touchEnabled {
                    handleTouchMessage(message, pointerCount: pointerCount)
                }

            case WireMessage.stylusEvent:
                guard controlInputBuffer.count >= Self.stylusEventSize else { return }
                let message = Data(controlInputBuffer.prefix(Self.stylusEventSize))
                controlInputBuffer = Data(controlInputBuffer.dropFirst(Self.stylusEventSize))
                if touchEnabled, clientSupportsStylus {
                    handleStylusMessage(message)
                } else {
                    debugLog("Ignoring stylus event before capability negotiation or with touch disabled")
                }

            case WireMessage.ping:
                // [type 4][clientTs 8 LE] -> pong [type 5][clientTs 8][serverSendTs 8]
                guard controlInputBuffer.count >= 9 else { return }
                let clientTs = controlInputBuffer.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self)
                }
                controlInputBuffer = Data(controlInputBuffer.dropFirst(9))
                let receivedAt = DispatchTime.now().uptimeNanoseconds
                var pong = Data(capacity: 17)
                pong.append(WireMessage.pong)
                withUnsafeBytes(of: clientTs) { pong.append(contentsOf: $0) }
                var sendTs = DispatchTime.now().uptimeNanoseconds
                withUnsafeBytes(of: &sendTs) { pong.append(contentsOf: $0) }
                let procDelayMs = Double(sendTs - receivedAt) / 1_000_000.0
                debugLog(String(format: "CTRL pong: procDelay=%.3fms", procDelayMs))
                connection.send(content: pong, completion: .contentProcessed { _ in })

            case WireMessage.keyframeRequest:
                guard controlInputBuffer.count >= 2 else { return }
                let flags = controlInputBuffer[controlInputBuffer.index(controlInputBuffer.startIndex, offsetBy: 1)]
                controlInputBuffer = Data(controlInputBuffer.dropFirst(2))
                onKeyframeRequested?((flags & 1) != 0)

            case WireMessage.clientSupportsBrightness:
                // [type 3] payload-free capability: client understands BRIGHT.
                controlInputBuffer = Data(controlInputBuffer.dropFirst())
                clientSupportsBrightness = true
                debugLog("Client supports brightness (BRIGHT armed)")
                if let value = lastBrightness {
                    sendBrightnessMessage(value, on: connection, path: "control")
                }

            case WireMessage.clientSupportsStylus:
                // The client opens its control session with this advert, so the
                // capability is established here for the whole session — the
                // same flag the video parser writes. Without this arm the flag
                // stayed false until a video reconnect re-sent the advert, and
                // every stroke on the control socket was dropped with no error
                // visible to the client.
                controlInputBuffer = Data(controlInputBuffer.dropFirst())
                let firstAdvert = !sessionState.withLock { state -> Bool in
                    let wasSupported = state.clientSupportsStylus
                    state.clientSupportsStylus = true
                    return wasSupported
                }
                if firstAdvert {
                    debugLog("Client supports S Pen stylus events (control channel)")
                }

            default:
                debugLog("Unknown control type: \(msgType)")
                controlInputBuffer = Data(controlInputBuffer.dropFirst())
            }
        }
    }

    /// Send a brightness command (0..255) to the client on the control channel.
    /// Only sent when the client declared support (type 3) — old clients
    /// disconnect on unknown message types, so never send unsolicited.
    /// No-op when the control connection is not ready. Call from any queue.
    func sendBrightness(_ value: UInt8) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.lastBrightness = value
            guard self.clientSupportsBrightness else {
                debugLog("BRIGHT queued: \(value) (client capability not armed)")
                return
            }
            guard let connection = self.controlConnection else {
                debugLog("BRIGHT queued: \(value) (no control connection)")
                return
            }
            self.sendBrightnessMessage(value, on: connection, path: "control")
        }
    }

    private func sendBrightnessMessage(_ value: UInt8, on connection: NWConnection, path: String) {
        var msg = Data(capacity: 2)
        msg.append(WireMessage.bright)
        msg.append(value)
        connection.send(content: msg, completion: .contentProcessed { _ in })
        debugLog("BRIGHT sent (\(path)): \(value)")
    }

    // Contender: a new connection that arrived while a live client is
    // streaming. Real clients speak first (decoder-limit/metadata/AVC
    // advertisements, or a ping) within a few ms of connecting; silent
    // liveness probes (checkServerRunning on the client) only read. Only a
    // contender that proves itself may take over — a silent one is rejected
    // after the deadline WITHOUT touching the live stream. Before this gate,
    // the client's 2s checklist probe cancelled the live video connection on
    // every pass, producing the reset-by-peer reconnect storm (2026-08-16).
    private var contender: NWConnection?
    private var contenderDeadline: DispatchWorkItem?
    private static let contenderProofWindow: TimeInterval = 1.5
    private static let authenticatedContenderWindow: TimeInterval = 5.0
    private static let loopbackControlProbeMaxBytes = 64

    /// Repeating session watchdog. Armed when a session goes live, stopped on
    /// any terminal path. It exists because a half-open socket is invisible:
    /// Network.framework delivers no `.failed`/`.cancelled` when a peer simply
    /// stops reading, so without a deadline the host would hold a "Connected"
    /// session for the life of the process.
    private var sessionWatchdog: DispatchSourceTimer?

    private func handleConnection(_ newConnection: NWConnection) {
        debugLog("New connection incoming...")
        if connectionReady, connection != nil {
            debugLog("Live client streaming — new connection held as contender until it speaks")
            armContender(newConnection)
            return
        }
        installConnection(newConnection)
    }

    /// Full takeover path used when no live client is streaming (or a
    /// contender proved itself): cancels the previous connection, resets
    /// per-connection protocol state, and waits for .ready. A promoted
    /// contender is already started and .ready — its handler won't see the
    /// .ready transition again, so drive startup directly instead.
    private func installConnection(
        _ newConnection: NWConnection,
        alreadyStarted: Bool = false,
        alreadyAuthenticated: Bool = false
    ) {
        // A stop() that is already draining networkQueue must not be followed
        // by a socket installed behind its back.
        if isStopped {
            debugLog("Rejecting connection that arrived after stop()")
            newConnection.cancel()
            return
        }
        // Publish the replacement before cancelling the prior client. The old
        // connection's .cancelled/.failed callback then cannot pass the
        // identity guard and tear down the promoted connection.
        let oldConnection = connection
        connection = newConnection
        sessionState.withLock { state in
            state.connectionReady = false
            state.clientSupportsFrameMetadata = false
            state.clientIsAvcOnly = false
            state.clientDecodeLimits = nil
            state.selectedCodec = nil
            state.codecSelectedSent = false
            state.startupPublished = false
            state.publishedMetadataSupport = nil
            state.publishedDecodeLimits = nil
        }
        inputBuffer.removeAll(keepingCapacity: true)
        resetFrameTransport(newConnection)

        if let oldConnection, oldConnection !== newConnection {
            sessionState.withLock { $0.receiving = false }
            oldConnection.cancel()
        }

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            // Identity guard: a terminal callback from a replaced connection
            // must not tear down the newer live one (same pattern as the
            // control connection above). Binding newConnection first is also
            // what keeps `===` from comparing two nils, which is `true`.
            guard self.connection === newConnection else {
                if case .failed = state { debugLog("Video state STALE terminal callback (connection replaced)") }
                return
            }
            debugLog("Connection state: \(state)")
            switch state {
            case .ready:
                self.onConnectionReady(newConnection, alreadyAuthenticated: alreadyAuthenticated)
            case .failed(let error):
                debugLog("Connection failed: \(error)")
                self.markDisconnected()
            case .cancelled:
                debugLog("Connection cancelled")
                self.markDisconnected()
            default:
                break
            }
        }

        if alreadyStarted {
            if newConnection.state == .ready {
                networkQueue.async { [weak self, weak newConnection] in
                    guard let self, let newConnection else { return }
                    self.onConnectionReady(newConnection, alreadyAuthenticated: alreadyAuthenticated)
                }
            }
            // A started-but-not-ready contender reaches .ready through the
            // state handler installed above, like a fresh connection.
        } else {
            newConnection.start(queue: networkQueue)
        }
    }

    private func resetFrameTransport(_ newConnection: NWConnection) {
        frameQueue.sync {
            if framePressureGeneration != 0 {
                WirelessTransportPressure.retire(generation: framePressureGeneration)
            }
            frameSendGeneration &+= 1
            framePressureGeneration = WirelessTransportPressure.reset(wireless: transportMode == .wireless)
            frameSendConnection = newConnection
            frameTransportReady = false
            frameWaitingForSync = true
            frameUsesMetadata = false
            frameSendsInFlight = 0
            droppedFrames = 0
            bytesSent = 0
            frameCount = 0
            totalFrameAgeNs = 0
            profiledFrameCount = 0
            lastStatsTime = DispatchTime.now()
        }
    }

    private func markFrameTransportReady(_ expected: NWConnection) {
        // Read the capability BEFORE entering frameQueue: sessionState is a leaf
        // lock and must never be taken while a queue hop is outstanding.
        let usesMetadata = sessionState.withLock { $0.clientSupportsFrameMetadata }
        frameQueue.sync {
            guard frameSendConnection === expected else { return }
            frameUsesMetadata = usesMetadata
            frameTransportReady = true
            WirelessTransportPressure.setReady(generation: framePressureGeneration)
        }
    }

    private func retireFrameTransport(_ expected: NWConnection?) {
        frameQueue.sync {
            if let expected, frameSendConnection !== expected { return }
            let pressureGeneration = framePressureGeneration
            frameSendGeneration &+= 1
            framePressureGeneration = 0
            frameSendConnection = nil
            frameTransportReady = false
            frameWaitingForSync = true
            frameUsesMetadata = false
            frameSendsInFlight = 0
            if pressureGeneration != 0 {
                WirelessTransportPressure.retire(generation: pressureGeneration)
            }
        }
    }

    /// Hold a would-be client until it proves it is real. The first byte it
    /// sends promotes it via installConnection (seeded with those bytes, so
    /// no client advertisement is lost); silence past the window cancels it.
    private func armContender(_ newConnection: NWConnection) {
        // Evict the PREVIOUS contender, never the new one. Passing the new
        // connection to clearContender(cancelSocket: true) cancelled the socket
        // that had not even been started yet, so it never reached .ready and a
        // legitimate USB/loopback reconnect could never take over — the user
        // had to stop and restart the server. It also left the old contender
        // un-cancelled (the `contender === c` test fails, so the property was
        // not nil'd while its deadline still fired), orphaning an accepted
        // socket with a live receive and no owner; one TCP fd per rejection.
        if let previous = contender, previous !== newConnection {
            debugLog("Superseded contender — cancelling it to keep one contender at a time")
            clearContender(previous, cancelSocket: true)
        }
        contender = newConnection
        let mode = transportMode
        let isLoopback = newConnection.endpoint.isLoopback
        guard mode == .wireless || isLoopback else {
            debugLog("Rejecting LAN contender: USB mode is active")
            clearContender(newConnection, cancelSocket: true)
            return
        }
        let isWireless = mode == .wireless && !isLoopback

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            // `===` on two optionals is true when BOTH are nil, so bind the
            // candidate first: the old nil === nil form let a deallocated
            // connection through to a force-unwrap.
            guard self.contender === newConnection else { return }
            switch state {
            case .ready:
                let candidate = newConnection
                if isWireless {
                    guard let expected = self.expectedAuthToken else {
                        debugLog("Wireless contender rejected — wireless mode is not active")
                        self.clearContender(candidate, cancelSocket: true)
                        return
                    }
                    debugLog("Wireless contender READY — authenticating before promotion")
                    self.runAuthHandshake(
                        connection: candidate,
                        expectedToken: expected,
                        onSuccess: { [weak candidate] in
                            guard let candidate else { return }
                            self.promoteAuthenticatedContender(candidate)
                        }
                    )
                } else {
                    self.armLoopbackContenderProof(candidate)
                }
            case .failed(let error):
                debugLog("Contender failed before proving: \(error)")
                self.clearContender(newConnection, cancelSocket: false)
            case .cancelled:
                self.clearContender(newConnection, cancelSocket: false)
            default:
                break
            }
        }
        newConnection.start(queue: networkQueue)

        let proofWindow = isWireless ? Self.authenticatedContenderWindow : Self.contenderProofWindow
        let deadline = DispatchWorkItem { [weak self, weak newConnection] in
            guard let self = self, let newConnection = newConnection else { return }
            guard self.contender === newConnection else { return }
            debugLog("Contender silent \(Int(proofWindow * 1000))ms — rejecting, live stream untouched")
            self.clearContender(newConnection, cancelSocket: true)
        }
        contenderDeadline = deadline
        networkQueue.asyncAfter(deadline: .now() + proofWindow, execute: deadline)
    }

    /// A loopback USB contender proves itself by sending any protocol byte.
    /// Wireless contenders use the full auth handshake above instead.
    private func armLoopbackContenderProof(_ newConnection: NWConnection) {
        newConnection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak newConnection] data, _, _, error in
            guard let self = self, let newConnection = newConnection else { return }
            guard self.contender === newConnection else { return }
            guard error == nil, let data, !data.isEmpty else { return }  // deadline handles silence
            debugLog("Contender spoke (\(data.count)B) — promoting to client")
            self.clearContender(newConnection, cancelSocket: false)
            self.installConnection(newConnection, alreadyStarted: true)
            self.inputBuffer.append(data)
            self.processInputBuffer(connection: newConnection)
        }
    }

    private func promoteAuthenticatedContender(_ candidate: NWConnection) {
        guard contender === candidate else {
            candidate.cancel()
            return
        }
        clearContender(candidate, cancelSocket: false)
        installConnection(candidate, alreadyStarted: true, alreadyAuthenticated: true)
    }

    private func clearContender(_ c: NWConnection, cancelSocket: Bool) {
        if contender === c { contender = nil }
        contenderDeadline?.cancel()
        contenderDeadline = nil
        if cancelSocket { c.cancel() }
    }

    /// A client is gone: stop treating the socket as sendable so the encode
    /// pipeline stops pushing frames into a corpse (the dropped-frame plateau
    /// after "Connection reset by peer"), and report the disconnect once.
    private func markDisconnected() {
        stopSessionWatchdog()
        let disconnectedConnection = connection
        sessionState.withLock { state in
            state.connectionReady = false
            state.receiving = false
            state.sessionGeneration &+= 1
        }
        retireFrameTransport(disconnectedConnection)
        connection = nil
        inputBuffer.removeAll(keepingCapacity: true)
        onClientDisconnected?()
    }

    // MARK: - Session lifetime

    /// The out-of-band control socket went away. Control carries pings, touch,
    /// stylus and brightness, but video is the primary path, so losing control
    /// alone must NOT end a live stream — the client legitimately drops and
    /// re-establishes control on Wi-Fi transitions. Only when video is not
    /// live either is the client genuinely gone, and then the session ends
    /// through the same path as a video-side failure.
    ///
    /// Previously all four control terminal exits just nil'd the socket, so a
    /// client whose control channel died silently kept a stale connected state
    /// with no way back to the accurate one.
    private func markControlDisconnected(_ c: NWConnection) {
        guard controlConnection === c else { return }
        controlConnection = nil
        controlAuthenticated = false
        c.cancel()
        let videoLive = sessionState.withLock { $0.connectionReady }
        if !videoLive {
            debugLog("Control socket closed with no live video — ending session")
            markDisconnected()
        } else {
            debugLog("Control socket closed; video still live — session continues")
        }
    }

    /// Records that the client sent us something. Called on every inbound byte
    /// on either socket — video or control, any message type — because a live
    /// control pinger is just as good proof of life as a video frame, and the
    /// client deliberately goes quiet on *both* sockets while backgrounded.
    private func noteInboundActivity() {
        sessionState.withLock { $0.lastInboundActivity = .now }
    }

    /// Marks the session live and starts the deadline that ends it. Called only
    /// on the first publish for a generation, so a capability re-advertisement
    /// cannot restart the client's budget indefinitely.
    private func beginSessionLifetime() {
        let generation: UInt64 = sessionState.withLock { state in
            state.sessionGeneration &+= 1
            state.lastInboundActivity = .now
            return state.sessionGeneration
        }
        startSessionWatchdog(generation: generation)
    }

    private func startSessionWatchdog(generation: UInt64) {
        stopSessionWatchdog()
        let tick = SessionLifetimePolicy.watchdogTickSeconds
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(
            deadline: .now() + tick,
            repeating: tick,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.checkSessionLifetime(generation: generation)
        }
        timer.resume()
        sessionWatchdog = timer
    }

    private func stopSessionWatchdog() {
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
    }

    /// Ends a session that has been silent past the deadline. A generation
    /// fence means a tick queued before a reconnect cannot act on the client
    /// that replaced it.
    private func checkSessionLifetime(generation: UInt64) {
        let (live, lastInbound, currentGeneration) = sessionState.withLock {
            ($0.connectionReady, $0.lastInboundActivity, $0.sessionGeneration)
        }
        // A session with no stamped activity is not being judged, it is waiting
        // on its install. Ending it here would be a false positive.
        guard generation == currentGeneration, let lastInbound else { return }
        let silence = .now - lastInbound
        guard SessionLifetimePolicy.shouldEndSession(
            sessionLive: live,
            hasInboundActivity: true,
            silence: silence
        ) else { return }

        debugLog(
            "Session silent for \(Int(silence / .seconds(1)))s — timing out and tearing down"
        )
        // Report the disconnect through the normal path first so per-client
        // state (stylus release, connected flag, lastConnected snapshot) is
        // cleared exactly as it is for an observed socket error, then escalate
        // to the host so the server and virtual display are released too.
        markDisconnected()
        onSessionTimeout?()
    }

    private func onConnectionReady(_ conn: NWConnection, alreadyAuthenticated: Bool = false) {
        // A .ready that lands after stop() drained the queues would otherwise
        // install a session nobody will ever tear down.
        if isStopped {
            debugLog("Rejecting connection that became ready after stop()")
            conn.cancel()
            return
        }
        if alreadyAuthenticated {
            beginExistingProtocol(on: conn)
            return
        }
        let mode = transportMode
        if mode == .usb && !conn.endpoint.isLoopback {
            debugLog("Rejecting LAN client: USB mode is active")
            conn.cancel()
            return
        }
        if conn.endpoint.isLoopback {
            debugLog("Client connected via loopback (\(mode.rawValue)) — skipping auth")
            beginExistingProtocol(on: conn)
            return
        }
        guard mode == .wireless, let expected = expectedAuthToken else {
            debugLog("Rejecting non-loopback client: wireless mode/auth is not active")
            conn.cancel()
            return
        }
        debugLog("Client connected via LAN — running auth handshake")
        runAuthHandshake(connection: conn, expectedToken: expected)
    }

    private func beginExistingProtocol(on conn: NWConnection) {
        startReceivingTouch()

        // Give new clients a short chance to opt in before the first frame.
        // Legacy clients send no capability message, so we continue shortly
        // after this window with the old frame type.
        // The client's capability adverts (decoder limits, metadata support)
        // land right after connect; a client racing a just-rebooted server
        // can deliver them past 100ms, silently downgrading the session to
        // the legacy no-metadata path. 250ms covers that race; the capability
        // handlers below still short-circuit startup the moment adverts arrive,
        // so well-behaved clients pay no extra delay. Negotiation stays
        // re-runnable: this timer is only the fallback for a client that never
        // advertises, and a late advert must still be able to correct it.
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.finishProtocolStartup(on: conn)
        }
    }

    private struct StartupPlan {
        let codec: StreamCodec
        /// Only an AVC-only client (which opted in with clientAvcOnly) is told.
        let sendCodecSelected: Bool
        let firstPublish: Bool
    }

    /// Decide — atomically — what the caller must publish, or nil when the wire
    /// already reflects every client capability (the caller's no-op case).
    ///
    /// This is reached from the networkQueue startup timer AND from receiveQueue
    /// in the capability arms, so the old "read a plain Bool, then set it twenty
    /// lines later" guard let both queues through: onCodecNegotiated fired twice
    /// for one connection, the host rebuilt the encoder twice (one orphaned) and
    /// the client received two displayConfig messages.
    private func planProtocolStartup(on conn: NWConnection) -> StartupPlan? {
        sessionState.withLock { state in
            guard !state.stopped, connection === conn else { return nil }
            let codec: StreamCodec = state.clientIsAvcOnly ? .h264 : .hevc
            let firstPublish = !state.startupPublished
            let changed = firstPublish
                || state.selectedCodec != codec
                || state.publishedMetadataSupport != state.clientSupportsFrameMetadata
                || !limitsMatch(state.publishedDecodeLimits, state.clientDecodeLimits)
            guard changed else { return nil }
            let plan = StartupPlan(
                codec: codec,
                sendCodecSelected: codec == .h264 && !state.codecSelectedSent,
                firstPublish: firstPublish
            )
            state.selectedCodec = codec
            state.codecSelectedSent = state.codecSelectedSent || plan.sendCodecSelected
            state.startupPublished = true
            state.publishedMetadataSupport = state.clientSupportsFrameMetadata
            state.publishedDecodeLimits = state.clientDecodeLimits
            return plan
        }
    }

    private func limitsMatch(
        _ lhs: (width: Int, height: Int)?,
        _ rhs: (width: Int, height: Int)?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.width == rhs.width && lhs.height == rhs.height
        default: return false
        }
    }

    private func finishProtocolStartup(on conn: NWConnection) {
        guard let plan = planProtocolStartup(on: conn) else { return }

        if plan.sendCodecSelected {
            // Must precede the display config so the client knows the codec
            // before it sizes and configures its decoder. Safe to send: this
            // client opted in via clientAvcOnly, and codecSelectedSent in the
            // plan guarantees it goes out at most once per connection.
            let msg = Data([WireMessage.codecSelected, plan.codec.wireId])
            conn.send(content: msg, completion: .contentProcessed { _ in })
            debugLog("Sent codecSelected: H.264")
        }
        // Synchronous, before sendDisplaySize(): the handler switches the
        // encoder AND updates displayWidth/Height (clamped for H.264) so the
        // display config below carries decoder-safe dimensions. It is
        // idempotent for an unchanged codec+size, so re-running it for a late
        // advert costs no rebuild.
        onCodecNegotiated?(plan.codec)

        debugLog(plan.firstPublish
            ? "Client connected - sending display config first"
            : "Client capability update - re-sending display config")
        sendDisplaySize()
        sessionState.withLock { $0.connectionReady = true }
        markFrameTransportReady(conn)
        if plan.firstPublish {
            let metadata = sessionState.withLock { $0.clientSupportsFrameMetadata }
            debugLog("Connection ready for frames (metadata=\(metadata ? "on" : "off"), codec=\(plan.codec))")
            // Start the disconnect deadline only on the first publish: a later
            // capability re-advertisement must not hand the client a fresh
            // five-minute budget.
            beginSessionLifetime()
            onClientConnected?()
        }
    }

    private func runAuthHandshake(
        connection conn: NWConnection,
        expectedToken: Data,
        onSuccess: (() -> Void)? = nil
    ) {
        let deadline = DispatchWorkItem {
            debugLog("Wireless auth timed out — closing connection")
            conn.cancel()
        }
        networkQueue.asyncAfter(deadline: .now() + 5, execute: deadline)

        // Read fixed prefix [magic 4][token 32][name_len 1] = 37 bytes.
        conn.receive(minimumIncompleteLength: HandshakeCodec.fixedPrefixLen,
                     maximumLength: HandshakeCodec.fixedPrefixLen) { [weak self] prefixData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                deadline.cancel()
                debugLog("Auth read error: \(error)")
                conn.cancel()
                return
            }
            guard let prefix = prefixData, prefix.count == HandshakeCodec.fixedPrefixLen else {
                deadline.cancel()
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let prefixBytes = Array(prefix)
            guard Array(prefixBytes[0..<4]) == HandshakeCodec.requestMagic else {
                deadline.cancel()
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let nameLen = Int(prefixBytes[36])
            guard (1...64).contains(nameLen) else {
                deadline.cancel()
                self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                return
            }
            // Read variable name.
            conn.receive(minimumIncompleteLength: nameLen, maximumLength: nameLen) { nameData, _, _, error in
                if let error = error {
                    deadline.cancel()
                    debugLog("Auth name read error: \(error)")
                    conn.cancel()
                    return
                }
                guard let nameData = nameData, nameData.count == nameLen else {
                    deadline.cancel()
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                    return
                }
                let full = prefix + nameData
                do {
                    let parsed = try HandshakeCodec.parseRequest(full)
                    if WirelessAuth.validate(parsed.token, expected: expectedToken) {
                        deadline.cancel()
                        debugLog("Wireless auth OK — device: \(parsed.deviceName)")
                        self.sendAuthResponse(conn, status: .ok, thenClose: false)
                        self.onWirelessClientPaired?(parsed.deviceName)
                        if let onSuccess {
                            onSuccess()
                        } else {
                            self.beginExistingProtocol(on: conn)
                        }
                    } else {
                        deadline.cancel()
                        debugLog("Wireless auth rejected: token mismatch")
                        self.sendAuthResponse(conn, status: .invalidToken, thenClose: true)
                    }
                } catch HandshakeError.invalidMagic {
                    deadline.cancel()
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                } catch HandshakeError.invalidName {
                    deadline.cancel()
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                } catch {
                    deadline.cancel()
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                }
            }
        }
    }

    private func sendAuthResponse(_ conn: NWConnection, status: HandshakeStatus, thenClose: Bool) {
        let bytes = HandshakeCodec.encodeResponse(status: status)
        conn.send(content: bytes, completion: .contentProcessed { _ in
            if thenClose {
                debugLog("Auth rejected (\(status)), closing connection")
                conn.cancel()
            }
        })
    }

    /// Largest dimension the client will accept from a display config.
    static let maxWireDimension = 16_384
    /// Largest total pixel count the client will accept (8K UHD).
    static let maxWirePixels: Int64 = 33_554_432

    /// DisplayConfig.fromWire on the client THROWS for a rotation outside
    /// {0,90,180,270}, a dimension outside 1...16384, or more than 8K pixels,
    /// and the client treats that as a fatal protocol error: an immediate,
    /// permanent reconnect loop with no host-side diagnostic. Normalize here so
    /// the host can never put such a value on the wire.
    static func normalizedRotation(_ rotation: Int) -> Int {
        let wrapped = ((rotation % 360) + 360) % 360
        let snapped = ((wrapped + 45) / 90) * 90
        return min(snapped, 270)
    }

    static func clampedDisplaySize(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = min(max(width, 1), maxWireDimension)
        var h = min(max(height, 1), maxWireDimension)
        guard Int64(w) * Int64(h) > maxWirePixels else { return (w, h) }
        let overflow = Double(w) * Double(h) / Double(maxWirePixels)
        let scale = 1 / overflow.squareRoot()
        w = max(1, Int((Double(w) * scale).rounded(.down)))
        h = max(1, Int((Double(h) * scale).rounded(.down)))
        // Flooring both can still land a few pixels over the client's ceiling.
        if Int64(w) * Int64(h) > maxWirePixels {
            let remaining = Double(w) * Double(h) / Double(maxWirePixels)
            w = max(1, Int((Double(w) / remaining).rounded(.down)))
            h = max(1, Int((Double(h) / remaining).rounded(.down)))
        }
        return (w, h)
    }

    /// Decodes the 4-byte decoder-limits payload, [w-hi][w-lo][h-hi][h-lo],
    /// 7 data bits each with the high bit always set. Returns nil when any
    /// byte lacks the marker bit.
    static func decodeClientDecoderLimits(_ payload: [UInt8]) -> (width: Int, height: Int)? {
        guard payload.count == 4, payload.allSatisfy({ $0 & 0x80 != 0 }) else { return nil }
        let width = (Int(payload[0] & 0x7F) << 7) | Int(payload[1] & 0x7F)
        let height = (Int(payload[2] & 0x7F) << 7) | Int(payload[3] & 0x7F)
        return (width, height)
    }

    static func displayConfigPayload(
        width: Int,
        height: Int,
        rotation: Int,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) -> Data {
        let size = clampedDisplaySize(width: width, height: height)
        let transform = normalizedRotation(rotation)
            + (flipHorizontal ? 1000 : 0)
            + (flipVertical ? 2000 : 0)
        var data = Data()
        data.append(WireMessage.displayConfig)
        data.append(contentsOf: withUnsafeBytes(of: Int32(size.width).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(size.height).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(transform).bigEndian) { Data($0) })
        return data
    }

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        let size = Self.clampedDisplaySize(width: width, height: height)
        let snapped = Self.normalizedRotation(rotation)
        if size.width != width || size.height != height || snapped != rotation {
            debugLog("Display config normalized: \(width)x\(height) @ \(rotation)° -> \(size.width)x\(size.height) @ \(snapped)°")
        }
        sessionState.withLock { state in
            state.displayWidth = size.width
            state.displayHeight = size.height
            state.rotation = snapped
            state.flipHorizontal = flipHorizontal
            state.flipVertical = flipVertical
        }
    }

    func updateDisplayTransform(rotation: Int, flipHorizontal: Bool, flipVertical: Bool) {
        let snapped = Self.normalizedRotation(rotation)
        sessionState.withLock { state in
            state.rotation = snapped
            state.flipHorizontal = flipHorizontal
            state.flipVertical = flipVertical
        }
        sendDisplaySize()
    }

    func sendDisplaySize() {
        guard let connection = connection else { return }
        let geometry = sessionState.withLock {
            (width: $0.displayWidth, height: $0.displayHeight, rotation: $0.rotation,
             flipHorizontal: $0.flipHorizontal, flipVertical: $0.flipVertical)
        }
        let data = Self.displayConfigPayload(
            width: geometry.width,
            height: geometry.height,
            rotation: geometry.rotation,
            flipHorizontal: geometry.flipHorizontal,
            flipVertical: geometry.flipVertical
        )
        connection.send(content: data, completion: .contentProcessed { _ in })
        debugLog("Sent display config: \(geometry.width)x\(geometry.height) @ \(geometry.rotation)°, h=\(geometry.flipHorizontal), v=\(geometry.flipVertical)")
    }

    private func startReceivingTouch() {
        guard !isReceiving else {
            debugLog("Already receiving touch events")
            return
        }
        sessionState.withLock { $0.receiving = true }
        debugLog("Starting input receive loop... (touch=\(touchEnabled ? "on" : "off"))")

        // Use loop-based pattern instead of recursion to prevent stack overflow
        receiveQueue.async { [weak self] in
            self?.touchReceiveLoop()
        }
    }

    private func touchReceiveLoop() {
        guard let connection = connection, isReceiving, !isStopped else {
            sessionState.withLock { $0.receiving = false }
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            // Identity guard: a stale completion from a replaced connection must
            // not kill the live connection's receive loop (isReceiving=false on
            // an old connection would starve the new client's input path).
            guard let self = self, self.isReceiving, !self.isStopped, self.connection === connection else { return }

            if error != nil || isComplete {
                // A peer that closed cleanly reports isComplete, and a reset
                // socket reports an error. Neither reaches the stateUpdateHandler
                // as .failed/.cancelled reliably, so the disconnect used to go
                // unreported here and the host kept a "Connected" session for a
                // socket nobody was on.
                self.sessionState.withLock { $0.receiving = false }
                self.inputBuffer.removeAll(keepingCapacity: true)
                self.markDisconnected()
                return
            }

            if let data = data, !data.isEmpty {
                // Any byte counts as proof of life, not just video frames: the
                // video path's own message types (display config, codec
                // selection, capability advertisements) are as good as a frame.
                self.noteInboundActivity()
                self.inputBuffer.append(data)
                self.processInputBuffer(connection: connection)
            }

            self.receiveQueue.async {
                self.touchReceiveLoop()
            }
        }
    }

    private func processInputBuffer(connection: NWConnection) {
        while let msgType = inputBuffer.first {
            switch msgType {
            case WireMessage.touchEvent:
                // Touch event: 1 type + 1 pointerCount + N*(4x+4y) + 4 action.
                // 1 finger: 14 bytes, 2 fingers: 22 bytes.
                guard inputBuffer.count >= 2 else { return }

                let pointerCount = Int(inputByte(at: 1))
                guard pointerCount == 1 || pointerCount == 2 else {
                    debugLog("Invalid touch pointer count: \(pointerCount)")
                    consumeInputBytes(1)
                    continue
                }

                let expectedSize = 2 + pointerCount * 8 + 4
                guard inputBuffer.count >= expectedSize else { return }

                let message = Data(inputBuffer.prefix(expectedSize))
                consumeInputBytes(expectedSize)

                // Drop early if host has touch disabled, after consuming exactly
                // this touch frame so coalesced ping/keyframe messages survive.
                if touchEnabled {
                    handleTouchMessage(message, pointerCount: pointerCount)
                }

            case WireMessage.stylusEvent:
                guard inputBuffer.count >= Self.stylusEventSize else { return }
                let message = Data(inputBuffer.prefix(Self.stylusEventSize))
                consumeInputBytes(Self.stylusEventSize)
                // A stylus packet is accepted only after the client has
                // advertised support. This keeps old hosts from seeing the
                // extended packet and gives old clients their legacy path.
                if touchEnabled, clientSupportsStylus {
                    handleStylusMessage(message)
                } else {
                    debugLog("Ignoring stylus event before capability negotiation or with touch disabled")
                }

            case WireMessage.ping:
                // Ping from client: echo back as pong (type=5) with client's timestamp.
                guard inputBuffer.count >= 9 else { return }

                let clientTimestamp = Data(inputBuffer.dropFirst().prefix(8))
                consumeInputBytes(9)

                var pong = Data(capacity: 9)
                pong.append(WireMessage.pong) // Type: Pong
                pong.append(clientTimestamp)
                connection.send(content: pong, completion: .contentProcessed { _ in })

            case WireMessage.keyframeRequest:
                // Keyframe request from Android decoder. The client sends a
                // two-byte message: type + flags.
                guard inputBuffer.count >= 2 else { return }

                let flags = inputByte(at: 1)
                consumeInputBytes(2)
                onKeyframeRequested?((flags & 1) != 0)

            case WireMessage.clientSupportsFrameMetadata:
                // One-byte opt-in from newer clients. Keeping this payload-free
                // lets older hosts safely ignore it without misaligning input.
                consumeInputBytes(1)
                let firstAdvert = !sessionState.withLock { state -> Bool in
                    let wasSupported = state.clientSupportsFrameMetadata
                    state.clientSupportsFrameMetadata = true
                    return wasSupported
                }
                if firstAdvert {
                    debugLog("Client supports video frame metadata")
                }
                finishProtocolStartup(on: connection)

            case WireMessage.clientAvcOnly:
                // Payload-free opt-in (same convention as type 8): the client
                // has no HEVC decoder, stream H.264 instead.
                consumeInputBytes(1)
                let firstAdvert = !sessionState.withLock { state -> Bool in
                    let wasAvcOnly = state.clientIsAvcOnly
                    state.clientIsAvcOnly = true
                    return wasAvcOnly
                }
                if firstAdvert {
                    debugLog("Client is AVC-only — will negotiate H.264")
                }
                finishProtocolStartup(on: connection)

            case WireMessage.clientDecoderLimits, WireMessage.legacyClientDecoderLimits:
                guard inputBuffer.count >= 5 else { return }

                let payload = (1...4).map { inputByte(at: $0) }
                consumeInputBytes(5)
                guard let limits = Self.decodeClientDecoderLimits(payload) else {
                    debugLog("Malformed decoder-limits payload — ignoring")
                    continue
                }
                if msgType == WireMessage.legacyClientDecoderLimits {
                    debugLog("Client sent decoder limits under legacy tag 11 — outdated Android build")
                }
                // Anything below QVGA-ish is a nonsense report — ignore it.
                if limits.width >= 256 && limits.height >= 256 {
                    sessionState.withLock { $0.clientDecodeLimits = (limits.width, limits.height) }
                    debugLog("Client decoder limit: \(limits.width)x\(limits.height)")
                }
                finishProtocolStartup(on: connection)

            case WireMessage.clientSupportsStylus:
                // Payload-free opt-in. The acknowledgement is emitted only
                // for a client that explicitly sent this byte, so old Android
                // clients never receive an unknown server message.
                consumeInputBytes(1)
                let firstAdvert = !sessionState.withLock { state -> Bool in
                    let wasSupported = state.clientSupportsStylus
                    state.clientSupportsStylus = true
                    return wasSupported
                }
                if firstAdvert {
                    connection.send(
                        content: Data([WireMessage.serverSupportsStylus]),
                        completion: .contentProcessed { _ in }
                    )
                    debugLog("Client supports S Pen stylus events")
                }
                finishProtocolStartup(on: connection)

            default:
                debugLog("Unknown client input type: \(msgType)")
                consumeInputBytes(1)
            }
        }
    }

    private func handleTouchMessage(_ data: Data, pointerCount: Int) {
        let x1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Float.self) }
        let y1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: Float.self) }

        var x2: Float = 0
        var y2: Float = 0
        if pointerCount >= 2 {
            x2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: Float.self) }
            y2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: Float.self) }
        }

        let actionOffset = 2 + pointerCount * 8
        let action = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: actionOffset, as: Int32.self) }

        // Mirror decodeStylusEvent's guard. A zero-extent client view yields
        // 0/0, and Kotlin's coerceIn passes NaN through unchanged, so a
        // non-finite coordinate reaches the cursor math and pins the pointer.
        guard x1.isFinite, y1.isFinite, x1 >= 0, x1 <= 1, y1 >= 0, y1 <= 1,
              x2.isFinite, y2.isFinite, x2 >= 0, x2 <= 1, y2 >= 0, y2 <= 1 else {
            debugLog("Non-finite or out-of-range touch payload — dropping")
            return
        }

        DispatchQueue.main.async {
            self.onTouchEvent?(x1, y1, Int(action), pointerCount, x2, y2)
        }
    }

    private func handleStylusMessage(_ data: Data) {
        guard let event = decodeStylusEvent(data) else {
            debugLog("Invalid stylus event payload")
            return
        }
        DispatchQueue.main.async {
            self.onStylusEvent?(event)
        }
    }

    private func decodeStylusEvent(_ data: Data) -> StylusEvent? {
        guard data.count >= Self.stylusEventSize,
              data[data.startIndex] == WireMessage.stylusEvent else { return nil }

        let action = Int(data[data.index(data.startIndex, offsetBy: 1)])
        guard (0...3).contains(action) else { return nil }
        let toolType = Int(data[data.index(data.startIndex, offsetBy: 2)])
        let x = readFloatLE(data, offset: 4)
        let y = readFloatLE(data, offset: 8)
        let pressure = readFloatLE(data, offset: 12)
        let tilt = readFloatLE(data, offset: 16)
        let orientation = readFloatLE(data, offset: 20)
        let buttons = readUInt32LE(data, offset: 24)
        guard x.isFinite, y.isFinite, pressure.isFinite,
              tilt.isFinite, orientation.isFinite else { return nil }

        return StylusEvent(
            x: x,
            y: y,
            action: action,
            toolType: toolType,
            pressure: pressure,
            tilt: tilt,
            orientation: orientation,
            buttonState: buttons
        )
    }

    private func readFloatLE(_ data: Data, offset: Int) -> Float {
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return Float(bitPattern: UInt32(littleEndian: raw))
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return UInt32(littleEndian: raw)
    }

    private static let stylusEventSize = 28

    private func inputByte(at offset: Int) -> UInt8 {
        inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: offset)]
    }

    private func consumeInputBytes(_ count: Int) {
        let endIndex = inputBuffer.index(inputBuffer.startIndex, offsetBy: count)
        inputBuffer.removeSubrange(inputBuffer.startIndex..<endIndex)
    }

    func sendFrame(_ data: Data, timestamp: UInt64, isKeyframe: Bool = false) {
        frameQueue.async { [weak self] in
            self?.sendEncodedFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }
    }

    /// Mirrors MAX_FRAME_SIZE in the Android client's StreamClient. A frame
    /// above it is rejected there with an IOException, which the user sees as
    /// an endless crash/reconnect loop that looks like a network fault. nil
    /// means the frame cannot be described in the 4-byte size field at all.
    static func wireFrameSize(_ size: Int) -> UInt32? {
        guard size > 0, size <= maxFrameBytes else { return nil }
        return UInt32(size)
    }
    static let maxFrameBytes = 5 * 1024 * 1024

    private func sendEncodedFrame(_ data: Data, timestamp: UInt64, isKeyframe: Bool) {
        guard !isStopped,
              frameTransportReady,
              let connection = frameSendConnection else { return }

        // Before the first sync frame there is no decoder reference chain yet,
        // so ignoring P-frames is safe. Once an IDR has been sent, every encoded
        // frame is preserved in order until the connection succeeds or fails.
        if frameWaitingForSync {
            guard isKeyframe else {
                droppedFrames += 1
                return
            }
            frameWaitingForSync = false
            debugLog("First keyframe accepted for new client")
        }

        guard let wireSize = Self.wireFrameSize(data.count) else {
            // Advertising a truncated size would desync the client's parser, so
            // the whole frame goes instead.
            droppedFrames += 1
            debugLog("Dropping \(data.count)B frame — above the client's \(Self.maxFrameBytes)B frame limit")
            return
        }

        let generation = frameSendGeneration
        let pressureGeneration = framePressureGeneration
        let header = makeFrameHeader(
            size: wireSize,
            timestamp: timestamp,
            isKeyframe: isKeyframe,
            usesMetadata: frameUsesMetadata
        )
        if pressureGeneration != 0,
           let tcpMetadata = connection.metadata(definition: NWProtocolTCP.definition) as? NWProtocolTCP.Metadata {
            WirelessTransportPressure.observeSendBuffer(
                generation: pressureGeneration,
                availableBytes: tcpMetadata.availableSendBuffer,
                frameBytes: data.count
            )
        }
        frameSendsInFlight += 1
        if pressureGeneration != 0 {
            WirelessTransportPressure.beginSend(generation: pressureGeneration, bytes: data.count)
        }

        // Avoid copying the entire encoded frame merely to prepend a 5/14-byte
        // protocol header. Network.framework keeps content in one logical
        // defaultMessage context: the header is incomplete and the existing
        // encoder Data completes it. batch() lets the stack coalesce both send
        // submissions while preserving the exact TCP byte stream.
        connection.batch {
            connection.send(
                content: header,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak connection] error in
                    if let error {
                        debugLog("Video header send failed: \(error) — cancelling current connection")
                        connection?.cancel()
                    }
                }
            )
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else { return }

                    // Pressure completion is generation-fenced independently,
                    // so an old callback can never reduce the replacement count.
                    if pressureGeneration != 0 {
                        WirelessTransportPressure.completeSend(generation: pressureGeneration, bytes: data.count)
                    }

                    self.frameQueue.async {
                        guard self.frameSendGeneration == generation,
                              self.frameSendConnection === connection else {
                            return
                        }

                        self.frameSendsInFlight = max(0, self.frameSendsInFlight - 1)
                        if let error {
                            self.droppedFrames += 1
                            self.frameTransportReady = false
                            debugLog("Video payload send failed: \(error) — cancelling current connection")
                            connection.cancel()
                        }
                    }
                }
            )
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let sendAge = now >= timestamp ? now - timestamp : 0
        updateStats(bytes: data.count, frameAgeNs: sendAge)
    }

    private func makeFrameHeader(
        size: UInt32,
        timestamp: UInt64,
        isKeyframe: Bool,
        usesMetadata: Bool
    ) -> Data {
        if usesMetadata {
            var header = Data(capacity: 14)
            header.append(WireMessage.videoFrameWithMetadata)
            appendFrameSize(size, to: &header)
            header.append(isKeyframe ? 1 : 0)
            var captureTimestamp = timestamp.bigEndian
            withUnsafeBytes(of: &captureTimestamp) { header.append(contentsOf: $0) }
            return header
        }

        // Keep legacy frame type 0 for clients that do not advertise metadata
        // support; remove after legacy clients age out.
        var header = Data(capacity: 5)
        header.append(WireMessage.legacyVideoFrame)
        appendFrameSize(size, to: &header)
        return header
    }

    private func appendFrameSize(_ size: UInt32, to packet: inout Data) {
        // The caller has already rejected anything above the client's frame
        // limit, so the value fits Int32 and the reinterpretation is exact.
        // Int32(size) would trap for an out-of-range frame instead.
        var frameSize = Int32(bitPattern: size).bigEndian
        withUnsafeBytes(of: &frameSize) { packet.append(contentsOf: $0) }
    }

    // Pipeline profiling: track frame age at send time
    private var totalFrameAgeNs: UInt64 = 0
    private var profiledFrameCount: UInt64 = 0

    private func updateStats(bytes: Int, frameAgeNs: UInt64 = 0) {
        bytesSent += UInt64(bytes)
        frameCount += 1
        if frameAgeNs > 0 {
            totalFrameAgeNs += frameAgeNs
            profiledFrameCount += 1
        }

        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed >= 1.0 {
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            let fps = Double(frameCount) / elapsed
            onStats?(fps, mbps)

            // Log pipeline latency profile
            if profiledFrameCount > 0 {
                let avgAgeMs = Double(totalFrameAgeNs) / Double(profiledFrameCount) / 1_000_000.0
                debugLog("Pipeline: \(String(format: "%.1f", fps))fps, \(String(format: "%.1f", mbps))Mbps, avg frame age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(droppedFrames), sendInFlight: \(frameSendsInFlight)")
            }

            bytesSent = 0
            frameCount = 0
            droppedFrames = 0
            totalFrameAgeNs = 0
            profiledFrameCount = 0
            lastStatsTime = now
        }
    }

    /// Main-thread only (AppDelegate.stopServer is @MainActor). MUST NOT be
    /// called from networkQueue, receiveQueue, controlQueue or frameQueue: the
    /// blocks below `sync` onto each of them, so a call from inside one would
    /// self-deadlock.
    func stop() {
        // Latch first: a .ready or newConnectionHandler already queued behind
        // this point sees `stopped` and cancels its own socket instead of
        // installing a session nothing will ever tear down.
        sessionState.withLock { state in
            state.stopped = true
            state.receiving = false
            state.connectionReady = false
            state.clientSupportsStylus = false
        }

        // Every remaining field has exactly one owning queue, so teardown runs
        // as a block on that queue rather than racing it from main. Draining
        // networkQueue first is what makes the latch above authoritative: a
        // connection installed after it would otherwise leak its socket.
        networkQueue.sync {
            stopSessionWatchdog()
            connection?.cancel()
            listener?.cancel()
            if let c = contender { clearContender(c, cancelSocket: true) }
            connection = nil
            listener = nil
        }
        // The cancelled sockets' terminal callbacks queue behind this block and
        // fail the identity guard (connection is already nil), so no spurious
        // onClientDisconnected is reported.
        controlQueue.sync {
            controlConnection?.cancel()
            controlListener?.cancel()
            controlConnection = nil
            controlListener = nil
            controlInputBuffer.removeAll(keepingCapacity: true)
            controlAuthenticated = false
            controlTouchCount = 0
            lastControlTouchNs = 0
            maxControlTouchGapMs = 0
            clientSupportsBrightness = false
            lastBrightness = nil
        }
        // Its own frameQueue.sync — never call this from frameQueue.
        retireFrameTransport(nil)
        frameQueue.sync {}
        receiveQueue.sync {}
    }
}
