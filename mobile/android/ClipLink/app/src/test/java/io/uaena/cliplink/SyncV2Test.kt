package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.HistoryHead
import io.uaena.cliplink.net.Protocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.atomic.AtomicLong

/**
 * SyncManager on a v2 connection, with fake links: the head, what is asked for and in what order, how the
 * answers are applied, the request timeout, a connection that ends, requests from the peer, deletes - and
 * that an older peer is left alone. Real stores on temp folders.
 */
class SyncV2Test {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var scope: CoroutineScope
    private lateinit var me: V2Peer
    private val now = AtomicLong(1_000_000L)

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        me = V2Peer("me", temp.root, scope, now::get)
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    /** The entries here are signed by "PEER", whichever link they come over. */
    private fun link(id: String = "PEER", protocol: Int = 2): V2Link {
        me.trusted.add("PEER")
        return V2Link(id, protocol).also { me.connectTo(it) }
    }

    private fun V2Link.requests(): List<List<String>> = sentOfType(Protocol.TYPE_HISTORY_REQUEST).map(Wire::keysOf)

    private fun V2Link.batches(): List<String> = sentOfType(Protocol.TYPE_HISTORY_BATCH)

    private fun quiet() = Thread.sleep(200)

    private val a = entryOf("a", 1)
    private val b = entryOf("b", 2)
    private val c = entryOf("c", 3)
    private val d = entryOf("d", 4)

    // ---- the head we send ----------------------------------------------------------------

    @Test
    fun `a v2 connection opens with a head of keys, times and deleted, and sends no batch`() {
        me.history.addAll(listOf(a, d))
        me.tomb.record(listOf("gone1", "gone2"))
        val peer = link()
        eventually("the head") { peer.sent.isNotEmpty() }
        quiet()

        assertEquals(listOf(Protocol.TYPE_HISTORY_HEAD), peer.sent.map(Wire::type))
        val json = JSONObject(Wire.payload(peer.sent.single()))
        assertEquals(setOf("Keys", "Times", "Deleted"), json.keys().asSequence().toSet())
        assertEquals(listOf(d.dk, a.dk), (0 until 2).map { json.getJSONArray("Keys").getString(it) })
        assertEquals(listOf(ms(4), ms(1)), (0 until 2).map { json.getJSONArray("Times").getLong(it) })
        assertEquals(listOf("gone2", "gone1"), (0 until 2).map { json.getJSONArray("Deleted").getString(it) })
    }

    @Test
    fun `a head is sent even with no entries and nothing deleted`() {
        val peer = link()
        eventually("the head") { peer.sent.isNotEmpty() }
        assertEquals("""{"Keys":[],"Times":[],"Deleted":[]}""", Wire.payload(peer.sent.single()))
    }

    @Test
    fun `a head is not sent to a device that is not trusted`() {
        val peer = V2Link("STRANGER")
        me.sync.registerConnection(peer)
        quiet()
        assertTrue(peer.sent.isEmpty())
    }

    // ---- what is asked for -----------------------------------------------------------------

