import Foundation

// Stacking of the items one history_batch brings. Plain values and plain
// functions, no UI: the engine decides WHICH items belong together, the
// planner decides WHAT the Synced list shows, and the SwiftUI views only draw
// the result. Nothing here is saved or sent: after a restart the history
// shows as ordinary cards, and no peer ever hears about a group.

/// The entries ONE history_batch added, shown as a single stack until the user
/// opens it. Members are `HistoryStore.identity(of:)` strings.
public struct BatchGroup: Identifiable, Equatable {
    public let id: String
    public internal(set) var memberIDs: [String]
    /// Set while the group is provisional: a history_head announced this many
    /// members (the front card included), but the history_batch with the rest
    /// has not arrived yet. Nil once it has, or when no head came first.
    public internal(set) var expectedSize: Int?

    public init(id: String, memberIDs: [String], expectedSize: Int? = nil) {
        self.id = id
        self.memberIDs = memberIDs
        self.expectedSize = expectedSize
    }

    public var isProvisional: Bool { expectedSize != nil }
    /// What the badge counts: the members so far, or the announced size while
    /// that is bigger.
    public var size: Int { max(memberIDs.count, expectedSize ?? 0) }
}

/// The engine's list of live groups.
public struct BatchGroupTracker: Equatable {
    /// A batch makes a group only when it adds at least this many new entries
    /// (GROUP_MIN_ITEMS on the other platforms). One new entry is a normal card.
    public static let groupMinItems = 2
    /// A stack needs a front card and one behind it: with fewer left, the
    /// last member is a normal card again.
    public static let minStackItems = 2

    public private(set) var groups: [BatchGroup] = []
    private var serial = 0
    /// For each connection that sent a history_head, the group that head made
    /// while its history_batch is on the way (the group may be gone by then:
    /// opened by the user, or its front card deleted).
    private var provisional: [ObjectIdentifier: String] = [:]

    public init() {}

    /// A batch added these new entries (never entries that were already
    /// known). Returns the new group, or nil when there are too few.
    @discardableResult
    public mutating func register(_ identities: [String]) -> BatchGroup? {
        var seen = Set<String>()
        let unique = identities.filter { seen.insert($0).inserted }
        guard unique.count >= Self.groupMinItems else { return nil }
        serial += 1
        let group = BatchGroup(id: "batch-\(serial)", memberIDs: unique)
        groups.append(group)
        return group
    }

    /// A history_head announced a stack: `front` (its newest entry) is in
    /// history already and `expectedSize` entries will be in all, the front one
    /// included. The group shows at once with just that card; the batch fills
    /// it in (see `registerBatch`). Nil, and no group, when `expectedSize` is
    /// under 2. A second head on the same connection finishes the first one's
    /// group before it starts its own.
    @discardableResult
    public mutating func registerProvisional(front: String, expectedSize: Int, connection: ObjectIdentifier) -> BatchGroup? {
        finish(connection: connection)
        guard expectedSize >= Self.groupMinItems else { return nil }
        serial += 1
        let group = BatchGroup(id: "batch-\(serial)", memberIDs: [front], expectedSize: expectedSize)
        groups.append(group)
        provisional[connection] = group.id
        return group
    }

    /// The history_batch of `connection` added these new entries (never known
    /// ones). When a head came first, they join the group it made: same group,
    /// the announced size gives way to the real count, and a group left with
    /// fewer than 2 members is gone. If that group was opened or removed in
    /// the meantime they stay ordinary cards. Without a head this is
    /// `register`. Returns the group the entries are in, if any.
    @discardableResult
    public mutating func registerBatch(_ identities: [String], connection: ObjectIdentifier?) -> BatchGroup? {
        guard let connection, let id = provisional.removeValue(forKey: connection) else { return register(identities) }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return nil }
        var seen = Set(groups[index].memberIDs)
        for identity in identities where seen.insert(identity).inserted {
            groups[index].memberIDs.append(identity)
        }
        groups[index].expectedSize = nil
        if groups[index].memberIDs.count < Self.minStackItems {
            groups.remove(at: index)
            return nil
        }
        return groups[index]
    }

    /// The batch a head announced is not coming (the connection closed, it was
    /// unreadable, or it added nothing), or another head took its place: the
    /// group counts only the members it has, and is gone with fewer than 2.
    /// True when a group was changed.
    @discardableResult
    public mutating func finish(connection: ObjectIdentifier) -> Bool {
        guard let id = provisional.removeValue(forKey: connection),
              let index = groups.firstIndex(where: { $0.id == id })
        else { return false }
        groups[index].expectedSize = nil
        if groups[index].memberIDs.count < Self.minStackItems { groups.remove(at: index) }
        return true
    }

    /// Members that left history (deleted, cleared, cut by the 25-item cap)
    /// leave their group; a group down to one member, or none, is gone. A
    /// provisional group may hold just its front card.
    public mutating func prune(keeping alive: Set<String>) {
        guard !groups.isEmpty else { return }
        groups = groups.compactMap { group -> BatchGroup? in
            var group = group
            group.memberIDs.removeAll { !alive.contains($0) }
            let enough = group.memberIDs.count >= Self.minStackItems || (group.isProvisional && !group.memberIDs.isEmpty)
            return enough ? group : nil
        }
    }

    /// The user opened the stack: it never closes again.
    public mutating func dissolve(id: String) {
        groups.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        groups.removeAll()
        provisional.removeAll()
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
    /// Every member that is still there, newest (the front card) first.
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
    /// The rows of the list, newest first. A stack sits where its newest member
    /// would be and its other members are not rows of their own; every other
    /// card keeps its place. `expanded` holds groups the user already opened
    /// (the engine drops them a moment later, so a snapshot in between cannot
    /// close one again).
    public static func rows(items: [SyncedItem], groups: [BatchGroup], expanded: Set<String> = []) -> [SyncedRow] {
        guard !groups.isEmpty else { return items.map { SyncedRow(item: $0, stack: nil) } }
        var groupIndex: [String: Int] = [:]
        for (index, group) in groups.enumerated() where !expanded.contains(group.id) {
            for id in group.memberIDs { groupIndex[id] = index }
        }
        guard !groupIndex.isEmpty else { return items.map { SyncedRow(item: $0, stack: nil) } }
        // The members that are in the list, in list order.
        var present: [Int: [String]] = [:]
        for item in items {
            if let index = groupIndex[item.id] { present[index, default: []].append(item.id) }
        }
        var rows: [SyncedRow] = []
        rows.reserveCapacity(items.count)
        for item in items {
            // A provisional group may have only its front card so far.
            guard let index = groupIndex[item.id], let members = present[index],
                  max(members.count, groups[index].expectedSize ?? 0) >= BatchGroupTracker.minStackItems
            else {
                rows.append(SyncedRow(item: item, stack: nil))
                continue
            }
            // Only the newest member makes a row; the rest are inside it.
            if members.first == item.id {
                let stack = StackInfo(groupID: groups[index].id, memberIDs: members, expectedSize: groups[index].expectedSize)
                rows.append(SyncedRow(item: item, stack: stack))
            }
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
