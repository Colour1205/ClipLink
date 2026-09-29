import CryptoKit
import Network
import XCTest
@testable import ClipLinkCore

/// Two complete engines talking over real sockets on loopback: discovery
/// beacons, handshake, trust, sync, history catch-up and file streaming.
final class EngineIntegrationTests: XCTestCase {

    final class Recorder: SyncEngineDelegate {
        private let lock = NSLock()
        // Written on the main queue: read only through the locked accessors.
        private var snapshot = EngineSnapshot()
        private(set) var received: [(ClipboardEntry, URL?)] = []
        private(set) var notices: [String] = []

        func syncEngine(_ engine: SyncEngine, didUpdate snapshot: EngineSnapshot) {
            lock.lock(); self.snapshot = snapshot; lock.unlock()
        }
        func syncEngine(_ engine: SyncEngine, didReceive entry: ClipboardEntry, fileURL: URL?) {
            lock.lock(); received.append((entry, fileURL)); lock.unlock()
        }
        func syncEngine(_ engine: SyncEngine, notice: String) {
            lock.lock(); notices.append(notice); lock.unlock()
        }
        var connectedCount: Int { lock.lock(); defer { lock.unlock() }; return snapshot.connectedCount }
        var receivedEntries: [(ClipboardEntry, URL?)] { lock.lock(); defer { lock.unlock() }; return received }
        var items: [SyncedItem] { lock.lock(); defer { lock.unlock() }; return snapshot.items }
        var pairingRequest: PairingRequest? { lock.lock(); defer { lock.unlock() }; return snapshot.pairingRequest }
        var devices: [DeviceRow] { lock.lock(); defer { lock.unlock() }; return snapshot.devices }
        var hasPassphrase: Bool { lock.lock(); defer { lock.unlock() }; return snapshot.hasPassphrase }
        var running: Bool { lock.lock(); defer { lock.unlock() }; return snapshot.network.running }
    }

    struct Node {
        let engine: SyncEngine
        let recorder: Recorder
        let dir: URL
    }

    private var nodes: [Node] = []
    private static var portBase: UInt16 = 49600

    override func tearDown() {
        for node in nodes {
            node.engine.shutdown()
            try? FileManager.default.removeItem(at: node.dir)
        }
        nodes.removeAll()
        Thread.sleep(forTimeInterval: 0.3)
        super.tearDown()
    }

