import XCTest
@testable import ClipLinkCore

/// Two complete engines talking over real sockets on loopback: discovery
/// beacons, handshake, trust, sync, history catch-up and file streaming.
final class EngineIntegrationTests: XCTestCase {

    final class Recorder: SyncEngineDelegate {
        private let lock = NSLock()
        private(set) var snapshot = EngineSnapshot()
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
        wait("A shows the passcode off") { !a.recorder.snapshot.hasPassphrase }
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
        XCTAssertEqual(TrustStore(directory: a.dir).device(b.engine.ownId)?.name, "Bravo", "stored with the trust record")

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

        // A rename reaches the peer with the next beacon - no reconnect.
        b.engine.setDeviceName("Studio PC")
        wait("A sees the rename") { name(a, of: b) == "Studio PC" }
        wait("A stored the rename") { TrustStore(directory: a.dir).device(b.engine.ownId)?.name == "Studio PC" }

        // A local nickname still wins; clearing the setting falls back to the OS name.
        a.engine.setNickname("My PC", for: b.engine.ownId)
        wait("nickname wins") { name(a, of: b) == "My PC" }
        a.engine.setDeviceName("Desk iPhone")
        wait("B sees A's setting") { name(b, of: a) == "Desk iPhone" }
        a.engine.setDeviceName("")
        wait("B sees A's OS name again") { name(b, of: a) == "iPhone" }
        XCTAssertEqual(a.recorder.connectedCount, 1, "renames never drop the link")
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
        wait("B tore down") { b.recorder.snapshot.network.running == false && a.recorder.connectedCount == 0 }
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
