package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.net.HandshakeMessage
import io.uaena.cliplink.net.KeyListMessage
import io.uaena.cliplink.net.Protocol
import io.uaena.cliplink.net.SyncHead
import io.uaena.cliplink.net.SyncManager
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire format of sync v2: the handshake's Protocol field, the v2 history_head, history_request and
 * delete payloads, and which keys a head makes worth asking for.
 */
class SyncProtocolTest {

    private fun strings(array: JSONArray) = (0 until array.length()).map { array.getString(it) }

    // ---- the handshake ------------------------------------------------------------

    @Test
    fun `the handshake we write says Protocol 2 and keeps its other fields`() {
        val json = JSONObject(HandshakeMessage("E", "I", "S", "P", deviceName = "Pixel 8").toJson())
        assertEquals(2, json.getInt("Protocol"))
        assertEquals(
            setOf("EphemeralPublicKey", "IdentityPublicKey", "Signature", "PassphraseProof", "DeviceName", "Protocol"),
            json.keys().asSequence().toSet(),
        )
        assertEquals(2, Protocol.VERSION)
    }

    @Test
    fun `a peer's Protocol is read from its handshake`() {
        fun read(field: String) = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S"$field}""",
        )!!.protocol
        assertEquals(2, read(""","Protocol":2"""))
        assertEquals(3, read(""","Protocol":3"""))
        assertEquals(2, read(""","Protocol":2.0"""))
    }

    @Test
    fun `a handshake with no usable Protocol means 1`() {
        fun read(field: String) = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S"$field}""",
        )!!.protocol
        assertEquals(1, read(""))
        assertEquals(1, read(""","Protocol":null"""))
        assertEquals(1, read(""","Protocol":"2""""))
        assertEquals(1, read(""","Protocol":1"""))
        assertEquals(1, read(""","Protocol":0"""))
        assertEquals(1, read(""","Protocol":-4"""))
        assertEquals(1, read(""","Protocol":2.5"""))
        assertEquals(1, read(""","Protocol":true"""))
        assertEquals(1, read(""","Protocol":[2]"""))
    }

    @Test
    fun `a handshake from before Protocol still parses and a round trip keeps it`() {
        val old = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","PassphraseProof":null,"DeviceName":"PC"}""",
        )!!
        assertEquals(1, old.protocol)
        assertEquals("PC", old.deviceName)
        val mine = HandshakeMessage("E", "I", "S", null, deviceName = "Pixel 8")
        assertEquals(mine, HandshakeMessage.parse(mine.toJson()))
    }

    @Test
    fun `a connection speaks the lower of the two versions and never more than ours`() {
        assertEquals(1, V2Link("P", peerProtocol = 1).protocol)
        assertEquals(2, V2Link("P", peerProtocol = 2).protocol)
        assertEquals(2, V2Link("P", peerProtocol = 7).protocol)
        assertFalse(V2Link("P", peerProtocol = 1).isV2)
        assertTrue(V2Link("P", peerProtocol = 2).isV2)
    }

    // ---- the v2 head ----------------------------------------------------------------

    @Test
    fun `a v2 head has Keys Times and Deleted and no Newest`() {
        val a = entryOf("a", 1)
        val b = entryOf("b", 5)
        val head = SyncHead.forHistory(listOf(a, b), listOf("gone2", "gone1"))
        val json = JSONObject(head.toJson())
        assertEquals(setOf("Keys", "Times", "Deleted"), json.keys().asSequence().toSet())
        // Newest first, whatever order the history had.
        assertEquals(listOf(b.dk, a.dk), strings(json.getJSONArray("Keys")))
        assertEquals(listOf(ms(5), ms(1)), (0 until 2).map { json.getJSONArray("Times").getLong(it) })
        assertEquals(listOf("gone2", "gone1"), strings(json.getJSONArray("Deleted")))
        assertFalse(json.has("Newest"))
    }

    @Test
    fun `the exact text of the v2 messages`() {
        val a = entryOf("a", 1)
        val b = entryOf("b", 5)
        assertEquals(
            """{"Keys":["sig-b-5","sig-a-1"],"Times":[1790416805000,1790416801000],"Deleted":["gone2","gone1"]}""",
            SyncHead.forHistory(listOf(a, b), listOf("gone2", "gone1")).toJson(),
        )
        assertEquals("""{"Keys":["sig-b-5","sig-a-1"]}""", KeyListMessage(listOf(b.dk, a.dk)).toJson())
        assertEquals(
            """{"Type":"history_request","Payload":"{\"Keys\":[\"sig-b-5\"]}"}""",
            Protocol.envelope(Protocol.TYPE_HISTORY_REQUEST, KeyListMessage(listOf(b.dk)).toJson()),
        )
        assertEquals(
            """{"Type":"delete","Payload":"{\"Keys\":[\"sig-a-1\"]}"}""",
            Protocol.envelope(Protocol.TYPE_DELETE, KeyListMessage(listOf(a.dk)).toJson()),
        )
        // Key order in a JSON object means nothing; the keys and values are what is pinned.
        val handshake = JSONObject(HandshakeMessage("E", "I", "S", null, deviceName = "Pixel 8").toJson())
        assertEquals(
            mapOf(
                "EphemeralPublicKey" to "E", "IdentityPublicKey" to "I", "Signature" to "S",
                "DeviceName" to "Pixel 8", "Protocol" to 2,
            ),
            handshake.keys().asSequence().associateWith { handshake.get(it) },
        )
    }

    @Test
    fun `a v2 head round trips`() {
        val head = SyncHead(listOf("k3", "k2", "k1"), listOf(30L, 20L, 10L), listOf("d2", "d1"))
        assertEquals(head, SyncHead.parse(head.toJson()))
        val empty = SyncHead(emptyList(), emptyList(), emptyList())
        assertEquals(empty, SyncHead.parse(empty.toJson()))
    }

    @Test
    fun `a head without Times or Deleted is read, and unknown keys are skipped`() {
        val bare = SyncHead.parse("""{"Keys":["a","b"]}""")!!
        assertEquals(listOf("a", "b"), bare.keys)
        assertNull(bare.times)
        assertTrue(bare.deleted.isEmpty())
        val extra = SyncHead.parse("""{"Keys":["a"],"Times":[5],"Deleted":["x"],"Future":{"a":1},"Newest":{"Content":"c"}}""")!!
        assertEquals(SyncHead(listOf("a"), listOf(5L), listOf("x")), extra)
    }

    @Test
    fun `Times that do not line up with the keys are dropped`() {
        assertNull(SyncHead.parse("""{"Keys":["a","b"],"Times":[1]}""")!!.times)
        assertNull(SyncHead.parse("""{"Keys":["a","b"],"Times":[1,2,3]}""")!!.times)
        assertNull(SyncHead.parse("""{"Keys":["a","b"],"Times":[1,"x"]}""")!!.times)
        assertNull(SyncHead.parse("""{"Keys":["a","b"],"Times":"nope"}""")!!.times)
        assertEquals(listOf(1L, 2L), SyncHead.parse("""{"Keys":["a","b"],"Times":[1,2]}""")!!.times)
    }

    @Test
    fun `a key that cannot be used takes its time with it`() {
        val head = SyncHead.parse("""{"Keys":["a",7,null,"","b"],"Times":[1,2,3,4,5]}""")!!
        assertEquals(listOf("a", "b"), head.keys)
        assertEquals(listOf(1L, 5L), head.times)
        val long = "k".repeat(2049)
        assertEquals(listOf("a"), SyncHead.parse("""{"Keys":["$long","a"],"Times":[1,2]}""")!!.keys)
        assertEquals(listOf("k".repeat(2048)), SyncHead.parse("""{"Keys":["${"k".repeat(2048)}"]}""")!!.keys)
    }

    @Test
    fun `more than 25 keys use the first 25 and more than 500 deleted use the first 500`() {
        val keys = (1..40).map { "k$it" }
        val deleted = (1..600).map { "d$it" }
        val head = SyncHead.parse(
            JSONObject()
                .put("Keys", JSONArray(keys))
                .put("Times", JSONArray((1..40).map { it.toLong() }))
                .put("Deleted", JSONArray(deleted))
                .toString(),
        )!!
        assertEquals(keys.take(25), head.keys)
        assertEquals((1..25).map { it.toLong() }, head.times)
        assertEquals(deleted.take(500), head.deleted)
        // What we send is capped the same way.
        val big = SyncHead.forHistory((1..30).map { entryOf("e$it", it) }, deleted)
        assertEquals(25, big.keys.size)
        assertEquals(25, big.times!!.size)
        assertEquals(500, big.deleted.size)
        assertEquals("sig-e30-30", big.keys.first())
    }

    @Test
    fun `anything that is not a head is null`() {
        assertNull(SyncHead.parse(""))
        assertNull(SyncHead.parse("not json"))
        assertNull(SyncHead.parse("[]"))
        assertTrue(SyncHead.parse("""{"Keys":"a"}""")!!.keys.isEmpty())
    }

    @Test
    fun `a head with no Keys is an empty list and still has its Deleted`() {
        val head = SyncHead.parse("""{"Deleted":["a","","b"],"Times":[1,2]}""")!!
        assertTrue(head.keys.isEmpty())
        assertNull(head.times)
        assertEquals(listOf("a", "b"), head.deleted)
        assertEquals(SyncHead(emptyList(), null, emptyList()), SyncHead.parse("{}"))
    }

    @Test
    fun `a v1 5 head still parses as the older form and a v2 head is not one`() {
        val newest = entryOf("n", 3)
        val oldForm = io.uaena.cliplink.net.HistoryHead(newest, listOf(newest.dk)).toJson()
        assertTrue(io.uaena.cliplink.net.HistoryHead.parse(oldForm) != null)
        // The same text read as a v2 head: the keys count, the Newest is not looked at.
        assertEquals(listOf(newest.dk), SyncHead.parse(oldForm)!!.keys)
        assertNull(io.uaena.cliplink.net.HistoryHead.parse(SyncHead(listOf("k"), null, emptyList()).toJson()))
    }

    // ---- request and delete -------------------------------------------------------------

    @Test
    fun `a request and a delete carry Keys and nothing else`() {
        val json = JSONObject(KeyListMessage(listOf("a", "b")).toJson())
        assertEquals(setOf("Keys"), json.keys().asSequence().toSet())
        assertEquals(listOf("a", "b"), strings(json.getJSONArray("Keys")))
        assertEquals(KeyListMessage(listOf("a", "b")), KeyListMessage.parse(KeyListMessage(listOf("a", "b")).toJson()))
    }

    @Test
    fun `a request keeps the first 100 usable keys`() {
        val keys = (1..150).map { "k$it" }
        val parsed = KeyListMessage.parse(JSONObject().put("Keys", JSONArray(keys)).toString())!!
        assertEquals(keys.take(100), parsed.keys)
        assertEquals(listOf("a", "b"), KeyListMessage.parse("""{"Keys":["a",5,"",null,"b"]}""")!!.keys)
        assertTrue(KeyListMessage.parse("""{"Keys":[]}""")!!.keys.isEmpty())
        assertNull(KeyListMessage.parse("""{"Other":[]}"""))
        assertNull(KeyListMessage.parse("nope"))
    }

    // ---- which keys a head makes worth asking for ---------------------------------------

    private fun local(range: IntRange): List<ClipboardEntry> = range.map { entryOf("l$it", it) }

    private fun head(vararg keysAndTimes: Pair<String, Long>) =
        SyncHead(keysAndTimes.map { it.first }, keysAndTimes.map { it.second }, emptyList())

    @Test
    fun `without times everything offered is wanted, up to 25`() {
        val keys = (1..30).map { "m$it" }
        val head = SyncHead(keys, null, emptyList())
        assertEquals(keys.take(25), SyncManager.wantedKeys(keys, head, local(1..3)))
        assertEquals(listOf("m1", "m2"), SyncManager.wantedKeys(listOf("m1", "m2"), SyncHead(listOf("m1", "m2"), null, emptyList()), emptyList()))
    }

    @Test
    fun `only the 25 newest by time of what is here and what would come are wanted`() {
        // 25 here, from second 100 to 124; three offered: one newer than all, one in between, one older than all.
        val here = local(100..124)
        val head = head("new" to ms(200), "mid" to ms(120) + 500, "old" to ms(50))
        assertEquals(listOf("new", "mid"), SyncManager.wantedKeys(listOf("new", "mid", "old"), head, here))
    }

    @Test
    fun `the first offered is always wanted even when it is older than everything`() {
        val here = local(100..124)
        val head = head("old" to ms(50), "older" to ms(40), "new" to ms(200))
        // "old" is the convenience item and stays in; "older" would be dropped at once; "new" is worth it.
        assertEquals(listOf("old", "new"), SyncManager.wantedKeys(listOf("old", "older", "new"), head, here))
    }

    @Test
    fun `an offered item and one here with the same time leave the one here in`() {
        val here = local(100..124)
        // 25 here from 100 to 124; "first" pushes out the oldest here (100), and "same" ties with it and loses.
        val head = head("first" to ms(150), "same" to ms(100))
        assertEquals(listOf("first"), SyncManager.wantedKeys(listOf("first", "same"), head, here))
        // As the first offered, the same one is the convenience item and is wanted all the same.
        val head2 = head("same" to ms(100), "newer" to ms(150))
        assertEquals(listOf("same", "newer"), SyncManager.wantedKeys(listOf("same", "newer"), head2, here))
    }

    @Test
    fun `times out of order never make more than 25 wanted`() {
        val here = local(100..123) // 24 here
        // The first offered is the oldest of all, then 25 newer ones: the first stays in, so one of the rest has to go.
        val keys = listOf("first") + (1..25).map { "m$it" }
        val head = SyncHead(keys, listOf(ms(1)) + (1..25).map { ms(200 + it) }, emptyList())
        val wanted = SyncManager.wantedKeys(keys, head, here)
        assertEquals(25, wanted.size)
        assertEquals("first", wanted.first())
        assertEquals(keys.take(25), wanted)
    }

    @Test
    fun `a time with no zone counts as UTC`() {
        val utc = DotNetTimestamp.epochMillis("2026-09-26T10:00:00.5000000Z")!!
        assertEquals(utc, DotNetTimestamp.epochMillis("2026-09-26T10:00:00.5000000")!!)
        assertEquals(utc, DotNetTimestamp.epochMillis("2026-09-26T10:00:00.5")!!)
        assertEquals(utc, DotNetTimestamp.epochMillis("2026-09-26T10:00:00.5+00:00")!!)
        assertEquals(utc - 8 * 3_600_000L, DotNetTimestamp.epochMillis("2026-09-26T10:00:00.5+08:00")!!)
        assertEquals(1_790_416_800_000L, DotNetTimestamp.epochMillis("2026-09-26T10:00:00"))
        assertNull(DotNetTimestamp.epochMillis("not a time"))
    }

    @Test
    fun `nothing missing means nothing wanted`() {
        assertTrue(SyncManager.wantedKeys(emptyList(), head("a" to ms(1)), local(1..2)).isEmpty())
    }
}