    /// Two nodes wired to beacon each other directly on 127.0.0.1.
    private func makePair() -> (Node, Node) {
        let base = Self.portBase
        Self.portBase += 10
        func node(listen: UInt16, peer: UInt16) -> Node {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-test-\(UUID().uuidString)")
            var config = EngineConfig(storageDirectory: dir)
            config.listenPort = listen
            config.discoveryPort = listen + 1
            config.peerPort = peer
            config.peerDiscoveryPort = peer + 1
            config.enableBroadcast = false
            config.enableSweeps = false
            config.extraBeaconTargets = ["127.0.0.1"]
            let engine = SyncEngine(config: config, identity: SoftwareIdentity(), secrets: MemorySecretStore())
            let recorder = Recorder()
            engine.delegate = recorder
            let n = Node(engine: engine, recorder: recorder, dir: dir)
            nodes.append(n)
            return n
        }
        return (node(listen: base, peer: base + 4), node(listen: base + 4, peer: base))
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func setPasscode(_ node: Node, _ code: String) {
        let done = expectation(description: "passcode")
        node.engine.setPassphrase(code) { ok in
            XCTAssertTrue(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testPasscodeAutoPairsThenSyncsTextImageAndFile() throws {
        let (a, b) = makePair()
        setPasscode(a, "  correct horse  ") // trimmed like every other platform
        setPasscode(b, "correct horse")
        a.engine.enterForeground()
        b.engine.enterForeground()

        wait("both connected") { a.recorder.connectedCount == 1 && b.recorder.connectedCount == 1 }

        // Text A -> B
        a.engine.sendText("hello from A é 🌍\nline two")
        wait("B received text") { b.recorder.receivedEntries.contains { $0.0.content == "hello from A é 🌍\nline two" } }

        // Image B -> A (inline base64)
        let png = Data((0..<5000).map { UInt8($0 % 251) })
        b.engine.sendImage(png: png)
        wait("A received image") { a.recorder.receivedEntries.contains { $0.0.type == "image" } }
        XCTAssertEqual(Data(base64Encoded: a.recorder.receivedEntries.first { $0.0.type == "image" }!.0.content), png)

        // File A -> B, several chunks
        let bytes = Data((0..<(Wire.fileChunkSize * 3 + 1234)).map { _ in UInt8.random(in: 0...255) })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).bin")
        try bytes.write(to: source)
        let sent = expectation(description: "file sent")
        a.engine.sendFile(at: source, name: "report.bin", moveIntoStore: false) { result in
            if case .sent = result { sent.fulfill() } else { XCTFail("\(result)") }
        }
        wait(for: [sent], timeout: 10)
        wait("B received file") { b.recorder.receivedEntries.contains { $0.0.type == "file" && $0.1 != nil } }
        let fileURL = b.recorder.receivedEntries.first { $0.0.type == "file" }!.1!
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        let payload = FilePayload.parse(b.recorder.receivedEntries.first { $0.0.type == "file" }!.0.content)!
        XCTAssertEqual(payload.fileName, "report.bin")
        XCTAssertEqual(payload.fileHash, payload.fileHash.uppercased(), "iOS sends uppercase hashes (Windows echo check)")
        XCTAssertEqual(payload.fileSize, Int64(bytes.count))
    }

    /// The passcode can be set, changed and cleared at any time - any length
    /// that isn't blank - and the very next beacon and handshake carry the new
    /// state. Clearing it keeps the devices that are already trusted.
    func testPasscodeCanBeSetChangedAndClearedAnyTime() throws {
        let (a, b) = makePair()
        // The proof A's next beacon and next handshake would carry.
        func proofs() -> (beacon: String?, handshake: String?) {
            a.engine.queue.sync { () -> (beacon: String?, handshake: String?) in
                let beacon = Beacon.parse(String(decoding: a.engine.currentBeacon(), as: UTF8.self), senderIP: "127.0.0.1")
                let handshake = a.engine.handshakeContext().passphraseKey.map { PassphraseAuth.proof(key: $0, deviceId: a.engine.ownId) }
                return (beacon?.proof, handshake)
            }
        }
        func expected(_ code: String) -> String {
            PassphraseAuth.proof(key: PassphraseAuth.deriveKey(passphrase: code), deviceId: a.engine.ownId)
        }
        XCTAssertNil(proofs().beacon)
        XCTAssertNil(proofs().handshake)

        setPasscode(a, "7") // no minimum length
        let short = expected("7")
        XCTAssertEqual(proofs().beacon, short)
        XCTAssertEqual(proofs().handshake, short)

        setPasscode(a, "  new code ") // changed without a restart, trimmed
        let changed = expected("new code")
        XCTAssertEqual(proofs().beacon, changed)
        XCTAssertEqual(proofs().handshake, changed)

        // The changed passcode is the one that pairs.
        setPasscode(b, "new code")
        a.engine.enterForeground()
        b.engine.enterForeground()
        wait("both connected") { a.recorder.connectedCount == 1 && b.recorder.connectedCount == 1 }

        a.engine.clearPassphrase()
        XCTAssertNil(proofs().beacon)
        XCTAssertNil(proofs().handshake)
        wait("A shows the passcode off") { !a.recorder.hasPassphrase }
        XCTAssertTrue(a.engine.queue.sync { a.engine.trust.isTrusted(b.engine.ownId) }, "clearing never untrusts")
        XCTAssertTrue(a.engine.queue.sync { a.engine.handshakeContext().trusted.contains(b.engine.ownId) })

        // ... and it can be set again straight away.
        setPasscode(a, "again")
        XCTAssertEqual(proofs().beacon, expected("again"))
    }

    func testHistoryCatchUpOnConnectAppliesOnlyNewest() throws {
        let (a, b) = makePair()
        setPasscode(a, "pw")
        setPasscode(b, "pw")
        // A captures three things while nobody is around.
        a.engine.enterForeground()
        a.engine.sendText("first")
        Thread.sleep(forTimeInterval: 0.05)
        a.engine.sendText("second")
        Thread.sleep(forTimeInterval: 0.05)
        a.engine.sendText("third")
        wait("A has history") { a.recorder.items.count == 3 }

        b.engine.enterForeground()
        wait("connected") { a.recorder.connectedCount == 1 && b.recorder.connectedCount == 1 }
        wait("B caught up") { b.recorder.items.count == 3 }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(b.recorder.receivedEntries.map(\.0.content), ["third"], "only the newest caught-up item lands on the clipboard")
        XCTAssertEqual(b.recorder.items.first?.entry.content, "third")
    }

    /// Drops `node`'s links and brings it back up, so each side sends its
    /// history_batch again.
    private func reconnect(_ node: Node, to other: Node) {
        let down = expectation(description: "backgrounded")
        node.engine.enterBackground(grace: 0) { down.fulfill() }
        wait(for: [down], timeout: 10)
        wait("link dropped") { other.recorder.connectedCount == 0 }
        node.engine.enterForeground()
        wait("reconnected", timeout: 30) { node.recorder.connectedCount == 1 && other.recorder.connectedCount == 1 }
    }

    /// Delete and Clear are local, but they stick: the peer still has the
    /// items and resends its whole history on every connect.
    func testDeletedAndClearedItemsDontComeBackFromHistoryBatches() throws {
        let (a, b) = makePair()
        setPasscode(a, "pw")
        setPasscode(b, "pw")
        a.engine.enterForeground()
        a.engine.sendText("keep")
        Thread.sleep(forTimeInterval: 0.05)
        a.engine.sendText("delete me")
        wait("A has history") { a.recorder.items.count == 2 }

        b.engine.enterForeground()
        wait("connected") { a.recorder.connectedCount == 1 && b.recorder.connectedCount == 1 }
        wait("B caught up") { b.recorder.items.count == 2 }
        wait("B applied the newest") { b.recorder.receivedEntries.count == 1 }

        // Delete one on B: gone locally, A untouched, nothing new on B's clipboard.
        let doomed = try XCTUnwrap(b.recorder.items.first { $0.entry.content == "delete me" })
        b.engine.deleteItem(id: doomed.id)
        wait("B deleted it") { b.recorder.items.map(\.entry.content) == ["keep"] }
        XCTAssertTrue(DeletedStore(directory: b.dir).contains(doomed.entry), "tombstone persisted")

        // A resends both in its history_batch; "after delete" follows on the
        // same link, so once it's here the batch has been handled.
        reconnect(b, to: a)
        a.engine.sendText("after delete")
        wait("B got the new item") { b.recorder.items.contains { $0.entry.content == "after delete" } }
        XCTAssertEqual(b.recorder.items.map(\.entry.content), ["after delete", "keep"], "the deleted item stays deleted")
        XCTAssertFalse(b.recorder.receivedEntries.dropFirst().contains { $0.0.content == "delete me" }, "never re-applied")
        wait("A kept everything (deleting is local only)") { a.recorder.items.count == 3 }

        // Clear everything on B, then the same again.
        b.engine.clearHistory()
        wait("B cleared") { b.recorder.items.isEmpty }
        reconnect(b, to: a)
        a.engine.sendText("after clear")
        wait("B got the newest item") { b.recorder.items.contains { $0.entry.content == "after clear" } }
        XCTAssertEqual(b.recorder.items.map(\.entry.content), ["after clear"], "nothing cleared came back")
        wait("A kept everything") { a.recorder.items.count == 4 }
    }

    func testManualPairingNeedsAcceptOnBothSides() throws {
        let (a, b) = makePair()
        a.engine.setDeviceName("Alpha")
        b.engine.setDeviceName("Bravo")
        a.engine.enterForeground()
        b.engine.enterForeground()
        a.engine.setPairingOpen(true)
        b.engine.setPairingOpen(true)

        // Whoever has the larger id dials on the pairing beacon; the other gets
        // the same prompt from the inbound handshake.
        wait("both prompted") { a.recorder.pairingRequest != nil && b.recorder.pairingRequest != nil }
        XCTAssertEqual(a.recorder.pairingRequest?.deviceId, b.engine.ownId)
        XCTAssertEqual(b.recorder.pairingRequest?.deviceId, a.engine.ownId)
        XCTAssertEqual(a.recorder.pairingRequest?.name, "Bravo", "the prompt can name the peer (handshake DeviceName)")
        XCTAssertEqual(b.recorder.pairingRequest?.name, "Alpha")
        XCTAssertEqual(a.recorder.connectedCount, 0, "nothing flows before Accept")

        a.engine.acceptPairing()
        b.engine.acceptPairing()
        wait("connected") { a.recorder.connectedCount == 1 && b.recorder.connectedCount == 1 }
        // Accept trusts it nameless; the name follows once the link decrypts
        // B's first line (its history batch).
        wait("stored with the trust record") { TrustStore(directory: a.dir).device(b.engine.ownId)?.name == "Bravo" }

        b.engine.sendText("paired!")
        wait("A received") { a.recorder.receivedEntries.contains { $0.0.content == "paired!" } }
    }

    func testDeviceNamesTravelInBeaconsAndHandshakes() throws {
        let (a, b) = makePair()
        a.engine.setSystemDeviceName("iPhone")
        b.engine.setDeviceName("  Colour's PC  ")
        setPasscode(a, "pw")
        setPasscode(b, "pw")
        a.engine.enterForeground()
        b.engine.enterForeground()
        wait("connected") { a.recorder.connectedCount == 1 && b.recorder.connectedCount == 1 }

        func name(_ node: Node, of other: Node) -> String? {
            node.recorder.devices.first { $0.deviceId == other.engine.ownId }?.name
        }
        wait("A shows B's name") { name(a, of: b) == "Colour's PC" }
        wait("B shows A's OS default name") { name(b, of: a) == "iPhone" }
        wait("A stored it") { TrustStore(directory: a.dir).device(b.engine.ownId)?.name == "Colour's PC" }
        wait("B stored it") { TrustStore(directory: b.dir).device(a.engine.ownId)?.name == "iPhone" }

        // A rename goes out in the very next beacon, but beacons are
        // unauthenticated: it's heard, yet a paired device keeps the name its
        // handshake stored - on screen and on disk - until the next handshake.
        func heard(_ node: Node, from other: Node) -> String? {
            node.engine.queue.sync { node.engine.sightings[other.engine.ownId]?.name }
        }
        func shownNow(_ node: Node, of other: Node) -> String? {
            node.engine.queue.sync { node.engine.buildSnapshot().devices.first(where: { $0.deviceId == other.engine.ownId })?.name }
        }
        b.engine.setDeviceName("Studio PC")
        a.engine.setDeviceName("Desk iPhone")
        wait("A heard B's rename") { heard(a, from: b) == "Studio PC" }
        wait("B heard A's rename") { heard(b, from: a) == "Desk iPhone" }
        XCTAssertEqual(shownNow(a, of: b), "Colour's PC", "a beacon never overrides a stored name")
        XCTAssertEqual(shownNow(b, of: a), "iPhone")
        XCTAssertEqual(TrustStore(directory: a.dir).device(b.engine.ownId)?.name, "Colour's PC", "nor is it stored")
        XCTAssertEqual(a.recorder.connectedCount, 1, "renames never drop the link")

        // The next handshake carries the new names, stored once the new link
        // decrypts its first line.
        reconnect(b, to: a)
        wait("A shows B's new name") { name(a, of: b) == "Studio PC" }
        wait("B shows A's new name") { name(b, of: a) == "Desk iPhone" }
        XCTAssertEqual(TrustStore(directory: a.dir).device(b.engine.ownId)?.name, "Studio PC")
        XCTAssertEqual(TrustStore(directory: b.dir).device(a.engine.ownId)?.name, "Desk iPhone")

        // A local nickname still wins; clearing the setting falls back to the OS name.
        a.engine.setNickname("My PC", for: b.engine.ownId)
        wait("nickname wins") { name(a, of: b) == "My PC" }
        a.engine.setDeviceName("")
        let beacon = a.engine.queue.sync { Beacon.parse(String(decoding: a.engine.currentBeacon(), as: UTF8.self), senderIP: "127.0.0.1") }
        XCTAssertEqual(beacon?.name, "iPhone")
    }

    /// Beacons are unauthenticated UDP: the name one carries is only ever
    /// shown - for a stranger, or a paired device with no stored name yet -
    /// never written to disk, and never shown over a name a handshake stored.
    func testBeaconNamesAreShownButNeverStored() throws {
        let (a, _) = makePair()
        setPasscode(a, "pw")
        let trustFile = a.dir.appendingPathComponent("trusted_devices.json")
        func hear(_ id: String, _ name: String?, proof: String? = nil) {
            let beacon = Beacon(tcpPort: 9, deviceId: id, proof: proof, address: nil, pairing: false, name: name, senderIP: "127.0.0.1")
            a.engine.queue.sync { a.engine.onBeacon(beacon) }
        }
        // The Devices row, then the label prompts, toasts and history use.
        func shown(_ id: String) -> [String?] {
            a.engine.queue.sync { () -> [String?] in
                let snapshot = a.engine.buildSnapshot()
                return [snapshot.devices.first(where: { $0.deviceId == id })?.name, snapshot.deviceNames[id]]
            }
        }
        func stored(_ id: String) -> String? { TrustStore(directory: a.dir).device(id)?.name }
        func stamp() -> Date? { (try? FileManager.default.attributesOfItem(atPath: trustFile.path))?[.modificationDate] as? Date }

        // A stranger nearby: shown by its beacon name, and nothing more.
        let stranger = SoftwareIdentity().publicKeyBase64
        hear(stranger, "Kitchen iPad")
        XCTAssertEqual(shown(stranger), ["Kitchen iPad", "Kitchen iPad"])
        XCTAssertNil(TrustStore(directory: a.dir).device(stranger))

        // Paired, with the name its handshake stored: beacons with that name
        // or another change nothing on screen or on disk.
        let desk = SoftwareIdentity().publicKeyBase64
        a.engine.queue.sync { a.engine.trust.trust(desk, address: "127.0.0.1", name: "Desk PC") }
        let before = try Data(contentsOf: trustFile)
        let written = stamp()
        for name in ["Desk PC", "Evil PC", "Desk PC", "Evil PC"] { hear(desk, name) }
        XCTAssertEqual(shown(desk), ["Desk PC", "Desk PC"], "a beacon never overrides a stored name")
        XCTAssertEqual(try Data(contentsOf: trustFile), before)
        XCTAssertEqual(stamp(), written, "no disk write for a beacon name")

        // Paired by its beacon's passcode proof, before any handshake: the
        // beacon's name is shown while none is stored, but isn't stored.
        let laptop = SoftwareIdentity().publicKeyBase64
        let proof = PassphraseAuth.proof(key: PassphraseAuth.deriveKey(passphrase: "pw"), deviceId: laptop)
        hear(laptop, "Travel Mac", proof: proof)
        XCTAssertTrue(a.engine.queue.sync { a.engine.trust.isTrusted(laptop) }, "auto-trusted by the proof")
        XCTAssertNil(stored(laptop), "nameless until a connection to it decrypts a line")
        XCTAssertEqual(shown(laptop), ["Travel Mac", "Travel Mac"])
        let paired = stamp()
        hear(laptop, "Other Mac", proof: proof)
        XCTAssertEqual(shown(laptop), ["Other Mac", "Other Mac"])
        XCTAssertNil(stored(laptop))
        XCTAssertEqual(stamp(), paired, "no disk write for a beacon name")
        XCTAssertEqual(stored(desk), "Desk PC")
    }

    /// The handshake signature covers only the ephemeral key, so a captured
    /// handshake from a paired device can be replayed with any DeviceName -
    /// but the replayer can never produce a line under the session key. The
    /// name is shown for that connection at once and stored only once the
    /// connection decrypts a line. Passcode pairing trusts it nameless.
    func testHandshakeNameIsStoredOnlyOnceTheLinkDecryptsALine() throws {
        let (a, _) = makePair()
        setPasscode(a, "pw")
        a.engine.enterForeground()
        wait("A listening") { a.engine.queue.sync { a.engine.status.listening } }

        let peer = SoftwareIdentity()
        let peerId = peer.publicKeyBase64
        let passcode = PassphraseAuth.deriveKey(passphrase: "pw")
        func stored() -> String? { TrustStore(directory: a.dir).device(peerId)?.name }
        func shown() -> String? { a.engine.queue.sync { a.engine.buildSnapshot().deviceNames[peerId] } }
        func connect(as name: String) throws -> PeerLink {
            let link = try handshake(with: a, as: peer, named: name, passcode: passcode)
            wait("A registered \(name)") { a.recorder.connectedCount == 1 }
            return link
        }
        func hangUp(_ link: PeerLink) {
            link.close()
            wait("A dropped it") { a.recorder.connectedCount == 0 }
        }

        // First contact, by passcode, on a link that never sends a line - all
        // a replayed handshake can do: trusted and shown by name, none stored.
        let silent = try connect(as: "Evil PC")
        XCTAssertTrue(TrustStore(directory: a.dir).isTrusted(peerId), "auto-paired by the passcode")
        XCTAssertEqual(shown(), "Evil PC", "shown for the connection at once")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNil(stored(), "never stored without a decrypted line")
        hangUp(silent)
        XCTAssertNil(stored())
        XCTAssertNil(shown(), "nor shown once that connection is gone")

        // The real device: its first line (the history batch every peer sends
        // at once) proves it holds the session key, and the name is stored.
        let real = try connect(as: "Desk PC")
        real.goLive()
        real.send(Envelope(type: Wire.MessageType.historyBatch, payload: "[]").jsonString())
        wait("stored once the link decrypted a line") { stored() == "Desk PC" }
        XCTAssertEqual(shown(), "Desk PC")
        hangUp(real)

        // A replay against the stored name: never shown over it, never stored.
        let replayed = try connect(as: "Evil PC")
        XCTAssertEqual(shown(), "Desk PC", "a stored name wins over an unproven one")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(stored(), "Desk PC")
        hangUp(replayed)
    }

    /// One key covers both directions, so a replayer that can't make a line
    /// can still send A's own lines back: the history batch at once, then
    /// every ping. An echo proves nothing - A drops the link at the first
    /// one, stores and keeps no name from it, and a working link to the same
    /// device stays.
    func testEchoedLinesNeverProveAReplayedHandshake() throws {
        let (a, _) = makePair()
        setPasscode(a, "pw")
        a.engine.enterForeground()
        wait("A listening") { a.engine.queue.sync { a.engine.status.listening } }

        let peer = SoftwareIdentity()
        let peerId = peer.publicKeyBase64
        let passcode = PassphraseAuth.deriveKey(passphrase: "pw")
        func stored() -> String? { TrustStore(directory: a.dir).device(peerId)?.name }
        func shown() -> String? { a.engine.queue.sync { a.engine.buildSnapshot().deviceNames[peerId] } }
        func heard() -> String? { a.engine.queue.sync { a.engine.sightings[peerId]?.name } }
        func live() -> PeerLink? { a.engine.queue.sync { a.engine.links[peerId] } }
        /// A handshake line `peer` really sent, as a replayer holds it: the
        /// ephemeral key's private half long gone, the name edited.
        func replay(as name: String) throws -> Reflector {
            let ephemeral = P256.KeyAgreement.PrivateKey().publicKey.derRepresentation
            let signature = try peer.sign(ephemeral)
            let line = HandshakeMessage(
                ephemeralPublicKey: ephemeral.base64EncodedString(),
                identityPublicKey: peerId,
                signature: signature.base64EncodedString(),
                passphraseProof: PassphraseAuth.proof(key: passcode, deviceId: peerId),
                deviceName: name
            ).jsonString()
            return Reflector(port: a.engine.config.listenPort, handshake: line)
        }

        // First contact, trusted by the passcode proof the line carries.
        let first = try replay(as: "Evil PC")
        wait("A dropped the echoing link") { first.closed }
        wait("A let its name go") { heard() == nil }
        XCTAssertGreaterThan(first.echoed, 0, "dropped for an echo")
        XCTAssertNil(live())
        XCTAssertNil(stored(), "an echo proves nothing")
        XCTAssertNil(shown())
        first.close()

        // The real device: A decrypts its first line, stores its name, and
        // has a working link to it.
        let real = try handshake(with: a, as: peer, named: "Desk PC", passcode: passcode)
        real.goLive()
        real.send(Envelope(type: Wire.MessageType.historyBatch, payload: "[]").jsonString())
        wait("stored once the link decrypted a line") { stored() == "Desk PC" }
        let working = try XCTUnwrap(live())
        XCTAssertTrue(working.hasReceivedSessionLine)

        // A replay while it's up: dropped at its first echo, and the working
        // link is never replaced.
        let second = try replay(as: "Evil PC")
        wait("A dropped the echoing link") { second.closed }
        wait("A let its name go") { heard() == nil }
        XCTAssertGreaterThan(second.echoed, 0, "dropped for an echo")
        XCTAssertTrue(live() === working, "the working link stays")
        XCTAssertFalse(real.isClosed)
        XCTAssertEqual(stored(), "Desk PC")
        XCTAssertEqual(shown(), "Desk PC")
        second.close()
        real.close()
    }

    /// Completes a handshake with `node` as `peer`, calling itself `name`. This
    /// side of the link stays held - it sends nothing - until it goes live.
    private func handshake(with node: Node, as peer: SoftwareIdentity, named name: String, passcode: Data) throws -> PeerLink {
        let context = HandshakeContext(identity: peer, trusted: [node.engine.ownId], passphraseKey: passcode, pairingOpen: false, deviceName: name)
        let done = expectation(description: "handshake as \(name)")
        var link: PeerLink?
        PeerLink.dial(host: "127.0.0.1", port: node.engine.config.listenPort, context: context, connectTimeout: 3,
                      maxLineBytes: 1 << 20, deliveryQueue: .main, gate: { _ in true }) { result in
            if case .success(let l) = result { link = l } else { XCTFail("handshake as \(name): \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(link)
    }

    func testUntrustedPeerIsRefusedWithoutPairingOrPasscode() throws {
        let (a, b) = makePair()
        a.engine.enterForeground()
        b.engine.enterForeground()
        // Unilateral trust on A only: B must refuse (pairing closed, no passcode).
        a.engine.trustDevice(b.engine.ownId)
        let outcome = expectation(description: "pair outcome")
        var result: PairOutcome?
        a.engine.pair(with: PairingInfo(publicKey: b.engine.ownId, address: "127.0.0.1:\(b.engine.config.listenPort)").address!) { o in
            result = o
            outcome.fulfill()
        }
        wait(for: [outcome], timeout: 15)
        if case .refused = result {} else { XCTFail("expected refused, got \(String(describing: result))") }
        XCTAssertEqual(b.recorder.connectedCount, 0)
    }

    func testBackgroundRefreshCatchesUpThenTearsDown() throws {
        let (a, b) = makePair()
        setPasscode(a, "pw")
        setPasscode(b, "pw")
        a.engine.enterForeground()
        a.engine.sendText("copied on the PC while the phone was asleep")
        wait("A has it") { a.recorder.items.count == 1 }

        let done = expectation(description: "background round")
        var got: [ClipboardEntry] = []
        b.engine.runBackgroundSync(budget: 20) { entries in
            got = entries
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(got.map(\.content), ["copied on the PC while the phone was asleep"])
        XCTAssertEqual(b.recorder.items.count, 1)
        wait("B tore down") { !b.recorder.running && a.recorder.connectedCount == 0 }
    }

    /// The Share extension is a second process running its own engine over
    /// the SAME storage and identity as the app (App Group + shared Keychain).
    func testShareExtensionItemReachesAppHistoryAndLatePeers() throws {
        let (app, peer) = makePair()
        setPasscode(app, "pw")
        setPasscode(peer, "pw")
        app.engine.enterForeground()
        // App goes to the background (its sockets close) ...
        let backgrounded = expectation(description: "backgrounded")
        app.engine.enterBackground(grace: 0) { backgrounded.fulfill() }
        wait(for: [backgrounded], timeout: 10)

        // ... and the user shares something: the extension's own engine.
        var extConfig = app.engine.config
        extConfig.logSink = nil
        let ext = SyncEngine(config: extConfig, identity: app.engine.identity, secrets: app.engine.secrets)
        let extRecorder = Recorder()
        ext.delegate = extRecorder
        ext.enterForeground()
        let sent = expectation(description: "shared")
        ext.sendText("shared from Safari") { _ in sent.fulfill() }
        wait(for: [sent], timeout: 10)
        let finished = expectation(description: "extension finished")
        ext.finish(grace: 2) { finished.fulfill() }
        wait(for: [finished], timeout: 10)

        // Back in the app: the shared item is in its history ...
        app.engine.enterForeground()
        wait("app sees the shared item") { app.recorder.items.contains { $0.entry.content == "shared from Safari" } }
        XCTAssertEqual(app.recorder.items.first { $0.entry.content == "shared from Safari" }?.isOwn, true)

        // ... and a peer that only shows up now still gets it (history_batch).
        peer.engine.enterForeground()
        wait("peer got it") { peer.recorder.items.contains { $0.entry.content == "shared from Safari" } }
    }

    /// App live (iPad side by side) + Share extension: the extension doesn't
    /// start a second node; it stores the item and pings, and the app's live
    /// node sends it straight away.
    func testShareExtensionHandsOffToLiveApp() throws {
        let (app, peer) = makePair()
        setPasscode(app, "pw")
        setPasscode(peer, "pw")
        app.engine.enterForeground()
        peer.engine.enterForeground()
        wait("connected") { app.recorder.connectedCount == 1 && peer.recorder.connectedCount == 1 }

        let ext = SyncEngine(config: app.engine.config, identity: app.engine.identity, secrets: app.engine.secrets)
        let stored = expectation(description: "stored")
        ext.sendText("shared while the app is open") { _ in stored.fulfill() }
        wait(for: [stored], timeout: 10)
        SyncEngine.announceExternalChange()

        wait("peer got it live") { peer.recorder.receivedEntries.contains { $0.0.content == "shared while the app is open" } }
        wait("app lists it") { app.recorder.items.contains { $0.entry.content == "shared while the app is open" } }
        ext.shutdown()
    }

    /// The Share extension's node drops file bytes, so it must never ask for
    /// any - not even the blobs missing from the history it shares with the
    /// app: the peer would stream each whole file for nothing.
    func testShareExtensionNeverAsksForFileBytes() throws {
        let (app, peer) = makePair()
        setPasscode(app, "pw")
        setPasscode(peer, "pw")
        app.engine.enterForeground()
        peer.engine.enterForeground()
        wait("connected") { app.recorder.connectedCount == 1 && peer.recorder.connectedCount == 1 }

        // The app has the peer's file in its history but not its bytes (as
        // after a download cut short).
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 4096).write(to: source)
        peer.engine.sendFile(at: source, name: "notes.bin", moveIntoStore: false)
        wait("app got the file") { app.recorder.receivedEntries.contains { $0.0.type == "file" && $0.1 != nil } }
        let entry = try XCTUnwrap(app.recorder.receivedEntries.first { $0.0.type == "file" }?.0)
        let payload = try XCTUnwrap(FilePayload.parse(entry.content))
        let backgrounded = expectation(description: "backgrounded")
        app.engine.enterBackground(grace: 0) { backgrounded.fulfill() }
        wait(for: [backgrounded], timeout: 10)
        app.engine.files.delete(payload.fileHash)

        var extConfig = app.engine.config
        extConfig.sendOnly = true
        let ext = SyncEngine(config: extConfig, identity: app.engine.identity, secrets: app.engine.secrets)
        let extRecorder = Recorder()
        ext.delegate = extRecorder
        ext.enterForeground()
        // A new link asks for missing blobs as it registers, before it counts
        // as connected.
        wait("extension connected", timeout: 30) { extRecorder.connectedCount == 1 }
        XCTAssertTrue(ext.queue.sync { ext.requestedAt.isEmpty }, "no file_request from a sender only")
        XCTAssertFalse(ext.files.exists(payload.fileHash))
        ext.shutdown()
    }
}

/// A replayer's socket: writes a handshake line, then sends back every line
/// it's sent after the acceptor's handshake - all it can do with lines under
/// a key it doesn't hold.
private final class Reflector {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.reflector")
    private let lock = NSLock()
    private var buffer = Data()
    private var sawHandshake = false
    private var echoCount = 0
    private var ended = false

    var echoed: Int { lock.lock(); defer { lock.unlock() }; return echoCount }
    /// The far side hung up.
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    init(port: UInt16, handshake: String) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connection.send(content: Data((handshake + "\n").utf8), completion: .contentProcessed { _ in })
                self.receive()
            case .failed, .cancelled:
                self.markEnded()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let next = self.buffer.index(after: newline)
                let line = Data(self.buffer[..<next])
                self.buffer = Data(self.buffer[next...])
                if self.sawHandshake {
                    self.lock.lock(); self.echoCount += 1; self.lock.unlock()
                    self.connection.send(content: line, completion: .contentProcessed { _ in })
                } else {
                    self.sawHandshake = true
                }
            }
            if isComplete || error != nil { self.markEnded() } else { self.receive() }
        }
    }

    private func markEnded() {
        lock.lock(); ended = true; lock.unlock()
    }
}
