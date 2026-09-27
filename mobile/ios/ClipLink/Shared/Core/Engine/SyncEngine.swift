import CryptoKit
import Foundation
import Network

/// Keychain-style storage for the few secrets the engine keeps (the passcode
/// key). The app backs it with the Keychain; tests use `MemorySecretStore`.
public protocol SecretStore: AnyObject {
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

public final class MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func data(for key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ data: Data?, for key: String) { lock.lock(); values[key] = data; lock.unlock() }
}

/// Everything the engine reports back. Always called on the main queue.
public protocol SyncEngineDelegate: AnyObject {
    func syncEngine(_ engine: SyncEngine, didUpdate snapshot: EngineSnapshot)
    /// A genuinely new item from a peer that belongs on this device's
    /// clipboard (subject to the user's auto-apply setting). File entries are
    /// delivered only once their bytes are here, with `fileURL` pointing at them.
    func syncEngine(_ engine: SyncEngine, didReceive entry: ClipboardEntry, fileURL: URL?)
    /// A short user-facing message (a toast).
    func syncEngine(_ engine: SyncEngine, notice: String)
}

public struct EngineConfig {
    public var storageDirectory: URL
    /// Our TCP listener. 49000 on every platform.
    public var listenPort: UInt16 = Wire.port
    /// Our UDP beacon socket.
    public var discoveryPort: UInt16 = Wire.port
    /// Where peers listen: destination for unicast beacons and for dials to
    /// stored or typed addresses (a beacon carries its own TCP port).
    public var peerPort: UInt16 = Wire.port
    public var peerDiscoveryPort: UInt16 = Wire.port
    /// Try 255.255.255.255 beacons. Works only with Apple's multicast
    /// entitlement; without it the engine notices and stops trying.
    public var enableBroadcast = true
    /// Unicast beacon + TCP identity sweeps of the Wi-Fi /24, the fallback
    /// that makes discovery work without broadcast.
    public var enableSweeps = true
    /// Extra unicast beacon targets (tests use 127.0.0.1).
    public var extraBeaconTargets: [String] = []
    public var maxLineBytes = 192 * 1024 * 1024
    /// For short-lived senders (the Share extension): ignore incoming history
    /// batches and file bytes - they would only cost memory the extension
    /// doesn't have - while still sending, streaming our own files, and
    /// answering file requests. Use a small `maxLineBytes` with it; oversized
    /// lines are skipped without being buffered.
    public var sendOnly = false
    /// Mirrors every log line (e.g. to os.Logger).
    public var logSink: ((String) -> Void)?

    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }
}

/// The ClipLink node: discovery, the listener, peer links, history, file
/// transfer and pairing. The iOS counterpart of ClipLinkEngine.kt +
/// SyncManager.kt and of Program.cs' daemon loop.
///
/// All mutable state is confined to `queue`. Public methods may be called
/// from any thread; they hop onto the queue.
public final class SyncEngine {
    public let config: EngineConfig
    public weak var delegate: SyncEngineDelegate?
    public let ownId: String

    let queue = DispatchQueue(label: "cliplink.engine", qos: .userInitiated)
    let identity: IdentitySigner
    let secrets: SecretStore
    let trust: TrustStore
    public let files: FileStore
    let history: HistoryStore
    let settingsFile: JSONFile

    // Networking
    var running = false
    var udp: UDPSocket?
    var server: TCPServer?
    var serverRetries = 0
    var tickTimer: DispatchSourceTimer?
    var reconnectTimer: DispatchSourceTimer?
    var pathMonitor: NWPathMonitor?
    var lastPathKey = ""
    var links: [String: PeerLink] = [:]
    var connectingTo: Set<String> = []
    var inboundFrom: [String: Int] = [:]
    var sightings: [String: Sighting] = [:]
    /// Trusted peers that are supposed to dial US (their id is the larger
    /// one, see DeviceOrder), and since when we've been waiting.
    var awaitingInbound: [String: Date] = [:]
    var nextOverrideDial: [String: Date] = [:]
    var backoff: [String: Backoff] = [:]
    /// When a stranger's handshake was last refused here (see beaconTargets).
    var refusedAt: [String: Date] = [:]
    var status = NetworkStatus()
    var lastUDPSweep = Date.distantPast
    var lastTCPSweep = Date.distantPast
    var tcpSweepInFlight = false
    var wantsTCPSweep = false
    var broadcastRetryAt = Date.distantPast
    var foregroundAt = Date()

