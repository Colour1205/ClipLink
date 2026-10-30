package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.Envelope
import io.uaena.cliplink.net.HistoryHead
import io.uaena.cliplink.net.Protocol
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The history_head message on the wire: the field names every platform
 * spells the same way, and which entry and which keys a batch gives it.
 */
class HistoryHeadTest {

    private fun ts(n: Int) = "2026-09-26T10:%02d:%02d.0000001Z".format(n / 60, n % 60)

    private fun entry(name: String, n: Int) =
        ClipboardEntry(name, ClipboardEntry.TYPE_TEXT, "PEER", ts(n), "sig-$name")

    @Test
    fun `the payload has Newest as an entry object and Keys as a list of strings`() {
        val newest = entry("b", 2)
        val json = JSONObject(HistoryHead(newest, listOf("sig-b", "sig-a")).toJson())
        assertEquals(setOf("Newest", "Keys"), json.keys().asSequence().toSet())
        // The same shape as an "entry" message's payload, signature included.
        assertEquals(newest.toJson().toString(), json.getJSONObject("Newest").toString())
        assertEquals("sig-b", json.getJSONObject("Newest").getString("Signature"))
        assertEquals(listOf("sig-b", "sig-a"), (0 until json.getJSONArray("Keys").length()).map { json.getJSONArray("Keys").getString(it) })
    }

    @Test
    fun `the envelope carries the payload as a string`() {
        val head = HistoryHead(entry("b", 2), listOf("sig-b", "sig-a"))
        val wire = Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, head.toJson())
        val obj = JSONObject(wire)
        assertEquals("history_head", obj.getString("Type"))
        assertTrue(obj.get("Payload") is String)
        val parsed = Envelope.parse(wire)!!
        assertEquals(head, HistoryHead.parse(parsed.payload))
    }

    @Test
    fun `a head round trips`() {
        val head = HistoryHead(entry("c", 3), listOf("sig-c", "sig-b", "sig-a"))
        assertEquals(head, HistoryHead.parse(head.toJson()))
    }

    @Test
    fun `a head written by another platform is read`() {
        val text = """{"Newest":{"Content":"hi","Type":"text","DeviceId":"D","Timestamp":"2026-09-26T10:00:05Z","Signature":"S1"},"Keys":["S1","S0"],"Other":1}"""
        val head = HistoryHead.parse(text)!!
        assertEquals("hi", head.newest.content)
        assertEquals("S1", head.newest.signature)
        assertEquals(listOf("S1", "S0"), head.keys)
    }

    @Test
    fun `anything that is not a head is null`() {
        assertNull(HistoryHead.parse(""))
        assertNull(HistoryHead.parse("not json"))
        assertNull(HistoryHead.parse("[]"))
        assertNull(HistoryHead.parse("""{"Keys":["a"]}"""))
        assertNull(HistoryHead.parse("""{"Newest":{"Content":"x","Type":"text","DeviceId":"D","Timestamp":"t"}}"""))
        assertNull(HistoryHead.parse("""{"Newest":"text","Keys":["a"]}"""))
        assertNull(HistoryHead.parse("""{"Newest":{"Content":"x"},"Keys":["a"]}"""))
    }

    @Test
    fun `keys that are not text are left out`() {
        val head = HistoryHead.parse(
            """{"Newest":{"Content":"x","Type":"text","DeviceId":"D","Timestamp":"t","Signature":"S"},"Keys":["S",7,null,"",{"a":1},"T"]}""",
        )!!
        assertEquals(listOf("S", "T"), head.keys)
    }

    @Test
    fun `a head for a batch names the newest entry and every key newest first`() {
        val batch = listOf(entry("mid", 5), entry("new", 9), entry("old", 1))
        val head = HistoryHead.forBatch(batch)!!
        assertEquals(batch[1], head.newest)
        assertEquals(listOf("sig-new", "sig-mid", "sig-old"), head.keys)
    }

    @Test
    fun `timestamps compare as instants, so a trimmed spelling does not change the order`() {
        val trimmed = ClipboardEntry("t", ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T10:00:07.5Z", "sig-t")
        val padded = ClipboardEntry("p", ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T10:00:07.4000000Z", "sig-p")
        val head = HistoryHead.forBatch(listOf(padded, trimmed))!!
        assertEquals(trimmed, head.newest)
        assertEquals(listOf("sig-t", "sig-p"), head.keys)
    }

    @Test
    fun `an entry with no signature is keyed the way a deletion is`() {
        val unsigned = ClipboardEntry("u", ClipboardEntry.TYPE_TEXT, "PEER", ts(1), null)
        assertEquals(listOf(unsigned.deletionKey), HistoryHead.forBatch(listOf(unsigned))!!.keys)
    }

    @Test
    fun `no entries make no head`() {
        assertNull(HistoryHead.forBatch(emptyList()))
    }
}
