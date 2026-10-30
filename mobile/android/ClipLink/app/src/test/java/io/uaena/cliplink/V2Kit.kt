package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.engine.BatchGroups
import io.uaena.cliplink.engine.GroupTag
import io.uaena.cliplink.engine.arrange
import io.uaena.cliplink.net.Envelope
import io.uaena.cliplink.net.KeyListMessage
import io.uaena.cliplink.net.Limits
import io.uaena.cliplink.net.PeerLink
import io.uaena.cliplink.net.Protocol
import io.uaena.cliplink.net.SyncHead
import io.uaena.cliplink.net.SyncManager
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.TrustCheck
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import org.json.JSONArray
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * What the v2 sync tests share: a device made of the real stores and the real SyncManager (the signature
 * check and the sockets are faked), wired to the groups the way the engine wires them.
 */

internal fun ts(n: Int) = "2026-09-26T10:%02d:%02d.0000001Z".format(n / 60, n % 60)

/** [ts]'s instant as a v2 head carries it. */
internal fun ms(n: Int): Long = DotNetTimestamp.epochMillis(ts(n))!!

internal fun entryOf(content: String, n: Int, device: String = "PEER") =
    ClipboardEntry(content, ClipboardEntry.TYPE_TEXT, device, ts(n), "sig-$content-$n")

internal val ClipboardEntry.dk: String get() = deletionKey

internal fun eventually(what: String, timeoutMs: Long = 5_000, condition: () -> Boolean) {
    val until = System.currentTimeMillis() + timeoutMs
    while (!condition()) {
        if (System.currentTimeMillis() > until) throw AssertionError("timed out waiting for: $what")
        Thread.sleep(10)
    }
}

/** Messages as they are on the wire. */
internal object Wire {
    fun entry(e: ClipboardEntry) = Protocol.envelope(Protocol.TYPE_ENTRY, e.toJson().toString())

    fun batch(entries: List<ClipboardEntry>) =
        Protocol.envelope(Protocol.TYPE_HISTORY_BATCH, ClipboardEntry.listToJson(entries).toString())

    fun head(keys: List<String>, times: List<Long>?, deleted: List<String> = emptyList()) =
        Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, SyncHead(keys, times, deleted).toJson())

    /** The head of a peer that has [entries]. */
    fun headOf(entries: List<ClipboardEntry>, deleted: List<String> = emptyList()) =
        Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, SyncHead.forHistory(entries, deleted).toJson())

    fun request(keys: List<String>) = Protocol.envelope(Protocol.TYPE_HISTORY_REQUEST, KeyListMessage(keys).toJson())

    fun delete(keys: List<String>) = Protocol.envelope(Protocol.TYPE_DELETE, KeyListMessage(keys).toJson())

    fun type(message: String): String = Envelope.parse(message)!!.type

    fun payload(message: String): String = Envelope.parse(message)!!.payload

    fun keysOf(message: String): List<String> = KeyListMessage.parse(payload(message))!!.keys

    /** The contents of a history_batch's entries, in order. */
    fun contentsOf(batchMessage: String): List<String> {
        val array = JSONArray(payload(batchMessage))
        return (0 until array.length()).map { array.getJSONObject(it).getString("Content") }
    }
}

/** The deleted keys of one device, oldest first, as DeletedStore keeps them. */
internal class Tombstones {
    private val keys = LinkedHashSet<String>()

    @Synchronized
    fun contains(key: String) = key in keys

    @Synchronized
    fun record(newKeys: Collection<String>) {
        newKeys.forEach {
            keys.remove(it)
            keys.add(it)
        }
    }

    @Synchronized
    fun recent(limit: Int): List<String> = keys.toList().takeLast(limit).reversed()

    @Synchronized
    fun all(): List<String> = keys.toList()
}

/** A connection that records what it is sent and lets the test play the read loop. */
internal class V2Link(override val peerDeviceId: String, override val peerProtocol: Int = 2) : PeerLink {
    val sent = CopyOnWriteArrayList<String>()

    @Volatile
    override var isClosed = false
    override val peerName: String? = null
    override var isSessionProven = false

    @Volatile
    override var closeReason: String? = null
    override var onMessage: (suspend (String) -> Unit)? = null
    override var onDisconnected: (() -> Unit)? = null
    override var onSessionProven: (() -> Unit)? = null

    /** While true a send waits, as a write does on a link that is not being read. */
    @Volatile
    var holdSends = false

    override suspend fun send(message: String) {
        while (holdSends && !isClosed) delay(5)
        if (isClosed) throw IOException("closed")
        sent.add(message)
    }

    override fun listen() = Unit

    override fun close(reason: String) {
        if (isClosed) return
        isClosed = true
        closeReason = reason
        onDisconnected?.invoke()
    }

