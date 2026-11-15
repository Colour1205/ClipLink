import XCTest
@testable import ClipLinkCore

/// What this device keeps on disk and in memory, and what it leaves alone when
/// it can't keep it: big pictures out of history.json (local only - on the wire
/// every picture still goes inline, whole), stores re-read only when their file
/// changed, files that don't fit in the free space, the Share extension's
/// version 1 batch, and what the list works out once per entry.
final class LocalFootprintTests: XCTestCase {

    private var directories: [URL] = []
    private var engines: [SyncEngine] = []

    override func tearDown() {
        engines.forEach { $0.shutdown() }
        engines.removeAll()
        Thread.sleep(forTimeInterval: 0.1)
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-footprint-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        return dir
    }

    private func makeEngine(_ dir: URL, identity: IdentitySigner = SoftwareIdentity(), sendOnly: Bool = false) -> SyncEngine {
        var config = EngineConfig(storageDirectory: dir)
        config.sendOnly = sendOnly
        let engine = SyncEngine(config: config, identity: identity, secrets: MemorySecretStore())
        engines.append(engine)
        return engine
    }

    private func at(_ seconds: TimeInterval) -> String {
        DotNetTimestamp.now(Date(timeIntervalSince1970: seconds))
    }

    /// A signed picture whose base64 (40,000 characters) is over HistoryStore.inlineLimit.
    private func bigPicture(by signer: IdentitySigner, at seconds: TimeInterval = 1_790_000_000, seed: Int = 1) throws -> ClipboardEntry {
        let bytes = Data((0..<30_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) })
        return try EntrySigning.sign(content: bytes.base64EncodedString(), type: Wire.EntryType.image, identity: signer, timestamp: at(seconds))
    }

    private func savedHistory(_ dir: URL) throws -> [[String: Any]] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("history.json"))) as? [[String: Any]])
    }

    // MARK: - Big pictures, kept out of history.json

    func testABigPictureIsKeptInAFileOfItsOwnAndComesBackExactlyAsSigned() throws {
        let dir = makeDirectory()
        let files = FileStore(directory: dir)
        let store = HistoryStore(directory: dir, fileStore: files)
        let peer = SoftwareIdentity()
        let picture = try bigPicture(by: peer)
        let small = try EntrySigning.sign(content: Data([1, 2, 3]).base64EncodedString(), type: Wire.EntryType.image, identity: peer, timestamp: at(1_790_000_001))
        let unsigned = ClipboardEntry(content: picture.content, type: Wire.EntryType.image, deviceId: "d", timestamp: at(1_790_000_002))
        store.add(contentsOf: [picture, small, unsigned])

        let kept = store.entries[0]
        XCTAssertEqual(kept.content, "", "held without its bytes")
        XCTAssertEqual(HistoryStore.identity(of: kept), HistoryStore.identity(of: picture))
        XCTAssertEqual(store.withContent(kept), picture, "and sent exactly as it was signed")
        XCTAssertNotNil(EntrySigning.verified(try XCTUnwrap(store.withContent(kept))))
        XCTAssertEqual(store.contentKey(of: kept), ContentPrint.key(of: picture), "its print without reading it back")
        let url = try XCTUnwrap(store.inlineURL(for: kept))
        XCTAssertEqual(url.lastPathComponent, FileStore.key(ContentHash.sha256Hex(Data(picture.content.utf8))))
        XCTAssertEqual(try Data(contentsOf: url), Data(picture.content.utf8))
        XCTAssertEqual(store.entries[1], small, "a small picture stays inline")
        XCTAssertEqual(store.entries[2], unsigned, "so does an unsigned one: its tombstone is made from its content")
        XCTAssertNil(store.inlineURL(for: small))
        XCTAssertEqual(store.withContent(store.entries), [picture, small, unsigned])

        let saved = try savedHistory(dir)
        XCTAssertEqual(saved[0]["Content"] as? String, "")
        let ref = try XCTUnwrap(saved[0]["ContentRef"] as? [String: Any])
        XCTAssertEqual(ref["Length"] as? Int, 40_000)
        XCTAssertNil(saved[1]["ContentRef"])

        // Another process (or a restart) reads it the same way.
        let reopened = HistoryStore(directory: dir, fileStore: FileStore(directory: dir))
        XCTAssertEqual(reopened.withContent(reopened.entries), [picture, small, unsigned])

        // Trimmed by the 25-item cap: its file goes with it.
        store.add(contentsOf: try (0..<Wire.historyCap).map {
            try EntrySigning.sign(content: "t\($0)", type: Wire.EntryType.text, identity: peer, timestamp: at(1_800_000_000 + TimeInterval($0)))
        })
        XCTAssertFalse(store.contains(picture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAHistoryAnOlderBuildWroteWithItsPicturesInlineLoadsAndMovesThemOutOnce() throws {
        let dir = makeDirectory()
        let peer = SoftwareIdentity()
        let picture = try bigPicture(by: peer)
        let text = try EntrySigning.sign(content: "hello", type: Wire.EntryType.text, identity: peer, timestamp: at(1_790_000_001))
        let historyFile = dir.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: [picture.jsonObject(), text.jsonObject()]).write(to: historyFile)

        let store = HistoryStore(directory: dir, fileStore: FileStore(directory: dir))
        XCTAssertEqual(store.entries, [picture, text], "read as it is")
        XCTAssertGreaterThan(try Data(contentsOf: historyFile).count, 40_000)

        store.moveBigPicturesOut()
        XCTAssertEqual(store.entries.map(\.content), ["", "hello"])
        XCTAssertEqual(store.withContent(store.entries), [picture, text])
        XCTAssertLessThan(try Data(contentsOf: historyFile).count, 2_000)

        // Nothing left to move: no write.
        let written = try FileManager.default.attributesOfItem(atPath: historyFile.path)[.modificationDate] as? Date
        store.moveBigPicturesOut()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: historyFile.path)[.modificationDate] as? Date, written)
    }

    func testAnEntryWhosePictureFileIsGoneIsLeftOutAndStrayFilesGoOnceOldEnough() throws {
        let dir = makeDirectory()
        let files = FileStore(directory: dir)
        let store = HistoryStore(directory: dir, fileStore: files)
        let peer = SoftwareIdentity()
        let lost = try bigPicture(by: peer, at: 1_790_000_000, seed: 1)
        let kept = try bigPicture(by: peer, at: 1_790_000_001, seed: 2)
        store.add(contentsOf: [lost, kept])
        try FileManager.default.removeItem(at: try XCTUnwrap(store.inlineURL(for: store.entries[0])))

        let reopened = HistoryStore(directory: dir, fileStore: files)
        XCTAssertEqual(reopened.withContent(reopened.entries), [kept], "it could be neither shown nor sent")

        // A file no saved history names - a process died between the two writes.
        let stray = files.inlineURL(for: String(repeating: "a", count: 64))
        try Data("x".utf8).write(to: stray)
        files.removeInline(keeping: reopened.inlineHashes, olderThan: 60)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "too new: the other process may be about to save the history naming it")
        files.removeInline(keeping: reopened.inlineHashes, olderThan: -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reopened.inlineURL(for: reopened.entries[0])).path))
    }

    func testTheShareExtensionSendsAVersion1PeerOnlyWhatItStoredAndTheAppSendsEverythingWhole() throws {
        let dir = makeDirectory()
        let identity = SoftwareIdentity()
        let app = makeEngine(dir, identity: identity)
        let picture = try bigPicture(by: identity)
        app.queue.sync { _ = app.history.add(picture) }

        let ext = makeEngine(dir, identity: identity, sendOnly: true)
        let shared = expectation(description: "shared")
        ext.sendText("shared") { _ in shared.fulfill() }
        wait(for: [shared], timeout: 5)

        XCTAssertEqual(ext.queue.sync { ext.historyBatchEntries() }.map(\.content), ["shared"])
        let everything = app.queue.sync { () -> [ClipboardEntry] in
            app.history.reload()
            return app.historyBatchEntries()
        }
        XCTAssertEqual(everything.map(\.content), ["shared", picture.content], "newest first, the picture inline")
    }

    // MARK: - Stores re-read only what changed

    func testAStoreReReadsItsFileOnlyWhenItsDateOrSizeChanged() throws {
        let dir = makeDirectory()
        let files = FileStore(directory: dir)
        let app = HistoryStore(directory: dir, fileStore: files)
        let ext = HistoryStore(directory: dir, fileStore: files)
        let peer = SoftwareIdentity()
        let first = try EntrySigning.sign(content: "first", type: Wire.EntryType.text, identity: peer, timestamp: at(1_790_000_000))
        ext.add(first)
        let historyFile = dir.appendingPathComponent("history.json")
        // A whole second: the date reads back exactly.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: historyFile.path)
        app.reload()
        XCTAssertEqual(app.entries, [first], "the other process's write is seen")

        // Other bytes, same length and date: as far as the stamp tells, unchanged.
        let original = String(decoding: try Data(contentsOf: historyFile), as: UTF8.self)
        try Data(original.replacingOccurrences(of: "\"first\"", with: "\"FIRST\"").utf8).write(to: historyFile)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: historyFile.path)
        app.reload()
        XCTAssertEqual(app.entries.map(\.content), ["first"], "not read again")

        // A different size is a change, whatever the date says.
        try Data(original.replacingOccurrences(of: "\"first\"", with: "\"first!\"").utf8).write(to: historyFile)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: historyFile.path)
        app.reload()
        XCTAssertEqual(app.entries.map(\.content), ["first!"])
    }

    // MARK: - Files that don't fit

    func testAFileThatDoesNotFitIsNotFetchedUntilThereMayBeRoom() throws {
        let engine = makeEngine(makeDirectory())
        let peer = SoftwareIdentity()
        engine.trust.trust(peer.publicKeyBase64)
        let payload = FilePayload(fileName: "big.bin", fileHash: String(repeating: "ab", count: 32), fileSize: 100 * 1024 * 1024)
        let entry = try EntrySigning.sign(content: payload.jsonString(), type: Wire.EntryType.file, identity: peer)
        let key = FileStore.key(payload.fileHash)
        let mb: Int64 = 1024 * 1024

        let room: [Bool] = engine.queue.sync {
            engine.history.add(entry)
            engine.received(entry, apply: false)
            var answers: [Bool] = []
            for free in [131 * mb, 132 * mb, 0] {
                engine.capacityOverride = free
                answers.append(engine.hasRoom(for: key))
            }
            engine.noteNeedsSpace(key)
            return answers
        }
        XCTAssertEqual(room, [false, true, true], "100 MB and 32 MB to spare; a volume that says nothing stops nothing")
        var item = try XCTUnwrap(engine.queue.sync { engine.buildSnapshot() }.items.first)
        XCTAssertTrue(item.needsSpace)
        XCTAssertFalse(item.fileAvailable)

        // Back in the foreground: asked for again, its free space checked first.
        engine.queue.sync { engine.retryFilesThatNeededSpace() }
        item = try XCTUnwrap(engine.queue.sync { engine.buildSnapshot() }.items.first)
        XCTAssertFalse(item.needsSpace)
    }

    // MARK: - What the list works out once per entry

    func testOnlyALongTokenOfPlainCharactersIsOpaque() {
        func kind(_ text: String) -> SyncedItem.Kind {
            SyncedItem.kind(for: ClipboardEntry(content: text, type: Wire.EntryType.text, deviceId: "d", timestamp: ""))
        }
        XCTAssertEqual(kind(String(repeating: "A", count: 40)), .opaque)
        XCTAssertEqual(kind("\n " + String(repeating: "x9+/=_-", count: 6) + "\n"), .opaque, "trimmed first")
        XCTAssertEqual(kind(String(repeating: "A", count: 39)), .text)
        XCTAssertEqual(kind(String(repeating: "é", count: 40)), .text, "not ASCII")
        XCTAssertEqual(kind(String(repeating: "A", count: 20) + " " + String(repeating: "A", count: 20)), .text)
        XCTAssertEqual(kind("https://example.com/" + String(repeating: "A", count: 40)), .link)
    }

    func testTheListShowsTheSameOnceAnEntrysFactsAreRememberedAndForgetsThemWithIt() throws {
        let engine = makeEngine(makeDirectory())
        let peer = SoftwareIdentity()
        let older = try EntrySigning.sign(content: String(repeating: "k", count: 48), type: Wire.EntryType.text, identity: peer, timestamp: at(1_790_000_000))
        let newer = try EntrySigning.sign(content: "hello", type: Wire.EntryType.text, identity: peer, timestamp: at(1_790_000_001))
        engine.queue.sync { _ = engine.history.add(contentsOf: [older, newer]) }
        let first = engine.queue.sync { engine.buildSnapshot() }
        let again = engine.queue.sync { engine.buildSnapshot() }
        XCTAssertEqual(first.items, again.items)
        XCTAssertEqual(first.items.map(\.kind), [.text, .opaque])
        XCTAssertEqual(first.items.map(\.entry), [newer, older], "newest first")
        XCTAssertEqual(first.items.last?.date, Date(timeIntervalSince1970: 1_790_000_000))

        // An entry that left the history is forgotten with it.
        engine.queue.sync { engine.history.remove(identity: HistoryStore.identity(of: older)) }
        let after = engine.queue.sync { engine.buildSnapshot() }
        XCTAssertEqual(after.items.map(\.entry), [newer])
        XCTAssertEqual(engine.queue.sync { engine.entryFacts.count }, 1)
    }
}
