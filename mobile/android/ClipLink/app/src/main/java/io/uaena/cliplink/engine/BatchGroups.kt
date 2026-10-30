package io.uaena.cliplink.engine

import io.uaena.cliplink.core.ClipboardEntry

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
)

/**
 * The batch groups of this session: which entries arrived together in one
 * history_batch. Memory only - a group is never saved or sent to anyone, so
 * after a restart the history shows as ordinary cards.
 *
 * Members are named by [io.uaena.cliplink.core.ClipboardEntry.deletionKey]. Who
 * is in front is the list's business (the newest member, by timestamp). A group
 * shrinks by itself when a member is deleted or trimmed away (see [resolve])
 * and is gone once fewer than [GROUP_MIN_ITEMS] are left.
 * Opening a stack ends its group ([dissolve]): it never stacks again.
 *
 * A group can start before its batch has arrived: [provisional] makes it from
 * the newest item alone (which came first, in a history_head) and the size the
 * head counted, and [complete] settles it when the batch is stored.
 *
 * Plain code on purpose, apart from the engine and the screen, so it can be
 * tested alone.
 */
class BatchGroups(private val maxGroups: Int = MAX_GROUPS) {

    private class Group(
        val id: Long,
        val members: List<String>,
        val createdAtMs: Long,
        val expectedSize: Int,
        /** [clock] when this group was last made or changed. */
        val stamp: Long,
    )

    private var groups: List<Group> = emptyList() // oldest first
    private var lastId = 0L

    /** Counts every change to the groups; a snapshot of the history is judged by it, see [horizon]. */
    private var clock = 0L

    /**
     * Makes a group of [newKeys] - the keys of the entries one batch added -
     * and returns its id, or null when there are fewer than
     * [GROUP_MIN_ITEMS] (they are then just cards). Entries the batch did not
     * add are not in [newKeys], so they never join a group.
     */
    @Synchronized
    fun record(newKeys: List<String>, nowMs: Long): Long? {
        val members = newKeys.distinct()
        if (members.size < GROUP_MIN_ITEMS) return null
        val id = ++lastId
        groups = (groups + Group(id, members, nowMs, 0, ++clock)).takeLast(maxGroups)
        return id
    }

    /**
     * Makes the group of a history_head: [newestKey] alone for now, and
     * [expectedSize] items to come (the head counted them from its keys), so
     * the list can show the whole stack at once. Returns its id, or null when
     * [expectedSize] is under [GROUP_MIN_ITEMS] (the newest is then just a
     * card).
     */
    @Synchronized
    fun provisional(newestKey: String, expectedSize: Int, nowMs: Long): Long? {
        if (expectedSize < GROUP_MIN_ITEMS) return null
        val id = ++lastId
        groups = (groups + Group(id, listOf(newestKey), nowMs, expectedSize, ++clock)).takeLast(maxGroups)
        return id
    }

    /**
     * Settles group [id]: [newKeys] (what the batch added) join it, and its
     * size is final from now on. A group left with fewer than
     * [GROUP_MIN_ITEMS] members ends. Does nothing for a group that is gone
     * (opened, or its newest deleted): the batch's items are then ordinary
     * cards. Returns whether anything changed, so a caller that settles
     * "just in case" can tell if the list needs a rebuild.
     */
    @Synchronized
    fun complete(id: Long, newKeys: List<String>): Boolean {
        val group = groups.firstOrNull { it.id == id } ?: return false
        val members = (group.members + newKeys).distinct()
        if (members.size < GROUP_MIN_ITEMS) {
            groups = groups.filterNot { it.id == id }
            return true
        }
        if (group.expectedSize == 0 && members.size == group.members.size) return false
        val settled = Group(id, members, group.createdAtMs, 0, ++clock)
        groups = groups.map { if (it.id == id) settled else it }
        return true
    }

    /** [record] for the entries one batch added. */
    fun recordBatch(added: List<ClipboardEntry>, nowMs: Long): Long? = record(added.map { it.deletionKey }, nowMs)

    /** Ends group [id]: its members are ordinary cards from now on. */
    @Synchronized
    fun dissolve(id: Long) {
        if (groups.any { it.id == id }) groups = groups.filterNot { it.id == id }
    }

    @Synchronized
    fun clear() {
        groups = emptyList()
    }

    /**
     * How far the groups have changed so far. Read BEFORE taking the snapshot
     * of the history that is passed to [resolve]: a group made or settled
     * after it is not judged against a snapshot that may predate its members.
     */
    @Synchronized
    fun horizon(): Long = clock

    /**
     * The group tag of every key in [present] (the history as it is now) that
     * is still in a group of [GROUP_MIN_ITEMS] or more present members (a
     * provisional group needs just one: the rest is still on its way).
     * A group last changed up to [horizon] that has fewer left is dropped for
     * good: its members were deleted or trimmed away, and they never come back.
     */
    @Synchronized
    fun resolve(present: Set<String>, horizon: Long): Map<String, GroupTag> {
        val result = HashMap<String, GroupTag>()
        val kept = ArrayList<Group>(groups.size)
        for (group in groups) {
            val here = group.members.filter { it in present }
            val needed = if (group.expectedSize > 0) 1 else GROUP_MIN_ITEMS
            if (here.size < needed) {
                if (group.stamp > horizon) kept.add(group)
                continue
            }
            kept.add(group)
            val tag = GroupTag(group.id, group.createdAtMs, group.expectedSize)
            here.forEach { result[it] = tag }
        }
        if (kept.size != groups.size) groups = kept
        return result
    }

    private companion object {
        /** A session that keeps receiving batches must not grow this for ever. */
        const val MAX_GROUPS = 64
    }
}