    // Pairing & trust
    var pairingOpen = false
    var pairingTargetKey: String?
    var pending: PendingPairing?
    var passphraseKey: Data?
    var cachedProof: String?
    var tailscaleIP = ""
    var nicknames: [String: String] = [:]

    // Sync & files
    var incoming: [String: IncomingTransfer] = [:]
    var pendingFiles: [String: PendingFile] = [:]
    var streaming: Set<String> = []
    var requestedAt: [String: Date] = [:]
    /// Hashes whose completed download is being hash-checked right now.
    var verifying: Set<String> = []

    /// Bumped by every foreground/background transition: a teardown still
    /// waiting out its grace period checks it and stands down if the app came
    /// back in the meantime.
    var lifecycleGeneration = 0

    // Background refresh
    var backgroundSession: UUID?
    var backgroundReceived: [ClipboardEntry] = []

    // UI
    var logLines: [LogLine] = []
    var publishScheduled = false
    var sweeping = false

    static let passphraseSecretKey = "passphrase_key"

    public init(config: EngineConfig, identity: IdentitySigner, secrets: SecretStore) {
        self.config = config
        self.identity = identity
        self.secrets = secrets
        self.ownId = identity.publicKeyBase64
        try? FileManager.default.createDirectory(at: config.storageDirectory, withIntermediateDirectories: true)
        trust = TrustStore(directory: config.storageDirectory)
        files = FileStore(directory: config.storageDirectory)
        history = HistoryStore(directory: config.storageDirectory, fileStore: files)
        settingsFile = JSONFile(url: config.storageDirectory.appendingPathComponent("engine_settings.json"))
        let settings = settingsFile.read() as? [String: Any] ?? [:]
        tailscaleIP = settings["tailscale_ip"] as? String ?? ""
        nicknames = settings["nicknames"] as? [String: String] ?? [:]
        passphraseKey = secrets.data(for: Self.passphraseSecretKey)
        cachedProof = passphraseKey.map { PassphraseAuth.proof(key: $0, deviceId: ownId) }
        observeExternalChanges()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Cross-process handoff
    //
    // The app and its Share extension share storage and identity. When the
    // app's node is already up (e.g. side by side on iPad), the extension
    // must not start a second node with the same device ID: it records the
    // item in the shared history and pings the app, whose live node sends it.

    static let externalChangeNotification = "io.uaena.ClipLink.historyChanged"
    static let liveMarkerName = "node.alive"

    /// True when another process's node refreshed its marker in the last few
    /// seconds (it does so every beacon tick while fully up).
    public static func anotherNodeIsLive(in directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(liveMarkerName), encoding: .utf8) else { return false }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let pid = Int32(parts[0]), let stamp = Double(parts[1]) else { return false }
        return pid != getpid() && Date().timeIntervalSince1970 - stamp < 6
    }