    @Test
    fun `the newest missing item is asked for alone and then the rest in one request`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c, d))) }
        eventually("two requests") { peer.requests().size == 2 }
        assertEquals(listOf(listOf(d.dk), listOf(c.dk, b.dk, a.dk)), peer.requests())
    }

    @Test
    fun `a single missing item is one request and no stack`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a))) }
        eventually("a request") { peer.requests().size == 1 }
        quiet()
        assertEquals(listOf(listOf(a.dk)), peer.requests())
    }

    @Test
    fun `keys already here, deleted here or nothing at all are not asked for`() {
        me.history.addAll(listOf(a))
        me.tomb.record(listOf(c.dk))
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c, d))) }
        eventually("two requests") { peer.requests().size == 2 }
        assertEquals(listOf(listOf(d.dk), listOf(b.dk)), peer.requests())

        val second = link("OTHER")
        runBlocking { second.deliver(Wire.headOf(listOf(a))) }
        quiet()
        assertTrue(second.requests().isEmpty())
    }

    @Test
    fun `a key asked of one connection is not asked of another`() {
        val first = link("ONE")
        val second = link("TWO")
        runBlocking { first.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("the requests") { first.requests().size == 2 }
        runBlocking { second.deliver(Wire.headOf(listOf(a, b, c, d))) }
        eventually("the one it can still be asked for") { second.requests().isNotEmpty() }
        quiet()
        // Only d is left: the others are on their way from the first.
        assertEquals(listOf(listOf(d.dk)), second.requests())
    }

    @Test
    fun `without times everything missing is asked for`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.head(listOf(c.dk, b.dk, a.dk), null)) }
        eventually("two requests") { peer.requests().size == 2 }
        assertEquals(listOf(listOf(c.dk), listOf(b.dk, a.dk)), peer.requests())
    }

    @Test
    fun `an item older than everything a full history keeps is not asked for unless it is the first`() {
        me.history.addAll((100..124).map { entryOf("l$it", it) })
        val old1 = entryOf("old1", 10)
        val old2 = entryOf("old2", 11)
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(old1, old2))) }
        eventually("a request") { peer.requests().isNotEmpty() }
        quiet()
        // The first (old2, the newer) is the item that goes on the clipboard; the other would be stored only to be dropped.
        assertEquals(listOf(listOf(old2.dk)), peer.requests())
    }

    @Test
    fun `a Newest in a head is ignored on a v2 connection and read on an older one`() {
        val v2 = link("NEW")
        val v15Head = Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, HistoryHead(c, listOf(c.dk, b.dk)).toJson())
        runBlocking { v2.deliver(v15Head) }
        eventually("a request") { v2.requests().isNotEmpty() }
        quiet()
        assertTrue(me.history.all().isEmpty())
        assertTrue(me.applied.isEmpty())
        assertEquals(listOf(listOf(c.dk), listOf(b.dk)), v2.requests())

        val old = link("OLD", protocol = 1)
        runBlocking { old.deliver(v15Head) }
        eventually("the newest stored") { me.history.all().size == 1 }
        assertEquals(listOf(c), me.applied.toList())
        assertTrue(old.requests().isEmpty())
    }

    @Test
    fun `a bad head is logged and nothing is asked`() {
        val peer = link()
        runBlocking { peer.deliver(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, "not json")) }
        quiet()
        assertTrue(peer.requests().isEmpty())
        assertTrue(me.log.any { it.contains("bad history_head") })
    }

    // ---- the answers -------------------------------------------------------------------------

    @Test
    fun `two requests are answered in order, the clipboard gets the first one once, the second applies nothing`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }

        runBlocking { peer.deliver(Wire.batch(listOf(c))) }
        eventually("the convenience item applied") { me.applied.size == 1 }
        assertEquals(listOf(c), me.applied.toList())
        // The stack is there at once with the count of the whole sync, with the convenience item in front.
        eventually("the stack") { me.tagOf(c)?.expectedSize == 3 }

        runBlocking { peer.deliver(Wire.batch(listOf(b, a))) }
        eventually("all three stored") { me.history.all().size == 3 }
        eventually("the stack settled") { me.tagOf(c)?.expectedSize == 0 }

        // Still one application, no notification for the rest.
        assertEquals(listOf(c), me.applied.toList())
        assertEquals(2, me.batches.size)
        assertNull(me.batches[1].toApply)
        // One stack of three, settled once.
        val tags = listOf(a, b, c).map { me.tagOf(it) }
        assertEquals(1, tags.map { it!!.id }.toSet().size)
        assertEquals(1, me.settled.size)
        assertEquals(listOf("c", "b", "a"), me.view())
    }

    @Test
    fun `the convenience item is the newest new one of its answer, wherever it stands in it`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }
        // The peer sends more than was asked, oldest first.
        runBlocking {
            peer.deliver(Wire.batch(listOf(a, b, c)))
            peer.deliver(Wire.batch(emptyList()))
        }
        eventually("stored") { me.history.all().size == 3 }
        assertEquals(listOf(c), me.applied.toList())
    }

    @Test
    fun `an answer with nothing new applies nothing and the other answer still stores its items`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }
        runBlocking {
            peer.deliver(Wire.batch(emptyList())) // the newest is gone from the peer already
            peer.deliver(Wire.batch(listOf(b, a)))
        }
        eventually("stored") { me.history.all().size == 2 }
        quiet()
        assertTrue(me.applied.isEmpty())
        assertNull(me.batches.single().toApply)
    }

    @Test
    fun `a batch nobody asked for is handled as an older peer's, the newest new item even if older than ours`() {
        me.history.addAll(listOf(entryOf("mine", 50)))
        val peer = link()
        runBlocking { peer.deliver(Wire.batch(listOf(a, b))) }
        eventually("stored") { me.history.all().size == 3 }
        quiet()
        assertEquals(listOf(b), me.applied.toList())
        assertEquals(1, me.batches.size)
    }

    @Test
    fun `an item deleted here comes back in no answer`() {
        me.tomb.record(listOf(c.dk))
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }
        assertEquals(listOf(listOf(b.dk), listOf(a.dk)), peer.requests())
        runBlocking {
            peer.deliver(Wire.batch(listOf(b)))
            peer.deliver(Wire.batch(listOf(c, a)))
        }
        eventually("stored") { me.history.all().size == 2 }
        assertEquals(setOf("a", "b"), me.contents())
    }

    // ---- timeouts and ended connections ----------------------------------------------------------

    @Test
    fun `a request that goes unanswered is dropped after 90 seconds and its keys can be asked elsewhere`() {
        val first = link("ONE")
        runBlocking { first.deliver(Wire.headOf(listOf(a, b))) }
        eventually("the requests") { first.requests().size == 2 }

        now.addAndGet(89_000)
        me.sync.expireRequests()
        val second = link("TWO")
        runBlocking { second.deliver(Wire.headOf(listOf(a, b))) }
        quiet()
        assertTrue("still pending on the first", second.requests().isEmpty())

        now.addAndGet(2_000)
        me.sync.expireRequests()
        runBlocking { second.deliver(Wire.headOf(listOf(a, b))) }
        eventually("asked of the second now") { second.requests().isNotEmpty() }
    }

    @Test
    fun `the late answers to requests that timed out are stored quietly, not taken for an older peer's batch`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("the requests") { peer.requests().size == 2 }
        now.addAndGet(91_000)
        me.sync.expireRequests()

        // Both answers come after all: the items are stored, but nothing reaches the clipboard, there is
        // no stack and no block - they stand by their time.
        runBlocking {
            peer.deliver(Wire.batch(listOf(c)))
            peer.deliver(Wire.batch(listOf(b, a)))
        }
        eventually("both stored") { me.history.all().size == 3 }
        quiet()
        assertTrue(me.applied.isEmpty())
        assertEquals(2, me.batches.size)
        assertTrue(me.batches.all { it.toApply == null })
        assertNull(me.tagOf(c))
        assertEquals(listOf("c", "b", "a"), me.view())
    }

    @Test
    fun `a late answer does not move the item the trim spares, and is trimmed like any other`() {
        me.history.addAll((100..123).map { entryOf("kept$it", it) })
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(c))) }
        eventually("the request") { peer.requests().size == 1 }
        runBlocking { peer.deliver(Wire.batch(listOf(c))) }
        eventually("c in") { me.history.all().size == 25 }
        assertEquals(listOf(c), me.applied.toList())

        // Another item of the same peer, answered too late: it is newer than c but older than the rest. c is
        // still the one the trim spares, so the late item is the oldest other one and goes at once.
        val x = entryOf("x", 5)
        runBlocking { peer.deliver(Wire.headOf(listOf(c, x))) }
        eventually("asked") { peer.requests().size == 2 }
        now.addAndGet(91_000)
        me.sync.expireRequests()
        runBlocking { peer.deliver(Wire.batch(listOf(x))) }
        quiet()
        assertEquals(25, me.history.all().size)
        assertTrue(me.history.all().contains(c))
        assertFalse(me.history.all().contains(x))
        assertEquals(listOf(c), me.applied.toList())
    }

    @Test
    fun `a late answer still asks for the bytes of a new file, and applies and announces nothing`() {
        val hash = "ab".repeat(32)
        val file = ClipboardEntry(
            io.uaena.cliplink.net.FilePayload("a.pdf", hash, 3).toJson(), ClipboardEntry.TYPE_FILE, "PEER", ts(3), "sig-file",
        )
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(file, b))) }
        eventually("the requests") { peer.requests().size == 2 }
        now.addAndGet(91_000)
        me.sync.expireRequests()

        runBlocking {
            peer.deliver(Wire.batch(listOf(file)))
            peer.deliver(Wire.batch(listOf(b)))
        }
        eventually("stored") { me.history.all().size == 2 }
        eventually("the bytes are asked for") { peer.sentOfType(Protocol.TYPE_FILE_REQUEST).isNotEmpty() }
        assertTrue(me.applied.isEmpty())
        assertNull(me.tagOf(file))
    }

    @Test
    fun `a late answer takes its own expired request, not one asked after the timeout`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b))) }
        eventually("the requests") { peer.requests().size == 2 }
        now.addAndGet(91_000)
        me.sync.expireRequests()

        // The same peer asks again (a new head) before the old answers have come.
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("asked again") { peer.requests().size == 4 }
        assertEquals(listOf(listOf(c.dk), listOf(b.dk, a.dk)), peer.requests().drop(2))

        runBlocking {
            peer.deliver(Wire.batch(listOf(b))) // late, for the first request
            peer.deliver(Wire.batch(listOf(a))) // late, for the second
        }
        // Stored quietly, each by its own marker: nothing on the clipboard, no stack.
        eventually("both stored") { me.history.all().size == 2 }
        quiet()
        assertTrue(me.applied.isEmpty())
        assertEquals(2, me.batches.size)
        assertTrue(me.batches.all { it.toApply == null })

        // Now the answers to the new requests, in order: c for the clipboard, the rest has nothing new.
        runBlocking {
            peer.deliver(Wire.batch(listOf(c)))
            peer.deliver(Wire.batch(listOf(b, a)))
        }
        eventually("all stored") { me.history.all().size == 3 }
        eventually("c applied") { me.applied.size == 1 }
        assertEquals(listOf(c), me.applied.toList())
        assertEquals(3, me.batches.size)
        assertEquals(c, me.batches[2].toApply)
    }

    @Test
    fun `a late answer arriving while a new sync's requests are queued does not touch that sync`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b))) }
        eventually("the requests") { peer.requests().size == 2 }
        now.addAndGet(91_000)
        me.sync.expireRequests()

        // A new head: its requests queue up behind the two expired markers.
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c, d))) }
        eventually("asked again") { peer.requests().size == 4 }
        assertEquals(listOf(listOf(d.dk), listOf(c.dk, b.dk, a.dk)), peer.requests().drop(2))

        // The late answers come first, in the order of the markers: stored quietly, nothing else happens.
        runBlocking {
            peer.deliver(Wire.batch(listOf(b)))
            peer.deliver(Wire.batch(listOf(a)))
        }
        eventually("both stored") { me.history.all().size == 2 }
        quiet()
        assertTrue(me.applied.isEmpty())
        assertTrue(me.settled.isEmpty())
        assertTrue(me.batches.all { it.toApply == null })

        // The new sync's own answers still pair with its own requests: d is the item for the clipboard and
        // heads a stack that waits for four, until the rest has come.
        runBlocking { peer.deliver(Wire.batch(listOf(d))) }
        eventually("d applied") { me.applied.size == 1 }
        assertEquals(listOf(d), me.applied.toList())
        assertEquals(4, me.tagOf(d)?.expectedSize)
        assertTrue(me.settled.isEmpty())

        runBlocking { peer.deliver(Wire.batch(listOf(c, b, a))) }
        eventually("c stored") { me.history.all().size == 4 }
        eventually("the stack settled") { me.settled.size == 1 }
        assertEquals(listOf(d), me.applied.toList())
    }

    // ---- two peers answering at once -------------------------------------------------------------

    /** Two connections, each asked for one item (its own newest missing one) as the convenience item. */
    private fun twoPeersEach(x: ClipboardEntry, y: ClipboardEntry): Pair<V2Link, V2Link> {
        val one = link("ONE")
        val two = link("TWO")
        runBlocking {
            one.deliver(Wire.headOf(listOf(x)))
            two.deliver(Wire.headOf(listOf(y)))
        }
        eventually("both asked") { one.requests().size == 1 && two.requests().size == 1 }
        return one to two
    }

    @Test
    fun `two peers answering at once change the clipboard once, the older item is only stored and leads its card`() {
        val (one, two) = twoPeersEach(c, b)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }
        runBlocking { two.deliver(Wire.batch(listOf(b))) }
        eventually("b stored") { me.history.all().size == 2 }
        quiet()

        assertEquals(listOf(c), me.applied.toList())
        assertEquals(2, me.batches.size)
        assertNull(me.batches[1].toApply)
        // It is the front of its own block, which arrived last.
        assertEquals(listOf("b", "c"), me.view())
    }

    @Test
    fun `a newer item inside the window still goes on the clipboard, an equal one does not`() {
        val (one, two) = twoPeersEach(c, d)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }
        runBlocking { two.deliver(Wire.batch(listOf(d))) }
        eventually("d applied") { me.applied.size == 2 }
        assertEquals(listOf(c, d), me.applied.toList())

        // The same time as the one applied last is not newer.
        val d2 = entryOf("d2", 4)
        runBlocking { one.deliver(Wire.headOf(listOf(d2))) }
        eventually("asked again") { one.requests().size == 2 }
        runBlocking { one.deliver(Wire.batch(listOf(d2))) }
        eventually("d2 stored") { me.history.all().size == 3 }
        quiet()
        assertEquals(listOf(c, d), me.applied.toList())
    }

    @Test
    fun `after 90 seconds an older convenience item goes on the clipboard again`() {
        val (one, two) = twoPeersEach(c, b)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }

        now.addAndGet(89_000)
        runBlocking { two.deliver(Wire.batch(listOf(b))) }
        eventually("b stored") { me.history.all().size == 2 }
        quiet()
        assertEquals(listOf(c), me.applied.toList())

        now.addAndGet(2_000) // 91 seconds after c
        runBlocking { two.deliver(Wire.headOf(listOf(a))) }
        eventually("asked for a") { two.requests().size == 2 }
        runBlocking { two.deliver(Wire.batch(listOf(a))) }
        eventually("a applied") { me.applied.size == 2 }
        assertEquals(listOf(c, a), me.applied.toList())
    }

    @Test
    fun `the same instant in another format is not newer, though its text sorts higher`() {
        // 12:00:03+02:00 is 10:00:03Z, the time of c; as text it sorts above "10:00:03...Z".
        val same = ClipboardEntry("same", ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T12:00:03.0000001+02:00", "sig-same")
        assertTrue("2026-09-26T12:00:03.0000001+02:00" > c.timestamp)
        val (one, two) = twoPeersEach(c, same)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }
        runBlocking { two.deliver(Wire.batch(listOf(same))) }
        eventually("same stored") { me.history.all().size == 2 }
        quiet()
        assertEquals(listOf(c), me.applied.toList())
    }

    @Test
    fun `a later instant whose text sorts lower still goes on the clipboard`() {
        // 09:00:04-02:00 is 11:00:04Z, an hour after c; as text it sorts below "10:00:03...Z".
        val later = ClipboardEntry("later", ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T09:00:04.0000001-02:00", "sig-later")
        assertTrue("2026-09-26T09:00:04.0000001-02:00" < c.timestamp)
        val (one, two) = twoPeersEach(c, later)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }
        runBlocking { two.deliver(Wire.batch(listOf(later))) }
        eventually("later applied") { me.applied.size == 2 }
        assertEquals(listOf(c, later), me.applied.toList())
    }

    @Test
    fun `a timestamp with no zone counts as UTC when compared with the one applied`() {
        // The same time as c, written with no zone.
        val bare = ClipboardEntry("bare", ClipboardEntry.TYPE_TEXT, "PEER", "2026-09-26T10:00:03.0000001", "sig-bare")
        val (one, two) = twoPeersEach(c, bare)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }
        runBlocking { two.deliver(Wire.batch(listOf(bare))) }
        eventually("bare stored") { me.history.all().size == 2 }
        quiet()
        assertEquals(listOf(c), me.applied.toList())
    }

    @Test
    fun `the item that did not get the clipboard is not spared by the trim`() {
        me.history.addAll((100..123).map { entryOf("kept$it", it) })
        val (one, two) = twoPeersEach(c, b)
        runBlocking { one.deliver(Wire.batch(listOf(c))) }
        eventually("c applied") { me.applied.size == 1 }
        assertEquals(25, me.history.all().size)

        // b is older than c and all: not spared, so it goes at once, and nothing else takes its place on the clipboard.
        runBlocking { two.deliver(Wire.batch(listOf(b))) }
        quiet()
        assertEquals(25, me.history.all().size)
        assertFalse(me.history.all().contains(b))
        assertTrue(me.history.all().contains(c))
        assertEquals(listOf(c), me.applied.toList())
    }

    @Test
    fun `a head with no Keys still has its Deleted applied`() {
        me.history.addAll(listOf(a))
        val peer = link()
        runBlocking { peer.deliver(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, """{"Deleted":["${a.dk}"]}""")) }
        eventually("a gone") { me.history.all().isEmpty() }
        assertTrue(me.tomb.contains(a.dk))
        quiet()
        assertTrue(peer.requests().isEmpty())
    }

    @Test
    fun `a timeout ends the waiting of a stack`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }
        runBlocking { peer.deliver(Wire.batch(listOf(c))) }
        eventually("the stack waits for three") { me.tagOf(c)?.expectedSize == 3 }

        now.addAndGet(91_000)
        me.sync.expireRequests()

        eventually("the stack settled") { me.settled.size == 1 }
        // Only the one item arrived: a single card, no stack.
        assertNull(me.tagOf(c))
    }

    @Test
    fun `a connection that ends hands what it was asked for to the other connections`() {
        val first = link("ONE")
        val second = link("TWO")
        runBlocking { first.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("the first is asked") { first.requests().size == 2 }
        runBlocking { second.deliver(Wire.headOf(listOf(a, b, c))) }
        quiet()
        assertTrue(second.requests().isEmpty())

        first.close("lost")

        // Nothing came from the first, so the convenience item is still owed.
        eventually("the second is asked") { second.requests().size == 2 }
        assertEquals(listOf(listOf(c.dk), listOf(b.dk, a.dk)), second.requests())
    }

    @Test
    fun `a connection that ends with an expired convenience marker in its queue is not owed to the clipboard by the others`() {
        val first = link("ONE")
        val second = link("TWO")
        runBlocking { first.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("the first is asked") { first.requests().size == 2 }
        runBlocking { second.deliver(Wire.headOf(listOf(a, b, c))) }
        quiet()
        assertTrue(second.requests().isEmpty())

        // Both requests of the first expire and stay in its queue as markers; then it goes.
        now.addAndGet(91_000)
        me.sync.expireRequests()
        first.close("lost")

        // Everything is asked of the second in one request that applies nothing: no request for the clipboard.
        eventually("the second is asked") { second.requests().isNotEmpty() }
        quiet()
        assertEquals(listOf(listOf(c.dk, b.dk, a.dk)), second.requests())
        runBlocking { second.deliver(Wire.batch(listOf(c, b, a))) }
        eventually("stored") { me.history.all().size == 3 }
        quiet()
        assertTrue(me.applied.isEmpty())
        assertTrue(me.batches.all { it.toApply == null })
    }

    @Test
    fun `after the convenience item arrived, what a lost connection owed is asked as items that apply nothing`() {
        val first = link("ONE")
        val second = link("TWO")
        runBlocking { first.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("the first is asked") { first.requests().size == 2 }
        runBlocking {
            second.deliver(Wire.headOf(listOf(a, b, c)))
            first.deliver(Wire.batch(listOf(c)))
        }
        eventually("c applied") { me.applied.size == 1 }
        first.close("lost")

        eventually("the second is asked") { second.requests().isNotEmpty() }
        quiet()
        assertEquals(listOf(listOf(b.dk, a.dk)), second.requests())
        runBlocking { second.deliver(Wire.batch(listOf(b, a))) }
        eventually("stored") { me.history.all().size == 3 }
        quiet()
        // The clipboard was not moved to an older item.
        assertEquals(listOf(c), me.applied.toList())
        // The stack that waited for the rest is final.
        eventually("settled") { me.settled.isNotEmpty() }
    }

    @Test
    fun `a connection that ends before its answers settles the stack it was building`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }
        runBlocking { peer.deliver(Wire.batch(listOf(c))) }
        eventually("the stack waits") { me.tagOf(c)?.expectedSize == 3 }
        peer.close("lost")
        eventually("settled") { me.settled.size == 1 }
        assertNull(me.tagOf(c))
    }

    // ---- requests from the peer --------------------------------------------------------------------

    @Test
    fun `a request is answered with one batch, newest first, and a key we no longer have is skipped`() {
        me.history.addAll(listOf(a, b, c))
        val peer = link()
        runBlocking { peer.deliver(Wire.request(listOf(a.dk, "nobody-has-this", c.dk))) }
        eventually("the answer") { peer.batches().isNotEmpty() }
        quiet()
        assertEquals(1, peer.batches().size)
        assertEquals(listOf("c", "a"), Wire.contentsOf(peer.batches().single()))
    }

    @Test
    fun `a request for nothing we have is answered with an empty list`() {
        me.history.addAll(listOf(a))
        val peer = link()
        runBlocking {
            peer.deliver(Wire.request(listOf("nobody-has-this")))
            peer.deliver(Wire.request(emptyList()))
        }
        eventually("two answers") { peer.batches().size == 2 }
        assertEquals(listOf("[]", "[]"), peer.batches().map(Wire::payload))
    }

    @Test
    fun `answers leave in the order the requests came`() {
        val big = ClipboardEntry("big".repeat(100_000), ClipboardEntry.TYPE_TEXT, "PEER", ts(5), "sig-big")
        me.history.addAll(listOf(a, big, c))
        val peer = link()
        runBlocking {
            peer.deliver(Wire.request(listOf(big.dk)))
            peer.deliver(Wire.request(listOf(a.dk)))
            peer.deliver(Wire.request(listOf(c.dk)))
        }
        eventually("three answers") { peer.batches().size == 3 }
        assertEquals(listOf(1, 1, 1), peer.batches().map { Wire.contentsOf(it).size })
        assertEquals(listOf("big".repeat(100_000), "a", "c"), peer.batches().map { Wire.contentsOf(it).single() })
    }

    @Test
    fun `only the first 100 keys of a request count`() {
        val history = (1..25).map { entryOf("e$it", it) }
        me.history.addAll(history)
        val peer = link()
        val beyond = (1..100).map { "unknown$it" } + history.map { it.dk }
        runBlocking { peer.deliver(Wire.request(beyond)) }
        val within = history.take(5).map { it.dk } + (1..100).map { "unknown$it" }
        runBlocking { peer.deliver(Wire.request(within)) }
        eventually("two answers") { peer.batches().size == 2 }
        assertEquals(0, JSONArray(Wire.payload(peer.batches()[0])).length())
        assertEquals(5, JSONArray(Wire.payload(peer.batches()[1])).length())
    }

    @Test
    fun `a peer that asks for far too much is cut off`() {
        val peer = link()
        peer.holdSends = true
        runBlocking { repeat(100) { peer.deliver(Wire.request(listOf("k$it"))) } }
        eventually("the link to be closed") { peer.isClosed }
        assertEquals("too many requests", peer.closeReason)
    }

    @Test
    fun `an older connection's request is not answered`() {
        me.history.addAll(listOf(a))
        val old = link("OLD", protocol = 1)
        eventually("its history") { old.sentOfType(Protocol.TYPE_HISTORY_BATCH).size == 1 }
        runBlocking { old.deliver(Wire.request(listOf(a.dk))) }
        quiet()
        assertEquals(1, old.sentOfType(Protocol.TYPE_HISTORY_BATCH).size)
        assertTrue(me.log.any { it.contains("unknown type") && it.contains(Protocol.TYPE_HISTORY_REQUEST) })
    }

    // ---- deletes -----------------------------------------------------------------------------------

    @Test
    fun `a delete removes the items, remembers every key and never touches the clipboard`() {
        me.history.addAll(listOf(a, b, c))
        val peer = link()
        runBlocking { peer.deliver(Wire.delete(listOf(a.dk, "never-had-this"))) }
        eventually("a removed") { me.history.all().size == 2 }
        assertEquals(setOf("b", "c"), me.contents())
        assertTrue(me.tomb.contains(a.dk))
        assertTrue(me.tomb.contains("never-had-this"))
        assertTrue(me.applied.isEmpty())
        assertEquals(1, me.listChanges.get())
        // Nothing is sent on: a delete from a peer is not broadcast again.
        quiet()
        assertTrue(peer.sentOfType(Protocol.TYPE_DELETE).isEmpty())
    }

    @Test
    fun `a deleted item offered again, live or in a batch, does not come back`() {
        me.history.addAll(listOf(a, b))
        val peer = link()
        runBlocking { peer.deliver(Wire.delete(listOf(a.dk))) }
        eventually("a removed") { me.history.all().size == 1 }
        runBlocking {
            peer.deliver(Wire.entry(a))
            peer.deliver(Wire.batch(listOf(a)))
        }
        quiet()
        assertEquals(setOf("b"), me.contents())
        assertTrue(me.applied.isEmpty())
    }

    @Test
    fun `what a head says was deleted is removed, with one update of the list`() {
        me.history.addAll(listOf(a, b, c))
        val peer = link()
        runBlocking { peer.deliver(Wire.head(listOf(b.dk), listOf(ms(2)), listOf(a.dk, c.dk))) }
        eventually("a and c removed") { me.history.all().size == 1 }
        quiet()
        assertEquals(setOf("b"), me.contents())
        assertTrue(me.tomb.contains(a.dk) && me.tomb.contains(c.dk))
        assertEquals(1, me.listChanges.get())
        assertTrue(me.applied.isEmpty())
        // b is here, nothing to ask for.
        assertTrue(peer.requests().isEmpty())
    }

    @Test
    fun `the same deleted keys in every head do not stamp them again`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.head(emptyList(), emptyList(), listOf("x1", "x2", "x3"))) }
        eventually("recorded") { me.tomb.contains("x3") }
        val before = me.tomb.all()
        runBlocking { peer.deliver(Wire.head(emptyList(), emptyList(), listOf("x1", "x2", "x3"))) }
        quiet()
        // Most recently deleted first on the wire, so the last of the list is the oldest here.
        assertEquals(listOf("x3", "x2", "x1"), before)
        assertEquals(before, me.tomb.all())
    }

    @Test
    fun `a delete from an older connection is not honoured`() {
        me.history.addAll(listOf(a))
        val old = link("OLD", protocol = 1)
        runBlocking { old.deliver(Wire.delete(listOf(a.dk))) }
        quiet()
        assertEquals(setOf("a"), me.contents())
    }

    @Test
    fun `a delete takes the front of a stack away and the next member steps up`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.headOf(listOf(a, b, c))) }
        eventually("two requests") { peer.requests().size == 2 }
        runBlocking {
            peer.deliver(Wire.batch(listOf(c)))
            peer.deliver(Wire.batch(listOf(b, a)))
        }
        eventually("stack of three") { me.history.all().size == 3 && me.tagOf(c)?.expectedSize == 0 }
        assertEquals(listOf("c", "b", "a"), me.view())

        runBlocking { peer.deliver(Wire.delete(listOf(c.dk))) }
        eventually("c gone") { me.history.all().size == 2 }
        assertEquals(listOf("b", "a"), me.view())
        assertNotNull(me.tagOf(b))
        assertEquals(me.tagOf(a)!!.id, me.tagOf(b)!!.id)

        // A stack left with one member is a single card.
        runBlocking { peer.deliver(Wire.delete(listOf(a.dk))) }
        eventually("a gone") { me.history.all().size == 1 }
        assertNull(me.tagOf(b))
        assertEquals(listOf("b"), me.view())
    }

    // ---- what this device deletes ---------------------------------------------------------------------

    @Test
    fun `a local delete is sent to v2 peers and not to older ones`() {
        me.history.addAll(listOf(a, b, c))
        val fresh = link("NEW")
        val old = link("OLD", protocol = 1)
        eventually("both are greeted") { fresh.sent.isNotEmpty() && old.sent.size == 2 }

        me.sync.deleteEntry(b)

        eventually("the delete") { fresh.sentOfType(Protocol.TYPE_DELETE).isNotEmpty() }
        assertEquals(listOf(b.dk), Wire.keysOf(fresh.sentOfType(Protocol.TYPE_DELETE).single()))
        assertEquals(setOf("a", "c"), me.contents())
        assertTrue(me.tomb.contains(b.dk))
        quiet()
        assertTrue(old.sentOfType(Protocol.TYPE_DELETE).isEmpty())
    }

    @Test
    fun `clearing the history tells v2 peers every key, split at 100`() {
        val many = (1..25).map { entryOf("e$it", it) }
        me.history.addAll(many)
        val fresh = link("NEW")
        eventually("greeted") { fresh.sent.isNotEmpty() }

        me.sync.clearHistory()

        eventually("the delete") { fresh.sentOfType(Protocol.TYPE_DELETE).isNotEmpty() }
        assertEquals(many.map { it.dk }.toSet(), Wire.keysOf(fresh.sentOfType(Protocol.TYPE_DELETE).single()).toSet())
        assertTrue(me.history.all().isEmpty())

        me.sync.broadcastDelete((1..250).map { "k$it" })
        eventually("three more") { fresh.sentOfType(Protocol.TYPE_DELETE).size == 4 }
        assertEquals(listOf(25, 100, 100, 50), fresh.sentOfType(Protocol.TYPE_DELETE).map { Wire.keysOf(it).size })
    }

    // ---- an older peer ------------------------------------------------------------------------------------

    @Test
    fun `an older peer gets the head and the whole history as before and never a request or a delete`() {
        me.history.addAll(listOf(a, b, c))
        val old = link("OLD", protocol = 1)
        eventually("head and batch") { old.sent.size == 2 }
        assertEquals(listOf(Protocol.TYPE_HISTORY_HEAD, Protocol.TYPE_HISTORY_BATCH), old.sent.map(Wire::type))
        val head = JSONObject(Wire.payload(old.sent[0]))
        assertTrue(head.has("Newest"))
        assertEquals(3, head.getJSONArray("Keys").length())
        assertEquals(3, JSONArray(Wire.payload(old.sent[1])).length())

        me.sync.deleteEntry(a)
        // Its head, if it sends one, is not a reason to ask it for anything.
        runBlocking { old.deliver(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, HistoryHead(d, listOf(d.dk)).toJson())) }
        runBlocking { old.deliver(Wire.batch(listOf(d))) }
        quiet()
        assertTrue(old.sentOfType(Protocol.TYPE_DELETE).isEmpty())
        assertTrue(old.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())
        assertEquals(2, old.sent.size)
        // What it sent applies once, the older way.
        assertEquals(listOf(d), me.applied.toList())
    }

    @Test
    fun `a v1 batch puts only the newest new item on the clipboard, though ours is newer`() {
        me.history.addAll(listOf(entryOf("mine", 90)))
        val old = link("OLD", protocol = 1)
        runBlocking { old.deliver(Wire.batch(listOf(c, a, b))) }
        eventually("stored") { me.history.all().size == 4 }
        quiet()
        assertEquals(listOf(c), me.applied.toList())
    }

    @Test
    fun `a v2 side that receives an entry live applies it like ever`() {
        val peer = link()
        runBlocking { peer.deliver(Wire.entry(a)) }
        eventually("applied") { me.applied.size == 1 }
        assertEquals(listOf(a), me.applied.toList())
        assertFalse(me.history.all().isEmpty())
    }
}
