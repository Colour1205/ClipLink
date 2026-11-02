package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.GroupTag
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.ui.ARRIVAL_WINDOW_MS
import io.uaena.cliplink.ui.COMMIT_DRAG_DP
import io.uaena.cliplink.ui.MAX_ANIMATED_REVEAL
import io.uaena.cliplink.ui.RELEASE_DRAG_DP
import io.uaena.cliplink.ui.RUBBER_REACH
import io.uaena.cliplink.ui.SyncedRow
import io.uaena.cliplink.ui.arrivesFresh
import io.uaena.cliplink.ui.buildRows
import io.uaena.cliplink.ui.dragProgress
import io.uaena.cliplink.ui.keyedItems
import io.uaena.cliplink.ui.reachedCommit
import io.uaena.cliplink.ui.revealAnimates
import io.uaena.cliplink.ui.revealSlots
import io.uaena.cliplink.ui.revealStart
import io.uaena.cliplink.ui.shouldCollapse
import io.uaena.cliplink.ui.shouldExpand
import io.uaena.cliplink.ui.springStiffness
import io.uaena.cliplink.ui.stackChromeAlpha
import io.uaena.cliplink.ui.stackLayerAlpha
import io.uaena.cliplink.ui.staggerDelayMs
import io.uaena.cliplink.ui.startInsetFraction
import io.uaena.cliplink.ui.startPeekDp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Synced list's rows: a group is one stack where its newest member is, the
 * rest of the list is untouched - and the numbers the stack's motion goes by.
 */
class SyncedRowsTest {

