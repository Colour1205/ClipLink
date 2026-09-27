import CryptoKit
import Foundation
import Network

/// What a handshake needs to know about this device, sampled once when the
/// handshake starts (every other platform samples pairing mode the same way).
struct HandshakeContext {
    let identity: IdentitySigner
    /// Trusted device IDs at the moment the handshake began.
    let trusted: Set<String>
    let passphraseKey: Data?
    /// "My pairing screen is open right now": lets an untrusted peer finish
    /// the handshake so the user can accept or reject it.
    let pairingOpen: Bool
}

enum HandshakeFailure: Error, CustomStringConvertible {
    /// TCP never connected (refused, timed out, host down, no route).
    case unreachable(String)
    /// iOS blocked the connection: Local Network access is off for this app.
    case localNetworkDenied
    /// Connected, but no handshake line arrived in time.
    case silent
    /// The peer hung up before sending its handshake line.
    case closedEarly
    case malformed
    /// We refused them: untrusted, no matching passcode, pairing closed.
    case refused(peerId: String)
    /// Outbound only: we read their line and chose not to continue - they
    /// never saw our handshake, so nothing was registered on their side.
    case notWanted(HandshakeMessage)
    case badSignature
    case selfConnection

    var description: String {
        switch self {
        case .unreachable(let why): return "unreachable (\(why))"
        case .localNetworkDenied: return "local network access denied"
        case .silent: return "no handshake received"
        case .closedEarly: return "closed before handshake"
        case .malformed: return "malformed handshake"
        case .refused(let id): return "refused untrusted \(id.prefix(12))…"
        case .notWanted(let theirs): return "not wanted: \(theirs.identityPublicKey.prefix(12))…"
        case .badSignature: return "bad handshake signature"
        case .selfConnection: return "connected to itself"
        }
    }
}

/// One authenticated, encrypted link to a peer. Mirrors PeerConnection.cs /
/// .kt / .ets on the wire:
///
/// - newline-delimited UTF-8 for the connection's whole life;
/// - one plaintext JSON handshake line per side, then every line is
///   base64(nonce || tag || AES-256-GCM ciphertext) under SHA256(ECDH);
/// - an encrypted `__ping__` every 3 s, and the link is declared dead after
///   9 s with no bytes at all from the peer.
///
/// One deliberate difference, invisible to peers: when THIS device dials, it
/// reads the peer's handshake line before writing its own. Every acceptor on
/// every platform writes first, so this never deadlocks - and it lets us
/// check who answered (and their passcode proof) before they learn who we
/// are, so a dial we'd reject never registers anything on the far side.
final class PeerLink {
    enum Direction { case outbound, inbound }

    enum Phase { case handshaking, holding, live, closed }

    let direction: Direction
    let remoteAddress: String?
    private(set) var peerDeviceId = ""
    /// False: only here because our pairing screen was open - must be
    /// accepted by the user before it is registered.
    private(set) var wasAlreadyTrusted = false
    /// True when THIS handshake's passcode proof is what established trust.
    private(set) var newlyTrustedViaPassphrase = false
    private(set) var connectedAt = Date()
    /// Whether any session line (a ping counts) has arrived yet - used to spot
    /// a peer that completes the handshake and then immediately hangs up,
    /// which is how a peer that doesn't trust us refuses.
    var hasReceivedSessionLine: Bool { sync { receivedSessionLine } }
    var isClosed: Bool { sync { phase == .closed } }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private var framer: LineFramer
    private var phase: Phase = .handshaking
    private var cipher: SessionCipher?
    private var pendingLines: [Data] = []
    private var lineWaiter: ((Data?) -> Void)?
    private var heldMessages: [String] = []
    private var lastActivity = Date()
    private var receivedSessionLine = false
    private var lastSessionLineAt = Date()
    private var reportedDrops = 0
    private var heartbeat: DispatchSourceTimer?
    private var handshakeTimer: DispatchSourceTimer?
    private var peerClosed = false
    /// Extra grace before the dead-peer rule applies to a freshly accepted
    /// pairing link: the user on the other side may still be deciding, and
    /// until they accept they send nothing at all.
    private var silenceGraceUntil: Date?

