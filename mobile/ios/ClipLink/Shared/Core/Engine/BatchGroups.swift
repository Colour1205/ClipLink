import Foundation

// Placement of what peers bring in the Synced list. Plain values and plain
// functions, no UI: the engine decides WHICH items belong together and in what
// order they arrived, the planner decides WHAT the list shows, and the SwiftUI
// views only draw the result. Nothing here is saved or sent: after a restart
// the history shows as a plain timeline, newest first, and no peer ever hears
// about a block or a stack.
//
// The list is built from two parts. First the SESSION BLOCKS, the one that
// arrived last on top: a live item (a peer's, or this device's own copy) is a
// block of one, and everything one reconnect brings is one block - the item that
// went on the clipboard (the convenience item, "C") in front and, behind it, the
// rest, collapsed into a stack card until the user opens it. Below them every
// other item, by timestamp. So what just arrived is on top even when it is older
// than something further down, and opening a stack keeps its items together
// right under C instead of scattering them over the timeline.

/// A session block: the entries that arrived together, shown as a single stack
/// card until the user opens it. Members are `HistoryStore.identity(of:)` strings.
public struct BatchGroup: Identifiable, Equatable {
    public let id: String
    public internal(set) var memberIDs: [String]
    /// Set while the block is provisional: a history_head announced this many
    /// members (the front card included), but the rest has not arrived yet.
    /// Nil once it has, or when no head came first.
    public internal(set) var expectedSize: Int?
    /// The front card: the item the reconnect put on the clipboard (C). Nil for
    /// a live item, and once C is gone - then the newest member leads.
    public internal(set) var frontID: String?
    /// The user opened the stack: its items are ordinary cards from then on (they
    /// stay together, in this block).
    public internal(set) var isOpen: Bool

    public init(id: String, memberIDs: [String], expectedSize: Int? = nil, frontID: String? = nil, isOpen: Bool = false) {
        self.id = id
        self.memberIDs = memberIDs
        self.expectedSize = expectedSize
        self.frontID = frontID
        self.isOpen = isOpen
    }

    public var isProvisional: Bool { expectedSize != nil }
    /// What the badge counts: the members so far, or the announced size while
    /// that is bigger.
    public var size: Int { max(memberIDs.count, expectedSize ?? 0) }
    /// Drawn as a stack: two or more items, or one with more on the way, and not
    /// opened. A block of one, or one the user opened, is just cards.
    public var isStack: Bool { !isOpen && !memberIDs.isEmpty && size >= BatchGroupTracker.minStackItems }
}

/// The engine's list of session blocks.
public struct BatchGroupTracker: Equatable {
    /// A batch makes a stack only when it adds at least this many new entries
    /// (GROUP_MIN_ITEMS on the other platforms). One new entry is a normal card.
    public static let groupMinItems = 2
    /// A stack needs a front card and one behind it: with fewer left, the
    /// last member is a normal card again.
    public static let minStackItems = 2

    /// Every block, in the order it arrived: the newest last.
    public private(set) var blocks: [BatchGroup] = []
    /// The blocks drawn as a stack right now.
    public var groups: [BatchGroup] { blocks.filter(\.isStack) }
    /// C of the block that arrived last, while no newer block has: the one entry
    /// history trimming spares (see `HistoryStore.add`). Nil for a live item.
    public private(set) var convenienceID: String?
    private var serial = 0
    /// For each connection that sent a history_head or got the first answer of a
    /// sync, the block that is being filled while the rest is on the way (the
    /// block may be gone by then: its front card deleted).
    private var provisional: [ObjectIdentifier: String] = [:]

    public init() {}

    private mutating func nextID() -> String {
        serial += 1
        return "batch-\(serial)"
    }

    /// A live item: a block of one, on top of everything that came before. It
    /// ends the trim protection of the block before it.
    public mutating func registerLive(_ identity: String) {
        blocks.append(BatchGroup(id: nextID(), memberIDs: [identity]))
        convenienceID = nil
    }

    /// A batch added these new entries, newest first (never entries that were
    /// already known); the first one is C. Returns the stack, or nil when there
    /// are too few for one.
    @discardableResult
    public mutating func register(_ identities: [String]) -> BatchGroup? {
        var seen = Set<String>()
        let unique = identities.filter { seen.insert($0).inserted }
        guard let front = unique.first else { return nil }
        let block = BatchGroup(id: nextID(), memberIDs: unique, frontID: front)
        blocks.append(block)
        convenienceID = front
        return block.isStack ? block : nil
    }

