import Darwin
import Foundation
import Network

// Discovery, dialing, accepting, registration and pairing.
//
// The rules the rest of the mesh plays by (all verified in the other ports):
//  - beacons every 2 s; any datagram on UDP 49000 is treated as a beacon,
//    broadcast or unicast alike;
//  - only the device with the ordinally LARGER id dials (DeviceOrder), on
//    beacons and on its 30 s stored-address pass;
//  - every node accepts every inbound connection that passes the handshake
//    gate, and the newest registered link to a peer replaces older ones.
//
// iOS can't hear broadcast beacons without Apple's multicast entitlement, so
// this node also: unicasts its beacon to every address it knows and, as a
// fallback, to the whole Wi-Fi /24 (peers that should dial us then do);
// dials stored addresses itself when it is the designated dialer; and when an
// address is unknown, finds peers with a TCP identity sweep (each acceptor
// writes its handshake line first, revealing who it is before we reveal
// anything).
extension SyncEngine {

    static let tickInterval: TimeInterval = 2
    static let reconnectInterval: TimeInterval = 30
    /// How long to leave a peer that is supposed to dial us to do so, before
    /// dialing it ourselves (its UDP path may be broken or its map stale).
    static let yieldGrace: TimeInterval = 5
    static let autoSweepInterval: TimeInterval = 60
    static let pairingSweepInterval: TimeInterval = 20
    static let maxInboundPerHost = 4
    static let maxInboundTotal = 16
    /// Untrusted, unlinked devices remembered from beacons/sweeps. Beacons are
    /// unauthenticated UDP: without a cap, spoofed ids grow this forever.
    static let maxStrangerSightings = 64
    /// How long to hold an outbound untrusted link before prompting: a peer
    /// whose own pairing screen is closed hangs up within one round trip.
    static let pairingVerdictDelay: TimeInterval = 1.5

    // MARK: - Start / kick

