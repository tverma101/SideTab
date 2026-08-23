import Foundation
import Network

private enum WireMessage {
    static let legacyVideoFrame: UInt8 = 0
    static let displayConfig: UInt8 = 1
    static let touchEvent: UInt8 = 2
    static let ping: UInt8 = 4
    static let pong: UInt8 = 5
    static let videoFrameWithMetadata: UInt8 = 6
    static let keyframeRequest: UInt8 = 7
    static let clientSupportsFrameMetadata: UInt8 = 8
    /// Client→server, payload-free (old hosts consume 1 byte safely):
    /// "this device has no HEVC decoder".
    static let clientAvcOnly: UInt8 = 9
    /// Server→client, 1-byte payload (StreamCodec.wireId). Sent ONLY to
    /// clients that sent clientAvcOnly — old clients disconnect on unknown
    /// message types, so this must never be sent unsolicited.
    static let codecSelected: UInt8 = 10
    /// Client→server, payload-free capability: "I understand BRIGHT (type 11)".
    /// Old servers log unknown control types and skip — safe unsolicited.
    static let clientSupportsBrightness: UInt8 = 3
    /// Server→client, 1-byte payload (0..255). Sent ONLY to clients that sent
    /// clientSupportsBrightness — old clients disconnect on unknown types.
    static let bright: UInt8 = 11
    /// Client→server, 4-byte payload: the client's max decode size (issue
    /// #41). Every payload byte has the high bit set, so old hosts that
    /// consume unknown types byte-by-byte skip the payload harmlessly.
    /// Value was 11 (collided with server→client BRIGHT) — bumped to 12
    /// so a brightness payload byte is never mistaken for a limit frame.
    static let clientDecoderLimits: UInt8 = 12
    /// Back-compat alias: old #41 tablets still send 11. Accept either.
    static let clientDecoderLimitsLegacy: UInt8 = 11
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
    private var controlTouchCount = 0
    private var lastControlTouchNs: UInt64 = 0
    private var maxControlTouchGapMs = 0.0
    private var clientSupportsBrightness = false
    private let controlQueue = DispatchQueue(label: "controlQueue", qos: .userInteractive)
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    /// Fired once per connection during protocol startup, BEFORE the display
    /// config is sent, for every outcome (.hevc or .h264) — so the capture
    /// pipeline can also revert to HEVC after an AVC-only client goes away.
    var onCodecNegotiated: ((StreamCodec) -> Void)?
    // Touch callback: (x1, y1, action, pointerCount, x2, y2)
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    var onStats: ((Double, Double) -> Void)?
    var onKeyframeRequested: ((Bool) -> Void)?
    // Whether host wants to receive touch events from client. Ping/pong is
    // handled regardless. When false, incoming touch frames are dropped
    // immediately without parsing or dispatching to main queue.
    var touchEnabled: Bool = true

