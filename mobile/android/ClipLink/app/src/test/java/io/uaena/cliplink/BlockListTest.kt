package io.uaena.cliplink

import io.uaena.cliplink.core.Base64Codec
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.store.BlockedDevice
import io.uaena.cliplink.store.isBlockedDevice
import io.uaena.cliplink.store.sameDeviceId
import io.uaena.cliplink.store.withBlocked
import io.uaena.cliplink.store.withoutBlocked
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/** The block list's matching and merge rules, and how a blocked row compares and sorts. */
class BlockListTest {

    /**
     * Stands in for android.util.Base64, which skips anything that is not
     * base64 when it decodes: the MIME decoder does the same, the basic one
     * throws. That leniency is the whole reason a key can be re-spelt.
     */
    private val codec = object : Base64Codec {
        override fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
        override fun decodeOrNull(text: String?): ByteArray? =
            if (text.isNullOrEmpty()) null else Base64.getMimeDecoder().decode(text)
    }

    private val keyA = Base64.getEncoder().encodeToString(ByteArray(40) { it.toByte() })
    private val keyB = Base64.getEncoder().encodeToString(ByteArray(40) { (it + 1).toByte() })

    @Test
    fun theSameTextIsTheSameDevice() {
        assertTrue(sameDeviceId(keyA, keyA, codec))
        assertFalse(sameDeviceId(keyA, keyB, codec))
    }

    @Test
    fun aReSpeltKeyIsStillTheBlockedDevice() {
        // A space and a dot slipped into the text decode to the same bytes,
        // so a comparison of text alone would be a way round the block.
        val respelt = keyA.substring(0, 10) + " . " + keyA.substring(10)
        assertFalse(respelt == keyA)
        assertTrue(sameDeviceId(keyA, respelt, codec))
        assertTrue(listOf(BlockedDevice(keyA)).isBlockedDevice(respelt, codec))
    }

    @Test
    fun anotherKeyIsNotBlocked() {
        assertFalse(listOf(BlockedDevice(keyA)).isBlockedDevice(keyB, codec))
        assertFalse(emptyList<BlockedDevice>().isBlockedDevice(keyA, codec))
    }

    @Test
    fun blockingAKeyTwiceKeepsOneEntryAndItsName() {
        val once = emptyList<BlockedDevice>().withBlocked(keyA, "Pixel", codec)
        val twice = once.withBlocked(keyA, null, codec)
        assertEquals(1, twice.size)
        assertEquals("Pixel", twice.single().name)
    }

    @Test
    fun aBetterNameReplacesAnOlderOne() {
        val list = listOf(BlockedDevice(keyA, "old")).withBlocked(keyA, "new", codec)
        assertEquals("new", list.single().name)
    }

    @Test
    fun aBlankNameIsNoName() {
        assertNull(emptyList<BlockedDevice>().withBlocked(keyA, "   ", codec).single().name)
    }

    @Test
    fun unblockingRemovesOnlyThatDevice() {
        val list = listOf(BlockedDevice(keyA), BlockedDevice(keyB)).withoutBlocked(keyA, codec)
        assertEquals(listOf(keyB), list.map { it.deviceId })
    }

    // ---- rows ------------------------------------------------------------------

    private fun row(id: String, trusted: Boolean = false, blocked: Boolean = false, name: String? = null) =
        DeviceRow(id, name, trusted, false, emptyList(), false, null, blocked = blocked)

    @Test
    fun aRowThatBecameBlockedIsADifferentRow() {
        // The Devices list is redrawn from a flow that drops equal lists.
        assertFalse(row("a") == row("a", blocked = true))
        assertFalse(row("a") == row("a").copy(connectedAddress = "192.168.1.5"))
    }

    @Test
    fun blockedDevicesSortLastThenTrustedThenTheRest() {
        val rows = listOf(
            row("d", blocked = true, name = "Aardvark"),
            row("c", name = "Cat"),
            row("b", trusted = true, name = "Bee"),
            row("a", trusted = true, name = "Ant"),
        )
        assertEquals(listOf("a", "b", "c", "d"), rows.sortedWith(DeviceRow.STABLE_ORDER).map { it.deviceId })
    }
}
