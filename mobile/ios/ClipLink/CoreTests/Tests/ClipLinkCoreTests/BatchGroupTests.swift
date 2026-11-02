import XCTest
@testable import ClipLinkCore

/// How a history_batch is applied (as one unit) and how the items it brings
/// are stacked in the Synced list. The pure parts (tracker, planner, motion
/// numbers) need no engine; the rest drive one engine's `applyHistoryBatch`
/// directly, without sockets.
final class BatchGroupTests: XCTestCase {

    // MARK: - Tracker

    func testOneNewEntryIsNoGroupAndTwoAre() {
        var tracker = BatchGroupTracker()
        XCTAssertNil(tracker.register([]))
        XCTAssertNil(tracker.register(["a"]))
        XCTAssertNil(tracker.register(["a", "a"]), "the same entry twice is still one entry")
        XCTAssertTrue(tracker.groups.isEmpty)

        let group = tracker.register(["b", "a"])
        XCTAssertEqual(group?.memberIDs, ["b", "a"])
        XCTAssertEqual(tracker.groups.count, 1)
        XCTAssertEqual(BatchGroupTracker.groupMinItems, 2)
    }

    func testTwoBatchesMakeTwoSeparateGroups() {
        var tracker = BatchGroupTracker()
        let first = tracker.register(["a", "b"])
        let second = tracker.register(["c", "d", "e"])
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(tracker.groups.map(\.memberIDs), [["a", "b"], ["c", "d", "e"]])
    }

    func testPruneShrinksGroupsAndDropsOnesDownToOne() {
        var tracker = BatchGroupTracker()
        tracker.register(["a", "b", "c"])
        tracker.register(["d", "e"])
        tracker.prune(keeping: ["a", "b", "d"])
        XCTAssertEqual(tracker.groups.map(\.memberIDs), [["a", "b"]], "the second group is down to one member: a normal card")
        tracker.prune(keeping: [])
        XCTAssertTrue(tracker.groups.isEmpty, "a group with every member deleted disappears")
    }

