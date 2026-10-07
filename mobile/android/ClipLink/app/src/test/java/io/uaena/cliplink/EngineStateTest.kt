package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.Ipv4
import io.uaena.cliplink.engine.BeaconBook
import io.uaena.cliplink.engine.BeaconBook.Recorded
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.engine.PeerNames
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.engine.uniqueKeysFor
import io.uaena.cliplink.net.Discovery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The engine's pure state logic: the Tailscale address check and the beacon
 * fields it protects, the beacon book's aging and bound, and the keys the
 * Synced list rows are told apart by.
 */
class EngineStateTest {

    // ---- the Tailscale address ---------------------------------------------------

    @Test
    fun `an IPv4 address is accepted and spelt canonically`() {
        assertEquals("100.64.0.1", Ipv4.normalize("100.64.0.1"))
        assertEquals("100.64.0.1", Ipv4.normalize("  100.64.0.1\n"))
        assertEquals("0.0.0.0", Ipv4.normalize("0.0.0.0"))
        assertEquals("255.255.255.255", Ipv4.normalize("255.255.255.255"))
    }

    @Test
    fun `anything else is refused`() {
        for (bad in listOf(
            "", "   ", "100.64.0", "100.64.0.1.5", "256.1.1.1", "1.1.1.-1", "a.b.c.d", "100.64.0.1:80",
            "fd7a:115c:a1e0::1", "::1", "my-phone.tailnet.ts.net", "100.64.0.1 extra", "01.2.3.4", "1..2.3",
            "1.2.3.4\u0000", "１.2.3.4", "1.2.3.", ".1.2.3",
        )) {
            assertNull("'$bad' must not be accepted", Ipv4.normalize(bad))
        }
        assertNull(Ipv4.normalize(null))
    }

    // ---- beacon fields --------------------------------------------------------------

    @Test
    fun `a beacon built with a hostile address carries no address at all`() {
        // A colon in the address used to shift every field after it, so every
        // receiver read the pairing flag and the name from the wrong place.
        for (bad in listOf("fd7a::1", "1.2.3.4:5", "evil:1:name", "host name", "1.2.3.256")) {
            val line = Discovery.build(49000, "KEY", "PROOF", bad, true, "Pixel 8")
            assertEquals("49000:KEY:PROOF:-:1:UGl4ZWwgOA==", line)
        }
        assertEquals(6, Discovery.build(49000, "KEY", null, "100.64.0.1", false, "n").split(':').size)
    }

    @Test
    fun `colons spaces and control characters are removed from every field`() {
        val line = Discovery.build(49000, "KE:Y\n 2", "PRO:OF\t", "100.64.0.1", true, "a:b")
        val parts = line.split(':')
        assertEquals(6, parts.size)
        assertEquals("KEY2", parts[1])
        assertEquals("PROOF", parts[2])
        assertEquals("1", parts[4])
        val parsed = checkNotNull(Discovery.parse(line, "10.0.0.2"))
        assertEquals("KEY2", parsed.deviceId)
        assertEquals("a:b", parsed.name) // the name is base64, so its colon is safe
        assertEquals("100.64.0.1", parsed.address)
        assertTrue(parsed.pairing)
    }

    @Test
    fun `fields are capped`() {
        val line = Discovery.build(49000, "K".repeat(1000), "P".repeat(1000), null, false, null)
        val parts = line.split(':')
        assertEquals(Discovery.MAX_ID_LENGTH, parts[1].length)
        assertEquals(Discovery.MAX_PROOF_LENGTH, parts[2].length)
    }

    @Test
    fun `a beacon with absurd fields is not trusted to be what it claims`() {
        assertNull(Discovery.parse("0:KEY:-", "10.0.0.2"))
        assertNull(Discovery.parse("70000:KEY:-", "10.0.0.2"))
        assertNull(Discovery.parse("-5:KEY:-", "10.0.0.2"))
        assertNull(Discovery.parse("49000:${"K".repeat(Discovery.MAX_ID_LENGTH + 1)}:-", "10.0.0.2"))
        // An overlong proof is no proof; a hostile address is no address.
        assertNull(checkNotNull(Discovery.parse("49000:KEY:${"P".repeat(500)}", "10.0.0.2")).proof)
        for (bad in listOf("a b", "x/y", "<script>", "a".repeat(100), "%00")) {
            assertNull(bad, checkNotNull(Discovery.parse("49000:KEY:-:$bad", "10.0.0.2")).address)
        }
        // A host name from a build that allows one is fine.
        assertEquals("phone.tailnet.ts.net", checkNotNull(Discovery.parse("49000:KEY:-:phone.tailnet.ts.net", "10.0.0.2")).address)
    }