    private fun item(name: String, group: Long? = null, expected: Int = 0, opened: Boolean = false) = SyncedItem(
        entry = ClipboardEntry(name, ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T10:00:00.0000001Z", "sig-$name"),
        isOwn = false,
        fileAvailable = true,
        group = group?.let { GroupTag(it, 0L, expected, opened) },
    )

    private fun rows(vararg items: SyncedItem) = buildRows(keyedItems(items.toList()))

    private fun SyncedRow.names() = when (this) {
        is SyncedRow.Single -> listOf(keyed.item.entry.content)
        is SyncedRow.Stack -> members.map { it.item.entry.content }
    }

    // ---- rows ----------------------------------------------------------------------

    @Test
    fun `a list with no groups is all ordinary cards in the same order`() {
        val result = rows(item("a"), item("b"), item("c"))
        assertTrue(result.all { it is SyncedRow.Single })
        assertEquals(listOf("a", "b", "c"), result.flatMap { it.names() })
    }

    @Test
    fun `a group is one stack with the newest in front`() {
        val result = rows(item("e", 1), item("d", 1), item("c", 1), item("b", 1), item("a", 1))
        assertEquals(1, result.size)
        val stack = result.single() as SyncedRow.Stack
        assertEquals(listOf("e", "d", "c", "b", "a"), stack.names())
        assertEquals("e", stack.front.item.entry.content)
        assertEquals(4, stack.behindCount)
        assertEquals(2, stack.layers)
        assertEquals(stack.front.key, stack.key)
    }

    @Test
    fun `a group of two has one layer behind the front`() {
        val stack = rows(item("b", 1), item("a", 1)).single() as SyncedRow.Stack
        assertEquals(1, stack.behindCount)
        assertEquals(1, stack.layers)
    }

    @Test
    fun `the stack sits where its newest member would be and nothing else moves`() {
        // A live entry (z) newer than the group, one between its members (m), and an old one (o).
        val result = rows(item("z"), item("c", 1), item("m"), item("b", 1), item("a", 1), item("o"))
        assertEquals(listOf("z"), result[0].names())
        assertEquals(listOf("c", "b", "a"), result[1].names())
        assertTrue(result[1] is SyncedRow.Stack)
        assertEquals(listOf("m"), result[2].names())
        assertEquals(listOf("o"), result[3].names())
        assertEquals(4, result.size)
    }

    @Test
    fun `two groups are two stacks`() {
        val result = rows(item("d", 2), item("c", 2), item("b", 1), item("a", 1))
        assertEquals(2, result.size)
        assertEquals(listOf("d", "c"), result[0].names())
        assertEquals(listOf("b", "a"), result[1].names())
        assertTrue(result.all { it is SyncedRow.Stack })
    }

    @Test
    fun `a member left alone on the screen is an ordinary card`() {
        val result = rows(item("b", 1), item("x"))
        assertTrue(result.all { it is SyncedRow.Single })
        assertEquals(2, result.size)
    }

    @Test
    fun `deleting the front item puts the next one in front`() {
        val before = rows(item("c", 1), item("b", 1), item("a", 1)).single() as SyncedRow.Stack
        val after = rows(item("b", 1), item("a", 1)).single() as SyncedRow.Stack
        assertEquals("c", before.front.item.entry.content)
        assertEquals("b", after.front.item.entry.content)
        assertEquals(1, after.behindCount)
    }

    @Test
    fun `row keys are all different`() {
        val result = rows(item("z"), item("c", 1), item("b", 1), item("a", 1), item("o"))
        assertEquals(result.size, result.map { it.key }.toSet().size)
    }

    // ---- opening the stack (the same numbers as StackMotion on HarmonyOS) ----------------

    @Test
    fun `the pull is a rubber band that never gets past its reach`() {
        assertEquals(0f, dragProgress(0f), 0f)
        assertEquals(0f, dragProgress(-50f), 0f)
        // Half the reach at the softness distance.
        assertEquals(0.4f, dragProgress(120f), 1e-6f)
        // About 0.52 at the commit point.
        assertEquals(0.8f * 220f / 340f, dragProgress(COMMIT_DRAG_DP), 1e-6f)
        var last = 0f
        for (t in 1..5_000 step 7) {
            val p = dragProgress(t.toFloat())
            assertTrue(p > last && p < RUBBER_REACH)
            last = p
        }
    }

    @Test
    fun `the cards pop at the commit point and go back above the release point`() {
        assertFalse(reachedCommit(219.9f))
        assertTrue(reachedCommit(220f))
        assertTrue(shouldCollapse(149.9f))
        assertFalse(shouldCollapse(RELEASE_DRAG_DP))
        // Between the two nothing changes either way: no flicker for a finger resting there.
        assertFalse(reachedCommit(180f))
        assertFalse(shouldCollapse(180f))
    }

    @Test
    fun `letting go opens it past the commit point or on a fast swipe down`() {
        assertTrue(shouldExpand(220f, 0f))
        assertFalse(shouldExpand(219f, 0f))
        assertTrue(shouldExpand(5f, 700f))
        assertFalse(shouldExpand(300f, -700f))
        assertFalse(shouldExpand(100f, 699f))
    }

    @Test
    fun `the count and the handle fade half again as fast as the stretch, and are gone after the pop`() {
        assertEquals(1f, stackChromeAlpha(0f, 0f), 0f)
        assertEquals(0.4f, stackChromeAlpha(0.4f, 0f), 1e-6f)
        assertEquals(0f, stackChromeAlpha(0.7f, 0f), 0f)
        assertEquals(0f, stackChromeAlpha(0f, 1f), 0f)
    }

    @Test
    fun `a layer further back is dimmer`() {
        assertEquals(1f, stackLayerAlpha(1, 0f), 1e-6f)
        assertEquals(0.78f, stackLayerAlpha(2, 0f), 1e-6f)
        assertEquals(0f, stackLayerAlpha(1, 1f), 0f)
    }

    // ---- the cards sliding out -------------------------------------------------------------

    @Test
    fun `cards are staggered thirty milliseconds apart, the first one too`() {
        assertEquals(0, staggerDelayMs(0))
        assertEquals(30, staggerDelayMs(1))
        assertEquals(120, staggerDelayMs(4))
    }

    @Test
    fun `the stagger never passes four hundred milliseconds`() {
        assertEquals(400, staggerDelayMs(14))
        assertEquals(400, staggerDelayMs(1_000))
    }

    @Test
    fun `only the first ten cards behind the front slide out`() {
        assertFalse(revealAnimates(0))
        assertTrue(revealAnimates(1))
        assertTrue(revealAnimates(10))
        assertFalse(revealAnimates(11))
        val names = (1..300).map { "n$it" }
        val big = rows(*names.map { item(it, 1) }.toTypedArray()).single() as SyncedRow.Stack
        val slots = revealSlots(big)
        assertEquals(MAX_ANIMATED_REVEAL, slots.size)
        // The ones behind the front, in order, numbered from 1; the front itself is not one of them.
        assertEquals(big.members.drop(1).take(MAX_ANIMATED_REVEAL).map { it.key }, slots.keys.toList())
        assertEquals((1..MAX_ANIMATED_REVEAL).toList(), slots.values.toList())
        assertFalse(slots.containsKey(big.members.last().key))
    }

    @Test
    fun `a card starts where its layer was, the ones past the layers with the last`() {
        assertEquals(8f, startPeekDp(1, 0f), 0f)
        assertEquals(16f, startPeekDp(2, 0f), 0f)
        assertEquals(16f, startPeekDp(7, 0f), 0f)
        // Pulled apart: 40 dp more per layer at a full stretch.
        assertEquals(2 * (8f + 0.5f * 40f), startPeekDp(2, 0.5f), 1e-6f)
        assertEquals(24f / 360f, startInsetFraction(1, 360f), 1e-6f)
        assertEquals(48f / 360f, startInsetFraction(3, 360f), 1e-6f)
        assertEquals(0.4f, startInsetFraction(2, 50f), 0f)
        assertEquals(0f, startInsetFraction(1, 0f), 0f)
    }

    @Test
    fun `a card slides out from under the front card, its bottom edge where the layer peeked out`() {
        // Density 2: a front card 300 x 100 dp at (16, 100) dp; the card behind
        // it laid out just below the stack's room, 300 x 80 dp.
        val d = 2f
        val start = revealStart(
            index = 1,
            stretch = 0.25f,
            frontCenterX = (16f + 150f) * d,
            cardBottom = 200f * d,
            ownLeft = 16f * d,
            ownTop = 228f * d,
            ownWidth = 300f * d,
            ownHeight = 80f * d,
            density = d,
        )
        assertEquals(1f - 24f / 300f, start.scale, 1e-6f)
        assertEquals(0f, start.dx, 1e-3f)
        // Its bottom edge (centre + half its scaled height) is 8 + 0.25 * 40 dp below the front card's.
        val bottom = (228f * d + 40f * d) + start.dy + 80f * d * start.scale / 2f
        assertEquals((200f + 18f) * d, bottom, 1e-3f)
    }

    // ---- new cards -----------------------------------------------------------------------

    @Test
    fun `a card grows in for two and a half seconds after it arrived`() {
        assertTrue(arrivesFresh(10_000L, 10_000L))
        assertTrue(arrivesFresh(10_000L, 10_000L + ARRIVAL_WINDOW_MS - 1))
        assertFalse(arrivesFresh(10_000L, 10_000L + ARRIVAL_WINDOW_MS))
        // Not one that was in the history before, or came with a late answer.
        assertFalse(arrivesFresh(0L, 10_000L))
        assertFalse(arrivesFresh(20_000L, 10_000L))
    }

    @Test
    fun `springs are as stiff as HarmonyOS springMotion responses`() {
        assertEquals(438.65f, springStiffness(0.3f), 0.01f)
        assertEquals(246.74f, springStiffness(0.4f), 0.01f)
    }

    // ---- what the user did to a stack, before the engine says so -------------------------------

    @Test
    fun `a stack the user opened is cards at once, and one put back is a stack again`() {
        val items = keyedItems(listOf(item("c", 1), item("b", 1), item("a", 1)))
        assertEquals(1, buildRows(items).size)
        assertEquals(listOf("c", "b", "a"), buildRows(items, mapOf(1L to true)).flatMap { it.names() })
        assertEquals(3, buildRows(items, mapOf(1L to true)).size)
        val opened = keyedItems(listOf(item("c", 1, opened = true), item("b", 1, opened = true)))
        assertEquals(2, buildRows(opened).size)
        assertEquals(1, buildRows(opened, mapOf(1L to false)).size)
    }

    // ---- a stack whose batch is still on its way -----------------------------------------------

    @Test
    fun `a newest item that expects more is a stack at once, counted by what is coming`() {
        val stack = rows(item("e", 1, expected = 5)).single() as SyncedRow.Stack
        assertEquals(listOf("e"), stack.names())
        assertEquals(5, stack.size)
        assertEquals(4, stack.behindCount)
        assertEquals(2, stack.layers)
        assertEquals(5, stack.expectedSize)
    }

    @Test
    fun `a provisional stack of two has one layer`() {
        val stack = rows(item("b", 1, expected = 2)).single() as SyncedRow.Stack
        assertEquals(1, stack.behindCount)
        assertEquals(1, stack.layers)
    }

    @Test
    fun `an item that expects only itself is an ordinary card`() {
        assertTrue(rows(item("a", 1, expected = 1)).single() is SyncedRow.Single)
        assertTrue(rows(item("a", 1, expected = 0)).single() is SyncedRow.Single)
    }

    @Test
    fun `the count follows whichever is more, the members or what was expected`() {
        val more = rows(item("c", 1, 3), item("b", 1, 3), item("a", 1, 3), item("x", 1, 3)).single() as SyncedRow.Stack
        assertEquals(3, more.behindCount) // four members, three expected
        val fewer = rows(item("b", 1, 6), item("a", 1, 6)).single() as SyncedRow.Stack
        assertEquals(5, fewer.behindCount) // two members so far, six expected
    }

    @Test
    fun `the badge does not change when the batch settles the stack`() {
        val before = rows(item("d", 1, expected = 4)).single() as SyncedRow.Stack
        val after = rows(item("d", 1), item("c", 1), item("b", 1), item("a", 1)).single() as SyncedRow.Stack
        assertEquals(before.behindCount, after.behindCount)
        assertEquals(before.groupId, after.groupId)
        assertEquals(before.key, after.key) // the same row, so no flash
    }
}