    static let heartbeatInterval: TimeInterval = 3
    static let deadAfter: TimeInterval = 9
    /// Raw bytes keep a link alive (a huge line can take a while), but a link
    /// that hasn't produced one decryptable line in this long is a zombie -
    /// e.g. a replayed handshake trickling junk to look alive.
    static let sessionLineDeadAfter: TimeInterval = 120
    static let handshakeTimeout: TimeInterval = 10

    /// Called on the delivery queue, in arrival order.
    var onMessage: ((PeerLink, String) -> Void)?
    /// Called once, on the delivery queue.
    var onClosed: ((PeerLink) -> Void)?
    /// Called once, on the delivery queue, when the first session line (a
    /// ping counts) decrypts: proof the peer really holds the session key.
    var onFirstSessionLine: ((PeerLink) -> Void)?
    /// Called on the delivery queue when a line over the size cap was skipped.
    var onOversizedLine: ((PeerLink) -> Void)?

    private init(connection: NWConnection, direction: Direction, remoteAddress: String?, maxLineBytes: Int, deliveryQueue: DispatchQueue) {
        self.connection = connection
        self.direction = direction
        self.remoteAddress = remoteAddress
        self.deliveryQueue = deliveryQueue
        self.framer = LineFramer(maxLineBytes: maxLineBytes)
        self.queue = DispatchQueue(label: "cliplink.link", qos: .userInitiated)
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) { return body() }
        return queue.sync(execute: body)
    }

    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    static func tcpParameters(connectTimeout: Int) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Mirrors the Windows daemon's EnableKeepAlive(20s idle, 10s, 5 probes):
        // keeps NAT/Tailscale mappings alive between clipboard changes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 5
        tcp.connectionTimeout = connectTimeout
        let params = NWParameters(tls: nil, tcp: tcp)
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4 // every peer listens on IPv4 only
        }
        return params
    }

    // MARK: - Establishing

    /// Dials `host:port` and runs the handshake as the dialer. `gate` sees the
    /// peer's handshake before ours is written; returning false closes the
    /// socket with nothing sent.
    static func dial(
        host: String,
        port: UInt16,
        context: HandshakeContext,
        connectTimeout: Int,
        maxLineBytes: Int,
        deliveryQueue: DispatchQueue,
        gate: @escaping (HandshakeMessage) -> Bool,
        completion: @escaping (Result<PeerLink, HandshakeFailure>) -> Void
    ) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            deliveryQueue.async { completion(.failure(.unreachable("bad port"))) }
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: tcpParameters(connectTimeout: connectTimeout))
        let link = PeerLink(connection: connection, direction: .outbound, remoteAddress: host, maxLineBytes: maxLineBytes, deliveryQueue: deliveryQueue)
        link.begin(context: context, gate: gate, connectDeadline: TimeInterval(connectTimeout) + 1, completion: completion)
    }

    /// Runs the handshake as the acceptor on a connection from our listener.
    static func accept(
        connection: NWConnection,
        context: HandshakeContext,
        maxLineBytes: Int,
        deliveryQueue: DispatchQueue,
        completion: @escaping (Result<PeerLink, HandshakeFailure>) -> Void
    ) {
        var remote: String?
        if case let .hostPort(host, _) = connection.endpoint {
            remote = NetworkInterfaces.normalize("\(host)")
        }
        let link = PeerLink(connection: connection, direction: .inbound, remoteAddress: remote, maxLineBytes: maxLineBytes, deliveryQueue: deliveryQueue)
        link.begin(context: context, gate: nil, connectDeadline: 5, completion: completion)
    }

    private func begin(
        context: HandshakeContext,
        gate: ((HandshakeMessage) -> Bool)?,
        connectDeadline: TimeInterval,
        completion: @escaping (Result<PeerLink, HandshakeFailure>) -> Void
    ) {
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
        var finished = false
        let finish: (Result<PeerLink, HandshakeFailure>) -> Void = { [self] result in
            guard !finished else { return }
            finished = true
            handshakeTimer?.cancel()
            handshakeTimer = nil
            if case .failure = result { teardown() }
            deliveryQueue.async { completion(result) }
        }

        // Backstop for the connect phase: .waiting can otherwise last forever.
        armHandshakeTimer(after: connectDeadline) { [self] in
            if connection.state != .ready { finish(.failure(.unreachable("connect timed out"))) }
        }

        var started = false
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !started else { return }
                started = true
                receiveLoop()
                runHandshake(context: context, gate: gate, finish: finish)
            case .waiting(let error):
                // Refused, unreachable, or blocked by policy. NWConnection would
                // keep retrying; a dial here should fail fast instead.
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    finish(.failure(.localNetworkDenied))
                } else if !started {
                    finish(.failure(.unreachable("\(error)")))
                }
            case .failed(let error):
                if !started { finish(.failure(.unreachable("\(error)"))) } else { markPeerClosed() }
            case .cancelled:
                if !started { finish(.failure(.unreachable("cancelled"))) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func armHandshakeTimer(after seconds: TimeInterval, _ handler: @escaping () -> Void) {
        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: handler)
        timer.resume()
        handshakeTimer = timer
    }

    private func runHandshake(context: HandshakeContext, gate: ((HandshakeMessage) -> Bool)?, finish: @escaping (Result<PeerLink, HandshakeFailure>) -> Void) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralSPKI = ephemeral.publicKey.derRepresentation
        let ownId = context.identity.publicKeyBase64
        let mine: HandshakeMessage
        do {
            let signature = try context.identity.sign(ephemeralSPKI)
            mine = HandshakeMessage(
                ephemeralPublicKey: ephemeralSPKI.base64EncodedString(),
                identityPublicKey: ownId,
                signature: signature.base64EncodedString(),
                passphraseProof: context.passphraseKey.map { PassphraseAuth.proof(key: $0, deviceId: ownId) }
            )
        } catch {
            finish(.failure(.unreachable("signing failed: \(error)")))
            return
        }
        let writeMine = { [self] in writeRaw(mine.jsonString() + "\n") }

        if direction == .inbound { writeMine() }

        armHandshakeTimer(after: Self.handshakeTimeout) { finish(.failure(.silent)) }
        awaitLine { [self] line in
            guard let line else {
                finish(.failure(peerClosed ? .closedEarly : .silent))
                return
            }
            guard let theirs = HandshakeMessage.parse(String(decoding: line, as: UTF8.self)) else {
                finish(.failure(.malformed))
                return
            }
            if theirs.identityPublicKey == ownId {
                finish(.failure(.selfConnection))
                return
            }
            if let gate, !gate(theirs) {
                finish(.failure(.notWanted(theirs)))
                return
            }

            let alreadyTrusted = context.trusted.contains(theirs.identityPublicKey)
            let passphraseVerified = !alreadyTrusted && context.passphraseKey.map {
                PassphraseAuth.verifyProof(key: $0, deviceId: theirs.identityPublicKey, proofBase64: theirs.passphraseProof)
            } == true
            let effectivelyTrusted = alreadyTrusted || passphraseVerified
            guard effectivelyTrusted || context.pairingOpen else {
                finish(.failure(.refused(peerId: theirs.identityPublicKey)))
                return
            }

            guard let theirEphemeral = Data(base64Encoded: theirs.ephemeralPublicKey),
                  WireSignature.verify(publicKeyBase64: theirs.identityPublicKey, data: theirEphemeral, signatureBase64: theirs.signature),
                  let key = try? HandshakeCrypto.sessionKey(myEphemeral: ephemeral, theirEphemeralSPKI: theirEphemeral)
            else {
                finish(.failure(.badSignature))
                return
            }

            if direction == .outbound { writeMine() }

            peerDeviceId = theirs.identityPublicKey
            wasAlreadyTrusted = effectivelyTrusted
            newlyTrustedViaPassphrase = passphraseVerified
            cipher = SessionCipher(key: key)
            connectedAt = Date()
            lastActivity = Date()
            phase = .holding
            // Lines that arrived glued to the handshake line are session lines.
            let early = pendingLines
            pendingLines.removeAll()
            early.forEach(handleSessionLine)
            finish(.success(self))
        }
    }

    // MARK: - Reading

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                do {
                    for line in try self.framer.append(data) {
                        self.handleIncomingLine(line)
                    }
                } catch {
                    // Only possible before the handshake line: a stranger
                    // streaming junk.
                    self.teardown()
                    return
                }
                if self.framer.droppedLines > self.reportedDrops {
                    self.reportedDrops = self.framer.droppedLines
                    self.deliveryQueue.async { [self] in self.onOversizedLine?(self) }
                }
            }
            if isComplete || error != nil {
                self.markPeerClosed()
                return
            }
            if self.phase != .closed { self.receiveLoop() }
        }
    }

    private func handleIncomingLine(_ line: Data) {
        switch phase {
        case .handshaking:
            if let waiter = lineWaiter {
                lineWaiter = nil
                waiter(line)
            } else {
                pendingLines.append(line)
            }
        case .holding, .live:
            handleSessionLine(line)
        case .closed:
            break
        }
    }

    private func handleSessionLine(_ line: Data) {
        guard let cipher else { return }
        let text: String
        do {
            text = try cipher.open(line)
        } catch {
            // A corrupt or forged line ends the connection, as on every platform.
            teardown()
            return
        }
        lastSessionLineAt = Date()
        if !receivedSessionLine {
            receivedSessionLine = true
            deliveryQueue.async { [self] in onFirstSessionLine?(self) }
        }
        if text == Wire.pingSentinel { return }
        if phase == .holding {
            heldMessages.append(text)
        } else {
            deliver(text)
        }
    }

    private func deliver(_ text: String) {
        deliveryQueue.async { [self] in onMessage?(self, text) }
    }

    private func awaitLine(_ waiter: @escaping (Data?) -> Void) {
        if !pendingLines.isEmpty {
            waiter(pendingLines.removeFirst())
        } else if peerClosed {
            waiter(nil)
        } else {
            lineWaiter = waiter
        }
    }

    private func markPeerClosed() {
        peerClosed = true
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter(nil)
        }
        if phase == .holding || phase == .live { teardown() }
    }

    // MARK: - Session

    /// Starts delivering messages and heartbeating. Messages that arrived
    /// while the link was held (awaiting a pairing decision) are delivered
    /// first, in order. `extendedGrace` postpones the dead-peer rule until the
    /// peer sends its first line (capped), for links the user just accepted.
    func goLive(extendedGrace: TimeInterval? = nil) {
        queue.async { [self] in
            guard phase == .holding else { return }
            phase = .live
            if let extendedGrace, !receivedSessionLine { silenceGraceUntil = Date().addingTimeInterval(extendedGrace) }
            lastActivity = Date()
            lastSessionLineAt = Date()
            let held = heldMessages
            heldMessages.removeAll()
            held.forEach(deliver)
            startHeartbeat()
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.phase == .live else { return }
            self.sendNow(Wire.pingSentinel, completion: nil)
            if let grace = self.silenceGraceUntil {
                if self.receivedSessionLine || Date() > grace { self.silenceGraceUntil = nil } else { return }
            }
            if Date().timeIntervalSince(self.lastSessionLineAt) > Self.sessionLineDeadAfter {
                self.teardown()
                return
            }
            if Date().timeIntervalSince(self.lastActivity) > Self.deadAfter {
                // Nothing at all from the peer for the timeout window: it is gone
                // even though TCP hasn't noticed.
                self.teardown()
            }
        }
        timer.resume()
        heartbeat = timer
    }

    /// Encrypts and queues one line. `completion(true)` once the bytes were
    /// handed to the network stack - used for backpressure on file streams.
    func send(_ plaintext: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in sendNow(plaintext, completion: completion) }
    }

    private func sendNow(_ plaintext: String, completion: ((Bool) -> Void)?) {
        // Never while held: a pairing candidate must receive nothing until the
        // user accepts - HarmonyOS reads any byte as "the other side accepted".
        guard phase == .live, let cipher, let sealed = try? cipher.seal(plaintext) else {
            completion?(false)
            return
        }
        var data = Data(sealed.utf8)
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error == nil)
        })
    }

    func sendAndWait(_ plaintext: String) async -> Bool {
        await withCheckedContinuation { continuation in
            send(plaintext) { continuation.resume(returning: $0) }
        }
    }

    private func writeRaw(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    /// Closes the link (a graceful FIN). Idempotent; `onClosed` fires once.
    func close() {
        queue.async { [self] in teardown() }
    }

    private func teardown() {
        guard phase != .closed else { return }
        let wasEstablished = phase == .holding || phase == .live
        phase = .closed
        heartbeat?.cancel()
        heartbeat = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter(nil)
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        if wasEstablished {
            deliveryQueue.async { [self] in onClosed?(self) }
        }
    }
}