    // Wireless auth: when non-nil, non-loopback connections must present this
    // 32-byte token before being allowed to proceed. nil means wireless mode
    // is inactive — non-loopback connections are rejected immediately.
    var expectedAuthToken: Data?
    var onWirelessClientPaired: ((String) -> Void)?

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "networkQueue", qos: .userInteractive)
    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastStatsTime = DispatchTime.now()
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var flipHorizontal = false
    private var flipVertical = false
    private var isReceiving = false
    private var isStopped = false
    private var connectionReady = false
    private var waitingForSyncFrame = false
    private var clientSupportsFrameMetadata = false
    private var clientIsAvcOnly = false
    /// Max decode size reported by the connected client (issue #41).
    private(set) var clientDecodeLimits: (width: Int, height: Int)?
    private var inputBuffer = Data()

    init(port: UInt16, controlPort: UInt16? = nil) {
        self.port = port
        self.controlPort = controlPort ?? port + 1
    }

    func start() {
        isStopped = false
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            // Optimize TCP for low-latency streaming
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true  // Disable Nagle's algorithm
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    debugLog("TCP Server listening on port \(self.port)")
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
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
            }
            controlListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: controlPort))
            controlListener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleControlConnection(newConnection)
            }
            controlListener?.stateUpdateHandler = { state in
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
        if let old = controlConnection {
            old.cancel()
        }
        controlInputBuffer = Data()  // fresh storage — never keep poisoned inline slices
        controlTouchCount = 0
        lastControlTouchNs = 0
        maxControlTouchGapMs = 0
        clientSupportsBrightness = false
        controlConnection = newConnection
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
                self.startReceivingControl()
            case .failed(let error):
                debugLog("Control connection failed: \(error)")
                self.controlConnection = nil
                newConnection.cancel()
            case .cancelled:
                self.controlConnection = nil
            default:
                break
            }
        }
        newConnection.start(queue: controlQueue)
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
                self.controlConnection = nil
                connection.cancel()
                return
            }
            if isComplete {
                debugLog("Control receive EOF — closing")
                self.controlConnection = nil
                connection.cancel()
                return
            }
            if let data = data, !data.isEmpty {
                debugLog("Control receive \(data.count)B")
                self.controlInputBuffer.append(data)
                self.processControlBuffer(connection: connection)
            }
            self.startReceivingControl()
        }
    }

    private func processControlBuffer(connection: NWConnection) {
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
        guard clientSupportsBrightness, let connection = controlConnection else { return }
        var msg = Data(capacity: 2)
        msg.append(WireMessage.bright)
        msg.append(value)
        connection.send(content: msg, completion: .contentProcessed { _ in })
        debugLog("BRIGHT sent: \(value)")
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
    private func installConnection(_ newConnection: NWConnection, alreadyStarted: Bool = false) {
        // Clean up old connection properly
        if let oldConnection = connection, oldConnection !== newConnection {
            isReceiving = false
            oldConnection.cancel()
        }

        connectionReady = false
        clientSupportsFrameMetadata = false
        clientIsAvcOnly = false
        clientDecodeLimits = nil
        waitingForSyncFrame = true
        inputBuffer.removeAll(keepingCapacity: true)
        connection = newConnection
        droppedFrames = 0

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self = self else { return }
            // Identity guard: a terminal callback from a replaced connection
            // must not tear down the newer live one (same pattern as the
            // control connection above).
            guard self.connection === newConnection else {
                if case .failed = state { debugLog("Video state STALE terminal callback (connection replaced)") }
                return
            }
            debugLog("Connection state: \(state)")
            switch state {
            case .ready:
                self.onConnectionReady(newConnection!)
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
                networkQueue.async { self.onConnectionReady(newConnection) }
            }
            // A started-but-not-ready contender reaches .ready through the
            // state handler installed above, like a fresh connection.
        } else {
            newConnection.start(queue: networkQueue)
        }
    }

    /// Hold a would-be client until it proves it is real. The first byte it
    /// sends promotes it via installConnection (seeded with those bytes, so
    /// no client advertisement is lost); silence past the window cancels it.
    private func armContender(_ newConnection: NWConnection) {
        clearContender(newConnection, cancelSocket: true)  // one contender at a time
        contender = newConnection

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self = self else { return }
            guard self.contender === newConnection else { return }
            switch state {
            case .failed(let error):
                debugLog("Contender failed before proving: \(error)")
                self.clearContender(newConnection!, cancelSocket: false)
            case .cancelled:
                self.clearContender(newConnection!, cancelSocket: false)
            default:
                break
            }
        }
        newConnection.start(queue: networkQueue)

        let deadline = DispatchWorkItem { [weak self, weak newConnection] in
            guard let self = self, let newConnection = newConnection else { return }
            guard self.contender === newConnection else { return }
            debugLog("Contender silent \(Int(Self.contenderProofWindow * 1000))ms — rejecting (probe?), live stream untouched")
            self.clearContender(newConnection, cancelSocket: true)
        }
        contenderDeadline = deadline
        networkQueue.asyncAfter(deadline: .now() + Self.contenderProofWindow, execute: deadline)

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
        connectionReady = false
        isReceiving = false
        connection = nil
        inputBuffer.removeAll(keepingCapacity: true)
        onClientDisconnected?()
    }

    private func onConnectionReady(_ conn: NWConnection) {
        if conn.endpoint.isLoopback {
            debugLog("Client connected via loopback (USB) — skipping auth")
            beginExistingProtocol(on: conn)
            return
        }
        guard let expected = expectedAuthToken else {
            debugLog("Rejecting non-loopback client: wireless mode not active")
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
        // the legacy no-metadata path. 250ms covers that race; the type-8
        // handler below still short-circuits startup the moment adverts
        // arrive, so well-behaved clients pay no extra delay.
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            self.finishProtocolStartup(on: conn)
        }
    }

    private func finishProtocolStartup(on conn: NWConnection) {
        guard connection === conn, !isStopped, !connectionReady else { return }

        let codec: StreamCodec = clientIsAvcOnly ? .h264 : .hevc
        if clientIsAvcOnly {
            // Safe to send: this client opted in via type 9. Must precede the
            // display config so the client knows the codec before it sizes
            // and configures its decoder.
            let msg = Data([WireMessage.codecSelected, codec.wireId])
            conn.send(content: msg, completion: .contentProcessed { _ in })
            debugLog("Sent codecSelected: H.264")
        }
        // Synchronous, before sendDisplaySize(): the handler switches the
        // encoder AND updates displayWidth/Height (clamped for H.264) so the
        // display config below carries decoder-safe dimensions.
        onCodecNegotiated?(codec)

        debugLog("Client connected - sending display config first")
        sendDisplaySize()
        connectionReady = true
        debugLog("Connection ready for frames (metadata=\(clientSupportsFrameMetadata ? "on" : "off"), codec=\(codec))")
        onClientConnected?()
    }

    private func runAuthHandshake(connection conn: NWConnection, expectedToken: Data) {
        // Read fixed prefix [magic 4][token 32][name_len 1] = 37 bytes.
        conn.receive(minimumIncompleteLength: HandshakeCodec.fixedPrefixLen,
                     maximumLength: HandshakeCodec.fixedPrefixLen) { [weak self] prefixData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                debugLog("Auth read error: \(error)")
                conn.cancel()
                return
            }
            guard let prefix = prefixData, prefix.count == HandshakeCodec.fixedPrefixLen else {
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let prefixBytes = Array(prefix)
            guard Array(prefixBytes[0..<4]) == HandshakeCodec.requestMagic else {
                self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                return
            }
            let nameLen = Int(prefixBytes[36])
            guard (1...64).contains(nameLen) else {
                self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                return
            }
            // Read variable name.
            conn.receive(minimumIncompleteLength: nameLen, maximumLength: nameLen) { nameData, _, _, error in
                if let error = error {
                    debugLog("Auth name read error: \(error)")
                    conn.cancel()
                    return
                }
                guard let nameData = nameData, nameData.count == nameLen else {
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                    return
                }
                let full = prefix + nameData
                do {
                    let parsed = try HandshakeCodec.parseRequest(full)
                    if WirelessAuth.validate(parsed.token, expected: expectedToken) {
                        debugLog("Wireless auth OK — device: \(parsed.deviceName)")
                        self.sendAuthResponse(conn, status: .ok, thenClose: false)
                        self.onWirelessClientPaired?(parsed.deviceName)
                        self.beginExistingProtocol(on: conn)
                    } else {
                        debugLog("Wireless auth rejected: token mismatch")
                        self.sendAuthResponse(conn, status: .invalidToken, thenClose: true)
                    }
                } catch HandshakeError.invalidMagic {
                    self.sendAuthResponse(conn, status: .invalidMagic, thenClose: true)
                } catch HandshakeError.invalidName {
                    self.sendAuthResponse(conn, status: .invalidName, thenClose: true)
                } catch {
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

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        displayWidth = width
        displayHeight = height
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    func updateDisplayTransform(rotation: Int, flipHorizontal: Bool, flipVertical: Bool) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        sendDisplaySize()
    }

    func sendDisplaySize() {
        guard let connection = connection else { return }

        let transform = rotation + (flipHorizontal ? 1000 : 0) + (flipVertical ? 2000 : 0)
        var data = Data()
        data.append(WireMessage.displayConfig)
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(transform).bigEndian) { Data($0) })

        connection.send(content: data, completion: .contentProcessed { _ in })
        debugLog("Sent display config: \(displayWidth)x\(displayHeight) @ \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
    }

    private func startReceivingTouch() {
        guard !isReceiving else {
            debugLog("Already receiving touch events")
            return
        }
        isReceiving = true
        debugLog("Starting input receive loop... (touch=\(touchEnabled ? "on" : "off"))")

        // Use loop-based pattern instead of recursion to prevent stack overflow
        receiveQueue.async { [weak self] in
            self?.touchReceiveLoop()
        }
    }

    private func touchReceiveLoop() {
        guard let connection = connection, isReceiving, !isStopped else {
            isReceiving = false
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            // Identity guard: a stale completion from a replaced connection must
            // not kill the live connection's receive loop (isReceiving=false on
            // an old connection would starve the new client's input path).
            guard let self = self, self.isReceiving, !self.isStopped, self.connection === connection else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                self.inputBuffer.removeAll(keepingCapacity: true)
                return
            }

            if let data = data, !data.isEmpty {
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
                if !clientSupportsFrameMetadata {
                    clientSupportsFrameMetadata = true
                    debugLog("Client supports video frame metadata")
                }
                finishProtocolStartup(on: connection)

            case WireMessage.clientAvcOnly:
                // Payload-free opt-in (same convention as type 8): the client
                // has no HEVC decoder, stream H.264 instead. Clients send this
                // BEFORE type 8, so it lands before finishProtocolStartup runs.
                consumeInputBytes(1)
                if !clientIsAvcOnly {
                    clientIsAvcOnly = true
                    debugLog("Client is AVC-only — will negotiate H.264")
                }

            case WireMessage.clientDecoderLimits, WireMessage.clientDecoderLimitsLegacy:
                // Type + 4 payload bytes: [w-hi][w-lo][h-hi][h-lo], 7 data
                // bits each with the high bit always set (old hosts skip the
                // payload harmlessly). Sent BEFORE type 8, like type 9.
                // Legacy clients used 11 (now BRIGHT's value on the opposite
                // direction); accept both with a high-bit guard so a stale
                // server→client BRIGHT frame is never parsed as a limit.
                guard inputBuffer.count >= 5 else { return }

                let payload = (1...4).map { inputByte(at: $0) }
                consumeInputBytes(5)
                guard payload.allSatisfy({ $0 & 0x80 != 0 }) else {
                    debugLog("Malformed decoder-limits payload — ignoring")
                    continue
                }
                let w = (Int(payload[0] & 0x7F) << 7) | Int(payload[1] & 0x7F)
                let h = (Int(payload[2] & 0x7F) << 7) | Int(payload[3] & 0x7F)
                // Anything below QVGA-ish is a nonsense report — ignore it.
                if w >= 256 && h >= 256 {
                    clientDecodeLimits = (w, h)
                    debugLog("Client decoder limit: \(w)x\(h) (wire \(msgType))")
                }

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

        DispatchQueue.main.async {
            self.onTouchEvent?(x1, y1, Int(action), pointerCount, x2, y2)
        }
    }

    private func inputByte(at offset: Int) -> UInt8 {
        inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: offset)]
    }

    private func consumeInputBytes(_ count: Int) {
        let endIndex = inputBuffer.index(inputBuffer.startIndex, offsetBy: count)
        inputBuffer.removeSubrange(inputBuffer.startIndex..<endIndex)
    }

    func sendFrame(_ data: Data, timestamp: UInt64, isKeyframe: Bool = false) {
        guard let connection = connection, !isStopped, connectionReady else { return }

        // With short-GOP encoding, a fresh client must start on a keyframe —
        // sending P-frames before the first IDR would feed garbage to its decoder.
        if waitingForSyncFrame {
            guard isKeyframe else {
                droppedFrames += 1
                return
            }
            waitingForSyncFrame = false
            debugLog("First keyframe sent to new client")
        }

        // No frame-age dropping or backpressure — send everything immediately.
        // The encode queue depth limit (2 pending) in ScreenCapture handles flow control.
        frameQueue.async { [weak self] in
            guard let self = self else { return }

            let packet = self.makeFramePacket(data, timestamp: timestamp, isKeyframe: isKeyframe)

            connection.send(content: packet, completion: .contentProcessed { error in
                if error != nil {
                    self.droppedFrames += 1
                }
            })

            // Track frame age at send time for pipeline profiling
            let sendAge = DispatchTime.now().uptimeNanoseconds - timestamp
            self.updateStats(bytes: data.count, frameAgeNs: sendAge)
        }
    }

    private func makeFramePacket(_ data: Data, timestamp: UInt64, isKeyframe: Bool) -> Data {
        if clientSupportsFrameMetadata {
            var packet = Data(capacity: data.count + 14)
            packet.append(WireMessage.videoFrameWithMetadata)
            appendFrameSize(data.count, to: &packet)
            packet.append(isKeyframe ? 1 : 0)
            var captureTimestamp = timestamp.bigEndian
            withUnsafeBytes(of: &captureTimestamp) { packet.append(contentsOf: $0) }
            packet.append(data)
            return packet
        }

        // Keep legacy frame type 0 for clients that do not advertise
        // metadata support; remove after legacy clients age out.
        var packet = Data(capacity: data.count + 5)
        packet.append(WireMessage.legacyVideoFrame)
        appendFrameSize(data.count, to: &packet)
        packet.append(data)
        return packet
    }

    private func appendFrameSize(_ size: Int, to packet: inout Data) {
        var frameSize = Int32(size).bigEndian
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
                debugLog("Pipeline: \(String(format: "%.1f", fps))fps, \(String(format: "%.1f", mbps))Mbps, avg frame age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(droppedFrames)")
            }

            bytesSent = 0
            frameCount = 0
            droppedFrames = 0
            totalFrameAgeNs = 0
            profiledFrameCount = 0
            lastStatsTime = now
        }
    }

    func stop() {
        isStopped = true
        isReceiving = false

        // Wait for pending operations before cancelling
        frameQueue.sync {}
        receiveQueue.sync {}
        controlQueue.sync {}

        connection?.cancel()
        listener?.cancel()
        controlConnection?.cancel()
        controlListener?.cancel()
        if let c = contender { clearContender(c, cancelSocket: true) }
        connection = nil
        listener = nil
        controlConnection = nil
        controlListener = nil
    }
}