    /// Tells a live node in another process that history changed on disk.
    public static func announceExternalChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(externalChangeNotification as CFString), nil, nil, true)
    }

    func touchLiveMarker() {
        let text = "\(getpid()) \(Date().timeIntervalSince1970)"
        try? text.write(to: config.storageDirectory.appendingPathComponent(Self.liveMarkerName), atomically: true, encoding: .utf8)
    }

    func clearLiveMarker() {
        let url = config.storageDirectory.appendingPathComponent(Self.liveMarkerName)
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("\(getpid()) ") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func observeExternalChanges() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<SyncEngine>.fromOpaque(observer).takeUnretainedValue().externalChange()
        }, Self.externalChangeNotification as CFString, nil, .deliverImmediately)
    }

    /// Another process added items (the Share extension, while this node is
    /// live): pick them up and send our own new ones to everyone connected.
    func externalChange() {
        queue.async { [self] in
            guard running, tickTimer != nil else { return }
            let known = Set(history.entries.map(HistoryStore.identity(of:)))
            reloadFromDisk()
            let added = history.entries.filter { !known.contains(HistoryStore.identity(of: $0)) }
            for entry in added.sorted(by: { DotNetTimestamp.isEarlier($0.timestamp, than: $1.timestamp) }) where entry.deviceId == ownId {
                let json = Envelope(type: Wire.MessageType.entry, payload: entry.jsonString()).jsonString()
                for link in links.values { link.send(json) }
                if entry.type == Wire.EntryType.file, let payload = FilePayload.parse(entry.content), files.exists(payload.fileHash) {
                    for link in links.values { streamFile(hash: payload.fileHash, to: link) }
                }
                log("sent \(entry.type) shared from another app to \(links.count) peer(s)")
            }
        }
    }

    // MARK: - Lifecycle

    /// Brings the node up (idempotent) and kicks an immediate discovery round:
    /// beacons, a stored-address reconnect pass and, when needed, sweeps. Call
    /// whenever the app becomes active.
    public func enterForeground() {
        queue.async { [self] in
            // The user opened the app mid background-refresh: keep everything
            // up and let the refresh round end without tearing down.
            backgroundSession = nil
            // Supersedes any background teardown still in its grace period.
            lifecycleGeneration += 1
            if !running {
                reloadFromDisk()
                startNetworking()
            } else if tickTimer == nil || reconnectTimer == nil {
                // Came back during the grace period: sockets and timers were
                // already stopped, the links are still up.
                reloadFromDisk()
                startTimers()
            }
            foregroundAt = Date()
            kick(reason: "foreground")
            schedulePublish()
        }
    }

    /// Tears the node down for suspension: iOS defuncts a suspended app's
    /// sockets, and closing them now lets peers drop us at once instead of
    /// waiting out their heartbeat. In-flight file transfers get up to
    /// `grace` seconds first (the app holds a background task meanwhile).
    public func enterBackground(grace: TimeInterval = 25, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            lifecycleGeneration += 1
            let generation = lifecycleGeneration
            stopNetworking()
            rejectPendingLocked()
            waitForTransfers(deadline: Date().addingTimeInterval(grace), generation: generation) { [self] superseded in
                if !superseded {
                    // Sockets may have been reopened meanwhile (path change,
                    // listener retry): close everything again, for good.
                    stopNetworking()
                    shutdownLinks()
                    running = false
                    status.running = false
                    schedulePublish()
                }
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// One bounded sync round while the app is in the background (driven by a
    /// BGAppRefreshTask / BGProcessingTask): bring the node up, reach trusted
    /// peers (beacons, reconnects, sweeps), let their history batches and any
    /// pending file transfers land, then tear everything down again. The other
    /// mobile ports can't do this at all - HarmonyOS and Android only sync
    /// while open (or under a foreground service).
    ///
    /// Completion (main queue) gets the peer items that arrived, newest first.
    public func runBackgroundSync(budget: TimeInterval, completion: @escaping ([ClipboardEntry]) -> Void) {
        queue.async { [self] in
            guard !running || backgroundSession != nil else {
                // Already up because the app is in the foreground: nothing to do.
                DispatchQueue.main.async { completion([]) }
                return
            }
            let session = UUID()
            backgroundSession = session
            backgroundReceived = []
            if !running {
                reloadFromDisk()
                startNetworking()
            }
            foregroundAt = Date()
            log("background refresh started")
            kick(reason: "background")
            let started = Date()
            let deadline = started.addingTimeInterval(max(5, budget))

            func finish(tearDown: Bool) {
                let received = backgroundReceived.sorted { DotNetTimestamp.isEarlier($1.timestamp, than: $0.timestamp) }
                backgroundReceived = []
                if tearDown {
                    backgroundSession = nil
                    stopNetworking()
                    rejectPendingLocked()
                    shutdownLinks()
                    running = false
                    status.running = false
                    log("background refresh finished: \(received.count) new item(s)")
                }
                schedulePublish()
                DispatchQueue.main.async { completion(received) }
            }

            func poll() {
                guard backgroundSession == session else {
                    // Foregrounded (keep running) or torn down by the expiration
                    // handler (already stopped).
                    return finish(tearDown: false)
                }
                guard running else { return finish(tearDown: false) }
                let now = Date()
                let elapsed = now.timeIntervalSince(started)
                let busy = !connectingTo.isEmpty || !incoming.isEmpty || !streaming.isEmpty || tcpSweepInFlight
                let everyoneHere = trust.all.allSatisfy { links[$0.publicKey] != nil || $0.publicKey == ownId }
                let settled = elapsed >= 6 && !busy && pendingFiles.isEmpty && (everyoneHere || elapsed >= 14)
                if now >= deadline || settled { return finish(tearDown: true) }
                queue.asyncAfter(deadline: .now() + 0.5) { poll() }
            }
            queue.asyncAfter(deadline: .now() + 1) { poll() }
        }
    }

    public func shutdown() {
        queue.async { [self] in
            lifecycleGeneration += 1
            stopNetworking()
            pathMonitor?.cancel()
            pathMonitor = nil
            rejectPendingLocked()
            shutdownLinks()
            running = false
            status = NetworkStatus()
            schedulePublish()
        }
    }

    /// Fresh sweeps and a reconnect pass now (pull-to-refresh).
    public func refreshNetwork() {
        queue.async { [self] in
            guard running, tickTimer != nil else { return }
            lastUDPSweep = .distantPast
            udpSweep(force: true)
            reconnectPass()
            tcpSweep(force: true, reason: "refresh")
        }
    }

    /// Another process (the Share extension) shares this storage and may have
    /// added history, trust or a passcode while this one was suspended.
    func reloadFromDisk() {
        trust.reload()
        history.reload()
        let settings = settingsFile.read() as? [String: Any] ?? [:]
        tailscaleIP = settings["tailscale_ip"] as? String ?? tailscaleIP
        nicknames = settings["nicknames"] as? [String: String] ?? nicknames
        passphraseKey = secrets.data(for: Self.passphraseSecretKey)
        cachedProof = passphraseKey.map { PassphraseAuth.proof(key: $0, deviceId: ownId) }
        schedulePublish()
    }

    /// Quiesces the engine for a short-lived process (the Share extension):
    /// everything stops once in-flight file streams finish or `grace` passes.
    public func finish(grace: TimeInterval, completion: @escaping () -> Void) {
        enterBackground(grace: grace, completion: completion)
    }

    /// Snapshot on demand, delivered on the main queue.
    public func currentSnapshot(_ completion: @escaping (EngineSnapshot) -> Void) {
        queue.async { [self] in
            let snapshot = buildSnapshot()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Polls until transfers finish or the deadline passes; `then(true)` as
    /// soon as a newer lifecycle transition supersedes this wait.
    private func waitForTransfers(deadline: Date, generation: Int, then: @escaping (Bool) -> Void) {
        if generation != lifecycleGeneration {
            then(true)
            return
        }
        if (streaming.isEmpty && incoming.isEmpty) || Date() >= deadline {
            then(false)
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in waitForTransfers(deadline: deadline, generation: generation, then: then) }
    }

    private func shutdownLinks() {
        for link in links.values { link.close() }
        links.removeAll()
        connectingTo.removeAll()
        inboundFrom.removeAll()
        awaitingInbound.removeAll()
        for transfer in incoming.values { transfer.abort() }
        incoming.removeAll()
    }

    /// Timers, UDP and the listener - everything except live links.
    func stopNetworking() {
        clearLiveMarker()
        stopTimers()
        udp?.close()
        udp = nil
        server?.stop()
        server = nil
        status.listening = false
    }

    func stopTimers() {
        tickTimer?.cancel()
        tickTimer = nil
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Pairing & trust API

    /// True exactly while the pairing screen is visible. Opening it advertises
    /// pairing in our beacon and lets untrusted peers finish a handshake;
    /// closing it rejects any request still waiting.
    public func setPairingOpen(_ open: Bool) {
        queue.async { [self] in
            guard pairingOpen != open else { return }
            pairingOpen = open
            if open {
                // beaconTick itself sweeps while pairing is open: one copy of
                // the pairing beacon per host, not two.
                lastUDPSweep = .distantPast
                beaconTick()
                tcpSweep(force: true, reason: "pairing")
            } else {
                pairingTargetKey = nil
                rejectPendingLocked()
            }
            schedulePublish()
        }
    }

    public func acceptPairing() {
        queue.async { [self] in
            guard let request = pending else { return }
            pending = nil
            if request.link.isClosed {
                notice("The other device cancelled the pairing request - try again.")
                schedulePublish()
                return
            }
            let id = request.link.peerDeviceId
            trust.trust(id, address: request.address)
            log("paired: \(DeviceLabel.short(id))")
            register(request.link, acceptedByUser: true)
            notice("Paired.")
            schedulePublish()
        }
    }

    public func rejectPairing() {
        queue.async { [self] in
            rejectPendingLocked()
            schedulePublish()
        }
    }

    func rejectPendingLocked() {
        pending?.link.close()
        pending = nil
    }

    /// Dials a scanned QR payload or a typed address/pairing text. Never writes
    /// trust by itself: the handshake and the accept prompts on both devices
    /// decide. Completion runs on the main queue.
    public func pair(with raw: String, completion: @escaping (PairOutcome) -> Void) {
        queue.async { [self] in
            pairLocked(raw) { outcome in DispatchQueue.main.async { completion(outcome) } }
        }
    }

    /// The Devices tab's "Trust" on a discovered device: trusts it here and
    /// dials it, ignoring the tie-breaker (like Android/HarmonyOS). The other
    /// side still decides for itself.
    public func trustDevice(_ deviceId: String) {
        queue.async { [self] in
            let address = addressCandidates(for: deviceId).first
            trust.trust(deviceId, address: address)
            log("trusted \(DeviceLabel.short(deviceId))")
            schedulePublish()
            if let address, links[deviceId] == nil {
                dial(deviceId: deviceId, candidates: [address], ignoreTieBreaker: true) { _ in }
            }
        }
    }

    /// Untrusts and - unlike Android/HarmonyOS, like Windows - closes any live
    /// link, so nothing more flows either way.
    public func untrustDevice(_ deviceId: String) {
        queue.async { [self] in
            trust.untrust(deviceId)
            if let link = links.removeValue(forKey: deviceId) { link.close() }
            backoff[deviceId] = nil
            awaitingInbound[deviceId] = nil
            log("untrusted \(DeviceLabel.short(deviceId))")
            notice("Removed \(displayName(for: deviceId)).")
            schedulePublish()
        }
    }

    public func setNickname(_ name: String, for deviceId: String) {
        queue.async { [self] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            nicknames[deviceId] = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
            saveSettings()
            schedulePublish()
        }
    }

    /// Derives the passcode key (PBKDF2, 210,000 rounds - off the engine queue)
    /// and starts advertising the proof. Completion on the main queue.
    public func setPassphrase(_ passphrase: String, completion: @escaping (Bool) -> Void) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let key = PassphraseAuth.deriveKey(passphrase: trimmed)
            queue.async { [self] in
                passphraseKey = key
                secrets.set(key, for: Self.passphraseSecretKey)
                cachedProof = PassphraseAuth.proof(key: key, deviceId: ownId)
                log("passcode set")
                schedulePublish()
                if running {
                    beaconTick()
                    udpSweep(force: true)
                    tcpSweep(force: true, reason: "passcode")
                }
                DispatchQueue.main.async { completion(true) }
            }
        }
    }

    public func clearPassphrase() {
        queue.async { [self] in
            passphraseKey = nil
            cachedProof = nil
            secrets.set(nil, for: Self.passphraseSecretKey)
            log("passcode cleared")
            schedulePublish()
        }
    }

    /// This device's off-LAN (Tailscale) IPv4, advertised in beacons and the
    /// pairing payload. Only IPv4 is accepted: the beacon is colon-delimited.
    public func setTailscaleIP(_ ip: String) {
        queue.async { [self] in
            let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            tailscaleIP = trimmed
            saveSettings()
            schedulePublish()
        }
    }

    func saveSettings() {
        settingsFile.write(["tailscale_ip": tailscaleIP, "nicknames": nicknames])
    }

    // MARK: - History API

    public func deleteItem(id: String) {
        queue.async { [self] in
            history.remove(identity: id)
            schedulePublish()
        }
    }

    /// Local only, as everywhere: peers keep their copies and may send other
    /// devices' items back on the next connect. Also drops waiting file
    /// entries (the HarmonyOS fix), so a transfer finishing later can't apply.
    public func clearHistory() {
        queue.async { [self] in
            history.clear()
            pendingFiles.removeAll()
            files.clearExports()
            schedulePublish()
        }
    }

    /// The stored bytes for a file entry, copied to a human-readable name for
    /// sharing / Quick Look / saving. Nil while still transferring.
    ///
    /// Deliberately NOT on the engine queue: FileStore's lookups are plain
    /// filesystem calls, and the UI calls this while rendering - it must
    /// never wait behind a large history batch being built.
    public func exportURL(for payload: FilePayload) -> URL? {
        guard files.exists(payload.fileHash) else { return nil }
        return try? files.exportCopy(hash: payload.fileHash, fileName: payload.fileName)
    }

    public func blobURL(forHash hash: String) -> URL? {
        files.exists(hash) ? files.url(for: hash) : nil
    }

    // MARK: - Publishing

    func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            publishScheduled = false
            let snapshot = buildSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.syncEngine(self, didUpdate: snapshot)
            }
        }
    }

    func notice(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncEngine(self, notice: message)
        }
    }

    func log(_ message: String) {
        config.logSink?(message)
        logLines.insert(LogLine(message: message), at: 0)
        if logLines.count > 100 { logLines.removeLast(logLines.count - 100) }
        schedulePublish()
    }

    func displayName(for deviceId: String) -> String {
        nicknames[deviceId] ?? DeviceLabel.short(deviceId)
    }

    public var pairingPayloadAddress: String? {
        let ts = tailscaleIP
        if !ts.isEmpty { return ts }
        return status.lanAddress
    }

    func buildSnapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ownDeviceId = ownId
        s.items = history.newestFirst.map(makeItem)
        s.devices = buildDeviceRows()
        s.connectedCount = links.count
        s.network = status
        s.log = logLines
        s.pairingOpen = pairingOpen
        s.pairingRequest = pending.map { PairingRequest(deviceId: $0.link.peerDeviceId, address: $0.address) }
        s.hasPassphrase = passphraseKey != nil
        s.tailscaleIP = tailscaleIP
        s.localAddresses = NetworkInterfaces.displayAddresses()
        // Includes our LAN address when there is no Tailscale IP: without an
        // Address, HarmonyOS refuses to dial a scanned code and Android has
        // nothing to dial either, since neither can hear our beacons.
        s.pairingPayload = PairingInfo(publicKey: ownId, address: pairingPayloadAddress).jsonString()
        s.transfers = incoming.mapValues { TransferProgress(fileName: $0.fileName, received: $0.received, total: $0.total) }
        s.sweeping = sweeping
        s.nicknames = nicknames
        return s
    }

    private func makeItem(_ entry: ClipboardEntry) -> SyncedItem {
        let payload = entry.type == Wire.EntryType.file ? FilePayload.parse(entry.content) : nil
        let isOwn = entry.deviceId == ownId
        return SyncedItem(
            id: HistoryStore.identity(of: entry),
            entry: entry,
            isOwn: isOwn,
            kind: SyncedItem.kind(for: entry),
            filePayload: payload,
            fileAvailable: payload.map { files.exists($0.fileHash) } ?? (entry.type != Wire.EntryType.file),
            date: DotNetTimestamp.date(entry.timestamp),
            sourceLabel: isOwn ? "This device" : displayName(for: entry.deviceId)
        )
    }

    private func buildDeviceRows() -> [DeviceRow] {
        var ids: [String] = trust.all.map(\.publicKey)
        var seen = Set(ids)
        let now = Date()
        for (id, sighting) in sightings where id != ownId && !seen.contains(id) && now.timeIntervalSince(sighting.lastSeen) < 300 {
            ids.append(id)
            seen.insert(id)
        }
        let rows = ids.map { id -> DeviceRow in
            let sighting = sightings[id]
            let trusted = trust.device(id)
            var addresses: [String] = []
            for a in addressCandidates(for: id) + [trusted?.address, sighting?.advertisedAddress].compactMap({ $0 }) where !addresses.contains(a) {
                addresses.append(a)
            }
            let lastSeen = [sighting?.lastSeen, links[id]?.connectedAt].compactMap { $0 }.max()
            return DeviceRow(
                deviceId: id,
                trusted: trusted != nil,
                connected: links[id] != nil,
                addresses: addresses,
                pairing: sighting?.pairing == true && now.timeIntervalSince(sighting?.pairingSeen ?? .distantPast) < 10,
                lastSeen: lastSeen,
                nearby: links[id] != nil || (sighting.map { now.timeIntervalSince($0.lastSeen) < 30 } ?? false)
            )
        }
        return rows.sorted {
            if $0.connected != $1.connected { return $0.connected }
            if $0.trusted != $1.trusted { return $0.trusted }
            return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
        }
    }
}