    /// A history_head announced a stack: `front` (its newest entry, C) is in
    /// history already and `expectedSize` entries will be in all, the front one
    /// included. The stack shows at once with just that card; the batch fills
    /// it in (see `registerBatch`). Returns nil, with `front` a block of one,
    /// when `expectedSize` is under 2. A second head on the same connection
    /// finishes the first one's block before it starts its own.
    @discardableResult
    public mutating func registerProvisional(front: String, expectedSize: Int, connection: ObjectIdentifier) -> BatchGroup? {
        finish(connection: connection)
        var block = BatchGroup(id: nextID(), memberIDs: [front], frontID: front)
        if expectedSize >= Self.groupMinItems {
            block.expectedSize = expectedSize
            provisional[connection] = block.id
        }
        blocks.append(block)
        convenienceID = front
        return block.isStack ? block : nil
    }

    /// The history_batch of `connection` added these new entries, newest first
    /// (never known ones). When a head came first, they join the block it made:
    /// same block, the announced size gives way to the real count. If the user
    /// opened that stack in the meantime they join it all the same but it stays
    /// open; if the block is gone (its front card deleted) they stay ordinary
    /// cards. Without a head this is `register`. Returns the stack the entries
    /// are in, if any.
    @discardableResult
    public mutating func registerBatch(_ identities: [String], connection: ObjectIdentifier?) -> BatchGroup? {
        guard let connection, let id = provisional.removeValue(forKey: connection) else { return register(identities) }
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        var seen = Set(blocks[index].memberIDs)
        for identity in identities where seen.insert(identity).inserted {
            blocks[index].memberIDs.append(identity)
        }
        blocks[index].expectedSize = nil
        return blocks[index].isStack ? blocks[index] : nil
    }

    /// The first answer of a version 2 sync on `connection` put `front` (C) and
    /// perhaps `others` in history. They are one new block. `expectedSize` is how
    /// many items the whole sync asked for (the badge counts it while the other
    /// answers are on their way); nil when nothing more is coming. `protectFront`
    /// false: C did not reach the clipboard (another convenience item was just
    /// there), so it still leads the block but the trim protection stays with the
    /// item that did.
    @discardableResult
    public mutating func registerSync(front: String, others: [String], expectedSize: Int?, connection: ObjectIdentifier, protectFront: Bool = true) -> BatchGroup? {
        finish(connection: connection)
        var seen: Set<String> = [front]
        var members = [front]
        for identity in others where seen.insert(identity).inserted { members.append(identity) }
        var block = BatchGroup(id: nextID(), memberIDs: members, frontID: front)
        if let expectedSize, expectedSize > members.count {
            block.expectedSize = expectedSize
            provisional[connection] = block.id
        }
        blocks.append(block)
        if protectFront { convenienceID = front }
        return block.isStack ? block : nil
    }

    /// A later answer of the same sync: these entries join the block `connection`
    /// has been filling. `last` is the final answer: the announced size gives way
    /// to the real count. With no block waiting (C never came, or its block was
    /// deleted) they belong to no block and stay where their timestamps put them.
    @discardableResult
    public mutating func joinSync(_ identities: [String], connection: ObjectIdentifier, last: Bool) -> BatchGroup? {
        guard let id = provisional[connection], let index = blocks.firstIndex(where: { $0.id == id }) else {
            provisional.removeValue(forKey: connection)
            return nil
        }
        var seen = Set(blocks[index].memberIDs)
        for identity in identities where seen.insert(identity).inserted {
            blocks[index].memberIDs.append(identity)
        }
        if last {
            blocks[index].expectedSize = nil
            provisional.removeValue(forKey: connection)
        }
        return blocks[index].isStack ? blocks[index] : nil
    }

    /// What the rest of the block `connection` is filling is not coming (the
    /// connection closed, it was unreadable, it timed out, it added nothing), or
    /// another head took its place: the block counts only the members it has, and
    /// is no stack with fewer than 2. True when a block was changed.
    @discardableResult
    public mutating func finish(connection: ObjectIdentifier) -> Bool {
        guard let id = provisional.removeValue(forKey: connection),
              let index = blocks.firstIndex(where: { $0.id == id })
        else { return false }
        blocks[index].expectedSize = nil
        return true
    }

    /// Members that left history (deleted, cleared, cut by the 25-item cap)
    /// leave their block; a block with none left is gone, one down to a single
    /// member is a normal card (it keeps its place at the top). A provisional
    /// block may hold just its front card.
    public mutating func prune(keeping alive: Set<String>) {
        guard !blocks.isEmpty else { return }
        blocks = blocks.compactMap { block -> BatchGroup? in
            var block = block
            block.memberIDs.removeAll { !alive.contains($0) }
            guard !block.memberIDs.isEmpty else { return nil }
            if let front = block.frontID, !alive.contains(front) { block.frontID = nil }
            return block
        }
        if let id = convenienceID, !alive.contains(id) { convenienceID = nil }
    }

    /// The user opened the stack: it never closes again, and its items stay
    /// together, right under C.
    public mutating func dissolve(id: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].isOpen = true
    }

    public mutating func removeAll() {
        blocks.removeAll()
        provisional.removeAll()
        convenienceID = nil
    }
}

// MARK: - What the list shows

