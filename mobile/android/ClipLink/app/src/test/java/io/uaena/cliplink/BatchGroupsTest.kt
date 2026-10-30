package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.BatchGroups
import io.uaena.cliplink.engine.GROUP_MIN_ITEMS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which items arrived together in one history_batch: when a group exists, who
 * is in it, and how it shrinks and ends. Memory only - nothing here is saved.
 */
class BatchGroupsTest {

    private fun ts(n: Int) = "2026-09-26T10:%02d:%02d.0000001Z".format(n / 60, n % 60)

    private fun entry(name: String, n: Int) =
        ClipboardEntry(name, ClipboardEntry.TYPE_TEXT, "PEER", ts(n), "sig-$name")

    @Test
    fun `the threshold is two`() {
        assertEquals(2, GROUP_MIN_ITEMS)
    }

    @Test
    fun `fewer than the threshold make no group`() {
        val groups = BatchGroups()
        assertNull(groups.record(emptyList(), 0))
        assertNull(groups.record(listOf("a"), 0))
        assertNull(groups.record(listOf("a", "a"), 0)) // one key twice is one item
        assertTrue(groups.resolve(setOf("a"), groups.horizon()).isEmpty())
    }

    @Test
    fun `two or more make one group with everyone in it`() {
        val groups = BatchGroups()
        val id = checkNotNull(groups.record(listOf("c", "b", "a"), 1_000))
        val tags = groups.resolve(setOf("a", "b", "c", "other"), groups.horizon())
        assertEquals(setOf("a", "b", "c"), tags.keys)
        assertEquals(setOf(id), tags.values.map { it.id }.toSet())
        assertEquals(1_000L, tags.getValue("a").createdAtMs)
    }

    @Test
    fun `a batch of entries is grouped by their deletion keys`() {
        val groups = BatchGroups()
        val entries = listOf(entry("mid", 5), entry("new", 9), entry("old", 1))
        assertTrue(groups.recordBatch(entries, 0) != null)
        val tags = groups.resolve(entries.map { it.deletionKey }.toSet(), groups.horizon())
        assertEquals(3, tags.size)
        assertEquals(1, tags.values.map { it.id }.toSet().size)
    }

    @Test
    fun `two batches make two groups`() {
        val groups = BatchGroups()
        val first = checkNotNull(groups.record(listOf("a2", "a1"), 0))
        val second = checkNotNull(groups.record(listOf("b3", "b2", "b1"), 0))
        assertNotEquals(first, second)
        val tags = groups.resolve(setOf("a1", "a2", "b1", "b2", "b3"), groups.horizon())
        assertEquals(first, tags.getValue("a1").id)
        assertEquals(second, tags.getValue("b2").id)
    }

    @Test
    fun `a group shrinks as members go and ends with the last but one`() {
        val groups = BatchGroups()
        groups.record(listOf("c", "b", "a"), 0)
        // The front one deleted: the others stay a group.
        assertEquals(setOf("a", "b"), groups.resolve(setOf("a", "b"), groups.horizon()).keys)
        // Another gone: one left is a normal card.
        assertTrue(groups.resolve(setOf("a"), groups.horizon()).isEmpty())
        // And it does not come back, even if the member list were to show up again.
        assertTrue(groups.resolve(setOf("a", "b", "c"), groups.horizon()).isEmpty())
    }

    @Test
    fun `a group with every member deleted disappears`() {
        val groups = BatchGroups()
        groups.record(listOf("b", "a"), 0)
        assertTrue(groups.resolve(emptySet(), groups.horizon()).isEmpty())
        assertTrue(groups.resolve(setOf("a", "b"), groups.horizon()).isEmpty())
    }

    @Test
    fun `a group made after a snapshot is not judged against it`() {
        val groups = BatchGroups()
        val horizon = groups.horizon()
        // The snapshot was taken before this batch's members were stored.
        groups.record(listOf("b", "a"), 0)
        assertTrue(groups.resolve(emptySet(), horizon).isEmpty())
        // Still a group for a later snapshot that has them.
        assertEquals(setOf("a", "b"), groups.resolve(setOf("a", "b"), groups.horizon()).keys)
    }

    @Test
    fun `opening a stack ends its group and nothing else`() {
        val groups = BatchGroups()
        val first = checkNotNull(groups.record(listOf("b", "a"), 0))
        groups.record(listOf("d", "c"), 0)
        groups.dissolve(first)
        assertEquals(setOf("c", "d"), groups.resolve(setOf("a", "b", "c", "d"), groups.horizon()).keys)
        groups.dissolve(first) // twice, or an id that never was: nothing
        groups.dissolve(99)
    }

