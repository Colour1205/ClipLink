package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.BatchGroups
import io.uaena.cliplink.net.HistoryHead
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
        @Volatile
        override var isSessionProven = false

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
    private val batches = CopyOnWriteArrayList<SyncManager.BatchApplied>()
    private val storedBatches = CopyOnWriteArrayList<List<ClipboardEntry>>()
    private val storedHeads = CopyOnWriteArrayList<Pair<ClipboardEntry, Int>>()
    private val settledHeads = CopyOnWriteArrayList<Long>()
    private val groups = BatchGroups()
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
        // What the engine does: a batch after a head joins the head's group.
        it.onBatchStored = { stored, headGroup ->
            storedBatches.add(stored)
            if (headGroup == null) groups.recordBatch(stored, 0L) else groups.complete(headGroup, stored.map { e -> e.deletionKey })
        }
        it.onHeadStored = { newest, expectedNew ->
            // Recorded last: a test that waits for it can then rely on the group.
            groups.provisional(newest.deletionKey, expectedNew, 0L).also { storedHeads.add(newest to expectedNew) }
        }
        it.onHeadSettled = { id ->
            settledHeads.add(id)
            groups.complete(id, emptyList())
        }
        // What the engine does with a batch: one announcement, the newest goes on the clipboard.
        it.onBatchApplied = { batch ->
            batches.add(batch)
            batch.toApply?.let(applied::add)
        }
    }

    private fun ts(n: Int) = "2026-09-26T10:%02d:%02d.0000001Z".format(n / 60, n % 60)

    private fun entry(content: String, n: Int, device: String = "PEER") =
        ClipboardEntry(content, ClipboardEntry.TYPE_TEXT, device, ts(n), "sig-$content-$n")

    private fun entryMessage(entry: ClipboardEntry) = Protocol.envelope(Protocol.TYPE_ENTRY, entry.toJson().toString())

    private fun batchMessage(entries: List<ClipboardEntry>) =
        Protocol.envelope(Protocol.TYPE_HISTORY_BATCH, ClipboardEntry.listToJson(entries).toString())

    private fun headMessage(newest: ClipboardEntry, keys: List<ClipboardEntry>) =
        Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, HistoryHead(newest, keys.map { it.deletionKey }).toJson())

    /**
     * The tag of [entry] in the groups, as the list would see it: with the
     * history as it is, and [among] (the entries a test cares about) too.
     * Asking about less than the whole history would end the groups of the rest.
     */
    private fun tagOf(entry: ClipboardEntry, among: List<ClipboardEntry>) =
        groups.resolve((among + history.all()).mapTo(HashSet()) { it.deletionKey }, groups.horizon())[entry.deletionKey]

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
    fun `removing a device tells it first, then ends its link`() {
        val peer = link()
        sync.unpair("PEER")
        eventually("the link to be closed") { peer.isClosed }
        assertEquals("removed", peer.closeReason)
        // After the history batch every new link gets, the last thing it was sent is the unpair.
        assertEquals(Protocol.envelope(Protocol.TYPE_UNPAIR, "{}"), peer.sent.last())
        assertFalse(sync.isConnected("PEER"))
        // No link, or twice: nothing.
        sync.unpair("PEER")
        sync.unpair("NOBODY")
    }

    @Test
    fun `a link counts as proven only once its peer has answered`() {
        val peer = link()
        assertTrue(sync.isConnected("PEER"))
        assertEquals(1, sync.connectionCount)
        assertEquals(0, sync.provenCount)
        assertTrue(sync.provenDeviceIds().isEmpty())
        peer.isSessionProven = true
        assertEquals(1, sync.provenCount)
        assertEquals(setOf("PEER"), sync.provenDeviceIds())
    }

    @Test
    fun `a trusted peer that unpairs gets the engine told and its link closed`() {
        val peer = link()
        val unpaired = CopyOnWriteArrayList<String>()
        sync.onUnpaired = { unpaired.add(it) }
        runBlocking { peer.deliver(Protocol.envelope(Protocol.TYPE_UNPAIR, "{}")) }
        eventually("the link to be closed") { peer.isClosed }
        assertEquals(listOf("PEER"), unpaired.toList())
        assertEquals("it removed this device", peer.closeReason)
    }

    @Test
    fun `an unpair from a device that is not trusted changes nothing`() {
        val peer = link(trust = false)
        val unpaired = CopyOnWriteArrayList<String>()
        sync.onUnpaired = { unpaired.add(it) }
        runBlocking { peer.deliver(Protocol.envelope(Protocol.TYPE_UNPAIR, "{}")) }
        eventually("the link to be closed") { peer.isClosed }
        assertTrue(unpaired.isEmpty())
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
        // The ones that stayed off the clipboard are still shown - by the one announcement of the batch.
        assertEquals(1, batches.size)
        assertEquals(0, historyChanges.get())
    }

    // ---- a batch is applied as one unit -------------------------------------------

    @Test
    fun `a batch is announced once, whatever the number of entries it adds`() {
        val peer = link()
        val entries = (1..10).map { entry("item $it", it) }

        runBlocking { peer.deliver(batchMessage(entries)) }
        eventually("the batch to be announced") { batches.isNotEmpty() }
        Thread.sleep(100)

        assertEquals(1, batches.size)
        assertEquals(1, storedBatches.size)
        assertEquals(entries.toSet(), batches.single().added.toSet())
        assertEquals("PEER", batches.single().from)
        assertEquals(entries.last(), batches.single().toApply) // the newest, once
        assertEquals(listOf(entries.last()), applied.toList())
        assertEquals(0, historyChanges.get()) // no per-entry "history changed"
    }

    @Test
    fun `a batch is split into new, already known and deleted entries`() {
        val deleted = mutableSetOf<String>()
        val store = HistoryStore(File(temp.root, "split.jsonl"), null, files, { it in deleted }, { })
        val known = entry("known", 1)
        val gone = entry("gone", 2)
        val fresh1 = entry("fresh1", 3)
        val fresh2 = entry("fresh2", 4)
        store.addAll(listOf(known))
        deleted.add(gone.signature!!)
        history = store
        sync = newSync()
        val peer = link()

        runBlocking { peer.deliver(batchMessage(listOf(known, gone, fresh1, fresh2))) }
        eventually("the batch") { batches.isNotEmpty() }

        assertEquals(listOf(fresh1, fresh2), batches.single().added)
        assertEquals(setOf(known, fresh1, fresh2), history.all().toSet())
        // Only the two new ones are a group: the known one and the deleted one are not in it.
        val all = listOf(known, gone, fresh1, fresh2).map { it.signature!! }.toSet()
        assertEquals(setOf(fresh1.signature, fresh2.signature), groups.resolve(all, groups.horizon()).keys)
    }

    @Test
    fun `receiving the same history again adds nothing and makes no group`() {
        val peer = link()
        val entries = (1..5).map { entry("item $it", it) }
        runBlocking { peer.deliver(batchMessage(entries)) }
        eventually("the first batch") { batches.size == 1 }

        runBlocking { peer.deliver(batchMessage(entries)) }
        Thread.sleep(300)

        assertEquals(1, batches.size)
        assertEquals(1, storedBatches.size)
        val keys = entries.map { it.signature!! }.toSet()
        assertEquals(1, groups.resolve(keys, groups.horizon()).values.map { it.id }.toSet().size)
        assertEquals(5, history.all().size)
    }

    @Test
    fun `one new entry in a batch is announced but is not a group`() {
        val peer = link()
        val a = entry("a", 1)
        val b = entry("b", 2)
        history.addAll(listOf(a))

        runBlocking { peer.deliver(batchMessage(listOf(a, b))) }
        eventually("the batch") { batches.isNotEmpty() }

        assertEquals(listOf(b), batches.single().added)
        assertTrue(groups.resolve(setOf(a.signature!!, b.signature!!), groups.horizon()).isEmpty())
    }

    @Test
    fun `two batches make two groups`() {
        val peerA = link("PEER")
        val peerB = link("OTHER")
        val first = listOf(entry("a1", 1, "PEER"), entry("a2", 2, "PEER"))
        val second = listOf(entry("b1", 3, "OTHER"), entry("b2", 4, "OTHER"), entry("b3", 5, "OTHER"))

        runBlocking {
            peerA.deliver(batchMessage(first))
            peerB.deliver(batchMessage(second))
        }
        eventually("both batches") { batches.size == 2 }

        val tags = groups.resolve((first + second).map { it.signature!! }.toSet(), groups.horizon())
        assertEquals(5, tags.size)
        assertEquals(2, tags.values.map { it.id }.toSet().size)
        assertEquals(tags[first[0].signature], tags[first[1].signature])
        assertTrue(tags[first[0].signature] != tags[second[0].signature])
    }

    @Test
    fun `a batch bigger than the history keeps only the newest and groups only those`() {
        val peer = link()
        val entries = (1..40).map { entry("item $it", it) }

        runBlocking { peer.deliver(batchMessage(entries)) }
        eventually("the batch") { batches.isNotEmpty() }

        assertEquals(HistoryStore.MAX_ITEMS, history.all().size)
        assertEquals(HistoryStore.MAX_ITEMS, batches.single().added.size)
        assertEquals(1, storedBatches.size)
        val survivors = history.all().map { it.signature!! }.toSet()
        assertEquals(survivors, groups.resolve(survivors, groups.horizon()).keys)
    }

    @Test
    fun `a live entry is stored and applied by itself and is never a group`() {
        val peer = link()
        runBlocking { peer.deliver(entryMessage(entry("live", 9))) }
        eventually("the entry") { applied.isNotEmpty() }
        Thread.sleep(100)

        assertTrue(batches.isEmpty())
        assertTrue(storedBatches.isEmpty())
        assertEquals(listOf("live"), applied.map { it.content })
    }

    @Test
    fun `a batch whose newest entry is a file still arriving is announced once and asks for the bytes once`() {
        val payload = """{"FileName":"a.bin","FileHash":"${"ab".repeat(32)}","FileSize":10}"""
        val file = ClipboardEntry(payload, ClipboardEntry.TYPE_FILE, "PEER", ts(9), "sig-file")
        val older = entry("older", 1)
        val peer = link()
        // Past the connect-time history batch and file check, which are not what is counted here.
        eventually("the history batch") { peer.sent.size == 1 }
        Thread.sleep(100)

        runBlocking { peer.deliver(batchMessage(listOf(older, file))) }
        eventually("the batch") { batches.isNotEmpty() }
        eventually("the file request") { peer.sent.any { it.contains("file_request") } }
        Thread.sleep(100)

        assertEquals(1, batches.size)
        assertEquals(null, batches.single().toApply) // applied when the bytes have come
        assertTrue(applied.isEmpty())
        assertEquals(0, historyChanges.get())
        assertEquals(1, peer.sent.count { it.contains("file_request") })
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
        assertTrue(batches.isEmpty())
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

    // ---- history_head: the newest first, the rest in the background -----------------------------

    @Test
    fun `a head with two or more new keys stores and applies the newest and shows a stack at once`() {
        val peer = link()
        val all = (1..4).map { entry("item $it", it) }
        val newest = all.last()

        runBlocking { peer.deliver(headMessage(newest, all.reversed())) }
        eventually("the head to be applied") { applied.isNotEmpty() }
        Thread.sleep(100)

        assertEquals(listOf(newest), history.all())
        assertEquals(listOf(newest), applied.toList())
        assertEquals(listOf(newest to 4), storedHeads.toList())
        val tag = checkNotNull(tagOf(newest, all))
        assertEquals(4, tag.expectedSize) // the badge says +3 before the batch is here
        assertTrue(batches.isEmpty())
    }

    @Test
    fun `a head with one new key is a normal card`() {
        val peer = link()
        val known = entry("known", 1)
        val newest = entry("newest", 2)
        history.addAll(listOf(known))

        runBlocking { peer.deliver(headMessage(newest, listOf(newest, known))) }
        eventually("the head to be applied") { applied.isNotEmpty() }
        Thread.sleep(100)

        assertEquals(listOf(newest to 1), storedHeads.toList())
        assertEquals(listOf(newest), applied.toList())
        assertEquals(setOf(known, newest), history.all().toSet())
        assertTrue(tagOf(newest, listOf(known, newest)) == null)
    }

    @Test
    fun `a head with no new keys does nothing`() {
        val peer = link()
        val a = entry("a", 1)
        val b = entry("b", 2)
        history.addAll(listOf(a, b))

        runBlocking { peer.deliver(headMessage(b, listOf(b, a))) }
        Thread.sleep(300)

        assertTrue(storedHeads.isEmpty())
        assertTrue(applied.isEmpty())
        assertEquals(listOf(a, b), history.all())
        assertTrue(tagOf(b, listOf(a, b)) == null)
    }

    @Test
    fun `a head whose newest is deleted here does nothing`() {
        val deleted = mutableSetOf<String>()
        history = HistoryStore(File(temp.root, "head-deleted.jsonl"), null, files, { it in deleted }, { })
        sync = newSync()
        val peer = link()
        val all = (1..3).map { entry("item $it", it) }
        deleted.add(all.last().signature!!)

        runBlocking { peer.deliver(headMessage(all.last(), all.reversed())) }
        Thread.sleep(300)

        assertTrue(storedHeads.isEmpty())
        assertTrue(applied.isEmpty())
        assertTrue(history.all().isEmpty())
    }

    @Test
    fun `a head whose newest is already known makes no stack and the batch works as before`() {
        val peer = link()
        val all = (1..3).map { entry("item $it", it) }
        val newest = all.last()
        history.addAll(listOf(newest))

        runBlocking { peer.deliver(headMessage(newest, all.reversed())) }
        Thread.sleep(300)
        assertTrue(storedHeads.isEmpty())
        assertTrue(applied.isEmpty())

        runBlocking { peer.deliver(batchMessage(all)) }
        eventually("the batch") { batches.isNotEmpty() }
        assertEquals(all.dropLast(1), batches.single().added)
        // As without a head: the group is made when the batch is stored, and the newest new one is applied.
        val tags = groups.resolve(all.map { it.deletionKey }.toSet(), groups.horizon())
        assertEquals(all.dropLast(1).map { it.deletionKey }.toSet(), tags.keys)
        assertEquals(listOf(all[1]), applied.toList())
    }

    @Test
    fun `a head with a bad signature is ignored and the batch still works`() {
        sync = newSync(verify = { if (it.content == "item 3") null else it })
        val peer = link()
        val all = (1..3).map { entry("item $it", it) }

        runBlocking {
            peer.deliver(headMessage(all.last(), all.reversed()))
            peer.deliver(batchMessage(all))
        }
        eventually("the batch") { batches.isNotEmpty() }

        assertTrue(storedHeads.isEmpty())
        assertTrue(log.any { it.contains("history head") && it.contains("signature") })
        // The forged newest is not in the batch either; the other two are a group made at batch time.
        assertEquals(all.dropLast(1), batches.single().added)
        assertEquals(listOf(all[1]), applied.toList())
        assertEquals(2, groups.resolve(all.map { it.deletionKey }.toSet(), groups.horizon()).size)
        assertTrue(settledHeads.isEmpty())
    }

    @Test
    fun `a head from a signer that is not trusted is ignored and the batch still works`() {
        val peer = link()
        val stranger = entry("from a stranger", 9, device = "STRANGER")
        val all = (1..3).map { entry("item $it", it) }

        runBlocking {
            peer.deliver(headMessage(stranger, listOf(stranger) + all.reversed()))
            peer.deliver(batchMessage(all))
        }
        eventually("the batch") { batches.isNotEmpty() }

        assertTrue(storedHeads.isEmpty())
        assertEquals(all, batches.single().added)
        assertEquals(listOf(all.last()), applied.toList())
        assertTrue(history.all().none { it.deviceId == "STRANGER" })
    }

    @Test
    fun `a head that is too large or is not readable is ignored`() {
        sync = newSync(maxEntryContentChars = 10)
        val peer = link()
        val big = entry("x".repeat(11), 5)

        runBlocking {
            peer.deliver(headMessage(big, listOf(big, entry("y", 4))))
            peer.deliver(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, "not json"))
            peer.deliver(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, """{"Newest":{"Content":"a"},"Keys":[]}"""))
            peer.deliver(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, """{"Keys":["a"]}"""))
        }
        eventually("four notes in the log") { log.size >= 4 }

        assertTrue(storedHeads.isEmpty())
        assertTrue(history.all().isEmpty())
        assertTrue(applied.isEmpty())
    }

    @Test
    fun `a head then its batch make one group with the same id and the same badge number`() {
        val peer = link()
        val all = (1..4).map { entry("item $it", it) }
        val newest = all.last()

        runBlocking { peer.deliver(headMessage(newest, all.reversed())) }
        eventually("the head") { applied.isNotEmpty() }
        val before = checkNotNull(tagOf(newest, all))

        // In no particular order, and with the newest in it again.
        runBlocking { peer.deliver(batchMessage(listOf(all[1], newest, all[0], all[2]))) }
        eventually("the batch") { batches.isNotEmpty() }
        Thread.sleep(100)

        val tags = groups.resolve(all.map { it.deletionKey }.toSet(), groups.horizon())
        assertEquals(all.map { it.deletionKey }.toSet(), tags.keys)
        assertEquals(setOf(before.id), tags.values.map { it.id }.toSet())
        assertEquals(setOf(0), tags.values.map { it.expectedSize }.toSet()) // the guess is over
        assertEquals(before.createdAtMs, tags.getValue(newest.deletionKey).createdAtMs)
        assertEquals(4, tags.size) // so the badge still says +3
        // The batch added the others, as one unit; the newest was known and is not added again.
        assertEquals(setOf(all[0], all[1], all[2]), batches.single().added.toSet())
        assertEquals(1, storedBatches.size)
        assertEquals(setOf(before.id), settledHeads.toSet()) // told, though the batch had settled it
        assertEquals(all.toSet(), history.all().toSet())
    }

    @Test
    fun `the side effects of the newest happen once, at the head`() {
        val peer = link()
        val all = (1..3).map { entry("item $it", it) }
        val newest = all.last()

        runBlocking {
            peer.deliver(headMessage(newest, all.reversed()))
            peer.deliver(batchMessage(all))
        }
        eventually("the batch") { batches.isNotEmpty() }
        Thread.sleep(100)

        assertEquals(listOf(newest), applied.toList()) // once, and not an older item over it
        assertEquals(null, batches.single().toApply)
        assertEquals(0, historyChanges.get())
    }

    @Test
    fun `a batch that adds nothing after its head leaves the newest as a card`() {
        val peer = link()
        val a = entry("a", 1)
        val b = entry("b", 2)
        val c = entry("c", 3)

        // The head claims two others are new; the batch turns out to hold none of them.
        runBlocking {
            peer.deliver(headMessage(c, listOf(c, b, a)))
            peer.deliver(batchMessage(listOf(c)))
        }
        eventually("the head to be settled") { settledHeads.isNotEmpty() }

        assertTrue(batches.isEmpty())
        assertEquals(listOf(c), history.all())
        assertTrue(tagOf(c, listOf(c)) == null)
    }

    @Test
    fun `a connection that closes before the batch ends the provisional group`() {
        val peer = link()
        val all = (1..4).map { entry("item $it", it) }
        runBlocking { peer.deliver(headMessage(all.last(), all.reversed())) }
        eventually("the head") { storedHeads.isNotEmpty() }
        assertEquals(4, checkNotNull(tagOf(all.last(), all)).expectedSize)

        peer.close()
        eventually("the head to be settled") { settledHeads.isNotEmpty() }

        // Only the newest arrived: it is an ordinary card, and nothing more is expected.
        assertTrue(tagOf(all.last(), all) == null)
        assertEquals(listOf(all.last()), history.all())
    }

    @Test
    fun `no head means a batch behaves as it always did`() {
        val peer = link()
        val all = (1..3).map { entry("item $it", it) }

        runBlocking { peer.deliver(batchMessage(all)) }
        eventually("the batch") { batches.isNotEmpty() }

        assertTrue(storedHeads.isEmpty())
        assertTrue(settledHeads.isEmpty())
        assertEquals(all, batches.single().added)
        assertEquals(all.last(), batches.single().toApply)
        assertEquals(3, groups.resolve(all.map { it.deletionKey }.toSet(), groups.horizon()).size)
    }

    @Test
    fun `a second head replaces the first and ends its group`() {
        val peer = link()
        val first = (1..3).map { entry("first $it", it) }
        val second = (11..14).map { entry("second $it", it) }

        runBlocking { peer.deliver(headMessage(first.last(), first.reversed())) }
        eventually("the first head") { storedHeads.size == 1 }
        val firstId = checkNotNull(tagOf(first.last(), first)).id

        runBlocking { peer.deliver(headMessage(second.last(), second.reversed())) }
        eventually("the second head") { storedHeads.size == 2 }

        assertEquals(listOf(firstId), settledHeads.toList())
        assertTrue(tagOf(first.last(), first) == null) // its newest is a card again
        val tag = checkNotNull(tagOf(second.last(), second))
        assertTrue(tag.id != firstId)
        assertEquals(4, tag.expectedSize)

        // The batch that comes belongs to the second head.
        runBlocking { peer.deliver(batchMessage(second)) }
        eventually("the batch") { batches.isNotEmpty() }
        val tags = groups.resolve(second.map { it.deletionKey }.toSet(), groups.horizon())
        assertEquals(setOf(tag.id), tags.values.map { it.id }.toSet())
        assertEquals(4, tags.size)
    }

    @Test
    fun `a stack opened before the batch arrives leaves the rest as ordinary cards`() {
        val peer = link()
        val all = (1..4).map { entry("item $it", it) }
        val newest = all.last()
        runBlocking { peer.deliver(headMessage(newest, all.reversed())) }
        eventually("the head") { storedHeads.isNotEmpty() }

        groups.dissolve(checkNotNull(tagOf(newest, all)).id) // the user opened it

        runBlocking { peer.deliver(batchMessage(all)) }
        eventually("the batch") { batches.isNotEmpty() }
        Thread.sleep(100)

        // All four are in the history, in one update, and none of them is stacked.
        assertEquals(all.toSet(), history.all().toSet())
        assertEquals(3, batches.single().added.size)
        assertTrue(groups.resolve(all.map { it.deletionKey }.toSet(), groups.horizon()).isEmpty())
    }

    @Test
    fun `a head from one connection does not touch the batch of another`() {
        val peerA = link("PEER")
        val peerB = link("OTHER")
        val a = (1..3).map { entry("a $it", it, "PEER") }
        val b = (11..13).map { entry("b $it", it, "OTHER") }

        runBlocking {
            peerA.deliver(headMessage(a.last(), a.reversed()))
            peerB.deliver(batchMessage(b))
        }
        eventually("both") { batches.size == 1 && storedHeads.size == 1 }
        Thread.sleep(100)

        // B's batch had no head: its own group, and its newest on the clipboard.
        val tagsB = b.mapNotNull { tagOf(it, a + b) }
        assertEquals(3, tagsB.size)
        assertEquals(setOf(0), tagsB.map { it.expectedSize }.toSet())
        assertTrue(applied.contains(b.last()))
        // A's stack is still waiting for its batch.
        assertEquals(3, checkNotNull(tagOf(a.last(), a)).expectedSize)
        assertTrue(settledHeads.isEmpty())
    }

    // ---- sending the head ------------------------------------------------------------------------

    @Test
    fun `a connection with two or more entries gets the head first and then the unchanged batch`() {
        // Stored out of order on purpose: the head names the newest, not the last stored.
        val stored = listOf(entry("middle", 20, "ME"), entry("newest", 30, "ME"), entry("oldest", 10, "ME"))
        history.addAll(stored)
        val peer = link("KNOWN")
        eventually("the head and the batch") { peer.sent.size == 2 }
        Thread.sleep(100)
        assertEquals(2, peer.sent.size)

        val headEnvelope = checkNotNull(io.uaena.cliplink.net.Envelope.parse(peer.sent[0]))
        assertEquals(Protocol.TYPE_HISTORY_HEAD, headEnvelope.type)
        val head = checkNotNull(HistoryHead.parse(headEnvelope.payload))
        val batchEnvelope = checkNotNull(io.uaena.cliplink.net.Envelope.parse(peer.sent[1]))
        assertEquals(Protocol.TYPE_HISTORY_BATCH, batchEnvelope.type)
        val batch = ClipboardEntry.listFromJson(org.json.JSONArray(batchEnvelope.payload))

        assertEquals(stored, batch) // the batch is what it was before
        assertEquals(batch.map { it.deletionKey }.toSet(), head.keys.toSet())
        assertEquals(batch.size, head.keys.size)
        assertEquals(listOf("newest", "middle", "oldest"), head.keys.map { key -> batch.first { it.deletionKey == key }.content })
        assertEquals(batch.first { it.deletionKey == head.keys.first() }, head.newest)
        assertEquals("newest", head.newest.content)
        assertTrue(head.newest.signature!!.isNotEmpty())
    }

    @Test
    fun `a connection with one entry or none gets no head`() {
        val none = link("NONE")
        eventually("its batch") { none.sent.size == 1 }
        history.addAll(listOf(entry("only", 1, "ME")))
        val one = link("ONE")
        eventually("its batch") { one.sent.size == 1 }
        Thread.sleep(150)

        assertEquals(1, none.sent.size)
        assertEquals(1, one.sent.size)
        assertTrue(one.sent.single().contains("history_batch"))
        assertFalse(one.sent.single().contains("history_head"))
    }

    @Test
    fun `a head is not sent to a device that is not trusted`() {
        history.addAll(listOf(entry("a", 1, "ME"), entry("b", 2, "ME")))
        val stranger = link("STRANGER", trust = false)
        Thread.sleep(200)
        assertTrue(stranger.sent.isEmpty())
    }

    @Test
    fun `what this app sends as a head and a batch its receiver turns into one stack`() {
        // The sending side: a history of four, made by a device the receiver trusts.
        val all = (1..4).map { entry("item $it", it, "ME") }
        history.addAll(all)
        val sender = link("RECEIVER")
        eventually("the head and the batch") { sender.sent.size == 2 }
        val wire = sender.sent.toList()

        // The receiving side: another history, another SyncManager, the same bytes.
        history = HistoryStore(File(temp.root, "receiver.jsonl"), null, files, { false }, { })
        sync = newSync()
        val receiver = link("SENDER")
        trusted.add("ME")
        runBlocking { receiver.deliver(wire[0]) }
        eventually("the head") { storedHeads.isNotEmpty() }
        assertEquals(listOf(all.last()), history.all())
        assertEquals(4, checkNotNull(tagOf(all.last(), all)).expectedSize)

        runBlocking { receiver.deliver(wire[1]) }
        eventually("the batch") { batches.isNotEmpty() }
        assertEquals(all.toSet(), history.all().toSet())
        assertEquals(listOf(all.last()), applied.toList())
        val tags = groups.resolve(all.map { it.deletionKey }.toSet(), groups.horizon())
        assertEquals(4, tags.size)
        assertEquals(1, tags.values.map { it.id }.toSet().size)
    }
}
