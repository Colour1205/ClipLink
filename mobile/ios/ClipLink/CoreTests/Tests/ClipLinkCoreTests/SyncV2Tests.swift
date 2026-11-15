import XCTest
@testable import ClipLinkCore

/// Sync version 2: the messages (history_head with keys, times and deleted keys;
/// history_request; delete), which keys are worth asking for, the placement of
/// what a sync brings (session blocks, the convenience item C, trimming) and
/// how one engine applies an answer or a peer's deletions - all without sockets.
/// The real exchange over links is in EngineIntegrationTests.
final class SyncV2Tests: XCTestCase {

    // MARK: - Helpers

    private func sign(_ label: String, at seconds: TimeInterval, by peer: IdentitySigner) throws -> ClipboardEntry {
        try EntrySigning.sign(content: label, type: Wire.EntryType.text, identity: peer,
                              timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: seconds)))
    }

    /// `count` text entries from `peer`, one second apart from `start`, oldest first.
    private func signedBatch(_ count: Int, from peer: IdentitySigner, start: TimeInterval = 1_790_000_000, label: String = "item") throws -> [ClipboardEntry] {
        try (0..<count).map { try sign("\(label) \($0)", at: start + TimeInterval($0), by: peer) }
    }

    private func key(_ entry: ClipboardEntry) -> String { DeletedStore.key(of: entry) }

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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-sync2-\(UUID().uuidString)")
        directories.append(dir)
        return dir
    }

    // MARK: - history_head, version 2

    func testTheHeadIsMadeFromTheHistoryNewestFirstWithMillisecondTimes() throws {
        let peer = SoftwareIdentity()
        let newestFirst = Array(try signedBatch(3, from: peer).reversed())
        let head = HistoryHeadV2.make(newestFirst: newestFirst, deleted: ["d1", "d2"])
        XCTAssertEqual(head.keys, newestFirst.map(key))
        XCTAssertEqual(head.times, [1_790_000_002_000, 1_790_000_001_000, 1_790_000_000_000], "Unix milliseconds, UTC")
        XCTAssertEqual(head.deleted, ["d1", "d2"])
    }

    func testTheHeadIsCutToTheCapsAndMayBeEmpty() throws {
        let peer = SoftwareIdentity()
        let many = Array(try signedBatch(30, from: peer).reversed())
        let deleted = (0..<600).map { "gone-\($0)" }
        let head = HistoryHeadV2.make(newestFirst: many, deleted: deleted)
        XCTAssertEqual(head.keys.count, 25)
        XCTAssertEqual(head.times.count, 25)
        XCTAssertEqual(head.deleted.count, 500)
        XCTAssertEqual(head.deleted.first, "gone-0", "the most recently deleted come first")

        let empty = HistoryHeadV2.make(newestFirst: [], deleted: [])
        XCTAssertEqual(HistoryHeadV2.parse(empty.jsonString()), empty, "an empty head is still a head")
    }

    func testTheHeadOnTheWireHasKeysTimesAndDeletedAndNoNewest() throws {
        let peer = SoftwareIdentity()
        let newestFirst = Array(try signedBatch(2, from: peer).reversed())
        let head = HistoryHeadV2.make(newestFirst: newestFirst, deleted: ["gone"])
        let line = Envelope(type: Wire.MessageType.historyHead, payload: head.jsonString()).jsonString()

        let envelope = try XCTUnwrap(WireJSON.object(line))
        XCTAssertEqual(envelope["Type"] as? String, "history_head")
        let payload = try XCTUnwrap(envelope["Payload"] as? String, "the payload is a JSON string, not a nested object")
        let object = try XCTUnwrap(WireJSON.object(payload))
        XCTAssertEqual(Set(object.keys), ["Keys", "Times", "Deleted"], "no Newest: the peer may have it already")
        XCTAssertEqual(object["Keys"] as? [String], newestFirst.map(key))
        let times = try XCTUnwrap(object["Times"] as? [NSNumber])
        XCTAssertEqual(times.map(\.int64Value), head.times, "plain integers")
        XCTAssertEqual(object["Deleted"] as? [String], ["gone"])
    }

    func testWhatTheSenderWritesTheReceiverParses() throws {
        let peer = SoftwareIdentity()
        let head = HistoryHeadV2.make(newestFirst: Array(try signedBatch(5, from: peer).reversed()), deleted: ["a", "b"])
        let envelope = try XCTUnwrap(Envelope.parse(Envelope(type: Wire.MessageType.historyHead, payload: head.jsonString()).jsonString()))
        XCTAssertEqual(HistoryHeadV2.parse(envelope.payload), head)
    }

    func testAHeadWithoutTimesOrDeletedIsFine() {
        let head = HistoryHeadV2.parse(#"{"Keys":["a","b"]}"#)
        XCTAssertEqual(head?.keys, ["a", "b"])
        XCTAssertEqual(head?.times, [])
        XCTAssertEqual(head?.deleted, [])
        XCTAssertEqual(HistoryHeadV2.parse("{}"), HistoryHeadV2(keys: [], times: [], deleted: []))
        XCTAssertEqual(HistoryHeadV2.parse(#"{"Keys":["a"],"Times":null,"Deleted":null}"#)?.keys, ["a"])
    }

    func testTimesOfTheWrongLengthOrKindAreDropped() {
        XCTAssertEqual(HistoryHeadV2.parse(#"{"Keys":["a","b"],"Times":[1]}"#)?.times, [], "shorter")
        XCTAssertEqual(HistoryHeadV2.parse(#"{"Keys":["a"],"Times":[1,2]}"#)?.times, [], "longer")
        XCTAssertEqual(HistoryHeadV2.parse(#"{"Keys":["a","b"],"Times":[1,"2"]}"#)?.times, [], "not a number")
        XCTAssertEqual(HistoryHeadV2.parse(#"{"Keys":["a","b"],"Times":[5,4]}"#)?.times, [5, 4])
        XCTAssertEqual(HistoryHeadV2.parse(#"{"Keys":["a","b"],"Times":[5,4]}"#)?.keys, ["a", "b"], "the keys stay")
    }

    func testAHeadKeepsAtMost25KeysAnd500DeletedAndSkipsBadKeys() {
        let keys = (0..<30).map { "\"k\($0)\"" }.joined(separator: ",")
        let times = (0..<30).map { String(1000 - $0) }.joined(separator: ",")
        let deleted = (0..<600).map { "\"d\($0)\"" }.joined(separator: ",")
        let big = HistoryHeadV2.parse("{\"Keys\":[\(keys)],\"Times\":[\(times)],\"Deleted\":[\(deleted)]}")
        XCTAssertEqual(big?.keys.count, 25, "the first 25")
        XCTAssertEqual(big?.keys.last, "k24")
        XCTAssertEqual(big?.times.count, 25, "and their times")
        XCTAssertEqual(big?.times.last, 1000 - 24)
        XCTAssertEqual(big?.deleted.count, 500)
        XCTAssertEqual(big?.deleted.last, "d499")

        // A key that is not a string is skipped, with its time.
        let mixed = HistoryHeadV2.parse(#"{"Keys":["a",5,null,"b"],"Times":[1,2,3,4],"Deleted":["x",7,"y"]}"#)
        XCTAssertEqual(mixed?.keys, ["a", "b"])
        XCTAssertEqual(mixed?.times, [1, 4])
        XCTAssertEqual(mixed?.deleted, ["x", "y"])

        // Over 2048 characters is not a key of ours.
        let long = String(repeating: "k", count: Wire.maxKeyLength + 1)
        let edge = String(repeating: "k", count: Wire.maxKeyLength)
        let limits = HistoryHeadV2.parse("{\"Keys\":[\"\(long)\",\"\(edge)\"],\"Deleted\":[\"\(long)\"]}")
        XCTAssertEqual(limits?.keys, [edge])
        XCTAssertEqual(limits?.deleted, [])
    }

    func testAHeadThatIsNotAnObjectIsRejected() {
        XCTAssertNil(HistoryHeadV2.parse("not json"))
        XCTAssertNil(HistoryHeadV2.parse(#"["a"]"#))
    }

    func testAVersion15HeadParsesAsAHeadWithoutItsNewest() throws {
        // On a version 2 connection a `Newest` is ignored: only the keys count.
        let peer = SoftwareIdentity()
        let newestFirst = Array(try signedBatch(3, from: peer).reversed())
        let old = try XCTUnwrap(HistoryHead.make(newestFirst: newestFirst))
        let asV2 = try XCTUnwrap(HistoryHeadV2.parse(old.jsonString()))
        XCTAssertEqual(asV2.keys, newestFirst.map(key))
        XCTAssertEqual(asV2.times, [])
        XCTAssertEqual(asV2.deleted, [])
        // ... and a version 1.5 reader still reads what it always did.
        XCTAssertEqual(HistoryHead.parse(old.jsonString()), old)
    }

    // MARK: - history_request and delete payloads

    func testAKeysMessageRoundTripsAndKeepsAtMost100() {
        let message = KeysMessage(keys: ["a", "b"])
        XCTAssertEqual(WireJSON.object(message.jsonString())?["Keys"] as? [String], ["a", "b"])
        XCTAssertEqual(Set((WireJSON.object(message.jsonString()) ?? [:]).keys), ["Keys"])
        XCTAssertEqual(KeysMessage.parse(message.jsonString()), message)

        let many = (0..<150).map { "\"k\($0)\"" }.joined(separator: ",")
        let parsed = KeysMessage.parse("{\"Keys\":[\(many)]}")
        XCTAssertEqual(parsed?.keys.count, 100, "the rest is ignored")
        XCTAssertEqual(parsed?.keys.last, "k99")
    }

    func testAKeysMessageSkipsWhatIsNotAKey() {
        let long = String(repeating: "k", count: Wire.maxKeyLength + 1)
        XCTAssertEqual(KeysMessage.parse("{\"Keys\":[\"a\",1,null,[\"x\"],\"\(long)\",\"b\"]}")?.keys, ["a", "b"])
        XCTAssertEqual(KeysMessage.parse(#"{"Keys":"a"}"#)?.keys, [])
        XCTAssertEqual(KeysMessage.parse("{}")?.keys, [])
        XCTAssertNil(KeysMessage.parse("not json"))
        XCTAssertNil(KeysMessage.parse("[]"))
    }

    func testMoreThan100KeysAreSplitOverSeveralMessages() {
        let keys = (0..<250).map { "k\($0)" }
        let messages = KeysMessage.messages(for: keys)
        XCTAssertEqual(messages.map(\.keys.count), [100, 100, 50])
        XCTAssertEqual(messages.flatMap(\.keys), keys, "in order, nothing lost")
        XCTAssertTrue(KeysMessage.messages(for: []).isEmpty)
    }

    func testTheNewMessageTypesHaveTheirWireNames() {
        XCTAssertEqual(Wire.MessageType.historyHead, "history_head")
        XCTAssertEqual(Wire.MessageType.historyRequest, "history_request")
        XCTAssertEqual(Wire.MessageType.historyBatch, "history_batch")
        XCTAssertEqual(Wire.MessageType.delete, "delete")
        XCTAssertEqual(Wire.requestTimeout, 90)
    }

    // MARK: - Which keys to ask for

    private func wanted(_ head: HistoryHeadV2, local: [(String, Int64)] = [], gone: Set<String> = [], pending: Set<String> = []) -> [String] {
        SyncEngine.wantedKeys(head: head, local: local.map { (key: $0.0, time: $0.1) }, isGone: { gone.contains($0) }, isPending: { pending.contains($0) })
    }

    func testKnownKeysAreNotAskedFor() {
        let head = HistoryHeadV2(keys: ["k3", "k2", "k1"], times: [3000, 2000, 1000], deleted: [])
        XCTAssertEqual(wanted(head), ["k3", "k2", "k1"])
        XCTAssertEqual(wanted(head, local: [("k2", 2000)]), ["k3", "k1"])
        XCTAssertEqual(wanted(head, local: [("k3", 3000), ("k2", 2000), ("k1", 1000)]), [])
    }

    func testTombstonedAndAlreadyPendingKeysAreNotAskedFor() {
        let head = HistoryHeadV2(keys: ["k3", "k2", "k1"], times: [3000, 2000, 1000], deleted: [])
        XCTAssertEqual(wanted(head, gone: ["k3"]), ["k2", "k1"], "deleted here: never")
        XCTAssertEqual(wanted(head, pending: ["k2"]), ["k3", "k1"], "being asked of another connection")
        XCTAssertEqual(wanted(head, gone: ["k3"], pending: ["k2"]), ["k1"])
    }

    func testOnlyWhatTheHistoryWouldKeepIsWorthAskingForNotEvenTheNewestMissingOne() {
        // 25 entries here, at 1000, 1010 ... 1240 ms.
        let local = (0..<25).map { ("local-\($0)", Int64(1000 + 10 * $0)) }
        // Newest first as the sender lists them: m0 is the newest, m2 would land inside our 25, m1 would not.
        let head = HistoryHeadV2(keys: ["m0", "m2", "m1"], times: [2000, 1105, 500], deleted: [])
        XCTAssertEqual(wanted(head, local: local), ["m0", "m2"], "the 25 newest of ours and theirs: m1 is too old to keep")

        // Older than everything a full history here keeps: an item trimmed here, or
        // one a partly paired peer still holds, is not fetched again on every reconnect.
        let older = HistoryHeadV2(keys: ["c", "d"], times: [500, 400], deleted: [])
        XCTAssertEqual(wanted(older, local: local), [], "not even the first one")

        // With room in the history, anything missing is worth having.
        XCTAssertEqual(wanted(older, local: Array(local.prefix(23))), ["c", "d"])
        XCTAssertEqual(wanted(older, local: Array(local.prefix(24))), ["c"], "one slot left: the newer of the two")
    }

    func testWithoutUsableTimesEverythingMissingIsAskedForUpTo25() {
        let keys = (0..<30).map { "k\($0)" }
        let noTimes = HistoryHeadV2(keys: keys, times: [], deleted: [])
        XCTAssertEqual(wanted(noTimes), Array(keys.prefix(25)))
        let wrongLength = HistoryHeadV2(keys: keys, times: [1, 2, 3], deleted: [])
        XCTAssertEqual(wanted(wrongLength), Array(keys.prefix(25)))
        // ... of the ones that are missing.
        XCTAssertEqual(wanted(HistoryHeadV2(keys: ["a", "b", "c"], times: [], deleted: []), local: [("b", 1)]), ["a", "c"])
    }

    func testARepeatedKeyIsAskedForOnceAndNothingMissingAsksNothing() {
        XCTAssertEqual(wanted(HistoryHeadV2(keys: ["a", "a", "b"], times: [3, 3, 2], deleted: [])), ["a", "b"])
        XCTAssertEqual(wanted(HistoryHeadV2(keys: [], times: [], deleted: [])), [])
        XCTAssertEqual(wanted(HistoryHeadV2(keys: ["a"], times: [1], deleted: []), gone: ["a"]), [])
    }

    // MARK: - Tombstones and the trim

    func testTombstonesKeepTheirOrderAndAPeersKeysDoNotMoveOldOnes() {
        let dir = makeDirectory()
        let store = DeletedStore(directory: dir)
        store.addRemote(keys: ["a", "b", "c"]) // oldest first
        XCTAssertEqual(store.recentKeys(limit: 500), ["c", "b", "a"], "most recently deleted first")
        store.addRemote(keys: ["a", "d"])
        XCTAssertEqual(store.recentKeys(limit: 500), ["d", "c", "b", "a"], "a was known: it keeps its place")
        XCTAssertEqual(store.recentKeys(limit: 2), ["d", "c"])
        XCTAssertEqual(store.removingDeletedKeys(["a", "x"]), ["x"], "they are real tombstones")
        XCTAssertEqual(DeletedStore(directory: dir).recentKeys(limit: 10), ["d", "c", "b", "a"], "and they are saved")
    }

    func testTheTombstoneCapIsEnoughForAHead() {
        XCTAssertGreaterThanOrEqual(DeletedStore.cap, 500)
        XCTAssertEqual(DeletedStore.cap, 2000)
        let store = DeletedStore(directory: makeDirectory())
        store.addRemote(keys: (0..<(DeletedStore.cap + 10)).map { "k\($0)" })
        XCTAssertEqual(store.count, DeletedStore.cap)
        XCTAssertEqual(store.recentKeys(limit: 1), ["k\(DeletedStore.cap + 9)"])
    }

    func testTheTrimDropsTheOldestEntryButSparesAProtectedOne() throws {
        let dir = makeDirectory()
        let store = HistoryStore(directory: dir, fileStore: FileStore(directory: dir))
        let peer = SoftwareIdentity()
        let base = try signedBatch(Wire.historyCap, from: peer, start: 1_700_000_000, label: "base")
        store.add(contentsOf: base)

        // Older than all of them, and protected: the oldest OTHER entry goes.
        let c = try sign("c", at: 1_600_000_000, by: peer)
        let added = store.add(contentsOf: [c], protecting: [HistoryStore.identity(of: c)])
        XCTAssertEqual(added, [c])
        XCTAssertEqual(store.entries.count, Wire.historyCap, "the total stays 25")
        XCTAssertTrue(store.contains(c))
        XCTAssertFalse(store.contains(base[0]))
        XCTAssertTrue(store.contains(base[1]))

        // Not protected: the oldest is the oldest.
        let older = try sign("older", at: 1_500_000_000, by: peer)
        XCTAssertTrue(store.add(contentsOf: [older]).isEmpty, "cut at once")
        let newer = try sign("newer", at: 1_800_000_000, by: peer)
        XCTAssertEqual(store.add(contentsOf: [newer]), [newer])
        XCTAssertFalse(store.contains(c), "now c is simply the oldest")
        XCTAssertEqual(store.entries.count, Wire.historyCap)
    }

    func testSeveralEntriesCanBeRemovedInOneWrite() throws {
        let dir = makeDirectory()
        let store = HistoryStore(directory: dir, fileStore: FileStore(directory: dir))
        let all = try signedBatch(5, from: SoftwareIdentity())
        store.add(contentsOf: all)
        store.remove(identities: [HistoryStore.identity(of: all[1]), HistoryStore.identity(of: all[3]), "no such identity"])
        XCTAssertEqual(store.entries.map(\.content), ["item 0", "item 2", "item 4"])
        store.remove(identities: [])
        XCTAssertEqual(store.entries.count, 3)
    }

    // MARK: - Blocks, C and what the list shows

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

    private func items(_ ids: [String]) -> [SyncedItem] { ids.map(item) }

    func testCIsOnTopEvenThoughItIsOlderThanTheItemsBelow() {
        // The timeline is newest first: c is the oldest of all.
        let list = items(["n1", "n2", "n3", "c"])
        let groups = [BatchGroup(id: "b", memberIDs: ["c"], frontID: "c")]
        let rows = StackPlanner.rows(items: list, groups: groups)
        XCTAssertEqual(rows.map(\.id), ["c", "n1", "n2", "n3"])
        XCTAssertNil(rows.first?.stack, "a block of one is a plain card")
    }

    func testACollapsedStackIsOneCardAtItsBlockPositionWithCInFront() {
        let list = items(["n1", "m1", "n2", "m2", "c", "n3"])
        let groups = [BatchGroup(id: "b", memberIDs: ["c", "m1", "m2"], frontID: "c")]
        let rows = StackPlanner.rows(items: list, groups: groups)
        XCTAssertEqual(rows.map(\.id), ["c", "n1", "n2", "n3"], "one card for the block, on top")
        XCTAssertEqual(rows.first?.stack?.memberIDs, ["c", "m1", "m2"], "C, then the others newest first")
        XCTAssertEqual(rows.first?.stack?.hiddenCount, 2)
    }

    func testOpeningAStackKeepsItsItemsTogetherRightBelowCAboveEverythingElse() {
        // n1 and n2 are NEWER than the stack's members, and still come after them.
        let list = items(["n1", "m1", "n2", "m2", "c", "n3"])
        let open = [BatchGroup(id: "b", memberIDs: ["c", "m1", "m2"], frontID: "c", isOpen: true)]
        XCTAssertEqual(StackPlanner.rows(items: list, groups: open).map(\.id), ["c", "m1", "m2", "n1", "n2", "n3"])
        XCTAssertTrue(StackPlanner.rows(items: list, groups: open).allSatisfy { $0.stack == nil })

        // The view's own memory of the stack it just opened does the same, before the engine has heard.
        let closed = [BatchGroup(id: "b", memberIDs: ["c", "m1", "m2"], frontID: "c")]
        XCTAssertEqual(StackPlanner.rows(items: list, groups: closed, expanded: ["b"]).map(\.id), ["c", "m1", "m2", "n1", "n2", "n3"])
    }

    func testALiveItemThatArrivesLaterGoesAboveTheBlock() {
        var tracker = BatchGroupTracker()
        tracker.register(["c", "m1", "m2"])
        tracker.registerLive("live")
        // The stack's items are newer by the clock; the live one arrived last.
        let list = items(["c", "m1", "m2", "live", "old"])
        let rows = StackPlanner.rows(items: list, groups: tracker.blocks)
        XCTAssertEqual(rows.map(\.id), ["live", "c", "old"])
        XCTAssertEqual(rows[1].stack?.memberIDs, ["c", "m1", "m2"])
    }

    func testWithNoBlocksTheListIsThePlainTimeline() {
        let list = items(["a", "b", "c"])
        XCTAssertEqual(StackPlanner.rows(items: list, groups: []).map(\.item), list)
        XCTAssertEqual(BatchGroupTracker().blocks, [])
    }

    func testDeletingTheFrontPromotesTheNextMemberAndOneLeftIsACard() {
        var tracker = BatchGroupTracker()
        tracker.register(["c", "m1", "m2"])
        tracker.prune(keeping: ["m1", "m2"])
        var rows = StackPlanner.rows(items: items(["m1", "m2"]), groups: tracker.blocks)
        XCTAssertEqual(rows.map(\.id), ["m1"])
        XCTAssertEqual(rows.first?.stack?.memberIDs, ["m1", "m2"])
        XCTAssertNil(tracker.convenienceID, "C is gone, nothing is protected")

        tracker.prune(keeping: ["m2"])
        rows = StackPlanner.rows(items: items(["m2", "n"]), groups: tracker.blocks)
        XCTAssertEqual(rows.map(\.id), ["m2", "n"])
        XCTAssertNil(rows.first?.stack, "a stack left with one member is a single card")
        XCTAssertTrue(tracker.groups.isEmpty)
    }

    func testOnlyTheLatestBlocksCIsProtected() {
        var tracker = BatchGroupTracker()
        XCTAssertNil(tracker.convenienceID)
        tracker.register(["c1", "x"])
        XCTAssertEqual(tracker.convenienceID, "c1")
        tracker.registerLive("live")
        XCTAssertNil(tracker.convenienceID, "a newer block ends the protection")
        tracker.register(["c2"])
        XCTAssertEqual(tracker.convenienceID, "c2", "also for a block of one")
        tracker.removeAll()
        XCTAssertNil(tracker.convenienceID)
        XCTAssertTrue(tracker.blocks.isEmpty)
    }

    private let oneObject = NSObject()
    private let otherObject = NSObject()
    private var connectionOne: ObjectIdentifier { ObjectIdentifier(oneObject) }
    private var connectionTwo: ObjectIdentifier { ObjectIdentifier(otherObject) }

    func testASyncShowsItsStackWithTheFullBadgeAsSoonAsCIsIn() {
        var tracker = BatchGroupTracker()
        let group = tracker.registerSync(front: "c", others: [], expectedSize: 5, connection: connectionOne)
        XCTAssertEqual(group?.memberIDs, ["c"])
        XCTAssertEqual(group?.expectedSize, 5)
        XCTAssertEqual(group?.size, 5)
        XCTAssertEqual(group?.frontID, "c")
        XCTAssertEqual(tracker.convenienceID, "c")

        // The next answer joins the same block ...
        let joined = tracker.joinSync(["m1", "m2"], connection: connectionOne, last: false)
        XCTAssertEqual(joined?.id, group?.id)
        XCTAssertEqual(joined?.memberIDs, ["c", "m1", "m2"])
        XCTAssertEqual(joined?.expectedSize, 5, "still waiting for more")
        // ... and the last one drops the announced size.
        let done = tracker.joinSync(["m3"], connection: connectionOne, last: true)
        XCTAssertEqual(done?.memberIDs, ["c", "m1", "m2", "m3"])
        XCTAssertNil(done?.expectedSize)
        XCTAssertEqual(tracker.groups.count, 1)
        XCTAssertNil(tracker.joinSync(["late"], connection: connectionOne, last: true), "nothing is waiting any more")
    }

    func testASyncOfOneIsACardAndAStackThatEndsWithOneDissolves() {
        var tracker = BatchGroupTracker()
        XCTAssertNil(tracker.registerSync(front: "c", others: [], expectedSize: nil, connection: connectionOne))
        XCTAssertEqual(tracker.blocks.count, 1, "still a block, and C leads it")
        XCTAssertTrue(tracker.groups.isEmpty)

        // The rest never comes: the connection closed.
        tracker.registerSync(front: "d", others: [], expectedSize: 3, connection: connectionTwo)
        XCTAssertEqual(tracker.groups.count, 1)
        XCTAssertTrue(tracker.finish(connection: connectionTwo))
        XCTAssertTrue(tracker.groups.isEmpty, "a group that ends with fewer than 2 members dissolves into a card")
    }

    func testALaterAnswerWithNoBlockWaitingJoinsNothing() {
        var tracker = BatchGroupTracker()
        XCTAssertNil(tracker.joinSync(["m1", "m2"], connection: connectionOne, last: true))
        XCTAssertTrue(tracker.blocks.isEmpty, "no block behind the user's back")
    }

    func testAnOpenedStackStaysOpenWhenMoreOfItsSyncArrives() {
        var tracker = BatchGroupTracker()
        let group = tracker.registerSync(front: "c", others: [], expectedSize: 3, connection: connectionOne)!
        tracker.dissolve(id: group.id)
        XCTAssertNil(tracker.joinSync(["m1", "m2"], connection: connectionOne, last: true), "no new stack")
        XCTAssertEqual(tracker.blocks.first?.memberIDs, ["c", "m1", "m2"], "but they join the block")
        let rows = StackPlanner.rows(items: items(["n1", "m1", "m2", "c"]), groups: tracker.blocks)
        XCTAssertEqual(rows.map(\.id), ["c", "m1", "m2", "n1"])
    }

    // MARK: - One engine applying an answer, and a peer's deletions

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

    private func makeEngine() -> (engine: SyncEngine, recorder: Recorder) {
        let engine = SyncEngine(config: EngineConfig(storageDirectory: makeDirectory()), identity: SoftwareIdentity(), secrets: MemorySecretStore())
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

    private func snapshot(_ engine: SyncEngine) -> EngineSnapshot {
        engine.queue.sync { engine.buildSnapshot() }
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    /// The answer to one request, on connection one. `requested` are the entries the request named
    /// (the answer's own by default). `expired`: the request had been given up on (a late answer).
    /// `now`: the moment the answer arrives.
    @discardableResult
    private func answer(_ engine: SyncEngine, _ entries: [ClipboardEntry], convenience: Bool, last: Bool, expected: Int, from peer: IdentitySigner, requested: [ClipboardEntry]? = nil, expired: Bool = false, now: Date = Date()) -> SyncEngine.HistoryBatchOutcome {
        let request = HistoryRequest(keys: (requested ?? entries).map(key), convenience: convenience, sentAt: Date(), expired: expired)
        return engine.queue.sync {
            engine.applyAnswer(entries, to: request, last: last, expectedSize: expected, from: peer.publicKeyBase64, connection: connectionOne, now: now)
        }
    }

    func testTheConvenienceAnswerPutsOneItemOnTheClipboardAndTheNextOneNothing() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let newestFirst = Array(try signedBatch(4, from: peer).reversed())

        let first = answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 4, from: peer)
        settle()
        XCTAssertEqual(first.fresh.map(\.content), ["item 3"])
        XCTAssertEqual(recorder.received.map(\.content), ["item 3"], "C, once")
        var snap = snapshot(engine)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups.first?.expectedSize, 4, "the badge counts everything asked for")
        let early = StackPlanner.rows(items: snap.items, groups: snap.blocks)
        XCTAssertEqual(early.count, 1)
        XCTAssertEqual(early.first?.stack?.hiddenCount, 3)

        let second = answer(engine, Array(newestFirst.dropFirst()), convenience: false, last: true, expected: 4, from: peer)
        settle()
        XCTAssertEqual(second.fresh.count, 3)
        XCTAssertEqual(recorder.received.map(\.content), ["item 3"], "the second answer puts nothing on the clipboard")
        snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, 4)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups.first?.memberIDs.count, 4)
        XCTAssertNil(snap.groups.first?.expectedSize, "the real count shows now")
        XCTAssertEqual(StackPlanner.rows(items: snap.items, groups: snap.blocks).first?.stack?.hiddenCount, 3, "the badge did not move")
        XCTAssertEqual(Set(recorder.snapshots.map { $0.items.count }), [1, 4], "one update per answer, never part of one")
    }

    func testAConvenienceAnswerWithNothingNewAppliesNothing() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entry = try sign("known", at: 1_790_000_000, by: peer)
        engine.history.add(entry)

        let outcome = answer(engine, [entry], convenience: true, last: true, expected: 1, from: peer)
        settle()
        XCTAssertTrue(outcome.fresh.isEmpty)
        XCTAssertEqual(outcome.known, 1)
        XCTAssertTrue(recorder.received.isEmpty)
        XCTAssertTrue(snapshot(engine).groups.isEmpty)
    }

    func testACThatIsNotNewerThanWhatIsHereIsStoredQuietlyByTime() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        engine.history.add(contentsOf: try signedBatch(3, from: peer, start: 1_800_000_000, label: "mine"))
        let old = try sign("old", at: 1_700_000_000, by: peer)

        let outcome = answer(engine, [old], convenience: true, last: true, expected: 1, from: peer)
        settle()

        XCTAssertEqual(outcome.fresh.map(\.content), ["old"], "stored")
        XCTAssertTrue(outcome.quiet, "and the rest of its sync is quiet too")
        XCTAssertNil(outcome.group)
        XCTAssertTrue(recorder.received.isEmpty, "not on the clipboard, no notification")
        XCTAssertNil(engine.queue.sync { engine.lastConvenience })
        let snap = snapshot(engine)
        XCTAssertTrue(snap.blocks.isEmpty, "not on top")
        XCTAssertEqual(StackPlanner.rows(items: snap.items, groups: snap.blocks).map(\.item.entry.content), ["mine 2", "mine 1", "mine 0", "old"], "a card by its time")
    }

    func testACAsOldAsTheNewestItemHereIsNotFreshButAnyCIsInAnEmptyHistory() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let first = try sign("first", at: 1_790_000_000, by: peer)
        XCTAssertTrue(engine.queue.sync { engine.isFresh(first) }, "an empty history: anything is newer")
        engine.history.add(first)
        let same = try sign("same moment", at: 1_790_000_000, by: peer)
        XCTAssertFalse(engine.queue.sync { engine.isFresh(same) }, "strictly newer only")

        let outcome = answer(engine, [same], convenience: true, last: true, expected: 1, from: peer)
        settle()
        XCTAssertTrue(outcome.quiet)
        XCTAssertTrue(recorder.received.isEmpty)
    }

    func testTheAnswersAfterAQuietCAreQuietTooUpToTheNextSync() throws {
        let now = Date()
        func request(_ convenience: Bool) -> HistoryRequest { HistoryRequest(keys: ["k"], convenience: convenience, sentAt: now) }
        let waiting = [request(false), request(false), request(true), request(false)]
        XCTAssertEqual(SyncEngine.quietingRestOfSync(waiting).map(\.quiet), [true, true, false, false], "the next convenience request starts another sync")
        XCTAssertEqual(SyncEngine.quietingRestOfSync([]).count, 0)

        // A quiet request's answer joins no block, even one that is waiting on the connection.
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let front = try sign("front", at: 1_790_000_100, by: peer)
        answer(engine, [front], convenience: true, last: false, expected: 3, from: peer)
        let rest = try signedBatch(2, from: peer, start: 1_790_000_000, label: "rest")
        let quietRequest = HistoryRequest(keys: rest.map(key), convenience: false, sentAt: now, quiet: true)
        let outcome = engine.queue.sync {
            engine.applyAnswer(rest, to: quietRequest, last: true, expectedSize: 3, from: peer.publicKeyBase64, connection: connectionOne)
        }
        settle()
        XCTAssertEqual(outcome.fresh.count, 2)
        XCTAssertNil(outcome.group)
        let snap = snapshot(engine)
        XCTAssertEqual(snap.blocks.first?.memberIDs, [HistoryStore.identity(of: front)], "the quiet items are cards by time")
        XCTAssertNil(snap.blocks.first?.expectedSize, "and the block stopped waiting with the last answer")
        XCTAssertEqual(recorder.received.map(\.content), ["front"])
    }

    // MARK: - The rest of a sync, a few keys to a request

    func testTheRestOfASyncIsAskedForAFewKeysToARequestInOrder() {
        let now = Date()
        let keys = (0..<10).map { "k\($0)" }
        let requests = SyncEngine.restRequests(keys, sentAt: now, quiet: false)
        XCTAssertEqual(requests.map(\.keys), [["k0", "k1", "k2", "k3"], ["k4", "k5", "k6", "k7"], ["k8", "k9"]])
        XCTAssertTrue(requests.allSatisfy { !$0.convenience && !$0.quiet && !$0.expired && $0.sentAt == now })
        XCTAssertEqual(SyncEngine.restRequests(Array(keys.prefix(4)), sentAt: now, quiet: false).map(\.keys), [["k0", "k1", "k2", "k3"]])
        XCTAssertEqual(SyncEngine.restRequests(Array(keys.prefix(5)), sentAt: now, quiet: true).map(\.quiet), [true, true])
        XCTAssertTrue(SyncEngine.restRequests([], sentAt: now, quiet: false).isEmpty)
        // A quiet C quiets every one of them, up to the next sync.
        let waiting = requests + [HistoryRequest(keys: ["c"], convenience: true, sentAt: now)]
        XCTAssertEqual(SyncEngine.quietingRestOfSync(waiting).map(\.quiet), [true, true, true, false])
    }

    func testAStackFillsInOverSeveralAnswersAndOnlyCReachesTheClipboard() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let newestFirst = Array(try signedBatch(9, from: peer).reversed())

        answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 9, from: peer)
        answer(engine, Array(newestFirst[1...4]), convenience: false, last: false, expected: 9, from: peer)
        var snap = snapshot(engine)
        XCTAssertEqual(snap.groups.first?.memberIDs.count, 5)
        XCTAssertEqual(snap.groups.first?.expectedSize, 9, "the badge still counts all of the sync")

        answer(engine, Array(newestFirst[5...8]), convenience: false, last: true, expected: 9, from: peer)
        settle()
        snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, 9)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups.first?.memberIDs.count, 9)
        XCTAssertNil(snap.groups.first?.expectedSize, "the real count once the last answer is in")
        XCTAssertEqual(recorder.received.map(\.content), ["item 8"], "C only")
    }

    func testAFreshCStaysAndAnOlderMemberOfItsSyncIsTheOneTheTrimCuts() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        engine.history.add(contentsOf: try signedBatch(Wire.historyCap, from: peer, start: 1_700_000_000, label: "base"))
        let c = try sign("c", at: 1_750_000_000, by: peer)

        answer(engine, [c], convenience: true, last: false, expected: 2, from: peer)
        var contents = snapshot(engine).items.map(\.entry.content)
        XCTAssertEqual(contents.count, Wire.historyCap, "the total stays 25")
        XCTAssertTrue(contents.contains("c"))
        XCTAssertFalse(contents.contains("base 0"), "the oldest item went")
        XCTAssertEqual(engine.queue.sync { engine.batchGroups.convenienceID }, HistoryStore.identity(of: c))

        // Another member of the same sync, older than the rest: it is the one cut, C stays.
        let later = try sign("later member", at: 1_650_000_000, by: peer)
        answer(engine, [later], convenience: false, last: true, expected: 2, from: peer)
        contents = snapshot(engine).items.map(\.entry.content)
        XCTAssertEqual(contents.count, Wire.historyCap)
        XCTAssertTrue(contents.contains("c"))
        XCTAssertFalse(contents.contains("later member"), "older than everything kept: cut at once")
    }

    func testALiveItemAfterASyncIsAboveItsBlockEvenWhenTheBlockIsNewerByTheClock() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        // Dated far in the future: newer than anything made now.
        let newestFirst = Array(try signedBatch(3, from: peer, start: 4_000_000_000, label: "block").reversed())
        answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 3, from: peer)
        answer(engine, Array(newestFirst.dropFirst()), convenience: false, last: true, expected: 3, from: peer)
        engine.sendText("live")
        engine.queue.sync {}

        let snap = snapshot(engine)
        XCTAssertEqual(snap.items.first?.entry.content, "block 2", "by the clock the stack leads")
        let rows = StackPlanner.rows(items: snap.items, groups: snap.blocks)
        XCTAssertEqual(rows.map(\.item.entry.content), ["live", "block 2"], "by arrival the live item does")
        XCTAssertEqual(rows.last?.stack?.memberIDs.count, 3)
    }

    func testPlacementIsNeverSaved() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let newestFirst = Array(try signedBatch(3, from: peer, start: 1_700_000_000).reversed())
        answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 3, from: peer)
        answer(engine, Array(newestFirst.dropFirst()), convenience: false, last: true, expected: 3, from: peer)
        engine.sendText("live")
        engine.queue.sync {}
        XCTAssertFalse(snapshot(engine).blocks.isEmpty)

        let restarted = SyncEngine(config: EngineConfig(storageDirectory: engine.config.storageDirectory), identity: SoftwareIdentity(), secrets: MemorySecretStore())
        engines.append(restarted)
        let snap = snapshot(restarted)
        XCTAssertEqual(snap.items.count, 4)
        XCTAssertTrue(snap.blocks.isEmpty)
        XCTAssertEqual(StackPlanner.rows(items: snap.items, groups: snap.blocks).map(\.id), snap.items.map(\.id), "the pure timeline after a restart")
        XCTAssertEqual(snap.items.map(\.entry.content), snap.items.sorted { DotNetTimestamp.isEarlier($1.entry.timestamp, than: $0.entry.timestamp) }.map(\.entry.content))
    }

    func testAnAnswerTakesValidEntriesNobodyAskedForAndSkipsTheRest() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let stranger = SoftwareIdentity()
        let asked = try sign("asked", at: 1_790_000_000, by: peer)
        let extra = try sign("extra", at: 1_790_000_001, by: peer)
        let outsider = try sign("outsider", at: 1_790_000_002, by: stranger)
        var tampered = try sign("real", at: 1_790_000_003, by: peer)
        tampered.content = "something else"
        let known = try sign("known", at: 1_790_000_004, by: peer)
        engine.history.add(known)
        let gone = try sign("gone", at: 1_790_000_005, by: peer)
        engine.deleted.add([gone])

        let outcome = answer(engine, [extra, outsider, tampered, known, gone], convenience: false, last: true, expected: 1, from: peer, requested: [asked])

        XCTAssertEqual(outcome.fresh.map(\.content), ["extra"], "valid, though not in the request")
        XCTAssertEqual(outcome.rejected, 2, "untrusted and tampered")
        XCTAssertEqual(outcome.known, 1)
        XCTAssertEqual(outcome.deleted, 1)
    }

    func testAPeersDeletionRemovesItemsRemembersKeysAndLeavesTheClipboardAlone() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let newestFirst = Array(try signedBatch(3, from: peer).reversed())
        answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 3, from: peer)
        answer(engine, Array(newestFirst.dropFirst()), convenience: false, last: true, expected: 3, from: peer)
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["item 2"])

        let keys = [key(newestFirst[1]), "a key we never had"]
        let changed = engine.queue.sync { engine.applyRemoteDeletions(keys) }
        settle()

        XCTAssertTrue(changed)
        XCTAssertEqual(snapshot(engine).items.map(\.entry.content), ["item 2", "item 0"])
        XCTAssertEqual(engine.queue.sync { engine.deleted.removingDeletedKeys(keys) }, [], "both are tombstones, even the one we never had")
        XCTAssertEqual(recorder.received.map(\.content), ["item 2"], "never touches the clipboard")
        XCTAssertFalse(engine.queue.sync { engine.applyRemoteDeletions(["a key we never had"]) }, "nothing left to remove")
    }

    func testWhenAPeerDeletesTheFrontTheNextMemberLeadsAndAStackOfOneIsACard() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let newestFirst = Array(try signedBatch(3, from: peer).reversed())
        answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 3, from: peer)
        answer(engine, Array(newestFirst.dropFirst()), convenience: false, last: true, expected: 3, from: peer)

        engine.queue.sync { engine.applyRemoteDeletions([key(newestFirst[0])]) }
        var snap = snapshot(engine)
        var rows = StackPlanner.rows(items: snap.items, groups: snap.blocks)
        XCTAssertEqual(rows.map(\.item.entry.content), ["item 1"], "the next member is the front card")
        XCTAssertEqual(rows.first?.stack?.memberIDs.count, 2)

        engine.queue.sync { engine.applyRemoteDeletions([key(newestFirst[1])]) }
        snap = snapshot(engine)
        rows = StackPlanner.rows(items: snap.items, groups: snap.blocks)
        XCTAssertEqual(rows.map(\.item.entry.content), ["item 0"])
        XCTAssertNil(rows.first?.stack)
        XCTAssertTrue(snap.groups.isEmpty)
    }

    func testADeletedItemOfferedAgainByAnAnswerABatchOrAHeadDoesNotComeBack() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try signedBatch(3, from: peer)
        engine.history.add(contentsOf: entries)
        engine.queue.sync { engine.applyRemoteDeletions([key(entries[2])]) }
        XCTAssertEqual(snapshot(engine).items.count, 2)

        let viaAnswer = answer(engine, [entries[2]], convenience: true, last: true, expected: 1, from: peer)
        XCTAssertTrue(viaAnswer.fresh.isEmpty)
        XCTAssertEqual(viaAnswer.deleted, 1)
        let viaBatch = engine.queue.sync { engine.applyHistoryBatch([entries[2]], from: peer.publicKeyBase64) }
        XCTAssertTrue(viaBatch.fresh.isEmpty)
        XCTAssertEqual(viaBatch.deleted, 1)
        XCTAssertTrue(engine.queue.sync { engine.deleted.contains(entries[2]) }, "a live entry message is dropped for the same reason")
        settle()
        XCTAssertEqual(snapshot(engine).items.count, 2)
        XCTAssertTrue(recorder.received.isEmpty)
    }

    // MARK: - Round 2: the late answer to an expired request

    func testALateAnswerToAnExpiredRequestIsStoredQuietlyWithTheUsualChecks() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let stranger = SoftwareIdentity()
        let entries = try signedBatch(3, from: peer)
        let outsider = try sign("outsider", at: 1_790_000_010, by: stranger)
        let gone = try sign("gone", at: 1_790_000_011, by: peer)
        engine.deleted.add([gone])

        // Even asked for as the convenience request, a late answer is no C.
        let outcome = answer(engine, entries + [outsider, gone], convenience: true, last: true, expected: 3, from: peer, expired: true)
        settle()

        XCTAssertEqual(outcome.fresh.map(\.content), ["item 2", "item 1", "item 0"], "valid and new: stored")
        XCTAssertEqual(outcome.rejected, 1, "an untrusted signer is still refused")
        XCTAssertEqual(outcome.deleted, 1, "and a deleted item still stays out")
        XCTAssertNil(outcome.group)
        XCTAssertTrue(recorder.received.isEmpty, "nothing on the clipboard, no notification")
        let snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, 3)
        XCTAssertTrue(snap.blocks.isEmpty, "no block and no stack: ordinary cards by time")
        XCTAssertNil(engine.queue.sync { engine.batchGroups.convenienceID })
    }

    func testALateAnswerDoesNotJoinOrEndTheStackAnotherRequestIsStillFilling() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let first = try sign("front", at: 1_790_000_100, by: peer)
        let late = try signedBatch(2, from: peer, start: 1_790_000_000, label: "late")

        answer(engine, [first], convenience: true, last: false, expected: 4, from: peer)
        XCTAssertEqual(snapshot(engine).blocks.first?.expectedSize, 4)

        // Last, as far as the open requests go: the marker is not one of them. It still must not end the waiting.
        answer(engine, late, convenience: false, last: true, expected: 4, from: peer, expired: true)
        settle()
        let snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, 3)
        XCTAssertEqual(snap.blocks.count, 1)
        XCTAssertEqual(snap.blocks.first?.memberIDs, [HistoryStore.identity(of: first)], "the late items did not join the block")
        XCTAssertEqual(snap.blocks.first?.expectedSize, 4, "and the block still waits for its real answers")
        XCTAssertEqual(recorder.received.map(\.content), ["front"])
    }

    func testALateAnswerStillAsksForTheBytesOfANewFileButAppliesNothing() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let hash = String(repeating: "ab", count: 32)
        let descriptor = FilePayload(fileName: "late.bin", fileHash: hash, fileSize: 5).jsonString()
        let file = try EntrySigning.sign(content: descriptor, type: Wire.EntryType.file, identity: peer,
                                         timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: 1_790_000_000)))

        answer(engine, [file], convenience: true, last: true, expected: 1, from: peer, expired: true)
        settle()

        XCTAssertEqual(snapshot(engine).items.count, 1)
        XCTAssertEqual(engine.queue.sync { engine.pendingFiles[FileStore.key(hash)]?.apply }, false, "its bytes are wanted, but it is not applied when they come")
        XCTAssertTrue(recorder.received.isEmpty)
    }

    // MARK: - Round 2: one clipboard change when two peers answer at once

    func testASecondConvenienceItemThatIsNotNewerStaysOffTheClipboardButIsStillAdded() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let first = try sign("first C", at: 1_790_000_100, by: peer)
        let older = try sign("older C", at: 1_790_000_050, by: peer)
        let sameTime = try sign("same time C", at: 1_790_000_100, by: peer)
        let newer = try sign("newer C", at: 1_790_000_200, by: peer)

        answer(engine, [first], convenience: true, last: true, expected: 1, from: peer)
        let second = answer(engine, [older], convenience: true, last: true, expected: 1, from: peer)
        let third = answer(engine, [sameTime], convenience: true, last: true, expected: 1, from: peer)
        settle()

        XCTAssertEqual(recorder.received.map(\.content), ["first C"], "older and equal: not on the clipboard")
        XCTAssertEqual(second.fresh.map(\.content), ["older C"], "but in the history")
        XCTAssertEqual(third.fresh.map(\.content), ["same time C"])
        XCTAssertTrue(second.quiet && third.quiet, "not newer than what is here: stored quietly")
        let snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, 3)
        XCTAssertEqual(snap.blocks.count, 1, "only the first leads a block")
        let rows = StackPlanner.rows(items: snap.items, groups: snap.blocks).map(\.item.entry.content)
        XCTAssertEqual(rows.first, "first C")
        XCTAssertEqual(rows.last, "older C", "the others are cards by time")
        XCTAssertEqual(engine.queue.sync { engine.batchGroups.convenienceID }, HistoryStore.identity(of: first), "only what went to the clipboard is protected")

        // A newer one is applied as always, and becomes the one to beat.
        answer(engine, [newer], convenience: true, last: true, expected: 1, from: peer)
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["first C", "newer C"])
        XCTAssertEqual(engine.queue.sync { engine.batchGroups.convenienceID }, HistoryStore.identity(of: newer))
        XCTAssertEqual(engine.queue.sync { engine.lastConvenience?.time }, SyncEngine.ticks(of: newer))
    }

    func testAConvenienceItemAfterTheWindowGoesToTheClipboardEvenIfOlderThanTheLastOne() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let c1 = try sign("c1", at: 1_790_000_100, by: peer)
        let c2 = try sign("c2", at: 1_790_000_050, by: peer)
        let c3 = try sign("c3", at: 1_790_000_080, by: peer)
        let start = Date()

        answer(engine, [c1], convenience: true, last: true, expected: 1, from: peer, now: start)
        // c1 is deleted here, so c2 is newer than everything left - but not than the item
        // that went to the clipboard moments ago.
        engine.queue.sync { _ = engine.applyRemoteDeletions([key(c1)]) }
        let second = answer(engine, [c2], convenience: true, last: true, expected: 1, from: peer, now: start.addingTimeInterval(Wire.requestTimeout - 1))
        XCTAssertFalse(second.quiet, "fresh")
        XCTAssertEqual(snapshot(engine).blocks.last?.frontID, HistoryStore.identity(of: c2), "it leads its block")
        XCTAssertEqual(engine.queue.sync { engine.lastConvenience?.time }, SyncEngine.ticks(of: c1), "89 seconds: still the same reconnect")
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["c1"])

        // Past 90 seconds from c1: a new reconnect, older or not.
        answer(engine, [c3], convenience: true, last: true, expected: 1, from: peer, now: start.addingTimeInterval(Wire.requestTimeout + 1))
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["c1", "c3"])
        XCTAssertEqual(engine.queue.sync { engine.lastConvenience?.time }, SyncEngine.ticks(of: c3))
        XCTAssertTrue(engine.queue.sync { engine.shouldApplyConvenience(c1, now: start.addingTimeInterval(Wire.requestTimeout + 2)) }, "newer than c3")
        XCTAssertFalse(engine.queue.sync { engine.shouldApplyConvenience(c2, now: start.addingTimeInterval(Wire.requestTimeout + 2)) }, "c2 is not newer than c3: 90 seconds are not over")
    }

    func testAConvenienceItemOlderThanAFullHistoryIsCutAtOnceAndProtectsNothing() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        engine.history.add(contentsOf: try signedBatch(Wire.historyCap, from: peer, start: 1_700_000_000, label: "base"))
        let trimmed = try sign("trimmed here long ago", at: 1_600_000_000, by: peer)

        let outcome = answer(engine, [trimmed], convenience: true, last: true, expected: 1, from: peer)
        settle()

        let contents = snapshot(engine).items.map(\.entry.content)
        XCTAssertEqual(contents.count, Wire.historyCap)
        XCTAssertFalse(contents.contains("trimmed here long ago"), "older than everything kept: cut at once")
        XCTAssertTrue(contents.contains("base 0"), "nothing newer went in its place")
        XCTAssertTrue(outcome.fresh.isEmpty)
        XCTAssertTrue(outcome.quiet)
        XCTAssertTrue(recorder.received.isEmpty, "the clipboard never hears of it")
        XCTAssertNil(engine.queue.sync { engine.batchGroups.convenienceID })
    }

    func testASyncWhoseFrontIsNotProtectedLeavesTheProtectionWhereItWas() {
        var tracker = BatchGroupTracker()
        tracker.registerSync(front: "c1", others: [], expectedSize: nil, connection: connectionOne)
        let group = tracker.registerSync(front: "c2", others: ["m"], expectedSize: nil, connection: connectionTwo, protectFront: false)
        XCTAssertEqual(group?.frontID, "c2", "it still leads its stack")
        XCTAssertEqual(tracker.blocks.count, 2)
        XCTAssertEqual(tracker.convenienceID, "c1")
    }

    // MARK: - One card per content, and deleting it

    func testTwoEntriesWithTheSameContentAreOneCardAndDeletingItDeletesBoth() throws {
        let (engine, _) = makeEngine()
        let first = trustedPeer(engine)
        let second = trustedPeer(engine)
        let older = try sign("same text", at: 1_790_000_000, by: first)
        let newer = try sign("same text\r\n", at: 1_790_000_010, by: second)
        let other = try sign("other", at: 1_790_000_005, by: first)
        engine.history.add(contentsOf: [older, newer, other])

        var snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, 3, "both stay in the history")
        let rows = StackPlanner.rows(items: snap.items, groups: snap.blocks)
        XCTAssertEqual(rows.map(\.item.entry.signature), [newer.signature, other.signature], "the newest twin shows, line endings aside")

        engine.deleteItem(id: rows[0].item.id)
        engine.queue.sync {}
        snap = snapshot(engine)
        XCTAssertEqual(snap.items.map(\.entry.content), ["other"], "the hidden twin goes too, or it would come back")
        XCTAssertTrue(engine.queue.sync { engine.deleted.contains(older) && engine.deleted.contains(newer) })
    }

    func testALiveTwinOnTopHidesTheOlderCardEvenInsideAStack() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let newestFirst = Array(try signedBatch(3, from: peer).reversed())
        answer(engine, [newestFirst[0]], convenience: true, last: false, expected: 3, from: peer)
        answer(engine, Array(newestFirst.dropFirst()), convenience: false, last: true, expected: 3, from: peer)
        XCTAssertEqual(StackPlanner.rows(items: snapshot(engine).items, groups: snapshot(engine).blocks).first?.stack?.memberIDs.count, 3)

        // This device copies "item 1" again: on top, and the stack loses its twin.
        engine.sendText("item 1")
        engine.queue.sync {}
        let snap = snapshot(engine)
        let rows = StackPlanner.rows(items: snap.items, groups: snap.blocks)
        XCTAssertEqual(rows.map(\.item.entry.content), ["item 1", "item 2"])
        XCTAssertTrue(rows[0].item.isOwn)
        XCTAssertEqual(rows[1].stack?.memberIDs.count, 2, "counted from the members left")
    }

    // MARK: - Shares: what every device has already

    func testAShareOfWhatIsAlreadyNewestIsNotSignedAgainAndTwoOfOneShareGoOnce() throws {
        let (engine, _) = makeEngine()
        engine.sendText("copied and synced")
        engine.queue.sync {}
        let made = expectation(description: "filter")
        var madeFilter: SendFilter?
        engine.makeSendFilter(newest: 1) { madeFilter = $0; made.fulfill() }
        wait(for: [made], timeout: 5)
        let filter = try XCTUnwrap(madeFilter)
        XCTAssertEqual(filter.prints, [ContentPrint.text("copied and synced")], "the newest entry, before the share")

        let done = expectation(description: "sent")
        done.expectedFulfillmentCount = 3
        var results: [SendResult] = []
        engine.sendText("copied and synced\n", filter: filter) { results.append($0); done.fulfill() }
        engine.sendText("new", filter: filter) { results.append($0); done.fulfill() }
        engine.sendText("new", filter: filter) { results.append($0); done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { if case .sent = $0 { return true } else { return false } }, "reported as shared")
        XCTAssertEqual(snapshot(engine).items.map(\.entry.content), ["new", "copied and synced"], "signed once each")
    }

    /// The app's on-open capture is checked against the history as it is once
    /// the reload of coming back is done - items the Share extension stored
    /// meanwhile included - not against the list it last showed.
    func testTheCaptureCheckSeesTheHistoryAfterTheWorkAlreadyQueued() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        engine.history.add(contentsOf: [try sign("older", at: 1_790_000_000, by: peer), try sign("newer\r\n", at: 1_790_000_001, by: peer)])
        // Another process writes the same history; the reload is queued first.
        let directory = engine.config.storageDirectory
        HistoryStore(directory: directory, fileStore: FileStore(directory: directory)).add(try sign("shared", at: 1_790_000_002, by: peer))
        engine.queue.async { engine.reloadFromDisk() }

        let asked = expectation(description: "prints")
        var answer: (all: Set<String>, newest: Set<String>)?
        engine.contentPrints(newest: 1) { all, newest in
            answer = (all: all, newest: newest)
            asked.fulfill()
        }
        wait(for: [asked], timeout: 5)
        let prints = try XCTUnwrap(answer)
        XCTAssertEqual(prints.all, Set([ContentPrint.text("older"), ContentPrint.text("newer"), ContentPrint.text("shared")]))
        XCTAssertEqual(prints.newest, Set([ContentPrint.text("shared")]), "the shared item is the newest")
    }

    // MARK: - A file waiting for its bytes

    func testAFileWaitingForItsBytesIsAppliedOnlyIfNothingNewerCameAndInTime() {
        let entry = ClipboardEntry(content: "{}", type: Wire.EntryType.file, deviceId: "d", timestamp: "")
        let armed = Date(timeIntervalSince1970: 1_000_000)
        var pending = PendingFile(entry: entry, apply: true, armedAt: armed, armedGeneration: 4, armedSerial: 7)
        XCTAssertTrue(pending.mayApply(now: armed.addingTimeInterval(60), generation: 4, serial: 7))
        XCTAssertTrue(pending.mayApply(now: armed.addingTimeInterval(PendingFile.applyLimit), generation: 4, serial: 7))
        XCTAssertFalse(pending.mayApply(now: armed.addingTimeInterval(PendingFile.applyLimit + 1), generation: 4, serial: 7), "over 10 minutes")
        XCTAssertFalse(pending.mayApply(now: armed, generation: 5, serial: 7), "the user changed the clipboard")
        XCTAssertFalse(pending.mayApply(now: armed, generation: 4, serial: 8), "a newer entry was meant for it")
        pending.apply = false
        XCTAssertFalse(pending.mayApply(now: armed, generation: 4, serial: 7))
        XCTAssertFalse(PendingFile(entry: entry, apply: true).mayApply(now: armed, generation: 0, serial: 0), "never armed")
    }

    func testAnOlderFileWhoseBytesLandAfterANewerItemIsNotApplied() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let bytes = Data("the file".utf8)
        let hash = ContentHash.sha256Hex(bytes)
        let descriptor = FilePayload(fileName: "late.bin", fileHash: hash, fileSize: Int64(bytes.count)).jsonString()
        let file = try EntrySigning.sign(content: descriptor, type: Wire.EntryType.file, identity: peer,
                                         timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: 1_790_000_000)))
        let text = try sign("newer text", at: 1_790_000_001, by: peer)
        engine.queue.sync {
            engine.history.add(file)
            engine.received(file, apply: true)
            engine.history.add(text)
            engine.received(text, apply: true)
            try? engine.files.write(bytes, hash: hash)
            engine.fulfillPendingFile(FileStore.key(hash))
        }
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["newer text"], "the file only finishes its card")

        // On its own, the same arrives and is applied.
        let (fresh, freshRecorder) = makeEngine()
        let sender = trustedPeer(fresh)
        let alone = try EntrySigning.sign(content: descriptor, type: Wire.EntryType.file, identity: sender)
        fresh.queue.sync {
            fresh.history.add(alone)
            fresh.received(alone, apply: true)
            try? fresh.files.write(bytes, hash: hash)
            fresh.fulfillPendingFile(FileStore.key(hash))
        }
        settle()
        XCTAssertEqual(freshRecorder.received.map(\.type), [Wire.EntryType.file])
    }

    /// File hashes are compared whatever their case (sync-dedupe-spec rule 4):
    /// iOS sends them in upper case, the other platforms in lower.
    func testAFileHashNamesTheSameBytesInEitherCase() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let bytes = Data("either case".utf8)
        let lower = ContentHash.sha256Hex(bytes)
        func fileEntry(_ hash: String, at seconds: TimeInterval) throws -> ClipboardEntry {
            try EntrySigning.sign(content: FilePayload(fileName: "a.txt", fileHash: hash, fileSize: Int64(bytes.count)).jsonString(),
                                  type: Wire.EntryType.file, identity: peer,
                                  timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: seconds)))
        }
        let upperEntry = try fileEntry(lower.uppercased(), at: 1_790_000_000)
        let lowerEntry = try fileEntry(lower, at: 1_790_000_001)

        // Waiting under the upper-case hash; the bytes land under the lower-case one.
        engine.queue.sync {
            engine.history.add(upperEntry)
            engine.received(upperEntry, apply: true)
            try? engine.files.write(bytes, hash: lower)
            engine.fulfillPendingFile(FileStore.key(lower))
        }
        settle()
        XCTAssertEqual(recorder.received.map(\.content), [upperEntry.content], "fulfilled")
        XCTAssertTrue(engine.files.exists(lower.uppercased()), "and found in either case")

        // Two entries name the same bytes, one in each case: the blob stays while either does.
        engine.history.add(lowerEntry)
        engine.history.remove(identity: HistoryStore.identity(of: upperEntry))
        XCTAssertTrue(engine.files.exists(lower), "the other entry still uses it")
        engine.history.remove(identity: HistoryStore.identity(of: lowerEntry))
        XCTAssertFalse(engine.files.exists(lower))
    }

    // MARK: - Exported copies

    func testAnExportedCopyGoesWithItsBlobWhenTheItemIsTrimmedAndOrphansGoAtStart() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let bytes = Data("exported".utf8)
        let hash = ContentHash.sha256Hex(bytes)
        try engine.files.write(bytes, hash: hash)
        let file = try EntrySigning.sign(content: FilePayload(fileName: "a.txt", fileHash: hash, fileSize: Int64(bytes.count)).jsonString(),
                                         type: Wire.EntryType.file, identity: peer,
                                         timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: 1_700_000_000)))
        engine.history.add(file)
        let export = try engine.files.exportCopy(hash: hash, fileName: "a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))

        // 25 newer items push it out.
        engine.history.add(contentsOf: try signedBatch(Wire.historyCap, from: peer, start: 1_800_000_000))
        XCTAssertFalse(engine.files.exists(hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path), "the copy held all the bytes")

        // A copy left behind by an older build goes when the app's node starts.
        let orphan = engine.files.exports.appendingPathComponent(String(repeating: "c", count: 64), isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let restarted = SyncEngine(config: EngineConfig(storageDirectory: engine.config.storageDirectory), identity: SoftwareIdentity(), secrets: MemorySecretStore())
        engines.append(restarted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: - Round 2: parsing

    func testAnEmptyKeyIsNoKeyInAHeadARequestOrADelete() {
        let head = HistoryHeadV2.parse(#"{"Keys":["a","","b"],"Times":[1,2,3],"Deleted":["","x"]}"#)
        XCTAssertEqual(head?.keys, ["a", "b"])
        XCTAssertEqual(head?.times, [1, 3], "its time goes with it")
        XCTAssertEqual(head?.deleted, ["x"])
        XCTAssertEqual(KeysMessage.parse(#"{"Keys":["","k",""]}"#)?.keys, ["k"])

        // An empty key does not use up one of the 25 slots.
        let keys = (["\"\""] + (0..<25).map { "\"k\($0)\"" }).joined(separator: ",")
        XCTAssertEqual(HistoryHeadV2.parse("{\"Keys\":[\(keys)]}")?.keys, (0..<25).map { "k\($0)" })
    }

    func testTheWantedListIsTheNewest25InTheSendersOrderEvenWhenTheTimesAreOutOfOrder() {
        // The first key is the oldest, the rest get newer down the list: the 25 newest
        // by time are m5 ... m29, and the first key is not one of them.
        let keys = ["c"] + (1...29).map { "m\($0)" }
        let times = [Int64(1)] + (1...29).map { Int64(1000 + $0) }
        let result = wanted(HistoryHeadV2(keys: keys, times: times, deleted: []))
        XCTAssertEqual(result, (5...29).map { "m\($0)" })
    }
}
