package io.uaena.cliplink.ui

import io.uaena.cliplink.engine.GROUP_MIN_ITEMS

/**
 * What the Synced list shows, top to bottom: an ordinary card, or one stack
 * standing for the items one sync with a peer added. Plain code with no
 * Compose in it, so the rules can be tested.
 */
sealed interface SyncedRow {
    /** The key the lazy list tells this row by. */
    val key: String

    data class Single(val keyed: KeyedItem) : SyncedRow {
        override val key: String get() = keyed.key
    }

    /**
     * [members] are in the order the list has them: the first is the card in
     * front (the item the sync put on the clipboard), then the others, newest
     * first. The row is keyed by the front item, so when the stack is opened
     * the front card is the same list item it was, and when the front item is
     * deleted the next one takes over the row.
     *
     * [expectedSize] is how many items the stack will have once its batch has
     * arrived, while only its newest is here (see [io.uaena.cliplink.engine.GroupTag.expectedSize]);
     * 0 otherwise. The count and the layers follow whichever is more.
     */
    data class Stack(
        val groupId: Long,
        val createdAtMs: Long,
        val members: List<KeyedItem>,
        val expectedSize: Int = 0,
    ) : SyncedRow {
        val front: KeyedItem get() = members.first()
        override val key: String get() = front.key

        /** Items in the stack, counting those still to come. */
        val size: Int get() = maxOf(members.size, expectedSize)

        /** Items hidden behind the front one. */
        val behindCount: Int get() = size - 1

        /** Layers drawn behind the front card: two, or one for a group of two. */
        val layers: Int get() = minOf(MAX_STACK_LAYERS, behindCount)
    }
}

internal const val MAX_STACK_LAYERS = 2

/**
 * [items] (in the order the list shows them: see
 * [io.uaena.cliplink.engine.arrange]) as rows. A group is one [SyncedRow.Stack]
 * placed where its front member is, the first of its members in [items]; its
 * other members are not rows of their own. Every other item keeps its place,
 * so the order of the rest does not change. A group with fewer than
 * [GROUP_MIN_ITEMS] members here is not a stack, unless it expects that many
 * (its front is here and the rest is on its way); one that was opened is not
 * a stack either - its members are rows, together where the stack was.
 */
fun buildRows(items: List<KeyedItem>): List<SyncedRow> {
    val members = LinkedHashMap<Long, MutableList<KeyedItem>>()
    for (keyed in items) {
        val group = keyed.item.group ?: continue
        members.getOrPut(group.id) { ArrayList() }.add(keyed)
    }
    val rows = ArrayList<SyncedRow>(items.size)
    val placed = HashSet<Long>()
    for (keyed in items) {
        val group = keyed.item.group
        val together = group?.let { members[it.id] }
        if (group == null || group.expanded || together == null || maxOf(together.size, group.expectedSize) < GROUP_MIN_ITEMS) {
            rows.add(SyncedRow.Single(keyed))
        } else if (placed.add(group.id)) {
            rows.add(SyncedRow.Stack(group.id, group.createdAtMs, together, group.expectedSize))
        }
    }
    return rows
}

// ---- the motion rules -----------------------------------------------------------

/** How far down a finger has to drag the handle for the stack to be fully open, in dp. */
internal const val EXPAND_DISTANCE_DP = 120f

/** A swipe down at least this fast opens the stack whatever the distance, in dp per second. */
internal const val EXPAND_FLING_DP_PER_SECOND = 700f

/** A drag that got this far (of 0 to 1) opens the stack when let go. */
internal const val EXPAND_COMPLETE_FRACTION = 1f / 3f

/**
 * Whether letting go of the handle opens the stack: it got about a third of
 * the way, or the swipe down was fast. A fast swipe back up closes it.
 */
internal fun expansionCompletes(progress: Float, velocityDpPerSecond: Float): Boolean = when {
    velocityDpPerSecond >= EXPAND_FLING_DP_PER_SECOND -> true
    velocityDpPerSecond <= -EXPAND_FLING_DP_PER_SECOND -> false
    else -> progress >= EXPAND_COMPLETE_FRACTION
}

/** Hidden cards that fly out of an opened stack. A group of hundreds only animates its first screenful; the rest just appear. */
internal const val MAX_ANIMATED_REVEAL = 10

internal const val STAGGER_STEP_MS = 30
internal const val STAGGER_TOTAL_CAP_MS = 400

/**
 * How long card number [index] (0 is the first to move) waits before it moves,
 * out of [count] cards: 30 ms apart, but never more than about 400 ms for the
 * whole group however many there are.
 */
internal fun staggerDelayMs(index: Int, count: Int): Int {
    if (count <= 1 || index <= 0) return 0
    val step = minOf(STAGGER_STEP_MS, STAGGER_TOTAL_CAP_MS / count)
    return index * step
}

/**
 * How one card of an opened stack flies out: it starts [stepsAbove] card
 * heights above its place (behind the front card) and waits [delayMs].
 */
data class RevealSlot(val stepsAbove: Int, val delayMs: Int)

/**
 * The cards of an opened stack that animate, by key: its members behind the
 * front one, newest first, up to [MAX_ANIMATED_REVEAL] of them. [columns] is
 * 1 for the list and 2 for the grid, where two cards share a row.
 */
internal fun revealSlots(stack: SyncedRow.Stack, columns: Int): Map<String, RevealSlot> {
    val behind = stack.members.drop(1).take(MAX_ANIMATED_REVEAL)
    val slots = LinkedHashMap<String, RevealSlot>()
    behind.forEachIndexed { index, keyed ->
        val position = index + 1 // how many cards after the front one
        val rowsBelow = (position + columns - 1) / columns
        slots[keyed.key] = RevealSlot(rowsBelow, staggerDelayMs(index, behind.size))
    }
    return slots
}
