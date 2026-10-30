package io.uaena.cliplink.engine

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp

/**
 * How many new entries one history_batch has to add before the Synced list
 * shows them as one stack instead of as ordinary cards. One new entry is just
 * a card.
 */
const val GROUP_MIN_ITEMS = 2

/** Which batch group an item belongs to, as the list sees it. */
data class GroupTag(
    val id: Long,
    /** When the group was made, in ms since the epoch - lets the list tell a stack that has just arrived from one that was already there. */
    val createdAtMs: Long,
    /**
     * While the group is provisional (its history_head has come but its
     * batch has not): how many items it will have, as the head counted them.
     * The list shows at least this many layers and this count. 0 once the size
     * is final.
     */
    val expectedSize: Int = 0,
    /** The stack was opened: its items are ordinary cards, but stay together below the one that was in front. */
    val expanded: Boolean = false,
)

/**
 * The session blocks as the list lays them out: [front] is the convenience
 * item (null when it is gone, deleted or trimmed), [others] are the other
 * members still here. The list puts the front first and the others, newest
 * first, right below it.
 */
class PlacedBlock(val front: String?, val others: List<String>)

/** What [BatchGroups.place] decided: the stacks, and the blocks most recently arrived first. */
class Placement(val tags: Map<String, GroupTag>, val blocks: List<PlacedBlock>)

/**
 * The session blocks of this device: what arrived together, and in what
 * order. A live item (a copy on either device) is a block of one; a sync with
 * a peer is one block, whose first member is the convenience item (the newest
 * item this device did not have, see HistoryStore.Arrival.Sync) and the rest
 * the other items that arrived with it. Blocks are named by
 * [io.uaena.cliplink.core.ClipboardEntry.deletionKey]. Memory only: a block
 * is never saved or sent to anyone, so after a restart the history shows by
 * timestamp alone.
 *
 * A block of two or more is a group, which the list shows as a stack while
 * it is closed. A group shrinks by itself when a member is deleted or
 * trimmed away (see [resolve]) and is a single card once fewer than
 * [GROUP_MIN_ITEMS] are left - its block stays where it arrived. Opening a
 * stack ([expand]) only turns it into cards: they stay together below the
 * front one, they do not go back to their timestamps.
 *
 * A group can start before its batch has arrived: [provisional] makes it from
 * the convenience item alone (which came first) and the size that was counted,
 * [join] adds what arrives next, and [complete] settles it when the last of it
 * is in.
 *
 * Plain code on purpose, apart from the engine and the screen, so it can be
 * tested alone.
 */
class BatchGroups(private val maxGroups: Int = MAX_GROUPS) {

    private class Block(
        val id: Long,
        /** The convenience item first, then the others in the order they arrived. */
        val members: List<String>,
        val createdAtMs: Long,
        val expectedSize: Int,
        /** [clock] when this block was last made or changed. */
        val stamp: Long,
        /** Still a stack (or about to be one); false for a single card, or a group that ended. Never true again. */
        val grouped: Boolean,
        val expanded: Boolean = false,
    ) {
        fun with(
            members: List<String> = this.members,
            expectedSize: Int = this.expectedSize,
            stamp: Long,
            grouped: Boolean = this.grouped,
            expanded: Boolean = this.expanded,
        ) = Block(id, members, createdAtMs, expectedSize, stamp, grouped, expanded)
    }

    private var blocks: List<Block> = emptyList() // oldest arrival first
    private var lastId = 0L

    /** Counts every change to the blocks; a snapshot of the history is judged by it, see [horizon]. */
    private var clock = 0L

    private fun add(members: List<String>, expectedSize: Int, nowMs: Long): Block {
        val grouped = maxOf(members.size, expectedSize) >= GROUP_MIN_ITEMS
        val block = Block(++lastId, members, nowMs, expectedSize, ++clock, grouped)
        blocks = (blocks + block).takeLast(maxGroups)
        return block
    }

    private fun replace(block: Block) {
        blocks = blocks.map { if (it.id == block.id) block else it }
    }