    // ---- the beacon book: aging and the bound -------------------------------------------

    private class Clock(var now: Long = 1_000_000L)

    private fun beacon(id: String, ip: String = "192.168.1.5", name: String? = null, pairing: Boolean = false, address: String? = null) =
        Discovery.Beacon(49000, id, null, address, pairing, name, ip)

    private val nobody: (String) -> Boolean = { false }

    @Test
    fun `a device that stops beaconing drops off after the window`() {
        val clock = Clock()
        val book = BeaconBook(maxAgeMs = 30_000, clock = { clock.now })
        book.record(beacon("A"), nobody)
        book.record(beacon("B"), nobody)
        clock.now += 20_000
        book.record(beacon("B"), nobody) // B keeps beaconing
        clock.now += 11_000 // A last seen 31 s ago, B 11 s

        assertEquals(listOf("A"), book.prune(nobody))
        assertEquals(listOf("B"), book.ids())
        assertNull(book.get("A"))
    }

    @Test
    fun `a trusted or connected device is kept, but no longer counts as here`() {
        val clock = Clock()
        val book = BeaconBook(maxAgeMs = 30_000, clock = { clock.now })
        book.record(beacon("TRUSTED", ip = "192.168.1.7"), nobody)
        book.record(beacon("STRANGER"), nobody)
        assertTrue(book.isRecent("TRUSTED"))

        clock.now += 60_000
        val gone = book.prune { it == "TRUSTED" }

        assertEquals(listOf("STRANGER"), gone)
        assertEquals("192.168.1.7", book.get("TRUSTED")?.senderIp) // still dialable
        assertFalse(book.isRecent("TRUSTED")) // but its "pairing screen open" is stale
        assertEquals(clock.now - 60_000, book.lastSeenAt("TRUSTED"))
    }

    @Test
    fun `forged beacons can't grow the book past its bound`() {
        val book = BeaconBook(maxEntries = 10)
        var rejected = 0
        repeat(1000) { i -> if (book.record(beacon("FAKE$i"), nobody) == Recorded.Rejected) rejected++ }
        assertEquals(10, book.size())
        assertEquals(990, rejected)
    }

    @Test
    fun `a trusted device still gets in when the book is full of strangers`() {
        val clock = Clock()
        val book = BeaconBook(maxEntries = 3, clock = { clock.now })
        for (i in 0 until 3) {
            clock.now += 1
            book.record(beacon("FAKE$i"), nobody)
        }
        assertEquals(Recorded.Rejected, book.record(beacon("FAKE9"), nobody))

        val isTrusted: (String) -> Boolean = { it == "FRIEND" }
        assertEquals(Recorded.Changed, book.record(beacon("FRIEND"), isTrusted))

        assertEquals(3, book.size())
        assertTrue("FRIEND" in book.ids())
        assertFalse("the quietest stranger made room", "FAKE0" in book.ids())
    }

    @Test
    fun `a stale stranger makes room for a new one`() {
        val clock = Clock()
        val book = BeaconBook(maxEntries = 2, maxAgeMs = 30_000, clock = { clock.now })
        book.record(beacon("OLD1"), nobody)
        book.record(beacon("OLD2"), nobody)
        clock.now += 31_000
        assertEquals(Recorded.Changed, book.record(beacon("NEW"), nobody))
        assertEquals(listOf("NEW"), book.ids())
    }

