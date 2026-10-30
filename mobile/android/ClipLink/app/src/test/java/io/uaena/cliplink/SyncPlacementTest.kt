package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.BatchGroups
import io.uaena.cliplink.engine.GroupTag
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.engine.arrange
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.HistoryStore.Arrival
import io.uaena.cliplink.ui.SyncedRow
import io.uaena.cliplink.ui.buildRows
import io.uaena.cliplink.ui.keyedItems
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Where items stand in the Synced list now: the blocks of this session first (a live item is a block of
 * one, a sync is one block with its convenience item in front), everything else below by timestamp - and
 * what the history's trim spares. Nothing here is saved.
 */
class SyncPlacementTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var files: FileStore
    private val tomb = Tombstones()

    @Before
    fun setUp() {
        files = FileStore(temp.newFolder("blobs"), temp.newFolder("shared"))
    }

    private fun store(name: String = "history.jsonl") =
        HistoryStore(File(temp.root, name), null, files, tomb::contains, tomb::record, recentDeleted = tomb::recent)

    private fun names(entries: List<ClipboardEntry>) = entries.map { it.content }

    private fun placed(groups: BatchGroups, entries: List<ClipboardEntry>): List<ClipboardEntry> {
        val keys = entries.mapTo(HashSet()) { it.dk }
        return arrange(entries, groups.place(keys, groups.horizon()).blocks)
    }

    // ---- the order ---------------------------------------------------------------------

    @Test
    fun `without blocks the list is the timeline, newest first`() {
        val entries = listOf(entryOf("a", 1), entryOf("c", 30), entryOf("b", 20))
        assertEquals(listOf("c", "b", "a"), names(placed(BatchGroups(), entries)))
    }

    @Test
    fun `the convenience item goes on top although it is older than the items below`() {
        val l1 = entryOf("l1", 10)
        val l2 = entryOf("l2", 20)
        val c = entryOf("c", 5)
        val groups = BatchGroups()
        groups.noteLive(l1.dk, 0)
        groups.noteLive(l2.dk, 0)
        groups.recordSync(c.dk, emptyList(), 0, 0)
        assertEquals(listOf("c", "l2", "l1"), names(placed(groups, listOf(l1, l2, c))))
    }

    @Test
    fun `the members of a sync stay together right below its convenience item, above every item outside it`() {
        // Items of the timeline with newer timestamps than all the members.
        val old1 = entryOf("old1", 40)
        val old2 = entryOf("old2", 50)
        val c = entryOf("c", 5)
        val b = entryOf("b", 4)
        val a = entryOf("a", 3)
        val groups = BatchGroups()
        val id = checkNotNull(groups.recordSync(c.dk, listOf(a.dk, b.dk), 0, 0))
        val all = listOf(old1, a, old2, b, c)

        // Closed: one stack in the first place, c in front.
        assertEquals(listOf("c", "b", "a", "old2", "old1"), names(placed(groups, all)))
        assertFalse(groups.place(all.map { it.dk }.toSet(), groups.horizon()).tags.getValue(c.dk).expanded)

        // Opened: the same order, no longer a stack.
        assertTrue(groups.expand(id))
        assertEquals(listOf("c", "b", "a", "old2", "old1"), names(placed(groups, all)))
        assertTrue(groups.place(all.map { it.dk }.toSet(), groups.horizon()).tags.getValue(a.dk).expanded)
        // Only once.
        assertFalse(groups.expand(id))
    }

    @Test
    fun `a live item that arrives later goes above the block, whatever its timestamp`() {
        val c = entryOf("c", 5)
        val b = entryOf("b", 4)
        val old = entryOf("old", 50)
        val groups = BatchGroups()
        groups.recordSync(c.dk, listOf(b.dk), 0, 0)
        val live = entryOf("live", 1)
        groups.noteLive(live.dk, 0)
        assertEquals(listOf("live", "c", "b", "old"), names(placed(groups, listOf(old, b, c, live))))
    }

    @Test
    fun `the block of a later sync is above the earlier one`() {
        val first = listOf(entryOf("f2", 20), entryOf("f1", 19))
        val second = listOf(entryOf("s2", 2), entryOf("s1", 1))
        val groups = BatchGroups()
        groups.recordSync(first[0].dk, listOf(first[1].dk), 0, 0)
        groups.recordSync(second[0].dk, listOf(second[1].dk), 0, 0)
        assertEquals(listOf("s2", "s1", "f2", "f1"), names(placed(groups, first + second)))
    }

    @Test
    fun `after a restart there are no blocks and the list is the timeline`() {
        val entries = listOf(entryOf("c", 5), entryOf("b", 4), entryOf("l2", 20), entryOf("l1", 10))
        val before = BatchGroups().also { it.recordSync(entries[0].dk, listOf(entries[1].dk), 0, 0) }
        assertEquals(listOf("c", "b", "l2", "l1"), names(placed(before, entries)))
        // A fresh BatchGroups is what a new process has.
        assertEquals(listOf("l2", "l1", "c", "b"), names(placed(BatchGroups(), entries)))
    }

    @Test
    fun `a front that is gone is replaced by the next member, and a block shrunk to one is a single card in its place`() {
        val c = entryOf("c", 5)
        val b = entryOf("b", 4)
        val a = entryOf("a", 3)
        val live = entryOf("live", 99)
        val groups = BatchGroups()
        groups.recordSync(c.dk, listOf(b.dk, a.dk), 0, 0)
        groups.noteLive(live.dk, 0)

        val withoutFront = listOf(a, b, live)
        val placement = groups.place(withoutFront.map { it.dk }.toSet(), groups.horizon())
        assertEquals(listOf("live", "b", "a"), names(arrange(withoutFront, placement.blocks)))
        assertEquals(setOf(a.dk, b.dk), placement.tags.keys)

        val onlyOne = listOf(a, live, entryOf("old", 100))
        val shrunk = groups.place(onlyOne.map { it.dk }.toSet(), groups.horizon())
        assertTrue(shrunk.tags.isEmpty())
        // The single card keeps its block's place: above the older timeline item, below the later live one.
        assertEquals(listOf("live", "a", "old"), names(arrange(onlyOne, shrunk.blocks)))
    }

    @Test
    fun `more of a sync joins its group, and settling makes the size final`() {
        val c = entryOf("c", 5)
        val b = entryOf("b", 4)
        val a = entryOf("a", 3)
        val groups = BatchGroups()
        val id = checkNotNull(groups.recordSync(c.dk, emptyList(), 3, 0))
        var tag = groups.place(setOf(c.dk), groups.horizon()).tags.getValue(c.dk)
        assertEquals(GroupTag(id, 0L, 3, false), tag)

        assertTrue(groups.join(id, listOf(b.dk)))
        tag = groups.place(setOf(c.dk, b.dk), groups.horizon()).tags.getValue(b.dk)
        assertEquals(3, tag.expectedSize)
        assertTrue(groups.join(id, listOf(a.dk)))
        assertTrue(groups.complete(id, emptyList()))
        tag = groups.place(setOf(c.dk, b.dk, a.dk), groups.horizon()).tags.getValue(a.dk)
        assertEquals(0, tag.expectedSize)
        // A group that is gone takes nothing.
        groups.dissolve(id)
        assertFalse(groups.join(id, listOf("x")))
    }

    @Test
    fun `a sync of one item is a block but not a stack`() {
        val c = entryOf("c", 5)
        val groups = BatchGroups()
        assertNull(groups.recordSync(c.dk, emptyList(), 1, 0))
        assertNull(groups.recordSync("x", emptyList(), 0, 0))
        assertTrue(groups.place(setOf(c.dk, "x"), groups.horizon()).tags.isEmpty())
        assertEquals(2, groups.place(setOf(c.dk, "x"), groups.horizon()).blocks.size)
    }

    @Test
    fun `a long session keeps only the latest blocks`() {
        val groups = BatchGroups(maxGroups = 3)
        (1..10).forEach { groups.noteLive("k$it", 0) }
        val blocks = groups.place((1..10).map { "k$it" }.toSet(), groups.horizon()).blocks
        assertEquals(listOf("k10", "k9", "k8"), blocks.map { it.front })
    }

    // ---- the rows ------------------------------------------------------------------------------

    private fun item(name: String, group: GroupTag? = null) = SyncedItem(
        entry = entryOf(name, 1),
        isOwn = false,
        fileAvailable = true,
        group = group,
    )

    @Test
    fun `an opened stack is ordinary cards, together, in the order the list has them`() {
        val closed = GroupTag(1, 0L, 0, expanded = false)
        val open = GroupTag(1, 0L, 0, expanded = true)
        val rowsClosed = buildRows(keyedItems(listOf(item("c", closed), item("b", closed), item("a", closed), item("x"))))
        assertEquals(2, rowsClosed.size)
        val stack = rowsClosed[0] as SyncedRow.Stack
        assertEquals("c", stack.front.item.entry.content)
        assertEquals(listOf("c", "b", "a"), stack.members.map { it.item.entry.content })

        val rowsOpen = buildRows(keyedItems(listOf(item("c", open), item("b", open), item("a", open), item("x"))))
        assertTrue(rowsOpen.all { it is SyncedRow.Single })
        assertEquals(listOf("c", "b", "a", "x"), rowsOpen.map { (it as SyncedRow.Single).keyed.item.entry.content })
        // The card in front keeps its key through the opening.
        assertEquals(stack.key, rowsOpen[0].key)
    }

    // ---- what the trim spares ----------------------------------------------------------------------

    private fun fullHistory(history: HistoryStore): List<ClipboardEntry> {
        val kept = (100 until 125).map { entryOf("kept$it", it) }
        history.addAll(kept)
        assertEquals(25, history.all().size)
        return kept
    }

    @Test
    fun `a sync's convenience item stays though it is older than all, and the oldest other item goes`() {
        val history = store()
        val kept = fullHistory(history)
        val c = entryOf("c", 1)
        val b = entryOf("b", 2)

        val stored = history.addAllNew(listOf(b, c), Arrival.Sync)

        // The newest of the new ones is the one spared; the other is older than all and is trimmed.
        assertEquals(listOf(b), stored)
        assertEquals(25, history.all().size)
        assertTrue(history.all().contains(b))
        assertFalse(history.all().contains(kept.first()))
        assertTrue(history.all().contains(kept.last()))
    }

    @Test
    fun `a convenience item that is not the one on the clipboard is not spared`() {
        val history = store()
        val kept = fullHistory(history)
        val c = entryOf("c", 1)

        // Older than all and not spared: it is stored and trimmed in the same step, and the history is as it was.
        assertTrue(history.addAllNew(listOf(c), Arrival.Sync, protectFront = { false }).isEmpty())
        assertEquals(kept, history.all())

        // Asked about the newest of the new ones, once, and spared when the answer is yes.
        val asked = ArrayList<ClipboardEntry>()
        val b = entryOf("b", 2)
        val stored = history.addAllNew(listOf(b, c), Arrival.Sync, protectFront = { asked.add(it); true })
        assertEquals(listOf(b), asked)
        assertEquals(listOf(b), stored) // b is spared, c (older than all) is the one trimmed
    }

    @Test
    fun `a skipped convenience item leaves the earlier one spared, in the same trim and after`() {
        val history = store()
        fullHistory(history)
        val c1 = entryOf("c1", 1)
        history.addAllNew(listOf(c1), Arrival.Sync)
        assertTrue(history.all().contains(c1))

        // Another convenience item that did not get the clipboard: older than all but c1. The oldest
        // unspared entry goes in the same call, and that is the skipped item, not c1.
        val skipped = entryOf("skipped", 2)
        assertTrue(history.addAllNew(listOf(skipped), Arrival.Sync, protectFront = { false }).isEmpty())
        assertTrue(history.all().contains(c1))
        assertFalse(history.all().contains(skipped))
        assertEquals(25, history.all().size)

        // Again, and a skipped item that comes with others: c1 is still spared.
        val skipped2 = entryOf("skipped2", 3)
        val more = entryOf("more", 150)
        val stored = history.addAllNew(listOf(more, skipped2), Arrival.Sync, protectFront = { false })
        assertEquals(listOf(more), stored)
        assertTrue(history.all().contains(c1))
        assertEquals(25, history.all().size)

        // An item that does get the clipboard moves the protection: c1 is trimmed by age from now on.
        val c3 = entryOf("c3", 4)
        history.addAllNew(listOf(c3), Arrival.Sync, protectFront = { true })
        assertTrue(history.all().contains(c3))
        assertFalse(history.all().contains(c1))
        assertEquals(25, history.all().size)
    }

    @Test
    fun `a skipped convenience item without any earlier one spares nothing`() {
        val history = store()
        val kept = fullHistory(history)
        val skipped = entryOf("skipped", 1)
        assertTrue(history.addAllNew(listOf(skipped), Arrival.Sync, protectFront = { false }).isEmpty())
        assertEquals(kept, history.all())
    }

    @Test
    fun `the next arrival ends the protection and the item is trimmed by age`() {
        val history = store()
        fullHistory(history)
        val c = entryOf("c", 1)
        history.addAllNew(listOf(c), Arrival.Sync)
        assertTrue(history.all().contains(c))

        // A later live item: c is the oldest and goes, the total stays 25.
        history.addAll(listOf(entryOf("live", 200)))
        assertFalse(history.all().contains(c))
        assertEquals(25, history.all().size)
    }

    @Test
    fun `more of the same sync keeps its item spared and a newer sync moves the protection`() {
        val history = store()
        fullHistory(history)
        val c1 = entryOf("c1", 1)
        history.addAllNew(listOf(c1), Arrival.Sync)
        // The rest of the sync arrives: c1 is still spared, other old entries are the ones to go.
        history.addAllNew(listOf(entryOf("more", 150), entryOf("more2", 151)), Arrival.SyncMore)
        assertTrue(history.all().contains(c1))
        assertEquals(25, history.all().size)

        // A newer sync with its own item: c1 is trimmed by age from now on, the new one is spared.
        val c2 = entryOf("c2", 2)
        history.addAllNew(listOf(c2), Arrival.Sync)
        assertTrue(history.all().contains(c2))
        assertFalse(history.all().contains(c1))
        assertEquals(25, history.all().size)
    }

    @Test
    fun `the protection is memory only`() {
        val history = store()
        fullHistory(history)
        val c = entryOf("c", 1)
        history.addAllNew(listOf(c), Arrival.Sync)

        // As after a restart: the same file, a new store.
        val reopened = store()
        assertTrue(reopened.all().contains(c))
        reopened.addAll(listOf(entryOf("live", 200)))
        assertFalse(reopened.all().contains(c))
        assertEquals(25, reopened.all().size)
    }

    @Test
    fun `an older peer's newest item is trimmed by age as ever and spared from then on`() {
        val history = store()
        fullHistory(history)
        // Older than everything a full history keeps: not stored, as before.
        assertTrue(history.addAllNew(listOf(entryOf("ancient", 1)), Arrival.SyncByAge).isEmpty())
        // In between: stored, and spared by the next trim.
        val mid = entryOf("mid", 100)
        val stored = history.addAllNew(listOf(mid), Arrival.SyncByAge)
        assertEquals(listOf(mid), stored)
        history.addAllNew(listOf(entryOf("more", 200)), Arrival.SyncMore)
        assertTrue(history.all().contains(mid))
        assertEquals(25, history.all().size)
    }

    @Test
    fun `only the convenience item is spared, not the other members`() {
        val history = store()
        fullHistory(history)
        val c = entryOf("c", 2)
        val b = entryOf("b", 1)
        val stored = history.addAllNew(listOf(c, b), Arrival.Sync)
        assertEquals(listOf(c), stored)
    }

    @Test
    fun `the character budget spares the convenience item too`() {
        val history = HistoryStore(
            File(temp.root, "small.jsonl"), null, files, tomb::contains, tomb::record, maxStoredChars = 100,
        )
        history.addAll(listOf(entryOf("x".repeat(40), 10), entryOf("y".repeat(40), 11)))
        val c = entryOf("c".repeat(40), 1)
        history.addAllNew(listOf(c), Arrival.Sync)
        assertTrue(history.all().contains(c))
        assertEquals(2, history.all().size)
    }

    // ---- deleting on a peer's word ---------------------------------------------------------------------

    @Test
    fun `applying a peer's deletes removes entries, tombstones every key and returns what went`() {
        val history = store()
        val a = entryOf("a", 1)
        val b = entryOf("b", 2)
        history.addAll(listOf(a, b))
        val gone = history.applyDeleted(listOf(a.dk, "stranger"))
        assertEquals(listOf(a), gone)
        assertEquals(listOf(b), history.all())
        assertTrue(tomb.contains(a.dk) && tomb.contains("stranger"))
        // Again: nothing to remove, nothing stamped again.
        val before = tomb.all()
        assertTrue(history.applyDeleted(listOf(a.dk, "stranger")).isEmpty())
        assertEquals(before, tomb.all())
        // Once deleted it does not return.
        assertFalse(history.add(a))
    }

    @Test
    fun `the history's tombstones come most recent first and clearing returns every key`() {
        val history = store()
        val a = entryOf("a", 1)
        val b = entryOf("b", 2)
        history.addAll(listOf(a, b))
        history.delete(a)
        assertEquals(listOf(a.dk), history.recentDeletedKeys(500))
        val keys = history.clear()
        assertEquals(listOf(b.dk), keys)
        assertEquals(listOf(b.dk, a.dk), history.recentDeletedKeys(500))
        assertEquals(listOf(b.dk), history.recentDeletedKeys(1))
        assertTrue(history.isKeyDeleted(a.dk))
    }
}
