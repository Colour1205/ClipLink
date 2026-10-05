package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.store.MAX_TOMBSTONES
import io.uaena.cliplink.store.Tombstone
import io.uaena.cliplink.store.blobToRelease
import io.uaena.cliplink.store.toTombstoneJson
import io.uaena.cliplink.store.tombstonesFromJson
import io.uaena.cliplink.store.withAdded
import io.uaena.cliplink.store.withTombstones
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deleting a synced item, and keeping it deleted: the key it is recorded
 * under, the capped tombstone list, and the history refusing a deleted entry
 * when a peer's history_batch carries it again.
 */
class DeletionTest {

    private fun entry(content: String, timestamp: String, signature: String? = "sig-$content") =
        ClipboardEntry(content, ClipboardEntry.TYPE_TEXT, "DEVICE", timestamp, signature)

    // ---- entry key ----------------------------------------------------------

    @Test
    fun `an entry is deleted under its signature exactly as received`() {
        val signed = entry("hi", "2026-09-26T12:34:56.1234500Z", signature = "MEUCIQ+/abc==")
        assertEquals("MEUCIQ+/abc==", signed.deletionKey)
        // A relay trimming the timestamp doesn't change what was deleted.
        assertEquals(signed.deletionKey, signed.copy(timestamp = "2026-09-26T12:34:56.12345Z").deletionKey)
    }

    @Test
    fun `an unsigned entry falls back to device type timestamp and content hash`() {
        val expected = "DEVICE|text|2026-09-26T12:34:56.12345Z|" +
            "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4"
        assertEquals(expected, entry("hi", "2026-09-26T12:34:56.12345Z", signature = null).deletionKey)
        assertEquals(expected, entry("hi", "2026-09-26T12:34:56.12345Z", signature = "").deletionKey)
    }

    // ---- tombstone store ----------------------------------------------------

    @Test
    fun `recording keys adds them once and refreshes one already deleted`() {
        val first = emptyList<Tombstone>().withTombstones(listOf("a", "b"), now = 10)
        assertEquals(listOf(Tombstone("a", 10), Tombstone("b", 10)), first)

        val again = first.withTombstones(listOf("a", "c"), now = 20)
        assertEquals(listOf(Tombstone("b", 10), Tombstone("a", 20), Tombstone("c", 20)), again)
    }

    @Test
    fun `the tombstone list is capped by dropping the oldest`() {
        val full = (1..MAX_TOMBSTONES).map { Tombstone("k$it", it.toLong()) }
        val next = full.withTombstones(listOf("new"), now = 5_000)
        assertEquals(MAX_TOMBSTONES, next.size)
        assertEquals("k2", next.first().key)
        assertEquals(Tombstone("new", 5_000), next.last())

        // Oldest by time, not by position - whatever order was read back.
        val shuffled = listOf(Tombstone("late", 30), Tombstone("early", 10), Tombstone("mid", 20))
        assertEquals(
            listOf("mid", "late", "x"),
            shuffled.withTombstones(listOf("x"), now = 40, cap = 3).map { it.key },
        )
    }

    @Test
    fun `tombstones round trip as Key and DeletedAt`() {
        val list = listOf(Tombstone("MEUCIQ+/abc==", 1_759_000_000_000), Tombstone("D|text|T|ab", 2))
        val json = list.toTombstoneJson()
        val first = JSONArray(json).getJSONObject(0)
        assertEquals("MEUCIQ+/abc==", first.getString("Key"))
        assertEquals(1_759_000_000_000, first.getLong("DeletedAt"))
        assertEquals(list, tombstonesFromJson(json))
    }

    @Test
    fun `unreadable tombstones read as none instead of throwing`() {
        assertEquals(emptyList<Tombstone>(), tombstonesFromJson("not json"))
        assertEquals(
            listOf(Tombstone("ok", 0)),
            tombstonesFromJson("""[{"Key":null,"DeletedAt":1},{"DeletedAt":2},{"Key":""},{"Key":"ok"},7]"""),
        )
    }

    // ---- incoming history ---------------------------------------------------

    @Test
    fun `a history batch skips deleted entries before storing or applying them`() {
        val kept = entry("kept", "2026-09-26T10:00:00.0000001Z")
        val deletedOne = entry("deleted one", "2026-09-26T10:00:01.1000000Z")
        val cleared = entry("cleared", "2026-09-26T10:00:02.0000001Z")
        val fresh = entry("fresh", "2026-09-26T10:00:03.0000001Z")

        val tombstones = emptyList<Tombstone>()
            .withTombstones(listOf(deletedOne.deletionKey), now = 1)
            .withTombstones(listOf(cleared.deletionKey), now = 2)
        val isDeleted = { key: String -> tombstones.any { it.key == key } }

        // The peer's batch, as SyncManager walks it: whatever add() takes is
        // stored AND applied; whatever it refuses is neither. The trimmed
        // timestamp is how a relayed copy of a deleted entry can arrive.
        val batch = listOf(kept, deletedOne.copy(timestamp = "2026-09-26T10:00:01.1Z"), cleared, fresh, kept)
        var history = listOf(kept)
        val applied = mutableListOf<ClipboardEntry>()
        for (incoming in batch) {
            val added = history.withAdded(incoming, isDeleted) ?: continue
            history = added
            applied += incoming
        }

        assertEquals(listOf(kept, fresh), history)
        assertEquals(listOf(fresh), applied)
        assertNull(listOf<ClipboardEntry>().withAdded(deletedOne, isDeleted))
        assertTrue(history.none { isDeleted(it.deletionKey) })
    }

    // ---- file blobs ---------------------------------------------------------

    private fun fileEntry(hash: String, timestamp: String) = ClipboardEntry(
        FilePayload("a.pdf", hash, 3).toJson(),
        ClipboardEntry.TYPE_FILE,
        "DEVICE",
        timestamp,
        "sig-$hash-$timestamp",
    )

    @Test
    fun `a deleted file's blob goes only when no remaining entry still uses it`() {
        // Real 64-hex hashes: FilePayload refuses anything else.
        val hash = "abc123".repeat(10) + "abcd"
        val first = fileEntry(hash, "2026-09-26T10:00:00.0000001Z")
        val resent = fileEntry(hash.uppercase(), "2026-09-26T11:00:00.0000001Z")
        val other = fileEntry("def456".repeat(10) + "defd", "2026-09-26T12:00:00.0000001Z")

        assertEquals(hash, first.blobToRelease(listOf(other)))
        // The same file sent twice is one blob - deleting one copy keeps it.
        assertNull(first.blobToRelease(listOf(resent, other)))
        assertNull(entry("text", "2026-09-26T10:00:00.0000001Z").blobToRelease(emptyList()))
    }
}