    func testDissolveAndClear() {
        var tracker = BatchGroupTracker()
        let a = tracker.register(["a", "b"])!
        tracker.register(["c", "d"])
        tracker.dissolve(id: a.id)
        XCTAssertEqual(tracker.groups.map(\.memberIDs), [["c", "d"]])
        tracker.removeAll()
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

    private func items(_ ids: [String]) -> [SyncedItem] { ids.map(item) }

    func testAStackIsOnTopWithItsFrontCardAndTheOtherCardsKeepTheirOrder() {
        // "live" arrived on its own before the batch, "old" is older than it.
        let list = items(["live", "g1", "mid", "g2", "g3", "old"])
        let groups = [BatchGroup(id: "x", memberIDs: ["g1", "g2", "g3"])]
        let rows = StackPlanner.rows(items: list, groups: groups)
        XCTAssertEqual(rows.map(\.id), ["g1", "live", "mid", "old"], "the block is on top, every other card keeps its order")
        XCTAssertEqual(rows[0].stack?.memberIDs, ["g1", "g2", "g3"], "the newest member is the front card")
        XCTAssertEqual(rows[0].stack?.hiddenCount, 2)
        XCTAssertEqual(rows[0].stack?.layerCount, 2)
        XCTAssertEqual(rows[0].item.id, "g1")
        XCTAssertNil(rows[1].stack)
    }

    func testLayersBehindTheFront() {
        let two = StackPlanner.rows(items: items(["a", "b"]), groups: [BatchGroup(id: "x", memberIDs: ["a", "b"])])
        XCTAssertEqual(two.first?.stack?.layerCount, 1, "2 items: 1 layer behind")
        let many = StackPlanner.rows(items: items(["a", "b", "c", "d", "e"]), groups: [BatchGroup(id: "x", memberIDs: ["a", "b", "c", "d", "e"])])
        XCTAssertEqual(many.first?.stack?.layerCount, 2)
        XCTAssertEqual(many.first?.stack?.hiddenCount, 4)
    }

    func testDeletingTheFrontMakesTheNextOneTheFrontAndOneLeftIsANormalCard() {
        let groups = [BatchGroup(id: "x", memberIDs: ["a", "b", "c"])]
        var rows = StackPlanner.rows(items: items(["b", "c"]), groups: groups)
        XCTAssertEqual(rows.map(\.id), ["b"])
        XCTAssertEqual(rows.first?.stack?.memberIDs, ["b", "c"])

        // Down to one (the engine would also have pruned the group by now).
        rows = StackPlanner.rows(items: items(["c"]), groups: groups)
        XCTAssertEqual(rows.map(\.id), ["c"])
        XCTAssertNil(rows.first?.stack)
    }

    func testOpenedGroupsAreOrdinaryCards() {
        let list = items(["a", "b", "c", "d"])
        let groups = [BatchGroup(id: "x", memberIDs: ["a", "b", "c"])]
        XCTAssertEqual(StackPlanner.rows(items: list, groups: groups, expanded: ["x"]).map(\.id), ["a", "b", "c", "d"])
        XCTAssertTrue(StackPlanner.rows(items: list, groups: groups, expanded: ["x"]).allSatisfy { $0.stack == nil })
    }

    func testTwoGroupsAreTwoStacks() {
        let list = items(["a", "c", "b", "d", "e"])
        let groups = [BatchGroup(id: "one", memberIDs: ["a", "b"]), BatchGroup(id: "two", memberIDs: ["c", "d", "e"])]
        let rows = StackPlanner.rows(items: list, groups: groups)
        XCTAssertEqual(rows.map(\.id), ["c", "a"], "the block that arrived last is on top")
        XCTAssertEqual(rows[0].stack?.memberIDs, ["c", "d", "e"])
        XCTAssertEqual(rows[1].stack?.memberIDs, ["a", "b"])
    }

    func testNoGroupsLeavesTheListAlone() {
        let list = items(["a", "b", "c"])
        XCTAssertEqual(StackPlanner.rows(items: list, groups: []).map(\.item), list)
    }

    // MARK: - Motion numbers

    func testDragStretchesLikeARubberBand() {
        XCTAssertEqual(StackMotion.progress(forDrag: -30), 0)
        XCTAssertEqual(StackMotion.progress(forDrag: 0), 0)
        // Half of the reach at the softness distance.
        XCTAssertEqual(StackMotion.progress(forDrag: 120), 0.4, accuracy: 0.0001)
        // About half way open at the commit point, and never all the way.
        XCTAssertEqual(StackMotion.progress(forDrag: 220), 0.8 * 220 / 340, accuracy: 0.0001)
        XCTAssertLessThan(StackMotion.progress(forDrag: 100_000), StackMotion.rubberReach)
        XCTAssertGreaterThan(StackMotion.progress(forDrag: 100_000), 0.79)
        XCTAssertGreaterThan(StackMotion.progress(forDrag: 61), StackMotion.progress(forDrag: 60))
    }

    func testCardsPopAtTheCommitPointAndGoBackAboveTheReleasePoint() {
        XCTAssertFalse(StackMotion.reachedCommit(219))
        XCTAssertTrue(StackMotion.reachedCommit(220))
        XCTAssertTrue(StackMotion.shouldCollapse(149))
        XCTAssertFalse(StackMotion.shouldCollapse(150))
        XCTAssertFalse(StackMotion.shouldCollapse(200), "between the two points nothing changes, so it does not flicker")
    }

    func testWhenALetGoOpensTheStack() {
        XCTAssertTrue(StackMotion.shouldExpand(translation: 220, velocity: 0))
        XCTAssertFalse(StackMotion.shouldExpand(translation: 219, velocity: 0))
        // A fast swipe down opens it however short; one up as fast keeps it shut.
        XCTAssertTrue(StackMotion.shouldExpand(translation: 20, velocity: 700))
        XCTAssertFalse(StackMotion.shouldExpand(translation: 300, velocity: -700))
        XCTAssertFalse(StackMotion.shouldExpand(translation: 100, velocity: 699))
    }

    func testTheCountAndHandleFadeAndTheLayersSpread() {
        XCTAssertEqual(StackMotion.chromeOpacity(progress: 0, fade: 0), 1)
        XCTAssertEqual(StackMotion.chromeOpacity(progress: 0.5, fade: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.chromeOpacity(progress: 0.8, fade: 0), 0)
        XCTAssertEqual(StackMotion.chromeOpacity(progress: 0, fade: 1), 0)
        XCTAssertEqual(StackMotion.layerShift(depth: 1, stretch: 0), 8)
        XCTAssertEqual(StackMotion.layerShift(depth: 2, stretch: 0.5), 56, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.layerOpacity(depth: 1, fade: 0), 1)
        XCTAssertEqual(StackMotion.layerOpacity(depth: 2, fade: 0), 0.78, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.layerOpacity(depth: 1, fade: 1), 0)
    }

    func testRevealedCardsStartWhereTheirLayersWere() {
        XCTAssertEqual(StackMotion.startPeek(index: 1, stretch: 0), 8)
        XCTAssertEqual(StackMotion.startPeek(index: 2, stretch: 0.5), 56, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.startPeek(index: 7, stretch: 1), 96, accuracy: 0.0001, "past the layers drawn, with the last one")
        XCTAssertEqual(StackMotion.startInsetFraction(index: 1, width: 240), 0.1, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.startInsetFraction(index: 2, width: 40), 0.4, accuracy: 0.0001, "capped")
        XCTAssertEqual(StackMotion.startInsetFraction(index: 1, width: 0), 0)
        // A 240 x 100 card 100 below the front card's bottom edge, in the same column.
        let start = StackMotion.revealStart(index: 1, stretch: 0, frontMidX: 120, frontBottom: 200,
                                            ownMidX: 120, ownMidY: 300, ownWidth: 240, ownHeight: 100)
        XCTAssertEqual(start.scale, 0.9, accuracy: 0.0001)
        XCTAssertEqual(start.dx, 0, accuracy: 0.0001)
        // Its scaled bottom edge (300 - 137 + 45) is 8 below the front card's.
        XCTAssertEqual(start.dy, -137, accuracy: 0.0001)
        // In the other column of the grid it comes across too.
        let across = StackMotion.revealStart(index: 2, stretch: 0.5, frontMidX: 90, frontBottom: 200,
                                             ownMidX: 270, ownMidY: 120, ownWidth: 160, ownHeight: 80)
        XCTAssertEqual(across.dx, -180, accuracy: 0.0001)
        XCTAssertEqual(across.scale, 0.7, accuracy: 0.0001)
        XCTAssertEqual(across.dy, 200 + 56 - 28 - 120, accuracy: 0.0001)
    }

    func testDragVelocityFollowsTheLastMoves() {
        var tracker = DragVelocity()
        XCTAssertEqual(tracker.velocity, 0)
        tracker.add(0, at: 10)
        XCTAssertEqual(tracker.velocity, 0, "one point is no speed")
        tracker.add(10, at: 10.01)
        tracker.add(30, at: 10.05)
        XCTAssertEqual(tracker.velocity, 600, accuracy: 0.001)
        // The finger rests, then lets go where it rested: it is still.
        tracker.add(30, at: 10.5)
        XCTAssertEqual(tracker.velocity, 0, accuracy: 0.001)
        // Only the last tenth of a second counts.
        tracker.add(130, at: 10.55)
        tracker.add(230, at: 10.6)
        XCTAssertEqual(tracker.velocity, 2000, accuracy: 0.001)
        tracker.reset()
        XCTAssertEqual(tracker.velocity, 0)
    }

    func testOnlyWhatJustArrivedInABlockIsFresh() {
        var fresh = FreshArrivals()
        // What the list first shows is not news.
        fresh.note(items: ["a", "b"], blockMembers: ["a"], now: 100)
        XCTAssertFalse(fresh.isFresh("a", now: 100))
        // A live item or a batch: in a block.
        fresh.note(items: ["c", "d", "a", "b"], blockMembers: ["a", "c", "d"], now: 101)
        XCTAssertTrue(fresh.isFresh("c", now: 101))
        XCTAssertTrue(fresh.isFresh("d", now: 103.4))
        XCTAssertFalse(fresh.isFresh("c", now: 103.5), "2.5 s later it is an ordinary card")
        XCTAssertFalse(fresh.isFresh("a", now: 101))
        // A late answer, placed by time: in no block.
        fresh.note(items: ["c", "d", "a", "late", "b"], blockMembers: ["a", "c", "d"], now: 102)
        XCTAssertFalse(fresh.isFresh("late", now: 102))
        XCTAssertTrue(fresh.isFresh("c", now: 102), "still fresh while the list changes around it")
        // Gone and back again is news again.
        fresh.note(items: ["a", "b"], blockMembers: ["a"], now: 110)
        fresh.note(items: ["c", "a", "b"], blockMembers: ["a", "c"], now: 111)
        XCTAssertTrue(fresh.isFresh("c", now: 111))
    }

    func testStaggerIsCappedAndBigStacksAnimateOnlyTheFirstCards() {
        XCTAssertEqual(StackMotion.staggerDelay(forIndex: 1), 0.03, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.staggerDelay(forIndex: 5), 0.15, accuracy: 0.0001)
        XCTAssertEqual(StackMotion.staggerDelay(forIndex: 500), 0.4, accuracy: 0.0001)
        XCTAssertTrue(StackMotion.animates(index: 1))
        XCTAssertTrue(StackMotion.animates(index: StackMotion.maxAnimatedCards))
        XCTAssertFalse(StackMotion.animates(index: StackMotion.maxAnimatedCards + 1))
        XCTAssertFalse(StackMotion.animates(index: 0), "the front card is already there")
    }

    // MARK: - Applying a batch in the engine

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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-batch-\(UUID().uuidString)")
        directories.append(dir)
        let engine = SyncEngine(config: EngineConfig(storageDirectory: dir), identity: SoftwareIdentity(), secrets: MemorySecretStore())
        let recorder = Recorder()
        engine.delegate = recorder
        engines.append(engine)
        return (engine, recorder)
    }

    /// A trusted peer: its public key is in the engine's trust list.
    private func trustedPeer(_ engine: SyncEngine) -> SoftwareIdentity {
        let peer = SoftwareIdentity()
        engine.trust.trust(peer.publicKeyBase64)
        return peer
    }

    /// `count` text entries from `peer`, one second apart from `start`, oldest first.
    private func batch(from peer: IdentitySigner, count: Int, start: TimeInterval = 1_790_000_000, label: String = "item") throws -> [ClipboardEntry] {
        try (0..<count).map { index in
            try EntrySigning.sign(content: "\(label) \(index)", type: Wire.EntryType.text, identity: peer,
                                  timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: start + TimeInterval(index))))
        }
    }

    private func apply(_ engine: SyncEngine, _ entries: [ClipboardEntry], from peer: IdentitySigner) -> SyncEngine.HistoryBatchOutcome {
        engine.queue.sync { engine.applyHistoryBatch(entries, from: peer.publicKeyBase64) }
    }

    private func snapshot(_ engine: SyncEngine) -> EngineSnapshot {
        engine.queue.sync { engine.buildSnapshot() }
    }

    /// Lets queued engine work finish and its main-queue hand-offs run.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    func testABatchReachesTheUIAsOneUpdateAndOneClipboardApply() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 6)

        let outcome = apply(engine, entries, from: peer)
        settle()

        XCTAssertEqual(outcome.fresh.count, 6)
        XCTAssertEqual(outcome.fresh.first?.content, "item 5", "newest first")
        let counts = Set(recorder.snapshots.map { $0.items.count })
        XCTAssertFalse(recorder.snapshots.isEmpty)
        XCTAssertEqual(counts, [6], "no update ever showed part of the batch")
        XCTAssertEqual(recorder.received.map(\.content), ["item 5"], "one apply, for the newest item only")
        let last = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(last.groups.count, 1)
        XCTAssertEqual(last.groups.first?.memberIDs.count, 6)
        XCTAssertEqual(last.items.first?.entry.content, "item 5")
    }

    func testNewKnownDeletedAndRejectedEntriesAreToldApart() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let stranger = SoftwareIdentity()
        var entries = try batch(from: peer, count: 5)
        // Already here: the first one arrived earlier.
        engine.history.add(entries[0])
        // Deleted here: the second.
        engine.deleted.add([entries[1]])
        // Signed by a device that is not trusted.
        entries.append(try batch(from: stranger, count: 1, label: "stranger")[0])
        // Right device, wrong content: the signature fails.
        var tampered = try batch(from: peer, count: 1, start: 1_790_000_100, label: "real")[0]
        tampered.content = "something else"
        entries.append(tampered)

        let outcome = apply(engine, entries, from: peer)

        XCTAssertEqual(outcome.fresh.map(\.content), ["item 4", "item 3", "item 2"])
        XCTAssertEqual(outcome.known, 1)
        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(outcome.rejected, 2)
        XCTAssertEqual(outcome.group?.memberIDs.count, 3, "the known and deleted entries are not in the group")
    }

    func testOneNewEntryIsNotAGroup() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let outcome = apply(engine, try batch(from: peer, count: 1), from: peer)
        XCTAssertEqual(outcome.fresh.count, 1)
        XCTAssertNil(outcome.group)
        XCTAssertTrue(snapshot(engine).groups.isEmpty)
    }

    func testTheSameHistoryAgainAddsNothingAndMakesNoGroup() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        let entries = try batch(from: peer, count: 4)
        _ = apply(engine, entries, from: peer)
        settle()
        let appliedBefore = recorder.received.count

        let again = apply(engine, entries, from: peer)
        settle()

        XCTAssertTrue(again.fresh.isEmpty)
        XCTAssertNil(again.group)
        XCTAssertEqual(again.known, 4)
        XCTAssertEqual(snapshot(engine).groups.count, 1, "still only the first group")
        XCTAssertEqual(recorder.received.count, appliedBefore, "nothing applied again")
    }

    func testTwoPeersMakeTwoGroups() throws {
        let (engine, _) = makeEngine()
        let first = trustedPeer(engine)
        let second = trustedPeer(engine)
        _ = apply(engine, try batch(from: first, count: 3, label: "one"), from: first)
        _ = apply(engine, try batch(from: second, count: 2, start: 1_790_000_500, label: "two"), from: second)
        let groups = snapshot(engine).groups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.memberIDs.count), [3, 2])
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }

    func testTheNewestNewItemIsAppliedEvenWhenSomethingNewerIsAlreadyHere() throws {
        let (engine, recorder) = makeEngine()
        let peer = trustedPeer(engine)
        // Something newer is already here.
        engine.history.add(try batch(from: peer, count: 1, start: 1_800_000_000, label: "newer")[0])
        _ = apply(engine, try batch(from: peer, count: 3), from: peer)
        settle()
        XCTAssertEqual(recorder.received.map(\.content), ["item 2"], "a reconnect puts the newest item it brought on the clipboard, old or not")
    }

    func testTheHistoryCapTrimsAGroup() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let first = apply(engine, try batch(from: peer, count: Wire.historyCap), from: peer)
        XCTAssertEqual(first.group?.memberIDs.count, Wire.historyCap)
        // Two newer entries push the two oldest out.
        _ = apply(engine, try batch(from: peer, count: 2, start: 1_790_001_000, label: "later"), from: peer)
        let snap = snapshot(engine)
        XCTAssertEqual(snap.items.count, Wire.historyCap)
        XCTAssertEqual(snap.groups.map(\.memberIDs.count), [Wire.historyCap - 2, 2])
    }

    func testDeletingMembersShrinksAndThenDropsTheGroup() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        _ = apply(engine, try batch(from: peer, count: 3), from: peer)
        var snap = snapshot(engine)
        let front = try XCTUnwrap(snap.items.first)

        engine.deleteItem(id: front.id)
        engine.queue.sync {}
        snap = snapshot(engine)
        XCTAssertEqual(snap.groups.first?.memberIDs.count, 2)
        let rows = StackPlanner.rows(items: snap.items, groups: snap.groups)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item.entry.content, "item 1", "the next most recent item is the front now")

        engine.deleteItem(id: try XCTUnwrap(snap.items.first).id)
        engine.queue.sync {}
        snap = snapshot(engine)
        XCTAssertTrue(snap.groups.isEmpty, "one member left: a normal card")
        XCTAssertEqual(snap.items.count, 1)
    }

    func testClearingHistoryRemovesGroups() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        _ = apply(engine, try batch(from: peer, count: 4), from: peer)
        XCTAssertEqual(snapshot(engine).groups.count, 1)
        engine.clearHistory()
        engine.queue.sync {}
        let snap = snapshot(engine)
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertTrue(snap.items.isEmpty)
    }

    func testOpeningAGroupDissolvesItAndKeepsTheItems() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        let outcome = apply(engine, try batch(from: peer, count: 3), from: peer)
        engine.dissolveGroup(id: try XCTUnwrap(outcome.group).id)
        engine.queue.sync {}
        let snap = snapshot(engine)
        XCTAssertTrue(snap.groups.isEmpty)
        XCTAssertEqual(snap.items.count, 3)
    }

    func testGroupsAreNeverSaved() throws {
        let (engine, _) = makeEngine()
        let peer = trustedPeer(engine)
        _ = apply(engine, try batch(from: peer, count: 3), from: peer)
        let dir = engine.config.storageDirectory
        // A new engine over the same storage (a restart): the items are there, no group.
        let restarted = SyncEngine(config: EngineConfig(storageDirectory: dir), identity: SoftwareIdentity(), secrets: MemorySecretStore())
        engines.append(restarted)
        let snap = snapshot(restarted)
        XCTAssertEqual(snap.items.count, 3)
        XCTAssertTrue(snap.groups.isEmpty)
    }
}