    /**
     * Makes a block of [newKeys] - the keys of the entries one batch added,
     * the convenience item first - and returns its id when it is a group, or
     * null when there are fewer than [GROUP_MIN_ITEMS] (they are then just
     * cards, but still a block: they arrived together, and now). Entries the
     * batch did not add are not in [newKeys], so they never join a group.
     */
    @Synchronized
    fun record(newKeys: List<String>, nowMs: Long): Long? {
        val members = newKeys.distinct()
        if (members.isEmpty()) return null
        val block = add(members, 0, nowMs)
        return block.id.takeIf { block.grouped }
    }

    /**
     * Makes the block of a sync before the rest of it has arrived:
     * [frontKey], the convenience item, alone for now, and [expectedSize]
     * items to come (counted from the head), so the list can show the whole
     * stack at once. Returns its id, or null when [expectedSize] is under
     * [GROUP_MIN_ITEMS] (the item is then just a card, in a block of its own).
     */
    @Synchronized
    fun provisional(frontKey: String, expectedSize: Int, nowMs: Long): Long? =
        recordSync(frontKey, emptyList(), expectedSize, nowMs)

    /**
     * Makes the block of the first answer of a v2 sync: [frontKey], the
     * convenience item, then [otherKeys] if anything else came with it, and
     * [expectedSize] items in all once the rest of the sync has arrived (0 or
     * 1 when it is not waiting for any). Returns its id when it is a group.
     */
    @Synchronized
    fun recordSync(frontKey: String, otherKeys: List<String>, expectedSize: Int, nowMs: Long): Long? {
        val members = (listOf(frontKey) + otherKeys).distinct()
        val block = add(members, if (expectedSize >= GROUP_MIN_ITEMS) expectedSize else 0, nowMs)
        return block.id.takeIf { block.grouped }
    }

    /**
     * A live item - one copied on a device, or arrived on its own: a block
     * of one, above every block that arrived before it.
     */
    @Synchronized
    fun noteLive(key: String, nowMs: Long) {
        add(listOf(key), 0, nowMs)
    }

    /**
     * Adds [newKeys] to group [id] without settling it: more of the same
     * sync arrived, and more is still to come. Does nothing for a group that
     * is gone (ended, or its newest deleted): the items are then ordinary
     * cards. Returns whether anything changed.
     */
    @Synchronized
    fun join(id: Long, newKeys: List<String>): Boolean {
        val block = blocks.firstOrNull { it.id == id && it.grouped } ?: return false
        val members = (block.members + newKeys).distinct()
        if (members.size == block.members.size) return false
        replace(block.with(members = members, stamp = ++clock))
        return true
    }

    /**
     * Settles group [id]: [newKeys] (what the batch added) join it, and its
     * size is final from now on. A group left with fewer than
     * [GROUP_MIN_ITEMS] members is a single card. Does nothing for a group
     * that is gone (opened before, or its newest deleted): the batch's items
     * are then ordinary cards. Returns whether anything changed, so a caller
     * that settles "just in case" can tell if the list needs a rebuild.
     */
    @Synchronized
    fun complete(id: Long, newKeys: List<String>): Boolean {
        val block = blocks.firstOrNull { it.id == id && it.grouped } ?: return false
        val members = (block.members + newKeys).distinct()
        if (members.size < GROUP_MIN_ITEMS) {
            replace(block.with(members = members, expectedSize = 0, stamp = ++clock, grouped = false))
            return true
        }
        if (block.expectedSize == 0 && members.size == block.members.size) return false
        replace(block.with(members = members, expectedSize = 0, stamp = ++clock))
        return true
    }

    /** [record] for the entries one batch added; [front], the convenience item, is first (default: the newest of them). */
    fun recordBatch(added: List<ClipboardEntry>, nowMs: Long, front: ClipboardEntry? = null): Long? {
        val first = front ?: added.maxByOrNull { DotNetTimestamp.canonical(it.timestamp) }
        val keys = listOfNotNull(first?.deletionKey) + added.filter { it !== first }.map { it.deletionKey }
        return record(keys, nowMs)
    }

