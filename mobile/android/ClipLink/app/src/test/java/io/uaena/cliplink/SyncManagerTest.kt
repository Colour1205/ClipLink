package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.Limits
import io.uaena.cliplink.net.PeerLink
import io.uaena.cliplink.net.Protocol
import io.uaena.cliplink.net.SyncManager
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.TrustCheck
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * SyncManager's message handling with fake connections: who is answered, what
 * is applied, and that a slow handler slows the sender instead of piling
 * messages up. Real stores on temp folders; the signature check and the
 * connections are fakes (the real ones need the Keystore and a socket).
 */
class SyncManagerTest {

    @get:Rule
    val temp = TemporaryFolder()

    /** A connection that records what it is sent and lets the test play the read loop. */
    private class FakeLink(override val peerDeviceId: String) : PeerLink {
        val sent = CopyOnWriteArrayList<String>()

        @Volatile
        override var isClosed = false
        override val peerName: String? = null
        override val isSessionProven = false

        @Volatile
        override var closeReason: String? = null
        override var onMessage: (suspend (String) -> Unit)? = null
        override var onDisconnected: (() -> Unit)? = null
        override var onSessionProven: (() -> Unit)? = null
        var listening = false

        override suspend fun send(message: String) {
            if (isClosed) throw IOException("closed")
            sent.add(message)
        }

        override fun listen() {
            listening = true
        }

        override fun close(reason: String) {
            if (isClosed) return
            isClosed = true
            closeReason = reason
            onDisconnected?.invoke()
        }

        /** What the read loop does with a decrypted message - it waits if the handler's inbox is full. */
        suspend fun deliver(message: String) {
            onMessage!!.invoke(message)
        }
    }

    private val trusted: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val log = CopyOnWriteArrayList<String>()
    private val applied = CopyOnWriteArrayList<ClipboardEntry>()
    private val historyChanges = AtomicInteger()
    private lateinit var files: FileStore
    private lateinit var history: HistoryStore
    private lateinit var scope: CoroutineScope
    private lateinit var sync: SyncManager