// MARK: - Supporting types

struct Sighting {
    var lastSeen: Date
    /// Addresses this device was actually reached at or heard from, with when.
    var addresses: [String: Date] = [:]
    var beaconPort: Int?
    var advertisedAddress: String?
    var pairing = false
    var pairingSeen = Date.distantPast
}

struct Backoff {
    var strikes: Int
    var until: Date
}

struct PendingPairing {
    let link: PeerLink
    let address: String?
}

struct PendingFile {
    var entry: ClipboardEntry
    var apply: Bool
}

final class IncomingTransfer {
    let wireHash: String
    let fileName: String
    let total: Int64
    let owner: ObjectIdentifier
    let url: URL
    let handle: FileHandle
    var nextIndex = 0
    var received: Int64 = 0
    var lastProgressPublish = Date.distantPast

    init?(wireHash: String, fileName: String, total: Int64, owner: ObjectIdentifier, url: URL) {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { return nil }
        self.wireHash = wireHash
        self.fileName = fileName
        self.total = total
        self.owner = owner
        self.url = url
        self.handle = handle
    }

    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

/// Human labels for device IDs. Every P-256 SPKI starts with the same 36
/// base64 characters, so the "first 12 characters" other platforms print are
/// identical for every device; a hash fingerprint actually tells them apart.
public enum DeviceLabel {
    public static func fingerprint(_ deviceId: String) -> String {
        let digest = SHA256.hash(data: Data(deviceId.utf8))
        let hex = digest.prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))·\(hex.suffix(4))"
    }

    public static func short(_ deviceId: String) -> String {
        "Device \(fingerprint(deviceId))"
    }
}
