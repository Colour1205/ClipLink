package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.GroupTag
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.ui.MAX_ANIMATED_REVEAL
import io.uaena.cliplink.ui.SyncedRow
import io.uaena.cliplink.ui.buildRows
import io.uaena.cliplink.ui.expansionCompletes
import io.uaena.cliplink.ui.keyedItems
import io.uaena.cliplink.ui.revealSlots
import io.uaena.cliplink.ui.staggerDelayMs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Synced list's rows: a group is one stack where its newest member is, the
 * rest of the list is untouched - and the numbers the stack's motion goes by.
 */
class SyncedRowsTest {

    private fun item(name: String, group: Long? = null, expected: Int = 0) = SyncedItem(
        entry = ClipboardEntry(name, ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T10:00:00.0000001Z", "sig-$name"),
        isOwn = false,
        fileAvailable = true,
        group = group?.let { GroupTag(it, 0L, expected) },
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

    // ---- opening the stack -----------------------------------------------------------------

    @Test
    fun `letting go a third of the way opens it`() {
        assertTrue(expansionCompletes(0.34f, 0f))
        assertTrue(expansionCompletes(1f, 0f))
        assertFalse(expansionCompletes(0.32f, 0f))
        assertFalse(expansionCompletes(0f, 0f))
    }

    @Test
    fun `a fast swipe down opens it however short, a fast swipe up closes it`() {
        assertTrue(expansionCompletes(0.05f, 1_500f))
        assertFalse(expansionCompletes(0.9f, -1_500f))
        assertFalse(expansionCompletes(0.05f, 200f))
    }

    // ---- the fly-out -------------------------------------------------------------------------

    @Test
    fun `cards are staggered thirty milliseconds apart`() {
        assertEquals(0, staggerDelayMs(0, 5))
        assertEquals(30, staggerDelayMs(1, 5))
        assertEquals(120, staggerDelayMs(4, 5))
    }

    @Test
    fun `the whole stagger never passes about four hundred milliseconds`() {
        for (count in listOf(2, 10, 14, 30, 100, 1_000)) {
            val last = staggerDelayMs(count - 1, count)
            assertTrue("count $count gave $last", last <= 400)
        }
        assertEquals(0, staggerDelayMs(0, 1))
    }

    @Test
    fun `only the first screenful of a big stack flies out`() {
        val names = (1..300).map { "n$it" }
        val big = rows(*names.map { item(it, 1) }.toTypedArray()).single() as SyncedRow.Stack
        val slots = revealSlots(big, columns = 1)
        assertEquals(MAX_ANIMATED_REVEAL, slots.size)
        // The ones behind the front, in order; the front itself is not one of them.
        assertEquals(big.members.drop(1).take(MAX_ANIMATED_REVEAL).map { it.key }, slots.keys.toList())
        // The rest just appear: they are not in the map.
        assertFalse(slots.containsKey(big.members.last().key))
    }

    @Test
    fun `in the grid two cards share a row`() {
        val stack = rows(item("d", 1), item("c", 1), item("b", 1), item("a", 1)).single() as SyncedRow.Stack
        val list = revealSlots(stack, columns = 1).values.map { it.stepsAbove }
        val grid = revealSlots(stack, columns = 2).values.map { it.stepsAbove }
        assertEquals(listOf(1, 2, 3), list)
        assertEquals(listOf(1, 1, 2), grid)
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
