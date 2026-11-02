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
 * [opened] says, by group id, what the user did last to a stack that the
 * items may not show yet: opened it (true), or put it back (false).
 */
fun buildRows(items: List<KeyedItem>, opened: Map<Long, Boolean> = emptyMap()): List<SyncedRow> {
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
        if (group == null || (opened[group.id] ?: group.expanded) || together == null || maxOf(together.size, group.expectedSize) < GROUP_MIN_ITEMS) {
            rows.add(SyncedRow.Single(keyed))
        } else if (placed.add(group.id)) {
            rows.add(SyncedRow.Stack(group.id, group.createdAtMs, together, group.expectedSize))
        }
    }
    return rows
}

// ---- the motion rules -----------------------------------------------------------
// The same numbers on every platform (StackMotion in the HarmonyOS app's
// SyncedRows.ets), apart from the UI so they can be tested.

/** How far each layer behind the front card peeks out below it, in dp. */
internal const val STACK_PEEK_DP = 8f

/** How much further out each layer slides, per layer, when the stack is fully stretched (at stretch 1), in dp. */
internal const val STACK_SPREAD_DP = 40f

/** How much narrower each layer is than the card in front, on each side, per step back, in dp. */
internal const val STACK_LAYER_INSET_DP = 12f

/**
 * Until the finger has moved this far down (dp) the stack only stretches,
 * against a resistance; at this point the cards pop out to their places by
 * themselves, with the finger still down.
 */
internal const val COMMIT_DRAG_DP = 220f

/**
 * Once popped, with the finger still down, the cards go back into the stack
 * if the finger comes back above this (dp). Lower than the commit point, so a
 * finger resting near it does not make the cards flicker open and shut.
 */
internal const val RELEASE_DRAG_DP = 150f

/** The most the stretch can reach (1 is the stack fully open): the finger only gets there in the limit. */
internal const val RUBBER_REACH = 0.8f

/** The finger's travel (dp) at which the stretch is half of [RUBBER_REACH]. The larger, the more it resists at first. */
internal const val RUBBER_SOFTNESS_DP = 120f

/** A swipe down at least this fast opens the stack whatever the distance, in dp per second. */
internal const val EXPAND_FLING_DP_PER_SECOND = 700f

/** Hidden cards that slide out of an opened stack. A group of hundreds only animates its first screenful; the rest just appear. */
internal const val MAX_ANIMATED_REVEAL = 10

/** Each card that slides out starts this much (ms) after the one before... */
internal const val STAGGER_STEP_MS = 30

/** ...but however many there are, the last one starts by then. */
internal const val MAX_STAGGER_MS = 400

/**
 * How far the stack has stretched (0, closed, to [RUBBER_REACH]) for a finger
 * that moved [translationDp] down: a rubber band, so it follows the finger
 * but gives less and less the further it is pulled.
 */
internal fun dragProgress(translationDp: Float): Float {
    if (translationDp <= 0f) return 0f
    return RUBBER_REACH * translationDp / (translationDp + RUBBER_SOFTNESS_DP)
}

/** Whether a finger that moved [translationDp] down has pulled far enough for the cards to pop out before it is lifted. */
internal fun reachedCommit(translationDp: Float): Boolean = translationDp >= COMMIT_DRAG_DP

/** Whether a finger still down, with the cards popped out, has come back far enough for them to go back into the stack. */
internal fun shouldCollapse(translationDp: Float): Boolean = translationDp < RELEASE_DRAG_DP

/**
 * Whether letting go of the handle opens the stack: the pull got to the
 * commit point, or the swipe down was fast. A fast swipe back up closes it.
 */
internal fun shouldExpand(translationDp: Float, velocityDpPerSecond: Float): Boolean = when {
    velocityDpPerSecond >= EXPAND_FLING_DP_PER_SECOND -> true
    velocityDpPerSecond <= -EXPAND_FLING_DP_PER_SECOND -> false
    else -> reachedCommit(translationDp)
}

/** How opaque the count and the handle are: fading as the stack stretches, and gone once it has popped open ([fade] 1). */
internal fun stackChromeAlpha(progress: Float, fade: Float): Float =
    (1f - minOf(1f, progress * 1.5f)) * (1f - fade)