    @Before
    fun setUp() {
        files = FileStore(temp.newFolder("blobs"), temp.newFolder("shared"))
        history = HistoryStore(File(temp.root, "history.jsonl"), null, files, { false }, { })
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        sync = newSync()
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun newSync(
        maxEntryContentChars: Int = Limits.MAX_ENTRY_CONTENT_CHARS,
        verify: (ClipboardEntry) -> ClipboardEntry? = { it },
    ) = SyncManager(scope, history, TrustCheck { it in trusted }, files, verify, maxEntryContentChars).also {
        it.onLog = { message -> log.add(message) }
        it.onEntryApplied = { entry -> applied.add(entry) }
        it.onHistoryChanged = { historyChanges.incrementAndGet() }
    }

    private fun ts(n: Int) = "2026-09-26T10:%02d:%02d.0000001Z".format(n / 60, n % 60)

    private fun entry(content: String, n: Int, device: String = "PEER") =
        ClipboardEntry(content, ClipboardEntry.TYPE_TEXT, device, ts(n), "sig-$content-$n")

    private fun entryMessage(entry: ClipboardEntry) = Protocol.envelope(Protocol.TYPE_ENTRY, entry.toJson().toString())

    private fun batchMessage(entries: List<ClipboardEntry>) =
        Protocol.envelope(Protocol.TYPE_HISTORY_BATCH, ClipboardEntry.listToJson(entries).toString())

    private fun eventually(what: String, timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val until = System.currentTimeMillis() + timeoutMs
        while (!condition()) {
            if (System.currentTimeMillis() > until) throw AssertionError("timed out waiting for: $what")
            Thread.sleep(10)
        }
    }

    private fun link(id: String = "PEER", trust: Boolean = true): FakeLink {
        if (trust) trusted.add(id)
        return FakeLink(id).also { sync.registerConnection(it) }
    }

    // ---- who is answered ------------------------------------------------------

    @Test
    fun `an entry from a trusted peer is stored and applied once`() {
        val peer = link()
        val e = entry("hello", 1)
        runBlocking {
            peer.deliver(entryMessage(e))
            peer.deliver(entryMessage(e)) // the same entry again: not new
        }
        eventually("the entry to be applied") { applied.isNotEmpty() }
        Thread.sleep(100)
        assertEquals(listOf(e), applied.toList())
        assertEquals(listOf(e), history.all())
    }

    @Test
    fun `a message from a device that is not trusted closes the link and does nothing`() {
        val peer = link(trust = false)
        runBlocking { peer.deliver(entryMessage(entry("hello", 1))) }
        eventually("the link to be closed") { peer.isClosed }
        assertEquals("no longer trusted", peer.closeReason)
        assertTrue(applied.isEmpty())
        assertTrue(history.all().isEmpty())
    }

    @Test
    fun `a device removed while connected is cut off at its next message`() {
        val peer = link()
        runBlocking { peer.deliver(entryMessage(entry("before", 1))) }
        eventually("the first entry") { applied.size == 1 }
        trusted.remove("PEER")
        runBlocking { peer.deliver(entryMessage(entry("after", 2))) }
        eventually("the link to be closed") { peer.isClosed }
        assertEquals(1, applied.size)
        assertEquals(1, history.all().size)
    }

    @Test
    fun `removing a device closes its connection and drops it from the connected list`() {
        val peer = link()
        val counts = CopyOnWriteArrayList<Int>()
        sync.onConnectionsChanged = { counts.add(it) }
        assertTrue(sync.isConnected("PEER"))

        sync.close("PEER")

        assertTrue(peer.isClosed)
        assertEquals("removed", peer.closeReason)
        assertFalse(sync.isConnected("PEER"))
        assertEquals(0, sync.connectionCount)
        assertEquals(listOf(0), counts.toList())
        assertTrue(log.any { it.startsWith("peer disconnected") && it.contains("(removed)") })
        // Closing a device with no link, or twice, is nothing.
        sync.close("PEER")
        sync.close("NOBODY")
    }

    @Test
    fun `a new connection gets the history, but not if its device isn't trusted`() {
        history.addAll(listOf(entry("old", 1, device = "ME")))
        val known = link("KNOWN")
        val stranger = link("STRANGER", trust = false)
        eventually("the history batch") { known.sent.size == 1 }
        Thread.sleep(150)
        assertTrue(known.sent.single().contains("history_batch"))
        assertTrue(stranger.sent.isEmpty())
    }

    @Test
    fun `new entries go only to devices that are still trusted`() {
        val stays = link("STAYS")
        val removed = link("REMOVED")
        eventually("both history batches") { stays.sent.size == 1 && removed.sent.size == 1 }

        trusted.remove("REMOVED")
        runBlocking { sync.broadcastEntries(listOf(entry("copied", 5, device = "ME"))) }

        eventually("the entry to reach the trusted device") { stays.sent.size == 2 }
        Thread.sleep(150)
        assertEquals(1, removed.sent.size) // still only its history batch
        assertTrue(stays.sent.last().contains("copied"))
    }

    @Test
    fun `a file request from a device that was removed streams nothing`() {
        val bytes = ByteArray(1000) { it.toByte() }
        val hash = FileStore.hashOf(bytes)
        files.write(hash, bytes)
        val peer = link()
        eventually("the history batch") { peer.sent.size == 1 }
        trusted.remove("PEER")
        runBlocking {
            peer.deliver(Protocol.envelope(Protocol.TYPE_FILE_REQUEST, """{"FileHash":"$hash"}"""))
        }
        eventually("the link to be closed") { peer.isClosed }
        Thread.sleep(150)
        assertTrue(peer.sent.none { it.contains("file_chunk") })
        // And asking the stream function directly gives the same answer.
        runBlocking { sync.streamFileToPeer(peer, files.path(hash), hash) }
        assertTrue(peer.sent.none { it.contains("file_chunk") })
    }

    // ---- a slow handler slows the sender --------------------------------------

    @Test
    fun `a handler that can't keep up makes the read loop wait instead of queueing`() {
        val peer = link()
        val release = CountDownLatch(1)
        val delivered = AtomicInteger()
        sync.onEntryApplied = { entry ->
            if (entry.content == "msg0") release.await(10, TimeUnit.SECONDS)
            applied.add(entry)
        }
        val total = 20
        val reader = CoroutineScope(Dispatchers.IO).launch {
            for (i in 0 until total) {
                peer.deliver(entryMessage(entry("msg$i", i)))
                delivered.incrementAndGet()
            }
        }

        // The handler holds message 0; two more fit in the inbox; the fourth
        // delivery is parked - nothing more is "read" until the handler moves.
        eventually("the inbox to fill") { delivered.get() >= 1 + Limits.INBOX_CAPACITY }
        Thread.sleep(300)
        assertEquals(1 + Limits.INBOX_CAPACITY, delivered.get())
        assertTrue(applied.isEmpty())

        release.countDown()
        eventually("every message to be handled") { applied.size == total }
        runBlocking { reader.join() }
        assertEquals(total, delivered.get())
        // In the order they arrived.
        assertEquals((0 until total).map { "msg$it" }, applied.map { it.content })
    }

    @Test
    fun `one message that blows up does not stop the next, nor the process`() {
        val peer = link()
        sync.onEntryApplied = { entry ->
            if (entry.content == "boom") throw StackOverflowError()
            applied.add(entry)
        }
        runBlocking {
            peer.deliver(entryMessage(entry("boom", 1)))
            peer.deliver(entryMessage(entry("fine", 2)))
        }
        eventually("the second message") { applied.size == 1 }
        assertEquals("fine", applied.single().content)
        assertTrue(log.any { it.contains("couldn't handle a message") })
        assertFalse(peer.isClosed)
    }

    // ---- history batches --------------------------------------------------------

    @Test
    fun `a history batch applies only the newest of what is new`() {
        val known = entry("known", 1)
        history.addAll(listOf(known))
        val middle = entry("middle", 20)
        val newest = entry("newest", 30)
        val oldest = entry("oldest", 10)
        val peer = link()

        // In no particular order, as a peer's history comes.
        runBlocking { peer.deliver(batchMessage(listOf(middle, newest, known, oldest))) }

        eventually("the batch to be handled") { history.all().size == 4 }
        eventually("the newest to be applied") { applied.isNotEmpty() }
        Thread.sleep(100)
        assertEquals(listOf(newest), applied.toList())
        assertEquals(setOf(known, middle, newest, oldest), history.all().toSet())
        // The ones that stayed off the clipboard are still shown.
        assertTrue(historyChanges.get() >= 1)
    }

    @Test
    fun `an entry older than everything a full history keeps is not new`() {
        val kept = (100 until 125).map { entry("kept$it", it) }
        history.addAll(kept)
        assertEquals(HistoryStore.MAX_ITEMS, history.all().size)
        val ancient = entry("ancient", 1)
        val peer = link()

        runBlocking {
            peer.deliver(batchMessage(listOf(ancient)))
            peer.deliver(entryMessage(ancient))
        }
        Thread.sleep(300)

        assertTrue(applied.isEmpty())
        assertEquals(kept.toSet(), history.all().toSet())
    }

    @Test
    fun `a batch with only entries that were seen before applies nothing`() {
        val a = entry("a", 1)
        history.addAll(listOf(a))
        val peer = link()
        runBlocking { peer.deliver(batchMessage(listOf(a))) }
        Thread.sleep(200)
        assertTrue(applied.isEmpty())
    }

    @Test
    fun `entries over the size limit are dropped and logged, the rest of the batch kept`() {
        sync = newSync(maxEntryContentChars = 100)
        val big = entry("x".repeat(101), 5)
        val small = entry("small", 6)
        val peer = link()

        runBlocking {
            peer.deliver(entryMessage(big))
            peer.deliver(batchMessage(listOf(big, small)))
        }
        eventually("the small entry") { applied.isNotEmpty() }
        Thread.sleep(100)

        assertEquals(listOf(small), applied.toList())
        assertEquals(listOf(small), history.all())
        assertTrue(log.any { it.contains("too large") })
    }

    @Test
    fun `an entry whose signature doesn't hold is dropped, in a batch and alone`() {
        sync = newSync(verify = { if (it.content == "forged") null else it })
        val peer = link()
        val real = entry("real", 3)
        runBlocking {
            peer.deliver(entryMessage(entry("forged", 1)))
            peer.deliver(batchMessage(listOf(entry("forged", 2), real)))
        }
        eventually("the real entry") { applied.isNotEmpty() }
        Thread.sleep(100)
        assertEquals(listOf(real), applied.toList())
        assertEquals(listOf(real), history.all())
        assertTrue(log.any { it.contains("failed signature/trust check") })
    }

    @Test
    fun `an entry from a signer that isn't trusted is dropped even with a good signature`() {
        val peer = link()
        runBlocking { peer.deliver(entryMessage(entry("hello", 1, device = "STRANGER"))) }
        Thread.sleep(200)
        assertTrue(applied.isEmpty())
        assertTrue(history.all().isEmpty())
    }

    // ---- what a history batch carries ---------------------------------------------

    @Test
    fun `a batch leaves out entries too big to repeat on every connect, newest first`() {
        fun sized(name: String, n: Int, size: Int) = entry(name.padEnd(size, '.'), n)
        val a = sized("A", 1, 10)
        val b = sized("B", 2, 25) // over the per-entry cap
        val c = sized("C", 3, 15)
        val d = sized("D", 4, 10)

        val selection = SyncManager.selectForRelay(listOf(a, b, c, d), maxEntryChars = 20, maxBatchChars = 30)

        // Newest first fills the budget: D (10), C (15), then A (10) no longer fits.
        assertEquals(listOf(c, d), selection.entries) // in the history's own order
        assertEquals(2, selection.skipped)
    }

    @Test
    fun `an ordinary history is sent whole`() {
        val entries = (1..10).map { entry("item $it", it) }
        val selection = SyncManager.selectForRelay(entries)
        assertEquals(entries, selection.entries)
        assertEquals(0, selection.skipped)
    }
}