    /** Ends group [id]: its members are ordinary cards from now on, and stay where the block is. */
    @Synchronized
    fun dissolve(id: Long) {
        val block = blocks.firstOrNull { it.id == id && it.grouped } ?: return
        replace(block.with(expectedSize = 0, stamp = ++clock, grouped = false))
    }

    /**
     * A stack was opened: its members become ordinary cards, right below the
     * one that was in front and above everything that is not in a block.
     * Returns whether there was a closed stack by that id.
     */
    @Synchronized
    fun expand(id: Long): Boolean {
        val block = blocks.firstOrNull { it.id == id && it.grouped && !it.expanded } ?: return false
        replace(block.with(stamp = ++clock, expanded = true))
        return true
    }

    @Synchronized
    fun clear() {
        blocks = emptyList()
    }

    /**
     * How far the blocks have changed so far. Read BEFORE taking the snapshot
     * of the history that is passed to [resolve] or [place]: a block made or
     * settled after it is not judged against a snapshot that may predate its
     * members.
     */
    @Synchronized
    fun horizon(): Long = clock

    /**
     * The group tag of every key in [present] (the history as it is now) that
     * is still in a group of [GROUP_MIN_ITEMS] or more present members (a
     * provisional group needs just one: the rest is still on its way).
     * A group last changed up to [horizon] that has fewer left is a single
     * card for good: its members were deleted or trimmed away, and they never
     * come back.
     */
    @Synchronized
    fun resolve(present: Set<String>, horizon: Long): Map<String, GroupTag> = place(present, horizon).tags

    /** [resolve], and the blocks in the order the list shows them. */
    @Synchronized
    fun place(present: Set<String>, horizon: Long): Placement {
        val tags = HashMap<String, GroupTag>()
        val placed = ArrayList<PlacedBlock>()
        val kept = ArrayList<Block>(blocks.size)
        for (block in blocks) {
            val here = block.members.filter { it in present }
            val needed = if (block.expectedSize > 0) 1 else GROUP_MIN_ITEMS
            var current = block
            if (block.grouped && here.size < needed) {
                // Made or settled after the snapshot: its members may just not be in it.
                if (block.stamp > horizon) {
                    kept.add(block)
                    continue
                }
                current = block.with(expectedSize = 0, stamp = block.stamp, grouped = false)
            }
            if (here.isEmpty()) {
                if (block.stamp > horizon) kept.add(block)
                continue
            }
            kept.add(current)
            if (current.grouped) {
                val tag = GroupTag(current.id, current.createdAtMs, current.expectedSize, current.expanded)
                here.forEach { tags[it] = tag }
            }
            val front = current.members.first()
            placed.add(PlacedBlock(front.takeIf { it in here }, here.filter { it != front }))
        }
        if (kept.size != blocks.size || kept.indices.any { kept[it] !== blocks[it] }) blocks = kept
        return Placement(tags, placed.asReversed())
    }

    private companion object {
        /** A session that keeps receiving things must not grow this for ever. */
        const val MAX_GROUPS = 64
    }
}

/**
 * [entries] in the order the Synced list shows them: the session [blocks]
 * first, the one that arrived last on top - each with its convenience item
 * in front and the other members right below it, newest first among
 * themselves, whatever their timestamps - and below them every other entry,
 * newest first. Nothing about this order is stored.
 */
fun arrange(entries: List<ClipboardEntry>, blocks: List<PlacedBlock>): List<ClipboardEntry> {
    val timeline = entries.sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
    if (blocks.isEmpty()) return timeline
    val byKey = timeline.groupBy { it.deletionKey }
    val age = HashMap<String, Int>() // 0 is the newest
    timeline.forEachIndexed { index, entry -> age.putIfAbsent(entry.deletionKey, index) }
    val placed = HashSet<String>()
    val result = ArrayList<ClipboardEntry>(timeline.size)
    fun place(key: String) {
        if (placed.add(key)) byKey[key]?.let(result::addAll)
    }
    for (block in blocks) {
        block.front?.let(::place)
        block.others.sortedBy { age[it] ?: Int.MAX_VALUE }.forEach(::place)
    }
    for (entry in timeline) place(entry.deletionKey)
    return result
}
