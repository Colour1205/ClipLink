package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.ui.keyedItems
import io.uaena.cliplink.ui.uniqueKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Synced lists are keyed by [keyedItems], not by `SyncedItem.id`: two
 * entries of one device can share an id, and a Lazy list given two equal keys
 * crashes the app - on the start tab, on every launch.
 */
class SyncedKeysTest {

    private fun item(
        content: String,
        signature: String?,
        deviceId: String = "device-a",
        timestamp: String = "2026-10-05T12:00:00.0000000Z",
        type: String = ClipboardEntry.TYPE_TEXT,
    ) = SyncedItem(
        entry = ClipboardEntry(content, type, deviceId, timestamp, signature),
        isOwn = false,
        fileAvailable = true,
    )

    @Test
    fun entriesSharingAnIdGetDifferentKeys() {
        val first = item("one", signature = "sig-one")
        val second = item("two", signature = "sig-two")
        // The collision this guards against: same device, same timestamp
        // text, same type - the id is all three.
        assertEquals(first.id, second.id)

        val keys = keyedItems(listOf(first, second)).map { it.key }

        assertEquals(2, keys.toSet().size)
    }

    @Test
    fun theSignatureIsTheKey() {
        val keyed = keyedItems(listOf(item("one", signature = "sig-one")))

        assertEquals("sig-one", keyed.single().key)
    }

    @Test
    fun aKeyDoesNotChangeWhenNewerItemsArePrepended() {
        val older = item("old", signature = "sig-old", timestamp = "2026-10-05T12:00:00.0000000Z")
        val newer = item("new", signature = "sig-new", timestamp = "2026-10-05T12:00:05.0000000Z")

        val before = keyedItems(listOf(older)).single().key
        val after = keyedItems(listOf(newer, older)).last().key

        assertEquals(before, after)
    }

    @Test
    fun anUnsignedEntryFallsBackToItsIdAndPosition() {
        val keys = keyedItems(
            listOf(
                item("one", signature = null),
                item("two", signature = ""),
            ),
        ).map { it.key }

        assertEquals(2, keys.toSet().size)
        assertTrue(keys[0].startsWith("device-a|"))
        assertNotEquals(keys[0], keys[1])
    }

    @Test
    fun itemsWithTheSameSignatureStillGetDifferentKeys() {
        val keys = keyedItems(
            listOf(
                item("same", signature = "sig"),
                item("same", signature = "sig"),
                item("same", signature = "sig"),
            ),
        ).map { it.key }

        assertEquals(3, keys.toSet().size)
        // The first one keeps the plain signature, so a list that never
        // repeats one is keyed by signature alone.
        assertEquals("sig", keys.first())
    }

    @Test
    fun aSuffixedKeyNeverCollidesWithARealSignature() {
        // "sig#dup1" is what the second "sig" would become - and it is also,
        // here, a signature of its own.
        val keys = uniqueKeys(listOf("sig", "sig", "sig#dup1"))

        assertEquals(3, keys.toSet().size)
    }

    @Test
    fun keysFollowTheListOrder() {
        val items = listOf(item("a", "sig-a"), item("b", "sig-b"), item("c", "sig-c"))

        val keyed = keyedItems(items)

        assertEquals(items, keyed.map { it.item })
        assertEquals(listOf("sig-a", "sig-b", "sig-c"), keyed.map { it.key })
    }
}