    func startNetworking() {
        running = true
        status.running = true
        startListener()
        startUDP()
        startTimers()

        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.queue.async { self.pathChanged(path) }
            }
            monitor.start(queue: queue)
            pathMonitor = monitor
        }
    }

    func startTimers() {
        guard tickTimer == nil, reconnectTimer == nil else { return }
        let tick = DispatchSource.makeTimerSource(queue: queue)
        tick.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        tick.setEventHandler { [weak self] in self?.beaconTick() }
        tick.resume()
        tickTimer = tick

        let reconnect = DispatchSource.makeTimerSource(queue: queue)
        reconnect.schedule(deadline: .now() + Self.reconnectInterval, repeating: Self.reconnectInterval)
        reconnect.setEventHandler { [weak self] in self?.kick(reason: "periodic") }
        reconnect.resume()
        reconnectTimer = reconnect
    }

    func pathChanged(_ path: NWPath) {
        let lan = NetworkInterfaces.lan()
        let key = "\(path.status)|\(lan?.ip ?? "-")|\(NetworkInterfaces.tailscale() ?? "-")"
        guard key != lastPathKey else { return }
        let first = lastPathKey.isEmpty
        lastPathKey = key
        status.lanAddress = lan?.ip
        schedulePublish()
        // Not while a background teardown is running out its grace period
        // (timers stopped): that would reopen sockets into suspension.
        guard running, tickTimer != nil, !first, path.status == .satisfied else { return }
        log("network changed - rediscovering")
        lastUDPSweep = .distantPast
        lastTCPSweep = .distantPast
        if udp == nil { startUDP() }
        if server == nil { startListener() }
        kick(reason: "network change")
    }

    /// One round of "find everyone now": beacons, sweeps, reconnects.
    func kick(reason: String) {
        // Only while fully up - never during a background grace teardown.
        guard running, tickTimer != nil else { return }
        status.lanAddress = NetworkInterfaces.lan()?.ip
        if udp == nil { startUDP() }
        if server == nil { startListener() }
        beaconTick()
        udpSweep(force: reason == "foreground" || reason == "background")
        reconnectPass()
        // Give peers that should dial us a moment to do so before sweeping.
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.tcpSweep(force: false, reason: reason)
        }
    }

    // MARK: - Listener

    func startListener() {
        let server: TCPServer
        do {
            server = try TCPServer(port: config.listenPort)
        } catch {
            status.listening = false
            status.lastError = "listener: \(error)"
            log("TCP server error: \(error)")
            return
        }
        server.onConnection = { [weak self] connection in
            self?.queue.async { self?.acceptInbound(connection) }
        }
        server.onState = { [weak self] ok, error in
            guard let self else { return }
            self.queue.async {
                self.status.listening = ok
                if ok {
                    self.serverRetries = 0
                } else {
                    self.log("TCP server error: \(error.map { "\($0)" } ?? "stopped")")
                    self.server?.stop()
                    self.server = nil
                    // Commonly EADDRINUSE right after a restart (TIME_WAIT, and
                    // allowLocalEndpointReuse is unreliable on some iOS versions,
                    // FB8658821): keep retrying for ~40 s rather than silently
                    // never being dialable.
                    if self.running, self.serverRetries < 40 {
                        self.serverRetries += 1
                        self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, self.running, self.tickTimer != nil, self.server == nil else { return }
                            self.startListener()
                        }
                    }
                }
                self.schedulePublish()
            }
        }
        server.start()
        self.server?.stop()
        self.server = server
    }

    func acceptInbound(_ connection: NWConnection) {
        guard running else {
            connection.cancel()
            return
        }
        var remote = "unknown"
        if case let .hostPort(host, _) = connection.endpoint { remote = NetworkInterfaces.normalize("\(host)") }
        // Handshakes are unauthenticated until they finish: bound how many a
        // stranger can hold open at once (each may buffer up to 64 KiB).
        guard inboundFrom[remote, default: 0] < Self.maxInboundPerHost,
              inboundFrom.values.reduce(0, +) < Self.maxInboundTotal else {
            connection.cancel()
            return
        }
        inboundFrom[remote, default: 0] += 1
        PeerLink.accept(connection: connection, context: handshakeContext(), maxLineBytes: config.maxLineBytes, deliveryQueue: queue) { [weak self] result in
            guard let self else { return }
            self.inboundFrom[remote, default: 1] -= 1
            if self.inboundFrom[remote] == 0 { self.inboundFrom[remote] = nil }
            switch result {
            case .success(let link):
                self.handleNewConnection(link, address: link.remoteAddress)
            case .failure(let failure):
                if case .refused(let id, let name) = failure {
                    self.refusedAt[id] = Date()
                    self.noteSighting(id, address: remote, name: name)
                }
            }
        }
    }

    func handshakeContext() -> HandshakeContext {
        HandshakeContext(
            identity: identity,
            trusted: Set(trust.all.map(\.publicKey)),
            passphraseKey: passphraseKey,
            pairingOpen: pairingOpen,
            deviceName: ownDeviceName
        )
    }

    // MARK: - UDP beacons

    func startUDP() {
        do {
            let socket = try UDPSocket(port: config.discoveryPort, queue: queue)
            socket.onDatagram = { [weak self] data, sender in self?.handleDatagram(data, from: sender) }
            udp = socket
        } catch {
            status.lastError = "discovery: \(error)"
            log("discovery failed to start: \(error)")
        }
    }

    func handleDatagram(_ data: Data, from sender: String) {
        guard let text = String(data: data, encoding: .utf8),
              let beacon = Beacon.parse(text, senderIP: sender),
              beacon.deviceId != ownId // our own broadcast, looped back
        else { return }
        onBeacon(beacon)
    }

    /// Exactly the Android/Windows sequence: auto-trust on a verifying
    /// passcode proof, then dial if trusted and we're the designated dialer,
    /// then the pairing dial if both pairing screens are open.
    func onBeacon(_ beacon: Beacon) {
        let id = beacon.deviceId
        // Spoof resistance: a never-seen id must at least be a real P-256 key.
        if sightings[id] == nil, !trust.isTrusted(id), !WireSignature.isValidPublicKey(id) { return }
        var sighting = sightings[id] ?? Sighting(lastSeen: Date())
        sighting.lastSeen = Date()
        if Self.isPeerAddress(beacon.senderIP) { sighting.addresses[beacon.senderIP] = Date() }
        sighting.beaconPort = beacon.tcpPort
        sighting.advertisedAddress = beacon.address
        sighting.pairing = beacon.pairing
        if beacon.pairing { sighting.pairingSeen = Date() }
        // A beacon without a name (an older build) keeps the one we know.
        // Beacons are unauthenticated UDP: the name is held here, in memory,
        // for display only - never written to the trust store.
        if let name = beacon.name { sighting.name = name }
        sightings[id] = sighting
        capStrangerSightings()
        schedulePublish()

        if !trust.isTrusted(id), let key = passphraseKey, let proof = beacon.proof,
           PassphraseAuth.verifyProof(key: key, deviceId: id, proofBase64: proof) {
            log("auto-trusting \(DeviceLabel.short(id)) (shared passcode)")
            // Nameless until its handshake: that stores the name.
            trust.trust(id, address: beacon.address)
        }

        guard links[id] == nil, !connectingTo.contains(id), DeviceOrder.shouldDial(peerId: id, ownId: ownId) else { return }
        if trust.isTrusted(id) {
            guard !isBackedOff(id) else { return }
            dial(deviceId: id, candidates: [beacon.senderIP], port: UInt16(clamping: beacon.tcpPort), ignoreTieBreaker: false) { _ in }
        } else if pairingOpen, beacon.pairing, pending == nil {
            dial(deviceId: id, candidates: [beacon.senderIP], port: UInt16(clamping: beacon.tcpPort), ignoreTieBreaker: false, purpose: .pairing) { _ in }
        }
    }

    func currentBeacon() -> Data {
        let address = tailscaleIP.isEmpty ? nil : tailscaleIP
        return Data(Beacon.build(tcpPort: Int(config.listenPort), deviceId: ownId, proof: cachedProof, address: address, pairing: pairingOpen, name: ownDeviceName).utf8)
    }

    func beaconTick() {
        guard running, let udp else { return }
        if tickTimer != nil { touchLiveMarker() }
        let beacon = currentBeacon()

        if config.enableBroadcast, status.broadcast != .unavailable || Date() >= broadcastRetryAt {
            // One copy per tick: the subnet-directed broadcast when we know the
            // subnet, the limited broadcast otherwise. (Windows starts a
            // separate pairing dial for every copy it hears.)
            let targets = NetworkInterfaces.lan().map { [NetworkInterfaces.directedBroadcast(for: $0)] } ?? ["255.255.255.255"]
            var ok = false
            var lastErr: Int32 = 0
            for t in targets {
                let err = udp.send(beacon, to: t, port: config.peerDiscoveryPort)
                if err == 0 { ok = true } else { lastErr = err }
            }
            if ok {
                if status.broadcast != .available { log("broadcast discovery available") }
                status.broadcast = .available
            } else if status.broadcast != .unavailable {
                status.broadcast = .unavailable
                log("broadcast blocked by iOS (\(String(cString: strerror(lastErr)))) - using direct discovery")
            }
            if !ok { broadcastRetryAt = Date().addingTimeInterval(60) }
        }

        var lanOK = false
        var lanErr: Int32 = 0
        let lan = NetworkInterfaces.lan()
        var sent = Set<String>()
        for target in beaconTargets() {
            // Broadcast already reached everyone on our own subnet.
            if status.broadcast == .available, let lan, let v = NetworkInterfaces.parse(target),
               v & lan.maskValue == lan.ipValue & lan.maskValue { continue }
            sent.insert(target)
            let err = udp.send(beacon, to: target, port: config.peerDiscoveryPort)
            if NetworkInterfaces.isPrivateLAN(target) {
                if err == 0 { lanOK = true } else { lanErr = err }
            }
        }
        if lanOK {
            setLocalNetwork(.allowed)
        } else if lanErr == EHOSTUNREACH || lanErr == EPERM || lanErr == EACCES {
            setLocalNetwork(.denied)
        }

        if pairingOpen { udpSweep(force: false, skip: sent) }
        overrideStalledInbound()
        pruneSightings()
    }

    func setLocalNetwork(_ value: NetworkStatus.LocalNetwork) {
        guard status.localNetwork != value else { return }
        let was = status.localNetwork
        status.localNetwork = value
        if value == .denied {
            log("local network access looks denied - Settings › Privacy & Security › Local Network")
        } else if was == .denied {
            log("local network access allowed")
            broadcastRetryAt = .distantPast
            lastUDPSweep = .distantPast
            lastTCPSweep = .distantPast
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.kick(reason: "local network allowed") }
        }
        schedulePublish()
    }

    /// Every address a beacon should reach individually: trusted peers' stored
    /// addresses and wherever we've recently seen anyone. Connected peers
    /// still get them (harmless, and it keeps us "seen" on their side).
    func beaconTargets() -> [String] {
        var targets = Set(config.extraBeaconTargets)
        for device in trust.all {
            if let a = device.address { targets.insert(a) }
        }
        let now = Date()
        for (id, sighting) in sightings {
            // Only devices that need to hear us: trusted ones, anyone while
            // pairing, and (with a passcode) strangers that haven't recently
            // refused us - otherwise a device removed here but still trusting
            // us would dial, be refused and redial every 2 s.
            let wanted = trust.isTrusted(id) || pairingOpen || id == pairingTargetKey ||
                (passphraseKey != nil && now.timeIntervalSince(refusedAt[id] ?? .distantPast) > 600)
            guard wanted else { continue }
            for (address, seen) in sighting.addresses where now.timeIntervalSince(seen) < 600 {
                targets.insert(address)
            }
        }
        let own = Set(NetworkInterfaces.ipv4().map(\.ip))
        return targets.filter { !own.contains($0) && NetworkInterfaces.parse($0) != nil }
    }

    /// Unicast our beacon to every host on the Wi-Fi /24. This is how peers
    /// that should dial us learn where we are when broadcast is unavailable.
    func udpSweep(force: Bool, skip: Set<String> = []) {
        guard running, config.enableSweeps, let udp, status.broadcast != .available,
              let lan = NetworkInterfaces.lan() else { return }
        let interval: TimeInterval = pairingOpen ? 4 : Self.reconnectInterval
        guard force || Date().timeIntervalSince(lastUDPSweep) >= interval else { return }
        lastUDPSweep = Date()
        let beacon = currentBeacon()
        let hosts = NetworkInterfaces.sweepHosts(for: lan).filter { !skip.contains($0) }
        var errors = 0
        // Paced, 32 datagrams per 10 ms: a /24 in under 0.1 s without dumping
        // 254 frames on the access point at once.
        func send(from start: Int) {
            guard running, let udp = self.udp else { return }
            let end = min(start + 32, hosts.count)
            for host in hosts[start..<end] where udp.send(beacon, to: host, port: config.peerDiscoveryPort) != 0 {
                errors += 1
            }
            if end < hosts.count {
                queue.asyncAfter(deadline: .now() + 0.01) { send(from: end) }
            } else if !hosts.isEmpty, errors == hosts.count {
                setLocalNetwork(.denied)
            }
        }
        send(from: 0)
    }

    func pruneSightings() {
        let now = Date()
        sightings = sightings.filter { id, s in
            trust.isTrusted(id) || links[id] != nil || now.timeIntervalSince(s.lastSeen) < 300
        }
    }

    /// `name`: what the device's handshake called itself, if anything. Held
    /// in memory only: a refused or unwanted handshake line was never
    /// verified, so storing a name is handleNewConnection's job.
    func noteSighting(_ id: String, address: String?, name: String? = nil) {
        guard id != ownId else { return }
        var sighting = sightings[id] ?? Sighting(lastSeen: Date())
        sighting.lastSeen = Date()
        if let address, Self.isPeerAddress(address) { sighting.addresses[address] = Date() }
        if let name { sighting.name = name }
        sightings[id] = sighting
        capStrangerSightings()
        schedulePublish()
    }

    /// Where a real peer can be: the LAN, Tailscale, or loopback (tests).
    /// Never a public address a spoofed beacon could aim our unicast at.
    static func isPeerAddress(_ ip: String) -> Bool {
        guard let v = NetworkInterfaces.parse(ip) else { return false }
        return NetworkInterfaces.isPrivateLAN(v) || NetworkInterfaces.isCGNAT(v) || (v & 0xFF00_0000) == 0x7F00_0000
    }

    func capStrangerSightings() {
        let strangers = sightings.filter { !trust.isTrusted($0.key) && links[$0.key] == nil && pending?.link.peerDeviceId != $0.key }
        guard strangers.count > Self.maxStrangerSightings else { return }
        for (id, _) in strangers.sorted(by: { $0.value.lastSeen < $1.value.lastSeen }).prefix(strangers.count - Self.maxStrangerSightings) {
            sightings[id] = nil
        }
    }

    /// Where to try a device, most promising first: addresses we actually
    /// heard it from or reached it at recently (LAN), then its stored address,
    /// then what it advertises for itself (usually Tailscale).
    func addressCandidates(for id: String) -> [String] {
        var result: [String] = []
        func add(_ a: String?) {
            guard let a, !a.isEmpty, !result.contains(a) else { return }
            result.append(a)
        }
        if let s = sightings[id] {
            s.addresses.sorted { $0.value > $1.value }.forEach { add($0.key) }
        }
        add(trust.device(id)?.address)
        add(sightings[id]?.advertisedAddress)
        return result
    }

    // MARK: - Reconnect pass

    /// For every trusted, unconnected peer: dial it if we're the designated
    /// dialer, otherwise make sure it's hearing our beacons so it dials us.
    func reconnectPass() {
        guard running else { return }
        for device in trust.all where device.publicKey != ownId {
            let id = device.publicKey
            guard links[id] == nil, !connectingTo.contains(id), !isBackedOff(id) else { continue }
            let candidates = addressCandidates(for: id)
            if DeviceOrder.shouldDial(peerId: id, ownId: ownId) {
                if candidates.isEmpty {
                    wantsTCPSweep = true
                } else {
                    dial(deviceId: id, candidates: candidates, ignoreTieBreaker: false) { [weak self] ok in
                        if !ok { self?.wantsTCPSweep = true }
                    }
                }
            } else if awaitingInbound[id] == nil {
                awaitingInbound[id] = Date()
            }
        }
    }

    /// A peer that should dial us hasn't, several beacons later: its UDP path
    /// to us may be broken, or it still holds a stale link to our previous
    /// session. Dial it ourselves - accepting is unconditional on every
    /// platform, and the newest link wins on both ends.
    func overrideStalledInbound() {
        let now = Date()
        for (id, since) in awaitingInbound {
            guard links[id] == nil else {
                awaitingInbound[id] = nil
                continue
            }
            guard trust.isTrusted(id) else {
                awaitingInbound[id] = nil
                continue
            }
            let jitter = Double(abs(id.hashValue % 1000)) / 1000
            guard now.timeIntervalSince(since) > Self.yieldGrace + jitter,
                  now >= nextOverrideDial[id] ?? .distantPast,
                  !connectingTo.contains(id), !isBackedOff(id)
            else { continue }
            let candidates = addressCandidates(for: id)
            guard !candidates.contains(where: { inboundFrom[$0] != nil }) else { continue }
            nextOverrideDial[id] = now.addingTimeInterval(Self.reconnectInterval)
            if candidates.isEmpty {
                wantsTCPSweep = true
                continue
            }
            dial(deviceId: id, candidates: candidates, ignoreTieBreaker: true) { [weak self] ok in
                if !ok { self?.wantsTCPSweep = true }
            }
        }
    }

    func isBackedOff(_ id: String) -> Bool {
        guard let b = backoff[id] else { return false }
        return Date() < b.until
    }

    // MARK: - Dialing

    enum DialPurpose { case sync, pairing }

    /// Tries `candidates` in order until one completes a handshake. `deviceId`
    /// is who we expect (nil for pairing a not-yet-identified device).
    func dial(
        deviceId: String?,
        candidates: [String],
        port: UInt16? = nil,
        ignoreTieBreaker: Bool,
        purpose: DialPurpose = .sync,
        completion: @escaping (Bool) -> Void
    ) {
        if let deviceId {
            guard !connectingTo.contains(deviceId) else {
                completion(false)
                return
            }
            connectingTo.insert(deviceId)
        }
        var remaining = candidates
        func next() {
            guard running, !remaining.isEmpty else {
                if let deviceId { connectingTo.remove(deviceId) }
                completion(false)
                return
            }
            let host = remaining.removeFirst()
            dialOnce(host: host, port: port ?? config.peerPort, expected: deviceId, purpose: purpose, ignoreTieBreaker: ignoreTieBreaker) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let link):
                    if let deviceId { self.connectingTo.remove(deviceId) }
                    self.handleNewConnection(link, address: host)
                    completion(true)
                case .failure:
                    next()
                }
            }
        }
        next()
    }

    func dialOnce(
        host: String,
        port: UInt16,
        expected: String?,
        purpose: DialPurpose,
        ignoreTieBreaker: Bool,
        completion: @escaping (Result<PeerLink, HandshakeFailure>) -> Void
    ) {
        let context = handshakeContext()
        let own = ownId
        let connected = Set(links.keys)
        let timeout = NetworkInterfaces.isPrivateLAN(host) ? 3 : 5
        // For sync dials, check who answered before revealing ourselves: a
        // peer we'd refuse anyway never gets to register a link to us.
        let gate: (HandshakeMessage) -> Bool = { theirs in
            if purpose == .pairing { return true }
            let id = theirs.identityPublicKey
            if connected.contains(id) && id != expected { return false }
            if !ignoreTieBreaker, id != expected, !DeviceOrder.shouldDial(peerId: id, ownId: own) { return false }
            if context.trusted.contains(id) { return true }
            if let key = context.passphraseKey, PassphraseAuth.verifyProof(key: key, deviceId: id, proofBase64: theirs.passphraseProof) { return true }
            return context.pairingOpen
        }
        PeerLink.dial(host: host, port: port, context: context, connectTimeout: timeout, maxLineBytes: config.maxLineBytes, deliveryQueue: queue, gate: gate) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let link):
                if NetworkInterfaces.isPrivateLAN(host) { self.setLocalNetwork(.allowed) }
                if let expected, link.peerDeviceId != expected {
                    // That address now belongs to someone else (e.g. the same
                    // phone reinstalled with a new identity). Forget it for the
                    // old identity; keep the link to whoever really answered.
                    self.log("\(host) answered as \(DeviceLabel.short(link.peerDeviceId)), not \(DeviceLabel.short(expected)) - clearing that stale address")
                    self.trust.clearAddress(expected)
                }
            case .failure(let failure):
                switch failure {
                case .localNetworkDenied:
                    self.setLocalNetwork(.denied)
                case .notWanted(let theirs):
                    self.noteSighting(theirs.identityPublicKey, address: host, name: theirs.deviceName)
                case .refused(let id, let name):
                    self.noteSighting(id, address: host, name: name)
                default:
                    break
                }
            }
            completion(result)
        }
    }

    // MARK: - TCP identity sweep

    /// Finds ClipLink peers on the Wi-Fi /24 whose address we don't know, by
    /// connecting to port 49000 and reading the handshake line every acceptor
    /// writes first. We continue the handshake only with peers we mean to
    /// dial (trusted and we're the designated dialer; a verifying passcode
    /// proof; the pairing target); everyone else is closed without us having
    /// sent a byte, and is remembered so our unicast beacons reach them.
    func tcpSweep(force: Bool, reason: String) {
        guard running, tickTimer != nil, config.enableSweeps, !tcpSweepInFlight, let lan = NetworkInterfaces.lan() else { return }
        guard status.localNetwork != .denied || force else { return }
        // Only peers WE must dial need finding: the rest dial us once our
        // unicast beacon sweep reaches them.
        let unreachedDialTargets = trust.all.contains {
            links[$0.publicKey] == nil && DeviceOrder.shouldDial(peerId: $0.publicKey, ownId: ownId) && !isBackedOff($0.publicKey)
        }
        let onForeground = ["foreground", "background", "network change", "local network allowed"].contains(reason)
        let needed = force || wantsTCPSweep || pairingOpen || pairingTargetKey != nil ||
            (onForeground && (unreachedDialTargets || (passphraseKey != nil && trust.all.isEmpty)))
        guard needed, status.broadcast != .available || pairingTargetKey != nil || force else { return }
        let interval = pairingOpen ? Self.pairingSweepInterval : Self.autoSweepInterval
        guard force || Date().timeIntervalSince(lastTCPSweep) >= interval else { return }

        tcpSweepInFlight = true
        wantsTCPSweep = false
        lastTCPSweep = Date()
        sweeping = true
        schedulePublish()

        // Skip hosts we already have a live link to: probing them costs a
        // connection for nothing.
        let liveHosts = Set(links.values.compactMap(\.remoteAddress))
        let hosts = NetworkInterfaces.sweepHosts(for: lan).filter { !liveHosts.contains($0) }
        let context = handshakeContext()
        let own = ownId
        let connected = Set(links.keys)
        let target = pairingTargetKey
        // The 24 probes' gates run concurrently on their own queues: a shared,
        // locked claim set lets only ONE probe per identity write our line (a
        // multi-homed peer answers on several addresses).
        let claims = SweepClaims(connected)
        let gate: (HandshakeMessage) -> Bool = { theirs in
            let id = theirs.identityPublicKey
            guard !connected.contains(id) else { return false }
            let wanted: Bool
            if id == target {
                wanted = true
            } else if !DeviceOrder.shouldDial(peerId: id, ownId: own) {
                wanted = false
            } else if context.trusted.contains(id) {
                wanted = true
            } else if let key = context.passphraseKey, PassphraseAuth.verifyProof(key: key, deviceId: id, proofBase64: theirs.passphraseProof) {
                wanted = true
            } else {
                wanted = context.pairingOpen
            }
            return wanted && claims.claim(id)
        }

        var queueOfHosts = hosts
        var active = 0
        var found = 0
        var denied = false
        let maxConcurrent = 24
        func pump() {
            while running, !denied, active < maxConcurrent, !queueOfHosts.isEmpty {
                let host = queueOfHosts.removeFirst()
                active += 1
                PeerLink.dial(host: host, port: config.peerPort, context: context, connectTimeout: 1, maxLineBytes: config.maxLineBytes, deliveryQueue: queue, gate: gate) { [weak self] result in
                    guard let self else { return }
                    active -= 1
                    switch result {
                    case .success(let link):
                        found += 1
                        // Our handshake line is out, so the peer has already
                        // made this its newest link: keep it (newest wins on
                        // both ends) rather than close the one it kept.
                        self.handleNewConnection(link, address: host)
                    case .failure(.notWanted(let theirs)):
                        found += 1
                        self.noteSighting(theirs.identityPublicKey, address: host, name: theirs.deviceName)
                    case .failure(.refused(let id, let name)):
                        found += 1
                        self.noteSighting(id, address: host, name: name)
                    case .failure(.localNetworkDenied):
                        denied = true
                        self.setLocalNetwork(.denied)
                    default:
                        break
                    }
                    pump()
                }
            }
            if active == 0 && (queueOfHosts.isEmpty || denied || !running) {
                tcpSweepInFlight = false
                sweeping = false
                if !denied { log("network sweep (\(reason)) found \(found) ClipLink device(s)") }
                // Anyone found who should dial us now gets our unicast beacons.
                beaconTick()
                schedulePublish()
            }
        }
        pump()
    }

    // MARK: - New connections

    /// The single funnel for every freshly handshaken link, whichever path
    /// made it (inbound, beacon dial, reconnect, sweep, manual pairing).
    func handleNewConnection(_ link: PeerLink, address: String?) {
        let id = link.peerDeviceId
        noteSighting(id, address: address, name: link.peerName)
        // Only a completed handshake (signature verified) stores a peer's
        // name: here, on passcode pairing below and on Accept. A beacon's
        // name is only ever displayed.
        trust.updateName(id, name: link.peerName)
        guard running else {
            link.close()
            return
        }

        if !link.wasAlreadyTrusted {
            // Only possible because our pairing screen is open. Hold it -
            // nothing read, nothing sent - until the user decides.
            guard pairingOpen, pending == nil else {
                link.close()
                return
            }
            if link.direction == .outbound {
                // We dialled without knowing whether ITS pairing screen is open
                // (sweeps and pairing dials can't tell). A peer that isn't
                // pairing refuses by hanging up within a round trip - wait for
                // that before bothering the user with a prompt.
                queue.asyncAfter(deadline: .now() + Self.pairingVerdictDelay) { [weak self] in
                    self?.promoteToPending(link, address: address)
                }
            } else {
                // Inbound: the peer dialled us from its own open pairing screen.
                promoteToPending(link, address: address)
            }
            return
        }

        // Registered FIRST: starting the read loop matters more than the
        // trust-store bookkeeping below.
        register(link, acceptedByUser: false)
        if link.newlyTrustedViaPassphrase {
            trust.trust(id, address: address, name: link.peerName)
            log("auto-paired via passcode: \(DeviceLabel.short(id))")
            notice("Paired with \(displayName(for: id)) using your passcode.")
        } else {
            // Back-fill the address we actually reached it at.
            if let address { trust.trust(id, address: address) }
            log("connected: \(DeviceLabel.short(id))")
        }
    }

    func promoteToPending(_ link: PeerLink, address: String?) {
        guard running, pairingOpen, pending == nil, !link.isClosed else {
            link.close()
            return
        }
        pending = PendingPairing(link: link, address: address)
        link.onClosed = { [weak self] closed in
            guard let self else { return }
            // The other side cancelled: clear the prompt so it can't block
            // the next real request.
            if self.pending?.link === closed {
                self.pending = nil
                self.log("pairing request from \(DeviceLabel.short(closed.peerDeviceId)) withdrawn")
            }
            self.schedulePublish()
        }
        log("pairing request from \(DeviceLabel.short(link.peerDeviceId))")
        schedulePublish()
    }

    func register(_ link: PeerLink, acceptedByUser: Bool) {
        let id = link.peerDeviceId
        link.onMessage = { [weak self] link, text in self?.handleMessage(text, from: link) }
        link.onClosed = { [weak self] link in self?.linkClosed(link) }
        link.onOversizedLine = { [weak self] link in
            guard let self else { return }
            self.log("skipped an oversized message from \(self.displayName(for: link.peerDeviceId))")
        }
        link.goLive(extendedGrace: acceptedByUser ? 60 : nil)
        awaitingInbound[id] = nil
        pairingTargetKey = pairingTargetKey == id ? nil : pairingTargetKey

        // History immediately, even "[]": HarmonyOS treats the first bytes
        // from us as "the other side accepted".
        sendHistoryBatch(to: link)
        requestMissingBlobs(from: link)

        if let previous = links[id], previous !== link, !previous.isClosed, previous.hasReceivedSessionLine,
           !link.hasReceivedSessionLine {
            // A working link already exists. The newest link wins - as on every
            // peer - but only once it proves itself by decrypting a line: a
            // replayed handshake can pass the gate yet never produce one, and
            // must not knock out the real connection. Genuine peers send their
            // history batch at once, so this takes a round trip.
            link.onFirstSessionLine = { [weak self] link in
                guard let self, !link.isClosed else { return }
                let old = self.links[id]
                self.links[id] = link
                if let old, old !== link { old.close() }
                self.schedulePublish()
            }
        } else {
            let previous = links[id]
            links[id] = link
            if let previous, previous !== link {
                // Only one live socket per peer: the orphan would otherwise keep
                // heartbeating while the peer may treat IT as canonical.
                previous.close()
            }
        }
        schedulePublish()
    }

    func linkClosed(_ link: PeerLink) {
        let id = link.peerDeviceId
        var aborted: [String] = []
        for (key, transfer) in incoming where transfer.owner == ObjectIdentifier(link) {
            transfer.abort()
            incoming[key] = nil
            aborted.append(transfer.wireHash)
        }
        // Nobody retries a broken stream on their own: ask whoever's left.
        let remaining = links.values.filter { $0 !== link }
        for hash in aborted where pendingFiles[FileStore.key(hash)] != nil {
            requestedAt[FileStore.key(hash)] = nil
            requestFile(hash, from: remaining)
        }
        guard links[id] === link else { return } // a replaced link; the live one stays
        links[id] = nil
        log("peer disconnected: \(DeviceLabel.short(id))")

        // Handshake done, then an immediate hang-up with nothing sent: that is
        // how a peer that doesn't trust us (or doesn't anymore) refuses.
        if Date().timeIntervalSince(link.connectedAt) < 3, !link.hasReceivedSessionLine {
            var b = backoff[id] ?? Backoff(strikes: 0, until: .distantPast)
            b.strikes += 1
            let delay = min(120, 10 * pow(2, Double(b.strikes - 1)))
            b.until = Date().addingTimeInterval(delay)
            backoff[id] = b
            if b.strikes == 2 {
                log("\(displayName(for: id)) keeps closing the connection - it may not trust this device")
            }
        } else {
            backoff[id] = nil
        }
        if trust.isTrusted(id), !DeviceOrder.shouldDial(peerId: id, ownId: ownId) {
            awaitingInbound[id] = Date()
        }
        schedulePublish()
    }

    // MARK: - Manual pairing

    func pairLocked(_ raw: String, completion: @escaping (PairOutcome) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return completion(.empty) }

        if let info = PairingInfo.parse(trimmed) {
            let key = info.publicKey
            if key == ownId { return completion(.ownCode) }
            if links[key] != nil {
                return completion(.connected(addressCandidates(for: key).first ?? displayName(for: key)))
            }
            var candidates = addressCandidates(for: key)
            if let a = info.address, !candidates.contains(a) { candidates.append(a) }
            if candidates.isEmpty {
                guard config.enableSweeps, NetworkInterfaces.lan() != nil else { return completion(.noAddress(key: key, name: info.name)) }
                // No address to dial: find it. If we're its dialer the sweep
                // connects straight away; otherwise our pairing beacons make it
                // dial us once its own Pairing screen is open.
                pairingTargetKey = key
                udpSweep(force: true)
                tcpSweep(force: true, reason: "pairing target")
                return completion(.searching(key: key, name: info.name))
            }
            return dialForPairing(candidates, completion: completion)
        }

        // Not JSON: the input IS an address ("192.168.1.20", "host:49000").
        var host = trimmed
        var port = config.peerPort
        if let colon = trimmed.lastIndex(of: ":"), trimmed.filter({ $0 == ":" }).count == 1,
           let p = UInt16(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon])
            port = p
        }
        dialForPairing([host], port: port, completion: completion)
    }

    /// HarmonyOS' outcome logic: dial each candidate, then read the peer's
    /// verdict from what the link does in the next 3 seconds.
    func dialForPairing(_ candidates: [String], port: UInt16? = nil, completion: @escaping (PairOutcome) -> Void) {
        var remaining = candidates
        var worst: PairOutcome?
        let label = candidates.joined(separator: " or ")
        func rank(_ o: PairOutcome?) -> Int {
            switch o {
            case .refused: return 3
            case .silent: return 2
            case .localNetworkDenied: return 4
            default: return 1
            }
        }
        func next() {
            guard !remaining.isEmpty else {
                return completion(worst ?? .unreachable(label))
            }
            let host = remaining.removeFirst()
            dialOnce(host: host, port: port ?? config.peerPort, expected: nil, purpose: .pairing, ignoreTieBreaker: true) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let failure):
                    let outcome: PairOutcome
                    switch failure {
                    case .localNetworkDenied: outcome = .localNetworkDenied
                    case .silent: outcome = .silent(host)
                    case .closedEarly, .refused, .malformed, .badSignature: outcome = .refused(host)
                    case .selfConnection: outcome = .ownCode
                    default: outcome = .unreachable(host)
                    }
                    if case .ownCode = outcome { return completion(.ownCode) }
                    if rank(outcome) >= rank(worst) { worst = outcome }
                    next()
                case .success(let link):
                    let id = link.peerDeviceId
                    let wasPending = self.pending != nil
                    let viaPasscode = link.newlyTrustedViaPassphrase
                    let trusted = link.wasAlreadyTrusted
                    self.handleNewConnection(link, address: host)
                    if !trusted {
                        if wasPending { return completion(.busy) }
                        // handleNewConnection holds an outbound candidate for the
                        // verdict window before prompting; report after it.
                        self.queue.asyncAfter(deadline: .now() + Self.pairingVerdictDelay + 0.1) {
                            if self.pending?.link === link {
                                completion(.prompt(host))
                            } else if self.pending != nil {
                                completion(.busy)
                            } else {
                                completion(.refused(host))
                            }
                        }
                        return
                    }
                    if viaPasscode { return completion(.passcode(host)) }
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        if link.isClosed {
                            completion(self.pending?.link.peerDeviceId == id ? .prompt(host) : .refused(host))
                        } else if link.hasReceivedSessionLine {
                            completion(.connected(host))
                        } else {
                            completion(.awaitingOther(host))
                        }
                    }
                }
            }
        }
        next()
    }
}

/// Identities already claimed by one of a sweep's concurrent probes.
final class SweepClaims {
    private let lock = NSLock()
    private var ids: Set<String>

    init(_ initial: Set<String>) { ids = initial }

    func claim(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.insert(id).inserted
    }
}