/// One card position in the Synced list: a plain card, or a stack whose front
/// card is `item`.
public struct SyncedRow: Identifiable, Equatable {
    public let item: SyncedItem
    public let stack: StackInfo?

    /// The front card's id, stack or not, so opening a stack keeps that card's
    /// view and only adds the others around it.
    public var id: String { item.id }

    public init(item: SyncedItem, stack: StackInfo?) {
        self.item = item
        self.stack = stack
    }
}

public struct StackInfo: Equatable {
    public let groupID: String
    /// Every member that is still there, the front card (C) first, then the
    /// others newest first.
    public let memberIDs: [String]
    /// Set while the group is provisional (see BatchGroup): more members are on
    /// the way than there are yet.
    public let expectedSize: Int?

    public init(groupID: String, memberIDs: [String], expectedSize: Int? = nil) {
        self.groupID = groupID
        self.memberIDs = memberIDs
        self.expectedSize = expectedSize
    }

    /// Items behind the front card, counting the ones still on the way.
    public var hiddenCount: Int { max(memberIDs.count, expectedSize ?? 0) - 1 }
    /// Layers drawn peeking out below the front card.
    public var layerCount: Int { min(StackMotion.maxLayers, hiddenCount) }
}

public enum StackPlanner {
    /// The rows of the list. First the session blocks, the one that arrived last
    /// on top (`groups` is every block, oldest arrival first, as the tracker keeps
    /// them): a block is its front card (C, else its newest member), then its
    /// other members newest first - collapsed into the front card's stack row,
    /// or, once opened, as ordinary rows right under it. Then every item that is
    /// in no block, by timestamp as `items` has them (newest first). So a block
    /// stays together on top even when its items are older than the rest.
    /// `expanded` holds groups the user already opened (the engine drops them a
    /// moment later, so a snapshot in between cannot close one again).
    public static func rows(items: [SyncedItem], groups: [BatchGroup], expanded: Set<String> = []) -> [SyncedRow] {
        guard !groups.isEmpty else { return items.map { SyncedRow(item: $0, stack: nil) } }
        var rows: [SyncedRow] = []
        rows.reserveCapacity(items.count)
        var placed = Set<String>()
        for group in groups.reversed() {
            let memberIDs = Set(group.memberIDs)
            // The members that are in the list, in list order. An item sits in
            // the newest block that has it.
            var members = items.filter { memberIDs.contains($0.id) && !placed.contains($0.id) }
            guard !members.isEmpty else { continue }
            for member in members { placed.insert(member.id) }
            if let front = group.frontID, let index = members.firstIndex(where: { $0.id == front }), index > 0 {
                let frontItem = members.remove(at: index)
                members.insert(frontItem, at: 0)
            }
            // A provisional block may have only its front card so far.
            let isStack = !group.isOpen && !expanded.contains(group.id)
                && max(members.count, group.expectedSize ?? 0) >= BatchGroupTracker.minStackItems
            if isStack {
                let stack = StackInfo(groupID: group.id, memberIDs: members.map(\.id), expectedSize: group.expectedSize)
                rows.append(SyncedRow(item: members[0], stack: stack))
            } else {
                rows.append(contentsOf: members.map { SyncedRow(item: $0, stack: nil) })
            }
        }
        for item in items where !placed.contains(item.id) {
            rows.append(SyncedRow(item: item, stack: nil))
        }
        return rows
    }
}

// MARK: - Motion numbers

/// The numbers behind the stack's gestures and animations, apart from the
/// views so they can be tested.
public enum StackMotion {
    /// Cards drawn behind the front one.
    public static let maxLayers = 2
    /// A drag this long (points) opens the stack all the way.
    public static let fullDragDistance: Double = 120
    /// Let go past this share of the distance and it opens.
    public static let completeFraction: Double = 1.0 / 3.0
    /// Each card that fans out starts this much (seconds) after the one before.
    public static let staggerStep: Double = 0.03
    /// However many items there are, the last one starts by then.
    public static let maxStagger: Double = 0.4
    /// A very large stack animates only its first cards; the rest appear in place.
    public static let maxAnimatedCards = 10

    /// 0 (closed) to 1 (open) for a finger that moved `translation` points down.
    public static func progress(forDrag translation: Double) -> Double {
        min(max(translation / fullDragDistance, 0), 1)
    }

    /// On release: open when it went far enough, or the swipe was fast
    /// (`projectedEnd` is where the drag would have come to rest).
    public static func shouldExpand(progress: Double, projectedEnd: Double) -> Bool {
        progress >= completeFraction || projectedEnd >= fullDragDistance
    }

    /// `index` counts the hidden items from 1, newest first.
    public static func animates(index: Int) -> Bool {
        index >= 1 && index <= maxAnimatedCards
    }

    public static func staggerDelay(forIndex index: Int) -> Double {
        min(Double(max(index, 0)) * staggerStep, maxStagger)
    }
}