/** How opaque layer [depth] (1 is right behind the front card) is: a little dimmer for each step back, and faded out after the pop. */
internal fun stackLayerAlpha(depth: Int, fade: Float): Float = (1f - 0.22f * (depth - 1)) * (1f - fade)

/**
 * Where the hidden card [index] (1 is the one right behind the front card)
 * starts when the stack opens, as the layer that stands for it: how far (dp)
 * its bottom edge peeks out below the front card, for a stack that was
 * stretched by [stretch] (0 to 1) when it opened. Cards past the layers drawn
 * start with the last layer.
 */
internal fun startPeekDp(index: Int, stretch: Float): Float {
    val depth = index.coerceIn(1, MAX_STACK_LAYERS)
    return depth * (STACK_PEEK_DP + maxOf(stretch, 0f) * STACK_SPREAD_DP)
}

/** How much narrower than its own width (a share of it, in all) the hidden card [index] starts: the inset of its layer. */
internal fun startInsetFraction(index: Int, widthDp: Float): Float {
    val depth = index.coerceIn(1, MAX_STACK_LAYERS)
    if (widthDp <= 0f) return 0f
    return minOf(2f * depth * STACK_LAYER_INSET_DP / widthDp, 0.4f)
}

/** Whether the hidden card [index] (1 is the one right behind the front card) animates when the stack opens. */
internal fun revealAnimates(index: Int): Boolean = index in 1..MAX_ANIMATED_REVEAL

/** How long (ms) the hidden card [index] waits before it moves: 30 ms after the one before, the last by 400 ms. */
internal fun staggerDelayMs(index: Int): Int = minOf(maxOf(index, 0) * STAGGER_STEP_MS, MAX_STAGGER_MS)

/**
 * The cards of an opened stack that slide out, by key, to their index (1 is
 * the one right behind the front card): its members behind the front one,
 * newest first, up to [MAX_ANIMATED_REVEAL] of them. The rest just appear.
 */
internal fun revealSlots(stack: SyncedRow.Stack): Map<String, Int> {
    val slots = LinkedHashMap<String, Int>()
    stack.members.forEachIndexed { index, keyed -> if (revealAnimates(index)) slots[keyed.key] = index }
    return slots
}

/** Where a card that slides out of a stack starts, relative to its place: moved by ([dx], [dy]) and scaled by [scale] about its centre. */
data class RevealStart(val dx: Float, val dy: Float, val scale: Float)

/**
 * Where the hidden card [index] starts, in the units of the positions given
 * (px): as the layer that stood for it - as narrow as the layer, centred
 * under the front card, its bottom edge peeking out below the front card's
 * bottom ([cardBottom]) where the layer's did. [density] turns the dp rules
 * into those units; [stretch] is how far the stack had been pulled apart.
 */
internal fun revealStart(
    index: Int,
    stretch: Float,
    frontCenterX: Float,
    cardBottom: Float,
    ownLeft: Float,
    ownTop: Float,
    ownWidth: Float,
    ownHeight: Float,
    density: Float,
): RevealStart {
    val scale = 1f - startInsetFraction(index, ownWidth / density)
    val dx = frontCenterX - (ownLeft + ownWidth / 2f)
    val dy = (cardBottom + startPeekDp(index, stretch) * density - ownHeight * scale / 2f) - (ownTop + ownHeight / 2f)
    return RevealStart(dx, dy, scale)
}

/** A card that arrived less than this long ago (ms) has just arrived, and comes in growing from small. */
internal const val ARRIVAL_WINDOW_MS = 2_500L

/** Whether a card that arrived at [arrivedAtMs] (0: not in this session, or not with a sync or a copy) still animates in at [nowMs]. */
internal fun arrivesFresh(arrivedAtMs: Long, nowMs: Long): Boolean =
    arrivedAtMs > 0L && nowMs - arrivedAtMs in 0 until ARRIVAL_WINDOW_MS

/**
 * The stiffness of a spring that settles in about [responseSeconds], as the
 * HarmonyOS app's springMotion(response, dampingFraction) curves are given:
 * (2 pi / response) squared, for a mass of 1. Its damping fraction is
 * Compose's damping ratio as it is.
 */
internal fun springStiffness(responseSeconds: Float): Float {
    val omega = 2.0 * Math.PI / responseSeconds
    return (omega * omega).toFloat()
}