    @Test
    fun `clearing the history removes the groups`() {
        val groups = BatchGroups()
        groups.record(listOf("b", "a"), 0)
        groups.clear()
        assertTrue(groups.resolve(setOf("a", "b"), groups.horizon()).isEmpty())
    }

    @Test
    fun `only the newest groups are kept in a long session`() {
        val groups = BatchGroups(maxGroups = 3)
        (1..5).forEach { groups.record(listOf("x$it", "y$it"), 0) }
        val everything = (1..5).flatMap { listOf("x$it", "y$it") }.toSet()
        assertEquals(6, groups.resolve(everything, groups.horizon()).size)
    }

    // ---- a group that starts from a history_head -------------------------------------------

    @Test
    fun `a head that counts fewer than two makes no group`() {
        val groups = BatchGroups()
        assertNull(groups.provisional("a", 0, 0))
        assertNull(groups.provisional("a", 1, 0))
        assertTrue(groups.resolve(setOf("a"), groups.horizon()).isEmpty())
    }

    @Test
    fun `a provisional group shows its one member and the size that is coming`() {
        val groups = BatchGroups()
        val id = checkNotNull(groups.provisional("new", 4, 1_000))
        val tags = groups.resolve(setOf("new"), groups.horizon())
        assertEquals(setOf("new"), tags.keys)
        assertEquals(id, tags.getValue("new").id)
        assertEquals(4, tags.getValue("new").expectedSize)
        assertEquals(1_000L, tags.getValue("new").createdAtMs)
    }

    @Test
    fun `the batch joins the provisional group, keeps its id and makes the size final`() {
        val groups = BatchGroups()
        val id = checkNotNull(groups.provisional("d", 4, 1_000))
        assertTrue(groups.complete(id, listOf("c", "b", "a")))
        val tags = groups.resolve(setOf("a", "b", "c", "d"), groups.horizon())
        assertEquals(setOf("a", "b", "c", "d"), tags.keys)
        assertEquals(setOf(id), tags.values.map { it.id }.toSet())
        assertEquals(setOf(0), tags.values.map { it.expectedSize }.toSet())
        assertEquals(setOf(1_000L), tags.values.map { it.createdAtMs }.toSet()) // not a new group
        assertEquals(false, groups.complete(id, emptyList())) // settling again changes nothing
    }

    @Test
    fun `a provisional group left with one member ends`() {
        val groups = BatchGroups()
        val id = checkNotNull(groups.provisional("d", 3, 0))
        assertTrue(groups.complete(id, emptyList()))
        assertTrue(groups.resolve(setOf("d"), groups.horizon()).isEmpty())
        assertEquals(false, groups.complete(id, listOf("c", "b"))) // gone for good
    }

    @Test
    fun `a group that was opened or is gone takes nothing from the batch`() {
        val groups = BatchGroups()
        val id = checkNotNull(groups.provisional("d", 3, 0))
        groups.dissolve(id)
        assertEquals(false, groups.complete(id, listOf("c", "b")))
        assertTrue(groups.resolve(setOf("b", "c", "d"), groups.horizon()).isEmpty())
    }

    @Test
    fun `a provisional group whose newest was deleted disappears`() {
        val groups = BatchGroups()
        groups.provisional("d", 3, 0)
        assertTrue(groups.resolve(emptySet(), groups.horizon()).isEmpty())
        assertTrue(groups.resolve(setOf("d"), groups.horizon()).isEmpty())
    }

    @Test
    fun `a snapshot from before the head does not end its group`() {
        val groups = BatchGroups()
        val horizon = groups.horizon()
        groups.provisional("d", 3, 0)
        assertTrue(groups.resolve(emptySet(), horizon).isEmpty()) // nothing to tag, but the group is kept
        assertEquals(setOf("d"), groups.resolve(setOf("d"), groups.horizon()).keys)
    }

    @Test
    fun `a snapshot from before the batch does not end the group the batch completes`() {
        val groups = BatchGroups()
        val id = checkNotNull(groups.provisional("d", 3, 0))
        val horizon = groups.horizon()
        // The list took its snapshot (only "d" in it) and then the batch was stored.
        groups.complete(id, listOf("c", "b"))
        groups.resolve(setOf("d"), horizon)
        assertEquals(setOf("b", "c", "d"), groups.resolve(setOf("b", "c", "d"), groups.horizon()).keys)
    }
}