    @Test
    fun `a repeated beacon only asks for a new list when something shown changed`() {
        val book = BeaconBook()
        assertEquals(Recorded.Changed, book.record(beacon("A", name = "Pixel"), nobody))
        // Every two seconds, the same: nothing for the Devices tab to redraw.
        assertEquals(Recorded.Refreshed, book.record(beacon("A", name = "Pixel"), nobody))
        assertEquals(Recorded.Refreshed, book.record(beacon("A", name = "Pixel"), nobody))
        // Its pairing screen opens, it moves, it is renamed, it learns an address: those show.
        assertEquals(Recorded.Changed, book.record(beacon("A", name = "Pixel", pairing = true), nobody))
        assertEquals(Recorded.Changed, book.record(beacon("A", name = "Pixel", pairing = true, ip = "192.168.1.9"), nobody))
        assertEquals(Recorded.Changed, book.record(beacon("A", name = "Pixel 8", pairing = true, ip = "192.168.1.9"), nobody))
        assertEquals(Recorded.Changed, book.record(beacon("A", name = "Pixel 8", pairing = true, ip = "192.168.1.9", address = "100.64.0.2"), nobody))
        assertEquals(Recorded.Refreshed, book.record(beacon("A", name = "Pixel 8", pairing = true, ip = "192.168.1.9", address = "100.64.0.2"), nobody))
    }

    @Test
    fun `a device forgotten by the book takes its beacon name with it`() {
        val names = PeerNames()
        names.heardInBeacon("A", "Pixel")
        names.heardInHandshake("B", "Handshake name")
        assertEquals("Pixel", names.display("A", null))
        names.forgetBeacon("A")
        assertNull(names.display("A", null))
        names.forgetBeacon("B") // a handshake name isn't a beacon's to forget
        assertEquals("Handshake name", names.display("B", null))
    }

    // ---- device rows -----------------------------------------------------------------------

    @Test
    fun `a row is the same row however recently its beacon was heard`() {
        fun row(seen: Long?) = DeviceRow("id", "name", true, false, listOf("1.2.3.4"), false, seen)
        assertEquals(row(1), row(2))
        assertEquals(row(null), row(99))
        assertEquals(row(1).hashCode(), row(2).hashCode())
        // Anything that is shown still counts.
        assertFalse(row(1) == row(1).copy(connected = true))
        assertFalse(row(1) == row(1).copy(addresses = emptyList()))
        assertFalse(row(1) == row(1).copy(name = null))
        assertFalse(row(1) == row(1).copy(pairing = true))
        assertFalse(row(1) == row(1).copy(trusted = false))
    }

    // ---- synced item keys ----------------------------------------------------------------------

    private fun entry(content: String, signature: String?, timestamp: String = "2026-09-26T10:00:00.0000001Z") =
        ClipboardEntry(content, ClipboardEntry.TYPE_TEXT, "DEVICE", timestamp, signature)

    @Test
    fun `two entries of one device with the same time and type get different keys`() {
        val first = entry("one", "sig-one")
        val second = entry("two", "sig-two") // same device, timestamp and type
        assertEquals(first.key, second.key) // the old key: a collision
        val keys = uniqueKeysFor(listOf(first, second))
        assertEquals(2, keys.toSet().size)
        assertEquals(listOf("sig-one", "sig-two"), keys)
    }

    @Test
    fun `keys are the same on every refresh and never repeat within one`() {
        val entries = listOf(entry("a", "s1"), entry("b", "s2"), entry("c", "s1"), entry("d", "s1"))
        val keys = uniqueKeysFor(entries)
        assertEquals(keys.size, keys.toSet().size)
        assertEquals(listOf("s1", "s2", "s1#2", "s1#3"), keys)
        assertEquals(keys, uniqueKeysFor(entries))
        // A different order of other entries doesn't move an entry's own key.
        assertEquals("s2", uniqueKeysFor(listOf(entry("b", "s2")))[0])
    }

    @Test
    fun `an item is identified by its unique key`() {
        val a = SyncedItem(entry("one", "sig-one"), isOwn = false, fileAvailable = true)
        val b = SyncedItem(entry("two", "sig-two"), isOwn = false, fileAvailable = true)
        assertEquals("sig-one", a.uniqueKey)
        assertEquals(a.uniqueKey, a.id)
        assertFalse(a.id == b.id)
        assertEquals("custom", a.copy(uniqueKey = "custom").id)
    }
}
