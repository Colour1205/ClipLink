import XCTest
@testable import ClipLinkCore

/// history_head: the small message in front of a big history_batch. It carries
/// the sender's newest entry and every key of the batch, so the receiver shows
/// the stack at once (provisional group) and fills it in when the batch arrives.
/// The first part needs no engine; the rest drive one engine's
/// `applyHistoryHead` and `applyHistoryBatch` directly, without sockets. The
/// real wire order is checked in EngineIntegrationTests.
final class HistoryHeadTests: XCTestCase {

    // MARK: - Wire format

    private func signedEntries(count: Int, from peer: IdentitySigner = SoftwareIdentity(), start: TimeInterval = 1_790_000_000, label: String = "item") throws -> [ClipboardEntry] {
        try (0..<count).map { index in
            try EntrySigning.sign(content: "\(label) \(index)", type: Wire.EntryType.text, identity: peer,
                                  timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: start + TimeInterval(index))))
        }
    }

    func testAHeadIsMadeOnlyForTwoOrMoreEntries() throws {
        let entries = try signedEntries(count: 3)
        XCTAssertNil(HistoryHead.make(newestFirst: []))
        XCTAssertNil(HistoryHead.make(newestFirst: Array(entries.prefix(1))))
        XCTAssertNotNil(HistoryHead.make(newestFirst: Array(entries.prefix(2))))
    }

    func testTheHeadHoldsTheNewestEntryAndEveryKeyNewestFirst() throws {
        let newestFirst = Array(try signedEntries(count: 4).reversed())
        let head = try XCTUnwrap(HistoryHead.make(newestFirst: newestFirst))
        XCTAssertEqual(head.newest, newestFirst[0])
        XCTAssertEqual(head.keys, newestFirst.map { $0.signature ?? "" })
        XCTAssertEqual(head.keys.count, 4)
    }

    func testTheHeadIsAnEnvelopeWithAJSONStringPayloadAndPascalCaseKeys() throws {
        let newestFirst = Array(try signedEntries(count: 2).reversed())
        let head = try XCTUnwrap(HistoryHead.make(newestFirst: newestFirst))
        let line = Envelope(type: Wire.MessageType.historyHead, payload: head.jsonString()).jsonString()

        let envelope = try XCTUnwrap(WireJSON.object(line))
        XCTAssertEqual(envelope["Type"] as? String, "history_head")
        let payload = try XCTUnwrap(envelope["Payload"] as? String, "the payload is a JSON string, not a nested object")
        let object = try XCTUnwrap(WireJSON.object(payload))
        XCTAssertEqual(Set(object.keys), ["Newest", "Keys"])
        let newest = try XCTUnwrap(object["Newest"] as? [String: Any])
        XCTAssertEqual(Set(newest.keys), ["Content", "Type", "DeviceId", "Timestamp", "Signature"])
        XCTAssertEqual(object["Keys"] as? [String], newestFirst.map { $0.signature ?? "" })
    }

    func testWhatTheSenderWritesTheReceiverParses() throws {
        let newestFirst = Array(try signedEntries(count: 5).reversed())
        let head = try XCTUnwrap(HistoryHead.make(newestFirst: newestFirst))
        let envelope = try XCTUnwrap(Envelope.parse(Envelope(type: Wire.MessageType.historyHead, payload: head.jsonString()).jsonString()))
        XCTAssertEqual(envelope.type, Wire.MessageType.historyHead)
        let parsed = try XCTUnwrap(HistoryHead.parse(envelope.payload))
        XCTAssertEqual(parsed, head)
        XCTAssertNotNil(EntrySigning.verified(parsed.newest), "the signature survives the trip")
    }

    func testHeadParsingNeedsAWellFormedNewestAndSkipsBadKeys() throws {
        XCTAssertNil(HistoryHead.parse("not json"))
        XCTAssertNil(HistoryHead.parse(#"{"Keys":["a"]}"#), "no Newest")
        XCTAssertNil(HistoryHead.parse(#"{"Newest":"text","Keys":[]}"#), "Newest is not an entry")
        XCTAssertNil(HistoryHead.parse(#"{"Newest":{"Content":"x"},"Keys":[]}"#), "Newest lacks its fields")

        let entry = try XCTUnwrap(try signedEntries(count: 1).first)
        let withBadKeys: [String: Any] = ["Newest": entry.jsonObject(), "Keys": ["a", 7, NSNull(), "b"] as [Any]]
        let json = WireJSON.string(withBadKeys)
        XCTAssertEqual(HistoryHead.parse(json)?.keys, ["a", "b"], "a key that is not a string is skipped")
        let noKeys = WireJSON.string(["Newest": entry.jsonObject()])
        XCTAssertEqual(HistoryHead.parse(noKeys)?.keys, [])
    }

    // MARK: - Tracker

    private let one = NSObject()
    private let two = NSObject()
    private var connectionOne: ObjectIdentifier { ObjectIdentifier(one) }
    private var connectionTwo: ObjectIdentifier { ObjectIdentifier(two) }

    func testAProvisionalGroupNeedsTwoOrMoreExpected() {
        var tracker = BatchGroupTracker()
        XCTAssertNil(tracker.registerProvisional(front: "a", expectedSize: 0, connection: connectionOne))
        XCTAssertNil(tracker.registerProvisional(front: "a", expectedSize: 1, connection: connectionOne))
        XCTAssertTrue(tracker.groups.isEmpty)

        let group = tracker.registerProvisional(front: "a", expectedSize: 5, connection: connectionOne)
        XCTAssertEqual(group?.memberIDs, ["a"])
        XCTAssertEqual(group?.expectedSize, 5)
        XCTAssertEqual(group?.size, 5)
        XCTAssertEqual(group?.isProvisional, true)
    }

    func testTheBatchFillsTheHeadsGroupAndKeepsItsId() {
        var tracker = BatchGroupTracker()
        let provisional = tracker.registerProvisional(front: "a", expectedSize: 4, connection: connectionOne)
        let filled = tracker.registerBatch(["b", "c", "d"], connection: connectionOne)
        XCTAssertEqual(filled?.id, provisional?.id)
        XCTAssertEqual(filled?.memberIDs, ["a", "b", "c", "d"])
        XCTAssertNil(filled?.expectedSize, "the real count shows now")
        XCTAssertEqual(filled?.size, 4)
        XCTAssertEqual(tracker.groups.count, 1)
    }

    func testAGroupLeftWithTooFewMembersDissolves() {
        var tracker = BatchGroupTracker()
        tracker.registerProvisional(front: "a", expectedSize: 4, connection: connectionOne)
        XCTAssertNil(tracker.registerBatch([], connection: connectionOne))
        XCTAssertTrue(tracker.groups.isEmpty, "only the front card is left: a normal card")
    }

    func testABatchWithoutAHeadMakesItsGroupAtBatchTime() {
        var tracker = BatchGroupTracker()
        XCTAssertEqual(tracker.registerBatch(["a", "b"], connection: connectionOne)?.memberIDs, ["a", "b"])
        XCTAssertNil(tracker.registerBatch(["c"], connection: connectionOne))
        XCTAssertEqual(tracker.registerBatch(["d", "e"], connection: nil)?.memberIDs, ["d", "e"])
        XCTAssertEqual(tracker.groups.count, 2)
    }

    func testAHeadBelongsToTheNextBatchOnItsOwnConnectionOnly() {
        var tracker = BatchGroupTracker()
        let first = tracker.registerProvisional(front: "a", expectedSize: 3, connection: connectionOne)
        // Another connection's batch does not touch it.
        let other = tracker.registerBatch(["x", "y"], connection: connectionTwo)
        XCTAssertNotEqual(other?.id, first?.id)
        XCTAssertEqual(tracker.groups.first?.expectedSize, 3)
        // After its own batch, the head is used up: the next batch is an ordinary one.
        tracker.registerBatch(["b", "c"], connection: connectionOne)
        let later = tracker.registerBatch(["p", "q"], connection: connectionOne)
        XCTAssertEqual(later?.memberIDs, ["p", "q"])
    }

    func testASecondHeadFinishesTheFirstGroupFirst() {
        var tracker = BatchGroupTracker()
        let first = tracker.registerProvisional(front: "a", expectedSize: 3, connection: connectionOne)
        let second = tracker.registerProvisional(front: "x", expectedSize: 4, connection: connectionOne)
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(tracker.groups.map(\.id), [second?.id].compactMap { $0 }, "the first one had only its front card: gone")
        XCTAssertEqual(tracker.groups.first?.memberIDs, ["x"])
        // The batch goes to the second head's group.
        XCTAssertEqual(tracker.registerBatch(["y", "z", "w"], connection: connectionOne)?.memberIDs, ["x", "y", "z", "w"])
    }

    func testClosingTheConnectionDropsTheAnnouncedSize() {
        var tracker = BatchGroupTracker()
        tracker.registerProvisional(front: "a", expectedSize: 5, connection: connectionOne)
        XCTAssertTrue(tracker.finish(connection: connectionOne))
        XCTAssertTrue(tracker.groups.isEmpty, "a group with fewer than 2 members dissolves")
        XCTAssertFalse(tracker.finish(connection: connectionOne), "nothing left to finish")
        XCTAssertFalse(tracker.finish(connection: connectionTwo))
    }

    func testAProvisionalGroupSurvivesPruneWithItsFrontCardOnly() {
        var tracker = BatchGroupTracker()
        tracker.registerProvisional(front: "a", expectedSize: 3, connection: connectionOne)
        tracker.prune(keeping: ["a"])
        XCTAssertEqual(tracker.groups.count, 1, "the front card is enough while the rest is on its way")
        tracker.prune(keeping: [])
        XCTAssertTrue(tracker.groups.isEmpty, "but not with the front card gone")
    }

    func testAnOpenedProvisionalGroupStaysOrdinaryWhenTheBatchComes() {
        var tracker = BatchGroupTracker()
        let group = tracker.registerProvisional(front: "a", expectedSize: 3, connection: connectionOne)!
        tracker.dissolve(id: group.id)
        XCTAssertNil(tracker.registerBatch(["b", "c"], connection: connectionOne), "no new group behind the user's back")
        XCTAssertTrue(tracker.groups.isEmpty)
    }

    // MARK: - Planner

    private func item(_ id: String) -> SyncedItem {
        SyncedItem(
            id: id,
            entry: ClipboardEntry(content: id, type: Wire.EntryType.text, deviceId: "device", timestamp: "2026-10-13T14:20:05.1230000Z", signature: id),
            isOwn: false,
            kind: .text,
            filePayload: nil,
            fileAvailable: true,
            date: nil,
            sourceLabel: "device"
        )
    }

    func testAProvisionalStackShowsTheAnnouncedBadgeAndLayersAtOnce() {
        let groups = [BatchGroup(id: "x", memberIDs: ["a"], expectedSize: 6)]
        let rows = StackPlanner.rows(items: [item("a"), item("old")], groups: groups)
        XCTAssertEqual(rows.map(\.id), ["a", "old"])
        let stack = rows.first?.stack
        XCTAssertEqual(stack?.memberIDs, ["a"])
        XCTAssertEqual(stack?.hiddenCount, 5, "+5, as the final stack will show")
        XCTAssertEqual(stack?.layerCount, 2)
        XCTAssertNil(rows[1].stack)
    }

    func testTheBadgeUsesTheLargerOfMembersAndAnnouncedSize() {
        let list = [item("a"), item("b"), item("c")]
        let more = StackPlanner.rows(items: list, groups: [BatchGroup(id: "x", memberIDs: ["a", "b", "c"], expectedSize: 2)])
        XCTAssertEqual(more.first?.stack?.hiddenCount, 2, "never smaller than what is there")
        let announced = StackPlanner.rows(items: list, groups: [BatchGroup(id: "x", memberIDs: ["a", "b"], expectedSize: 5)])
        XCTAssertEqual(announced.first?.stack?.hiddenCount, 4)
        let two = StackPlanner.rows(items: [item("a")], groups: [BatchGroup(id: "x", memberIDs: ["a"], expectedSize: 2)])
        XCTAssertEqual(two.first?.stack?.hiddenCount, 1)
        XCTAssertEqual(two.first?.stack?.layerCount, 1)
    }

    func testTheBadgeDoesNotMoveWhenTheBatchArrives() {
        let list = (["a", "b", "c", "d"]).map(item)
        let before = StackPlanner.rows(items: [item("a")], groups: [BatchGroup(id: "x", memberIDs: ["a"], expectedSize: 4)])
        let after = StackPlanner.rows(items: list, groups: [BatchGroup(id: "x", memberIDs: ["a", "b", "c", "d"])])
        XCTAssertEqual(before.first?.stack?.hiddenCount, after.first?.stack?.hiddenCount)
        XCTAssertEqual(before.first?.stack?.layerCount, after.first?.stack?.layerCount)
        XCTAssertEqual(before.first?.id, after.first?.id, "the same front card, so no flash")
    }

    func testAnOpenedProvisionalStackIsAnOrdinaryCard() {
        let groups = [BatchGroup(id: "x", memberIDs: ["a"], expectedSize: 4)]
        let rows = StackPlanner.rows(items: [item("a")], groups: groups, expanded: ["x"])
        XCTAssertNil(rows.first?.stack)
    }

    // MARK: - Engine

    /// Collects what the engine tells the UI, on the main queue.
    private final class Recorder: SyncEngineDelegate {
        private let lock = NSLock()
        private var all: [EngineSnapshot] = []
        private var entries: [ClipboardEntry] = []
        func syncEngine(_ engine: SyncEngine, didUpdate snapshot: EngineSnapshot) { lock.lock(); all.append(snapshot); lock.unlock() }
        func syncEngine(_ engine: SyncEngine, didReceive entry: ClipboardEntry, fileURL: URL?) { lock.lock(); entries.append(entry); lock.unlock() }
        func syncEngine(_ engine: SyncEngine, notice: String) {}
        var snapshots: [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return all }
        var received: [ClipboardEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    }

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

    private func makeEngine() -> (engine: SyncEngine, recorder: Recorder) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-head-\(UUID().uuidString)")
        directories.append(dir)
        let engine = SyncEngine(config: EngineConfig(storageDirectory: dir), identity: SoftwareIdentity(), secrets: MemorySecretStore())
        let recorder = Recorder()
        engine.delegate = recorder
        engines.append(engine)
        return (engine, recorder)
    }

    private func trustedPeer(_ engine: SyncEngine) -> SoftwareIdentity {
        let peer = SoftwareIdentity()
        engine.trust.trust(peer.publicKeyBase64)
        return peer
    }

    /// `count` text entries from `peer`, one second apart, oldest first.
    private func batch(from peer: IdentitySigner, count: Int, label: String = "item") throws -> [ClipboardEntry] {
        try signedEntries(count: count, from: peer, label: label)
    }

    /// What the sender in the other app would send for `entries` (oldest first).
    private func head(for entries: [ClipboardEntry]) throws -> HistoryHead {
        try XCTUnwrap(HistoryHead.make(newestFirst: Array(entries.reversed())))
    }

    private func applyHead(_ engine: SyncEngine, _ head: HistoryHead, from peer: IdentitySigner, on connection: ObjectIdentifier) -> SyncEngine.HistoryHeadOutcome {
        engine.queue.sync { engine.applyHistoryHead(head, from: peer.publicKeyBase64, connection: connection) }
    }

    private func applyBatch(_ engine: SyncEngine, _ entries: [ClipboardEntry], from peer: IdentitySigner, on connection: ObjectIdentifier?) -> SyncEngine.HistoryBatchOutcome {
        engine.queue.sync { engine.applyHistoryBatch(entries, from: peer.publicKeyBase64, connection: connection) }
    }

    private func snapshot(_ engine: SyncEngine) -> EngineSnapshot {
        engine.queue.sync { engine.buildSnapshot() }
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    func testAHeadWithSeveralNewKeysShowsTheStackAtOnce() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 6)

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()

        XCTAssertTrue(outcome.accepted)
        XCTAssertTrue(outcome.newestIsNew)
        XCTAssertEqual(outcome.expectedNew, 6)
        let snap = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(snap.items.map(\.entry.content), ["item 5"], "only the newest entry is in history so far")
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups.first?.expectedSize, 6)
        let rows = StackPlanner.rows(items: snap.items, groups: snap.groups)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item.entry.content, "item 5", "the front card is the newest entry")
        XCTAssertEqual(rows.first?.stack?.hiddenCount, 5, "+5 from the keys")
        XCTAssertEqual(rows.first?.stack?.layerCount, 2)
        XCTAssertEqual(recorder.received.map(\.content), ["item 5"], "applied once, now")
    }

    func testAHeadWithOneNewKeyIsJustACard() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 4)
        // The other three are here already.
        engine.history.add(contentsOf: Array(entries.prefix(3)))

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()

        XCTAssertTrue(outcome.newestIsNew)
        XCTAssertEqual(outcome.expectedNew, 1)
        XCTAssertNil(outcome.group)
        let snap = snapshot(engine)
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertEqual(snap.items.first?.entry.content, "item 3")
        XCTAssertEqual(recorder.received.map(\.content), ["item 3"])
    }

    func testAHeadWithNoNewKeysChangesNothing() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 3)
        engine.history.add(contentsOf: entries)

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()

        XCTAssertTrue(outcome.accepted)
        XCTAssertFalse(outcome.newestIsNew)
        XCTAssertEqual(outcome.expectedNew, 0)
        XCTAssertNil(outcome.group)
        XCTAssertTrue(snapshot(engine).groups.isEmpty)
        XCTAssertEqual(snapshot(engine).items.count, 3)
        XCTAssertTrue(recorder.received.isEmpty, "nothing applied")
    }

    func testDeletedKeysAreNotCountedAsNew() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 5)
        // The user deleted two of the older ones here.
        engine.deleted.add([entries[0], entries[1]])

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)

        XCTAssertEqual(outcome.expectedNew, 3)
        XCTAssertEqual(outcome.group?.expectedSize, 3)
        XCTAssertEqual(snapshot(engine).groups.first?.expectedSize, 3)
    }

    func testRepeatedKeysCountOnce() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 3)
        var head = try self.head(for: entries)
        head.keys += head.keys
        XCTAssertEqual(applyHead(engine, head, from: peer, on: connectionOne).expectedNew, 3)
    }

    func testANewestEntryThatIsKnownAlreadyStartsNoGroup() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 5)
        engine.history.add(entries[4])

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()

        XCTAssertTrue(outcome.accepted)
        XCTAssertFalse(outcome.newestIsNew)
        XCTAssertEqual(outcome.expectedNew, 4, "the others are still counted")
        XCTAssertNil(outcome.group, "the front card would be an old one: no provisional stack")
        XCTAssertTrue(recorder.received.isEmpty, "a known entry is not applied again")

        // The batch then behaves as today: its group appears at batch time.
        let batchOutcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        XCTAssertEqual(batchOutcome.fresh.count, 4)
        XCTAssertEqual(batchOutcome.group?.memberIDs.count, 4)
        XCTAssertNil(batchOutcome.group?.expectedSize)
    }

    func testANewestEntryTheUserDeletedIgnoresTheHead() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 3)
        engine.deleted.add([entries[2]])

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)

        XCTAssertFalse(outcome.accepted)
        XCTAssertTrue(snapshot(engine).items.isEmpty)
        XCTAssertTrue(snapshot(engine).groups.isEmpty)
    }

    func testAHeadWithABadSignatureIsIgnoredAndTheBatchStillWorks() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 4)
        var tampered = try head(for: entries)
        tampered.newest.content = "something else"

        let outcome = applyHead(engine, tampered, from: peer, on: connectionOne)
        settle()
        XCTAssertFalse(outcome.accepted)
        XCTAssertNil(outcome.group)
        XCTAssertTrue(snapshot(engine).items.isEmpty, "nothing was added")
        XCTAssertTrue(recorder.received.isEmpty)

        let batchOutcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        settle()
        XCTAssertEqual(batchOutcome.fresh.count, 4)
        XCTAssertEqual(batchOutcome.group?.memberIDs.count, 4, "as if there had been no head")
        XCTAssertEqual(recorder.received.map(\.content), ["item 3"])
    }

    func testAHeadSignedByAnUntrustedDeviceIsIgnoredAndTheBatchStillWorks() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let stranger = SoftwareIdentity()
        let entries = try batch(from: peer, count: 3)
        let strangerEntry = try XCTUnwrap(try batch(from: stranger, count: 1, label: "stranger").first)
        let head = HistoryHead(newest: strangerEntry, keys: [strangerEntry.signature ?? ""] + (try self.head(for: entries)).keys)

        let outcome = applyHead(engine, head, from: peer, on: connectionOne)
        settle()
        XCTAssertFalse(outcome.accepted)
        XCTAssertTrue(snapshot(engine).items.isEmpty)
        XCTAssertTrue(recorder.received.isEmpty)

        let batchOutcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        XCTAssertEqual(batchOutcome.group?.memberIDs.count, 3)
    }

    func testHeadThenBatchIsOneGroupWithTheSameIdAndTheBadgeUnmoved() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 6)

        let headOutcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()
        let afterHead = try XCTUnwrap(recorder.snapshots.last)
        let badgeBefore = StackPlanner.rows(items: afterHead.items, groups: afterHead.groups).first?.stack?.hiddenCount

        // The batch is the same list the sender always sent: everything, oldest first.
        let batchOutcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        settle()
        let afterBatch = try XCTUnwrap(recorder.snapshots.last)
        let rows = StackPlanner.rows(items: afterBatch.items, groups: afterBatch.groups)

        XCTAssertEqual(batchOutcome.fresh.count, 5, "the head's entry is known and skipped")
        XCTAssertEqual(batchOutcome.known, 1)
        XCTAssertEqual(batchOutcome.group?.id, headOutcome.group?.id, "the same group")
        XCTAssertEqual(afterBatch.groups.count, 1)
        XCTAssertEqual(afterBatch.groups.first?.id, headOutcome.group?.id)
        XCTAssertEqual(afterBatch.groups.first?.memberIDs.count, 6)
        XCTAssertNil(afterBatch.groups.first?.expectedSize, "the badge now counts real members")
        XCTAssertEqual(afterBatch.items.count, 6)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, afterHead.items.first?.id, "the same front card: no flash")
        XCTAssertEqual(rows.first?.stack?.hiddenCount, badgeBefore, "the badge number does not change")
        XCTAssertEqual(badgeBefore, 5)
        // Every snapshot showed the head's group or the finished one, never a second group.
        let ids = Set(recorder.snapshots.flatMap { $0.groups.map(\.id) })
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(Set(recorder.snapshots.map { $0.items.count }), [1, 6], "the head, then the whole batch, nothing in between")
    }

    func testTheHeadsSideEffectsHappenOnceAndTheBatchDoesNotRepeatThem() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 5)

        _ = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["item 4"])

        _ = applyBatch(engine, entries, from: peer, on: connectionOne)
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["item 4"], "still the one apply, from the head")
    }

    func testAHeadsNewestEntryLandsOnTheClipboardEvenWhenSomethingNewerIsHere() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        // Something newer is here already.
        engine.history.add(try XCTUnwrap(try signedEntries(count: 1, from: peer, start: 1_800_000_000, label: "newer").first))
        let entries = try batch(from: peer, count: 3)

        let outcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        settle()

        XCTAssertTrue(outcome.newestIsNew)
        XCTAssertEqual(recorder.received.map(\.content), ["item 2"], "the head's newest entry is the one item of a reconnect that lands on the clipboard")

        _ = applyBatch(engine, entries, from: peer, on: connectionOne)
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["item 2"], "and the batch behind it adds nothing there")
    }

    func testTheConnectionClosingBeforeTheBatchEndsTheProvisionalGroup() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 6)
        _ = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        XCTAssertEqual(snapshot(engine).groups.count, 1)

        engine.queue.sync { engine.finishProvisional(connectionOne) }
        settle()

        let snap = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertTrue(snap.groups.isEmpty, "a front card alone is a normal card")
        XCTAssertEqual(snap.items.map(\.entry.content), ["item 5"], "the entry the head brought stays")
    }

    func testABatchThatAddsNothingMoreEndsTheProvisionalGroup() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 4)
        _ = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)

        // Only the entry the head already brought comes in the batch (the rest failed their checks).
        let outcome = applyBatch(engine, [entries[3]], from: peer, on: connectionOne)

        XCTAssertTrue(outcome.fresh.isEmpty)
        XCTAssertTrue(snapshot(engine).groups.isEmpty)
        XCTAssertEqual(snapshot(engine).items.count, 1)
    }

    func testABatchWithFewerEntriesThanAnnouncedKeepsTheRealCount() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 6)
        _ = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)

        // Three of the others are not signed by a trusted device.
        let stranger = SoftwareIdentity()
        let strangers = try batch(from: stranger, count: 3, label: "stranger")
        let delivered = Array(entries.suffix(3)) + strangers
        let outcome = applyBatch(engine, delivered, from: peer, on: connectionOne)

        XCTAssertEqual(outcome.rejected, 3)
        XCTAssertEqual(outcome.fresh.count, 2)
        let snap = snapshot(engine)
        XCTAssertEqual(snap.groups.first?.memberIDs.count, 3)
        XCTAssertNil(snap.groups.first?.expectedSize)
        XCTAssertEqual(StackPlanner.rows(items: snap.items, groups: snap.groups).first?.stack?.hiddenCount, 2)
    }

    func testNoHeadMeansTheOldBehaviour() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 5)

        let outcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        settle()

        XCTAssertEqual(outcome.fresh.count, 5)
        XCTAssertEqual(outcome.group?.memberIDs.count, 5)
        XCTAssertNil(outcome.group?.expectedSize)
        XCTAssertEqual(Set(recorder.snapshots.map { $0.items.count }), [5], "one update with everything")
        XCTAssertEqual(recorder.received.map(\.content), ["item 4"])
    }

    func testASecondHeadReplacesTheFirstGroup() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let first = try batch(from: peer, count: 4, label: "first")
        let second = try signedEntries(count: 3, from: peer, start: 1_790_000_100, label: "second")

        let firstOutcome = applyHead(engine, try head(for: first), from: peer, on: connectionOne)
        let secondOutcome = applyHead(engine, try head(for: second), from: peer, on: connectionOne)

        let snap = snapshot(engine)
        XCTAssertNotEqual(firstOutcome.group?.id, secondOutcome.group?.id)
        XCTAssertEqual(snap.groups.map(\.id), [secondOutcome.group?.id].compactMap { $0 })
        XCTAssertEqual(snap.groups.first?.expectedSize, 3)
        XCTAssertEqual(snap.items.map(\.entry.content), ["second 2", "first 3"], "both front cards stay; the first is a normal card")

        // The batch that follows belongs to the second head.
        let outcome = applyBatch(engine, second, from: peer, on: connectionOne)
        XCTAssertEqual(outcome.group?.id, secondOutcome.group?.id)
        XCTAssertEqual(outcome.group?.memberIDs.count, 3)
    }

    func testTwoConnectionsKeepTheirOwnProvisionalGroups() throws {
        let (engine, _) = makeEngine()
        let first = trustedPeer(engine)
        let second = trustedPeer(engine)
        let a = try batch(from: first, count: 3, label: "a")
        let b = try signedEntries(count: 4, from: second, start: 1_790_000_500, label: "b")

        let headA = applyHead(engine, try head(for: a), from: first, on: connectionOne)
        let headB = applyHead(engine, try head(for: b), from: second, on: connectionTwo)
        XCTAssertEqual(snapshot(engine).groups.count, 2)

        // B's batch first: it fills B's group and leaves A's alone.
        let batchB = applyBatch(engine, b, from: second, on: connectionTwo)
        XCTAssertEqual(batchB.group?.id, headB.group?.id)
        XCTAssertEqual(snapshot(engine).groups.first { $0.id == headA.group?.id }?.expectedSize, 3)

        engine.queue.sync { engine.finishProvisional(connectionOne) }
        let groups = snapshot(engine).groups
        XCTAssertEqual(groups.map(\.id), [headB.group?.id].compactMap { $0 })
        XCTAssertEqual(groups.first?.memberIDs.count, 4)
    }

    func testOpeningTheStackBeforeTheBatchLeavesOrdinaryCards() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 6)
        let headOutcome = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)

        engine.dissolveGroup(id: try XCTUnwrap(headOutcome.group).id)
        engine.queue.sync {}
        XCTAssertTrue(snapshot(engine).groups.isEmpty)
        XCTAssertEqual(snapshot(engine).items.count, 1)

        let outcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        settle()

        XCTAssertEqual(outcome.fresh.count, 5)
        XCTAssertNil(outcome.group, "no stack comes back after the user opened it")
        let snap = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(snap.items.count, 6, "the rest arrive as ordinary cards in one update")
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertEqual(recorder.received.map(\.content), ["item 5"])
    }

    func testDeletingTheFrontCardBeforeTheBatchStopsTheStack() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 4)
        _ = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        engine.deleteItem(id: try XCTUnwrap(snapshot(engine).items.first).id)
        engine.queue.sync {}
        XCTAssertTrue(snapshot(engine).groups.isEmpty)

        // The deleted entry stays deleted; the rest arrive as ordinary cards.
        let outcome = applyBatch(engine, entries, from: peer, on: connectionOne)
        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertNil(outcome.group)
        XCTAssertEqual(snapshot(engine).items.count, 3)
    }

    func testTheHeadsGroupIsNeverSaved() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 4)
        _ = applyHead(engine, try head(for: entries), from: peer, on: connectionOne)
        _ = applyBatch(engine, entries, from: peer, on: connectionOne)

        let restarted = SyncEngine(config: EngineConfig(storageDirectory: engine.config.storageDirectory), identity: SoftwareIdentity(), secrets: MemorySecretStore())
        engines.append(restarted)
        let snap = snapshot(restarted)
        XCTAssertEqual(snap.items.count, 4)
        XCTAssertTrue(snap.groups.isEmpty)
    }
}