    suspend fun deliver(message: String) {
        onMessage!!.invoke(message)
    }

    fun sentOfType(type: String): List<String> = sent.filter { Wire.type(it) == type }
}

/** One end of a pair of connections that hand each other what they send. */
internal class WireLink(override val peerDeviceId: String, override val peerProtocol: Int = 2) : PeerLink {
    val sent = CopyOnWriteArrayList<String>()
    var other: WireLink? = null

    @Volatile
    override var isClosed = false
    override val peerName: String? = null
    override var isSessionProven = false

    @Volatile
    override var closeReason: String? = null
    override var onMessage: (suspend (String) -> Unit)? = null
    override var onDisconnected: (() -> Unit)? = null
    override var onSessionProven: (() -> Unit)? = null

    override suspend fun send(message: String) {
        if (isClosed) throw IOException("closed")
        sent.add(message)
        // The other end may not have been registered yet.
        var waited = 0
        while (other?.onMessage == null && waited++ < 400) delay(5)
        other?.onMessage?.invoke(message)
    }

    override fun listen() = Unit

    override fun close(reason: String) {
        if (isClosed) return
        isClosed = true
        closeReason = reason
        onDisconnected?.invoke()
        other?.close("the other end closed")
    }

    fun sentOfType(type: String): List<String> = sent.filter { Wire.type(it) == type }
}

/**
 * A device: its history, deleted keys and groups are the real ones; [applied] is what reached its clipboard.
 * Wired like ClipLinkEngine wires them.
 */
internal class V2Peer(
    val id: String,
    root: File,
    scope: CoroutineScope,
    clock: () -> Long = System::currentTimeMillis,
    maxStoredChars: Long = Limits.MAX_STORED_CHARS,
) {
    val tomb = Tombstones()
    val trusted: MutableSet<String> = ConcurrentHashMap.newKeySet()
    val files = FileStore(File(root, "$id-blobs").also { it.mkdirs() }, File(root, "$id-shared").also { it.mkdirs() })
    val history = HistoryStore(
        storage = File(root, "$id-history.jsonl"),
        legacy = null,
        fileStore = files,
        isDeletedKey = tomb::contains,
        recordDeleted = tomb::record,
        maxStoredChars = maxStoredChars,
        recentDeleted = tomb::recent,
    )
    val groups = BatchGroups()
    val applied = CopyOnWriteArrayList<ClipboardEntry>()
    val batches = CopyOnWriteArrayList<SyncManager.BatchApplied>()
    val settled = CopyOnWriteArrayList<Long>()
    val log = CopyOnWriteArrayList<String>()
    val listChanges = AtomicInteger()

    val sync: SyncManager = SyncManager(
        scope, history, TrustCheck { it in trusted }, files, { it }, Limits.MAX_ENTRY_CONTENT_CHARS, clock,
    ).also { sync ->
        sync.onLog = { log.add(it) }
        sync.onEntryApplied = { applied.add(it) }
        sync.onHistoryChanged = { listChanges.incrementAndGet() }
        sync.onBatchStored = { stored, headGroup ->
            if (headGroup == null) groups.recordBatch(stored, 0L) else groups.complete(headGroup, stored.map { it.dk })
        }
        sync.onHeadStored = { newest, expected -> groups.provisional(newest.dk, expected, 0L) }
        sync.onHeadSettled = { id ->
            settled.add(id)
            groups.complete(id, emptyList())
        }
        sync.onLiveStored = { stored ->
            stored.sortedBy { DotNetTimestamp.canonical(it.timestamp) }.forEach { groups.noteLive(it.dk, 0L) }
        }
        sync.onSyncStored = { stored ->
            val front = stored.front
            val others = stored.stored.filter { it !== front }.map { it.dk }
            when {
                front != null -> groups.recordSync(front.dk, others, stored.expectedSize, 0L)
                stored.groupId != null -> stored.groupId.also { groups.join(it, others) }
                else -> groups.recordBatch(stored.stored, 0L)
            }
        }
        sync.onBatchApplied = { batch ->
            batches.add(batch)
            batch.toApply?.let(applied::add)
        }
    }

    fun connectTo(link: PeerLink): PeerLink {
        trusted.add(link.peerDeviceId)
        sync.registerConnection(link)
        return link
    }

    /** What the Synced list would show, top to bottom, as item contents. */
    fun view(): List<String> {
        val all = history.all()
        val placement = groups.place(all.mapTo(HashSet()) { it.dk }, groups.horizon())
        return arrange(all, placement.blocks).map { it.content }
    }

    fun tagOf(e: ClipboardEntry): GroupTag? {
        val all = history.all()
        return groups.place(all.mapTo(HashSet()) { it.dk }, groups.horizon()).tags[e.dk]
    }

    fun contents(): Set<String> = history.all().map { it.content }.toSet()
}
