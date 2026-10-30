package io.uaena.cliplink.net

import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.core.untrusted
import io.uaena.cliplink.engine.GROUP_MIN_ITEMS
import io.uaena.cliplink.engine.shortIdOf
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.HistoryStore.Arrival
import io.uaena.cliplink.store.newestOf
import io.uaena.cliplink.store.TrustCheck
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedSendChannelException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** How long an "unpair" gets to leave before its socket is closed. */
private const val UNPAIR_FLUSH_MS = 300L

/** How long a history_request, or a history_head with no batch behind it, waits for its answer. */
private const val REQUEST_TIMEOUT_MS = 90_000L

/** See [SyncManager.takeConvenienceSlot]. */
private const val CONVENIENCE_WINDOW_MS = 90_000L

/** Answers one v2 peer may have waiting to be sent; a peer asking for more than that is not asking in good faith. */
private const val MAX_QUEUED_ANSWERS = 32

/**
 * Owns the set of live peer connections and everything that flows over them.
 * Mirrors Program.cs's HandleMessage / SendHistoryBatch / ClipboardChanged /
 * HandleFileChunk / HandleFileRequest / StreamFileToPeer.
 *
 * A connection is only ever as good as its peer's trust record: nothing is
 * sent to, answered for or accepted from a device that is no longer trusted -
 * removing a device closes its link (see [close]), and the checks below are
 * the backstop for a message that was already in flight.
 */
class SyncManager(
    private val scope: CoroutineScope,
    private val history: HistoryStore,
    private val trust: TrustCheck,
    private val fileStore: FileStore,
    /** The entry as its signer signed it, or null if its signature doesn't hold - see [Signing.verified]. */
    private val verify: (ClipboardEntry) -> ClipboardEntry? = { Signing.verified(it) },
    /** An entry with more characters of content than this is dropped on arrival, unread. */
    private val maxEntryContentChars: Int = Limits.MAX_ENTRY_CONTENT_CHARS,
    /** Milliseconds since the epoch - what the request timeouts are counted by. */
    private val clock: () -> Long = System::currentTimeMillis,
) {

    private val connections = ConcurrentHashMap<String, PeerLink>()

    /** Incoming chunk streams, one sender's per file - see [IncomingFiles]. */
    private val incoming = IncomingFiles<PeerLink>(fileStore, sizeHint = ::expectedSizeOf)

    /** See [takeConvenienceSlot]: the time (Unix milliseconds) of the last convenience item applied, and when. */
    private var lastConvenience: Pair<Long, Long>? = null
    private val convenienceLock = Any()

    /** Verified entries waiting on bytes that are still streaming in, keyed by hash. */
    private val pendingEntries = ConcurrentHashMap<String, ClipboardEntry>()

    /**
     * What a history_head did on a connection, until the history_batch it
     * announced arrives (or the connection ends, or [REQUEST_TIMEOUT_MS] pass
     * without it - see [expireRequests]). Made by that connection's own
     * handler, which takes its messages one at a time; a timeout may end it
     * from another thread, so it is only ever taken out of the map, never
     * changed. [groupId] is the provisional group the head made, if it made
     * one, and [since] when it was made.
     */
    private class HeadState(val groupId: Long?, val since: Long)

    private val heads = ConcurrentHashMap<PeerLink, HeadState>()

    /**
     * A history_request sent to a peer and not answered yet. The peer answers
     * in the order it was asked, so a history_batch always belongs to the
     * front of its connection's queue.
     */
    private class Outstanding(
        val keys: List<String>,
        /** The request for the one item that goes on the clipboard when it arrives - see [HistoryStore.Arrival.Sync]. */
        val convenience: Boolean,
        val sentAt: Long,
        /** For the convenience request: how many items the whole sync asked for, the number on its stack. */
        val expectedSize: Int,
    ) {
        /**
         * Given up on after [REQUEST_TIMEOUT_MS] (see [expireRequests]). It stays in the queue as a marker: the
         * peer may still answer it, and that answer has to be paired with it (and stored quietly, see
         * [handleLateAnswer]), or it would be paired with a later request, or find the queue empty and be taken
         * for an older peer's batch. It leaves only with its answer or with the connection, and is no open
         * request for the timeout or for a stack's waiting. Under [syncLock].
         */
        var expired = false
    }

    /** What goes out on a v2 connection, in this order and nothing else in between - see [SyncState.outbox]. */
    private sealed interface Outgoing {
        /** Our history_head, made when its turn comes so that it is up to date. */
        object Head : Outgoing

        /** A message that is ready: a request, a delete. */
        class Ready(val message: String) : Outgoing

        /** The answer to a history_request for [keys]. */
        class Answer(val keys: List<String>) : Outgoing
    }

    /**
     * Everything a v2 connection has going. [queue], [head] and [groupId] are
     * guarded by [syncLock]: the connection's handler, the other connections'
     * (when one ends) and the periodic tick all reach them.
     */
    private class SyncState(val conn: PeerLink) {
        val queue = ArrayDeque<Outstanding>()

        /** The last history_head the peer sent: kept to ask again of someone else, see [askAgain]. */
        var head: SyncHead? = null

        /** The group of the sync under way (the stack its items are shown as), if it has one. */
        var groupId: Long? = null

        /**
         * One coroutine writes this, so that requests, answers and deletes leave in the order they were
         * decided: the peer pairs each history_batch with the request it answers by that order alone, and a
         * big answer must not be overtaken by a small one asked later.
         */
        val outbox = Channel<Outgoing>(Channel.UNLIMITED)

        /** Answers in [outbox] not written yet. */
        val answersQueued = AtomicInteger()
    }

    private val syncStates = ConcurrentHashMap<PeerLink, SyncState>()

    /** Guards every [SyncState]'s fields and [pending]. Never held while calling out to the screen. */
    private val syncLock = Any()

    /** Keys asked for and not answered yet, and of whom - so that nobody else is asked for them. Under [syncLock]. */
    private val pending = HashMap<String, PeerLink>()

    /** How often each file has been asked for again after a transfer of it failed - see [requestAgain]. */
    private val retries = ConcurrentHashMap<String, Int>()

    /**
     * Guards against streaming the same file to the same peer twice at once
     * (key `deviceId:hash`). Broadcasting a fresh file proactively streams it,
     * and the receiving side ALSO broadcasts a file_request the moment it sees
     * an entry whose bytes it lacks. Without this guard the sender starts a
     * second concurrent stream, the two chunk sequences interleave on the
     * wire, and the result fails hash verification at the far end - which is
     * exactly what "file transfer failed hash verification" turned out to be.
     */
    private val streamingInFlight: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf())

    /**
     * A received entry is now to go on the clipboard (a file's: once its
     * bytes are here) - and is reported, whatever it does with the clipboard.
     */
    var onEntryApplied: ((ClipboardEntry) -> Unit)? = null

    /**
     * A live entry was stored without being applied yet: a file's, still
     * arriving. (A history_batch does not use this - see [onBatchApplied].)
     */
    var onHistoryChanged: (() -> Unit)? = null

    /**
     * A history_batch's new entries have just been stored, called once for the
     * whole batch and before anything can read them back: the place to note
     * which entries arrived together. The second argument is the provisional
     * group the batch's history_head made, if there was one: the entries join
     * it. Runs under the history's lock, so it must be quick - see
     * [HistoryStore.addAllNew].
     */
    var onBatchStored: ((List<ClipboardEntry>, Long?) -> Unit)? = null

    /**
     * A history_head's newest entry has just been stored (same rules as
     * [onBatchStored]), and [expectedNew] of the keys in the head are not
     * here yet, that one included. Returns the id of the provisional group
     * to show at once, or null for none.
     */
    var onHeadStored: ((newest: ClipboardEntry, expectedNew: Int) -> Long?)? = null

    /**
     * The batch a head announced has been dealt with, or will never come (the
     * connection ended, another head came first, or it took too long): the
     * provisional group given is not a guess any more. Called for every head
     * that made a group, also when the batch already settled it, so the
     * receiver rebuilds the list only if it still has to. On a v2 connection:
     * the last request of a sync has been answered, or has been given up.
     */
    var onHeadSettled: ((Long) -> Unit)? = null

    /**
     * Entries of one live item have just been stored - arrived on their own
     * as an "entry", or this device's own copy or share: each a block of one.
     * Same rules as [onBatchStored].
     */
    var onLiveStored: ((List<ClipboardEntry>) -> Unit)? = null

    /**
     * The answer to a v2 history_request has just been stored (same rules as
     * [onBatchStored]). Returns the id of the group the sync's items are
     * shown in, if it has one - given back with the next answer of that sync.
     */
    var onSyncStored: ((SyncStored) -> Long?)? = null

    /**
     * A history_batch was applied as one unit - the one place a batch is
     * announced, however many entries it added. Not called for a batch that
     * added nothing.
     */
    var onBatchApplied: ((BatchApplied) -> Unit)? = null

    /**
     * A file's bytes arrived that no newly received entry was waiting on -
     * an older item's, asked for again (see [requestMissingFiles]). Its item
     * can stop saying it's still transferring.
     */
    var onFileStored: ((String) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null
    var onConnectionsChanged: ((Int) -> Unit)? = null

    /** A registered connection's first envelope decrypted - see [PeerConnection.onSessionProven]. */
    var onSessionProven: ((PeerLink) -> Unit)? = null

    /** A registered connection ended - the live one for its peer or a stale one. */
    var onConnectionClosed: ((PeerLink) -> Unit)? = null

    /**
     * A trusted peer said it no longer trusts this device (it was removed there,
     * or its request was ignored there). The argument is the peer's id; the engine
     * drops its trust record here too, so the peer stops being redialled and
     * stops asking. See [handleMessage].
     */
    var onUnpaired: ((String) -> Unit)? = null

    val connectionCount: Int get() = connections.size

    /**
     * Connections whose peer has answered - its first line decrypted, which it only
     * sends once it accepted this device. A trusting device that dials one that has
     * not accepted yet is linked, but the peer may still be asking its user: that is
     * not "connected" for anyone looking at the Devices tab.
     */
    val provenCount: Int get() = connections.values.count { it.isSessionProven }

    fun provenDeviceIds(): Set<String> = connections.filterValues { it.isSessionProven }.keys.toSet()

    fun connectedDeviceIds(): Set<String> = connections.keys.toSet()

    fun isConnected(deviceId: String): Boolean = connections.containsKey(deviceId)

    /** The live connections whose peers are still trusted - the only ones anything is sent to. */
    private fun trustedConnections(): List<PeerLink> =
        connections.values.filter { trust.isTrusted(it.peerDeviceId) }

    /**
     * Wires a freshly handshaken connection into ongoing sync: registers it,
     * starts listening, and sends our history.
     *
     * Registration happens FIRST, before any logging or trust-store write the
     * caller might do. Those are conveniences; starting the read loop is not.
     * Doing them in the other order means one thrown exception leaves the link
     * unregistered and unlistened - isConnected stays false, the peer redials
     * every two seconds forever, and no clipboard data ever moves.
     */
    fun registerConnection(conn: PeerLink) {
        // One coroutine handles this connection's messages, one at a time and
        // in the order they arrived. A coroutine per message, as this used to
        // be, let a file's chunks overtake each other on their way to the
        // disk - and the file then failed its hash check.
        //
        // The inbox is small, and the read loop waits when it is full: a
        // handler that is slower than the network (two JSON parses, a base64
        // decode and a disk write per 256 KB chunk) then slows the sender
        // through TCP, where an unbounded queue used to hold however much of
        // a 1 GB file the phone could be sent before it ran out of memory.
        val inbox = Channel<String>(Limits.INBOX_CAPACITY)
        // Before anything can be read: the peer's head may be the first line.
        val sync = if (conn.isV2) SyncState(conn).also { syncStates[conn] = it } else null
        if (sync != null) scope.launch { writeOutbox(sync) }
        conn.onMessage = { message ->
            try {
                inbox.send(message)
            } catch (e: ClosedSendChannelException) {
                // The link is ending; whatever was in flight goes with it.
            }
        }
        scope.launch { handleInOrder(inbox, conn) }
        // Off the read loop - what comes of it is a trust-store write.
        conn.onSessionProven = { scope.launch(Dispatchers.IO) { onSessionProven?.invoke(conn) } }
        conn.onDisconnected = {
            // Whatever it delivered before it went is still handled.
            inbox.close()
            onConnectionClosed?.invoke(conn)
            // Evict only if the map still points at THIS connection. Removing
            // by device id alone meant a stale link's teardown deleted the
            // newer live connection that had replaced it - after which
            // isConnected said false, the next beacon dialled again, and the
            // whole thing looped without clipboard ever flowing. The Windows
            // daemon carries the identical guard; both ends need it, or the
            // other end's churn keeps the loop alive.
            if (connections.remove(conn.peerDeviceId, conn)) {
                onConnectionsChanged?.invoke(connections.size)
                val why = conn.closeReason?.let { " ($it)" }.orEmpty()
                onLog?.invoke("peer disconnected: ${shortIdOf(conn.peerDeviceId)}$why")
            }
        }
        (conn as? PeerConnection)?.onDropped = { note ->
            onLog?.invoke("$note from ${shortIdOf(conn.peerDeviceId)}")
        }
        conn.listen()

        // The window between the handshake completing and this method wiring
        // onDisconnected is small but real - a peer that vanishes inside it
        // fired its disconnect against a null callback, and onDisconnected
        // will never fire now that it's wired (PeerConnection.finish() is
        // idempotent). This connection is simply dead - bail out before
        // touching the map at all, so whatever was already registered for
        // this peer (if anything) is left exactly as it was.
        if (conn.isClosed) {
            inbox.close()
            return
        }

        val previous = connections.put(conn.peerDeviceId, conn)
        onConnectionsChanged?.invoke(connections.size)
        scope.launch {
            // v2: the head alone, the peer asks for what it lacks. Older: the whole history.
            if (sync != null) sync.outbox.trySend(Outgoing.Head) else sendHistoryBatch(conn)
            requestMissingFiles(conn)
        }

        if (previous != null && previous !== conn) {
            // A second connection to this same peer just replaced the first
            // one in the map. connectingTo already stops THIS device from
            // dialling the same peer twice at once (see ClipLinkEngine's
            // maybeAutoConnect/reconnectOffLanPeers), but it has no say over
            // the PEER dialling twice, or over acceptConnection taking a
            // second incoming socket from a peer this device is already
            // connected to - the TCP accept loop takes every connection
            // unconditionally, and only identifies which peer it was after
            // the handshake finishes.
            //
            // Without this, `previous` was left alive as an orphan: its own
            // read loop and heartbeat kept running even though nothing sent
            // on it anymore, and this device's own map already points at
            // the new connection - but the peer on the other end of that
            // orphaned socket has no idea it's been superseded, and may
            // still consider IT the canonical connection. That split-brain
            // (each side treating a different one of the duplicate sockets
            // as "the" connection) is what caused a peer's connected status
            // to disagree with whether sync was actually working, and
            // connections appearing to drop later - once whichever side's
            // orphan eventually noticed the other end had stopped using it.
            // Closing it here immediately, instead of waiting for its own
            // heartbeat to notice, means there is only ever one live socket
            // per peer on this end.
            previous.close("replaced by a newer connection")
        }
    }

    /**
     * Ends [deviceId]'s link, if it has one - for a device that has just been
     * removed: it must not keep receiving what is copied, asking for files
     * or showing as connected.
     */
    fun close(deviceId: String, reason: String = "removed") {
        connections[deviceId]?.close(reason)
    }

    /**
     * Tells [deviceId] it is no longer trusted here, then ends its link - for a
     * device that has just been removed. The peer drops this device too and stops
     * redialling (its [onUnpaired]). Best effort: a peer that is gone, or a build
     * that does not know the message, is left to the engine's RequestQuiet.
     */
    fun unpair(deviceId: String) {
        val conn = connections[deviceId] ?: return
        scope.launch { unpairAndClose(conn, "removed") }
    }

    /** [unpair] for a link that is not registered, such as a pairing request that is being ignored. */
    suspend fun unpairAndClose(conn: PeerLink, reason: String) {
        runCatching { conn.send(Protocol.envelope(Protocol.TYPE_UNPAIR, "{}")) }
        delay(UNPAIR_FLUSH_MS) // let it leave before the socket goes
        conn.close(reason)
    }

    fun closeAll() {
        connections.values.toList().forEach { it.close("closed locally") }
        connections.clear()
        onConnectionsChanged?.invoke(0)
    }

    /** Periodic housekeeping: gives up on file streams and requests that have gone quiet. */
    fun tidyTransfers() {
        val stale = incoming.dropStale()
        if (stale.isNotEmpty()) onLog?.invoke("${stale.size} stalled file transfer(s) abandoned")
        expireRequests()
    }

    /** [registerConnection]'s consumer: [conn]'s messages, in order, until it closes and they're all handled. */
    private suspend fun handleInOrder(inbox: Channel<String>, conn: PeerLink) {
        try {
            for (message in inbox) {
                try {
                    handleMessage(message, conn)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    // One bad message mustn't stop the ones after it - nor
                    // take the app with it, whatever it threw.
                    onLog?.invoke("couldn't handle a message from ${shortIdOf(conn.peerDeviceId)} ($e)")
                }
            }
        } finally {
            // Only now: the last chunks of a file it finished sending may
            // still have been queued when the link went.
            abandonTransfersFrom(conn)
            // A head whose batch never came: its stack is what it is.
            heads.remove(conn)?.settle()
            endSync(conn)
        }
    }

    /**
     * The files [conn] was still sending can't be resumed, only started
     * over - by another peer that has them, or by this one once it's back
     * (see [requestMissingFiles]).
     */
    private fun abandonTransfersFrom(conn: PeerLink) {
        val abandoned = incoming.abandonAll(conn)
        if (abandoned.isEmpty()) return
        onLog?.invoke("${abandoned.size} file transfer(s) from ${shortIdOf(conn.peerDeviceId)} broke off")
        val others = connections.values.filter { it !== conn }
        abandoned.forEach { requestAgain(it, others) }
    }

    private suspend fun sendHistoryBatch(conn: PeerLink) {
        if (!trust.isTrusted(conn.peerDeviceId)) return
        val selection = selectForRelay(history.all())
        if (selection.skipped > 0) {
            onLog?.invoke("${selection.skipped} large item(s) left out of the history sent to ${shortIdOf(conn.peerDeviceId)}")
        }
        // The newest first and on its own: the batch can be megabytes, and the
        // peer can show the stack from this while it is still arriving. One
        // entry needs no head, the batch is as small as the head would be.
        if (selection.entries.size >= GROUP_MIN_ITEMS) {
            HistoryHead.forBatch(selection.entries)?.let { head ->
                runCatching { conn.send(Protocol.envelope(Protocol.TYPE_HISTORY_HEAD, head.toJson())) }
            }
        }
        runCatching {
            conn.send(
                Protocol.envelope(
                    Protocol.TYPE_HISTORY_BATCH,
                    ClipboardEntry.listToJson(selection.entries).toString(),
                ),
            )
        }
    }

    // ---- v2: head, request, answer, delete -------------------------------------

    /** [state]'s connection's writer: everything for a v2 peer leaves through here, in the order it was queued. */
    private suspend fun writeOutbox(state: SyncState) {
        for (item in state.outbox) {
            val conn = state.conn
            if (item is Outgoing.Answer) state.answersQueued.decrementAndGet()
            if (!trust.isTrusted(conn.peerDeviceId)) continue
            val message = when (item) {
                Outgoing.Head -> Protocol.envelope(
                    Protocol.TYPE_HISTORY_HEAD,
                    SyncHead.forHistory(history.all(), history.recentDeletedKeys(Protocol.MAX_HEAD_DELETED)).toJson(),
                )
                is Outgoing.Ready -> item.message
                is Outgoing.Answer -> answerFor(item.keys, conn)
            }
            try {
                conn.send(message)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // The link ended; its read loop says so.
            }
        }
    }

    /**
     * The one history_batch that answers a history_request for [keys]: the entries this device has for them,
     * newest first, none for a key it no longer has - an empty list when it has none, so the asker stops
     * waiting. Limited like the batch of an older connection (see [selectForRelay]).
     */
    private fun answerFor(keys: List<String>, conn: PeerLink): String {
        val wanted = keys.toHashSet()
        val newestFirst = history.all()
            .filter { it.deletionKey in wanted }
            .sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
        val selection = selectForRelay(newestFirst)
        if (selection.skipped > 0) {
            onLog?.invoke("${selection.skipped} large item(s) left out of the answer sent to ${shortIdOf(conn.peerDeviceId)}")
        }
        return Protocol.envelope(Protocol.TYPE_HISTORY_BATCH, ClipboardEntry.listToJson(selection.entries).toString())
    }

    /** Deletes [entry] on this device for good (see [HistoryStore.delete]) and tells the v2 peers to do the same. */
    fun deleteEntry(entry: ClipboardEntry) {
        history.delete(entry)
        broadcastDelete(listOf(entry.deletionKey))
    }

    /** [deleteEntry] for everything in the history. */
    fun clearHistory() {
        broadcastDelete(history.clear())
    }

    /**
     * Tells every connected v2 peer that these items were deleted on this device (one the user deleted, or all
     * of them). Older peers get nothing: they keep their copy, and ours stays out of this history all the same.
     * Nothing received from a peer is sent on this way - the heads carry that to whoever was away.
     */
    fun broadcastDelete(keys: List<String>) {
        val batches = keys.distinct().chunked(Protocol.MAX_REQUEST_KEYS)
        if (batches.isEmpty()) return
        for (conn in trustedConnections()) {
            val state = syncStates[conn] ?: continue
            for (batch in batches) {
                state.outbox.trySend(Outgoing.Ready(Protocol.envelope(Protocol.TYPE_DELETE, KeyListMessage(batch).toJson())))
            }
        }
    }

    /** A v2 history_head: what the peer deleted goes first, then what it has that we lack is asked for. */
    private fun handleSyncHead(payload: String, conn: PeerLink) {
        val state = syncStates[conn] ?: return
        val head = SyncHead.parse(payload) ?: run {
            onLog?.invoke("received invalid message from peer (bad history_head JSON)")
            return
        }
        applyPeerDeletes(head.deleted)
        synchronized(syncLock) {
            state.head = head
            ask(state, convenienceOwed = true)
        }
    }

    /** The peer deleted [keys]: the same as a delete here, and one update of the list for all of them. */
    private fun applyPeerDeletes(keys: List<String>) {
        if (history.applyDeleted(keys).isNotEmpty()) onHistoryChanged?.invoke()
    }

    /**
     * Asks [state]'s peer for what its last head lists and this device lacks (and has not asked someone else
     * for): the newest of those first and alone, which will go on the clipboard, then the rest in one request.
     * With [convenienceOwed] false there is no such item to wait for (it came already from a peer that went
     * away), and what is wanted goes in a single request that applies nothing. Under [syncLock].
     */
    private fun ask(state: SyncState, convenienceOwed: Boolean): Boolean {
        val head = state.head ?: return false
        val local = history.all()
        val have = local.mapTo(HashSet()) { it.deletionKey }
        val missing = head.keys.distinct().filter { it !in have && !history.isKeyDeleted(it) && it !in pending }
        val wanted = wantedKeys(missing, head, local)
        if (wanted.isEmpty()) return false
        val now = clock()
        val requests = if (convenienceOwed) {
            listOfNotNull(
                Outstanding(listOf(wanted.first()), convenience = true, sentAt = now, expectedSize = wanted.size),
                wanted.drop(1).takeIf { it.isNotEmpty() }?.let { Outstanding(it, convenience = false, sentAt = now, expectedSize = 0) },
            )
        } else {
            listOf(Outstanding(wanted, convenience = false, sentAt = now, expectedSize = 0))
        }
        for (request in requests) {
            state.queue.addLast(request)
            request.keys.forEach { pending[it] = state.conn }
            state.outbox.trySend(Outgoing.Ready(Protocol.envelope(Protocol.TYPE_HISTORY_REQUEST, KeyListMessage(request.keys).toJson())))
        }
        onLog?.invoke("asked ${shortIdOf(state.conn.peerDeviceId)} for ${wanted.size} item(s)")
        return true
    }

    /** The history_request [peer] sent: answered in its turn, with one history_batch. */
    private fun handleHistoryRequest(payload: String, conn: PeerLink) {
        val state = syncStates[conn] ?: return
        val request = KeyListMessage.parse(payload) ?: run {
            onLog?.invoke("received invalid message from peer (bad history_request JSON)")
            return
        }
        if (state.answersQueued.incrementAndGet() > MAX_QUEUED_ANSWERS) {
            conn.close("too many requests")
            return
        }
        state.outbox.trySend(Outgoing.Answer(request.keys))
    }

    /** The peer deleted these items and says so: gone here too, tombstoned, and the clipboard left alone. */
    private fun handleDelete(payload: String) {
        val message = KeyListMessage.parse(payload) ?: run {
            onLog?.invoke("received invalid message from peer (bad delete JSON)")
            return
        }
        applyPeerDeletes(message.keys)
    }

    /**
     * Takes the request that a history_batch just arrived for, off the front of [conn]'s queue; null when it
     * has none (the batch was not asked for, and is dealt with as an older peer's). Its keys stay pending
     * until the answer is stored: in between they are neither here nor on their way, and another peer's head
     * would have them asked for again.
     */
    private fun takeOutstanding(conn: PeerLink): Outstanding? = synchronized(syncLock) {
        val state = syncStates[conn] ?: return null
        state.queue.removeFirstOrNull()
    }

    /**
     * The answer to [request]: every entry in it is checked like any other, and the new ones are stored in
     * one go. If it was the request for the convenience item, the newest new entry is that item and goes on
     * the clipboard - once, with the usual side effects; every other answer applies nothing to the
     * clipboard, though a file's bytes are still asked for.
     */
    private fun handleSyncAnswer(payload: String, conn: PeerLink, request: Outstanding) {
        try {
            val verified = verifiedBatch(payload) ?: return
            val state = syncStates[conn] ?: return
            val groupBefore = synchronized(syncLock) { state.groupId }
            val arrival = when {
                request.convenience -> Arrival.Sync
                groupBefore != null -> Arrival.SyncMore
                // Nothing of this sync is on the clipboard: its items are a block of their own.
                else -> Arrival.Live
            }
            var group: Long? = groupBefore
            var told = false
            // The convenience item as the store sees it (the newest of the new ones, before the trim), and
            // whether it may go on the clipboard: only that one is spared by the trim.
            var candidate: ClipboardEntry? = null
            var mayApply = false
            val protectFront: ((ClipboardEntry) -> Boolean)? = if (request.convenience) {
                { entry -> candidate = entry; mayApply = takeConvenienceSlot(entry); mayApply }
            } else {
                null
            }
            val fresh = history.addAllNew(verified, arrival, protectFront) { stored ->
                val front = if (request.convenience) newestOf(stored) else null
                group = onSyncStored?.invoke(SyncStored(stored, front, groupBefore, request.expectedSize))
                told = true
            }
            if (told) synchronized(syncLock) { state.groupId = group }
            if (fresh.isEmpty()) return

            // Not the newest of what is left when the convenience item itself is gone (trimmed, or it did not
            // get the slot): nothing else takes its place on the clipboard.
            val convenience = candidate?.takeIf { mayApply && fresh.any { f -> f === it } }
            var toApply: ClipboardEntry? = null
            for (entry in fresh) {
                if (entry === convenience) {
                    if (startApplying(entry)) toApply = entry
                } else {
                    fetchWithoutApplying(entry)
                }
            }
            onBatchApplied?.invoke(BatchApplied(conn.peerDeviceId, fresh, toApply))
        } finally {
            synchronized(syncLock) { request.keys.forEach { if (pending[it] === conn) pending.remove(it) } }
            settleIfAnswered(conn)
        }
    }

    /**
     * The answer to a request that was given up on (see [Outstanding.expired]), which came after all. Its
     * entries are checked like any other and the new ones stored, but nothing is put on the clipboard, nobody
     * is told, and they make no stack: the sync they belonged to is long over. A file's bytes are still asked
     * for. [Arrival.SyncMore] leaves the item the trim spares as it is - this is not a block of its own.
     */
    private fun handleLateAnswer(payload: String, conn: PeerLink) {
        val verified = verifiedBatch(payload) ?: return
        val fresh = history.addAllNew(verified, Arrival.SyncMore)
        if (fresh.isEmpty()) return
        fresh.forEach(::fetchWithoutApplying)
        onBatchApplied?.invoke(BatchApplied(conn.peerDeviceId, fresh, null))
    }

    /**
     * Whether [candidate], the convenience item of an answer, may go on the clipboard now. Not when another
     * convenience item went there less than [CONVENIENCE_WINDOW_MS] ago and this one is not newer: two peers
     * answering at once each bring their newest missing item, and the clipboard changes once. Otherwise it
     * may, and it becomes the item the next one is compared with. Memory only, and for the whole engine, not
     * for a connection. Has a lock of its own: it is called under the history's, and must not wait for [syncLock].
     */
    private fun takeConvenienceSlot(candidate: ClipboardEntry): Boolean = synchronized(convenienceLock) {
        val now = clock()
        // Instants, not text: the same time in two formats is equal, and equal is not newer. No zone counts as UTC.
        val timestamp = DotNetTimestamp.epochMillis(candidate.timestamp) ?: Long.MIN_VALUE
        val last = lastConvenience
        if (last != null && now - last.second < CONVENIENCE_WINDOW_MS && timestamp <= last.first) return false
        lastConvenience = timestamp to now
        true
    }

    /** The last request of [conn]'s sync has been answered: the size of its stack is final. */
    private fun settleIfAnswered(conn: PeerLink) {
        val settled = synchronized(syncLock) {
            val state = syncStates[conn] ?: return
            if (state.queue.any { !it.expired }) return
            state.groupId.also { state.groupId = null }
        }
        settled?.let { onHeadSettled?.invoke(it) }
    }

    /**
     * [conn] has ended and its last messages are handled. What it was asked for and never sent is asked of
     * the other v2 peers from the heads they last sent (a transfer that broke off is not lost), and the
     * stack its sync was building is final.
     */
    private fun endSync(conn: PeerLink) {
        val settled: Long?
        synchronized(syncLock) {
            val state = syncStates.remove(conn) ?: return
            state.outbox.close()
            settled = state.groupId
            askAgain(excluding = conn, convenienceOwed = state.queue.any { it.convenience && !it.expired })
            state.queue.clear()
        }
        settled?.let { onHeadSettled?.invoke(it) }
    }

    /**
     * Asks every other live v2 peer again for what its last head lists and nobody is bringing now. The first
     * to be asked takes the keys; the item for the clipboard is asked as such only when a connection that
     * never delivered it was the one that went (it is not applied twice, nor in place of a newer one).
     * Under [syncLock].
     */
    private fun askAgain(excluding: PeerLink, convenienceOwed: Boolean) {
        // The keys of the connection that went are free again before anyone is asked.
        pending.values.removeAll { it === excluding }
        var owed = convenienceOwed
        for (state in syncStates.values) {
            if (state.conn === excluding || state.conn.isClosed) continue
            if (ask(state, owed)) owed = false
        }
    }

    /**
     * Gives up on every request that has gone unanswered for [REQUEST_TIMEOUT_MS] (no retry on the same
     * connection - the next one does the work), and on a v1.5 head whose batch never came. A stack that was
     * waiting for them stops waiting. A request given up on stays in its queue as an expired marker, so that
     * its answer, if it comes after all, is paired with it (see [Outstanding.expired]).
     */
    fun expireRequests(now: Long = clock()) {
        val settled = ArrayList<Long>()
        synchronized(syncLock) {
            for (state in syncStates.values) {
                var dropped = 0
                for (request in state.queue) {
                    if (request.expired || now - request.sentAt < REQUEST_TIMEOUT_MS) continue
                    request.expired = true
                    request.keys.forEach { if (pending[it] === state.conn) pending.remove(it) }
                    dropped++
                }
                if (dropped == 0) continue
                onLog?.invoke("gave up waiting for $dropped answer(s) from ${shortIdOf(state.conn.peerDeviceId)}")
                if (state.queue.any { !it.expired }) continue
                state.groupId?.let { settled.add(it) }
                state.groupId = null
            }
        }
        settled.forEach { onHeadSettled?.invoke(it) }
        for ((conn, head) in heads) {
            if (now - head.since >= REQUEST_TIMEOUT_MS && heads.remove(conn, head)) head.settle()
        }
    }

    /**
     * Sends to every connected peer and records locally. For file entries the
     * caller must have cached the bytes into [FileStore] under the hash first;
     * this then proactively streams them rather than waiting to be asked,
     * matching the daemon's own ClipboardChanged handling.
     */
    suspend fun broadcastEntry(entry: ClipboardEntry) = broadcastEntries(listOf(entry))

    /** [broadcastEntry] for several at once, recorded in one go - see [HistoryStore.addAll]. */
    suspend fun broadcastEntries(entries: List<ClipboardEntry>) {
        val peers = trustedConnections()
        for (entry in entries) {
            val json = Protocol.envelope(Protocol.TYPE_ENTRY, entry.toJson().toString())
            peers.forEach { conn ->
                scope.launch { runCatching { conn.send(json) } }
            }
        }
        history.addAllNew(entries, Arrival.Live) { stored -> onLiveStored?.invoke(stored) }

        for (entry in entries) {
            if (entry.type != ClipboardEntry.TYPE_FILE) continue
            val payload = FilePayload.parse(entry.content) ?: continue
            if (!fileStore.exists(payload.fileHash)) continue
            peers.forEach { conn ->
                scope.launch { streamFileToPeer(conn, fileStore.path(payload.fileHash), payload.fileHash) }
            }
        }
    }

    /**
     * The entry as its signer signed it, or null if the signature or trust
     * check fails. Store and apply what this returns, not what arrived - see
     * [Signing.verified].
     */
    private fun verifiedAndTrusted(entry: ClipboardEntry): ClipboardEntry? =
        verify(entry)?.takeIf { trust.isTrusted(it.deviceId) }

    private suspend fun handleMessage(message: String, conn: PeerLink) {
        // Backstop for a message already in flight when its sender was
        // removed: a device that isn't trusted any more is nobody to answer.
        if (!trust.isTrusted(conn.peerDeviceId)) {
            onLog?.invoke("dropped a message from ${shortIdOf(conn.peerDeviceId)} - not a trusted device any more")
            conn.close("no longer trusted")
            return
        }
        val envelope = Envelope.parse(message) ?: run {
            onLog?.invoke("received invalid message from peer (bad JSON)")
            return
        }
        when (envelope.type) {
            Protocol.TYPE_ENTRY -> {
                val received = parseEntry(envelope.payload) ?: return
                if (received.content.length > maxEntryContentChars) {
                    onLog?.invoke("dropped a ${received.type} entry from ${shortIdOf(received.deviceId)} - too large")
                    return
                }
                val entry = verifiedAndTrusted(received) ?: run {
                    onLog?.invoke(
                        "dropped ${received.type} entry from ${shortIdOf(received.deviceId)} " +
                            "- failed signature/trust check",
                    )
                    return
                }
                // Empty for anything deleted on this device, and for an entry
                // so old that it was stored only to be evicted at once, so a
                // deleted or ancient item is neither stored nor applied.
                if (history.addAllNew(listOf(entry), Arrival.Live) { stored -> onLiveStored?.invoke(stored) }.isEmpty()) return
                applyAndReport(entry)
            }

            // On a v2 connection the head is the keys and tombstones of the peer's history, and a
            // `Newest` in it is not read. On an older one it is the newest entry and the keys.
            Protocol.TYPE_HISTORY_HEAD ->
                if (conn.isV2) handleSyncHead(envelope.payload, conn) else handleHistoryHead(envelope.payload, conn)

            Protocol.TYPE_HISTORY_BATCH -> {
                // On a v2 connection a batch answers a request - and one that nobody asked for is an older peer's.
                val request = if (conn.isV2) takeOutstanding(conn) else null
                if (request != null) {
                    // Too late: its stack has stopped waiting and minutes may have passed, so what it brings is
                    // stored like any quiet add and never put on the clipboard.
                    if (request.expired) handleLateAnswer(envelope.payload, conn)
                    else handleSyncAnswer(envelope.payload, conn, request)
                } else {
                    val head = heads.remove(conn)
                    try {
                        handleHistoryBatch(envelope.payload, conn.peerDeviceId, head)
                    } finally {
                        // Normally settled already, by the batch being stored.
                        head?.settle()
                    }
                }
            }

            Protocol.TYPE_HISTORY_REQUEST ->
                if (conn.isV2) handleHistoryRequest(envelope.payload, conn) else logUnknownType(envelope.type)

            Protocol.TYPE_DELETE -> if (conn.isV2) handleDelete(envelope.payload) else logUnknownType(envelope.type)

            // Every FileHash below has passed FileStore.isValidHash - the
            // parsers refuse anything else - so a peer can only ever name a
            // blob in the FileStore, never a path to one of this app's files.
            Protocol.TYPE_FILE_CHUNK -> handleFileChunk(envelope.payload, conn)

            Protocol.TYPE_FILE_REQUEST -> {
                val request = FileRequestMessage.parse(envelope.payload) ?: return
                if (fileStore.exists(request.fileHash)) {
                    // On its own coroutine: this peer's messages are handled
                    // in order, and none should wait for a whole file to go.
                    scope.launch { streamFileToPeer(conn, fileStore.path(request.fileHash), request.fileHash) }
                }
                // If we don't have it either, stay silent - the requester
                // broadcast to everyone, someone else may have it.
            }

            Protocol.TYPE_UNPAIR -> {
                // The peer removed this device, or ignored its request: it no longer
                // trusts it. Dropping it here too ends its redialling - trust on one
                // side only never became a pairing, and only ever produced a request
                // at the other end. Only a peer can say this about itself: the message
                // came over its proven session, and all it changes is whether this
                // device trusts it.
                onUnpaired?.invoke(conn.peerDeviceId)
                conn.close("it removed this device")
            }

            else -> logUnknownType(envelope.type)
        }
    }

    private fun logUnknownType(type: String) {
        onLog?.invoke("received message with unknown type from peer: $type")
    }

    /** The head made a provisional group: it is final now, whatever came of the batch. */
    private fun HeadState.settle() {
        groupId?.let { onHeadSettled?.invoke(it) }
    }

    /**
     * The newest entry of the history_batch that follows, and how many new
     * ones it will bring. Checked like an "entry" message; one that fails is
     * ignored whole and the batch then works on its own. The newest is stored
     * and applied now (and so not again by the batch); when the head counts
     * two or more new, the receiver is told to show a stack right away.
     */
    private fun handleHistoryHead(payload: String, conn: PeerLink) {
        // A second head: the first one's batch is not coming.
        heads.remove(conn)?.settle()
        val head = HistoryHead.parse(payload) ?: run {
            onLog?.invoke("received invalid message from peer (bad history_head JSON)")
            return
        }
        val received = head.newest
        if (received.content.length > maxEntryContentChars) {
            onLog?.invoke("dropped a history head from ${shortIdOf(received.deviceId)} - too large")
            return
        }
        val newest = verifiedAndTrusted(received) ?: run {
            onLog?.invoke("dropped a history head from ${shortIdOf(received.deviceId)} - failed signature/trust check")
            return
        }
        val expectedNew = history.countNew(head.keys)
        var groupId: Long? = null
        // Empty for an entry that is known, deleted here or older than all a full history keeps.
        val stored = history.addAllNew(listOf(newest), Arrival.SyncByAge) { groupId = onHeadStored?.invoke(newest, expectedNew) }
        if (stored.isEmpty()) return
        heads[conn] = HeadState(groupId, clock())
        applyAndReport(newest)
    }

    /**
     * The entries of a history_batch payload that are small enough and whose signature and signer hold - one
     * that fails is skipped and the rest kept - or null when the payload is not a list of entries.
     */
    private fun verifiedBatch(payload: String): List<ClipboardEntry>? {
        val entries = untrusted { ClipboardEntry.listFromJson(JSONArray(payload)) } ?: run {
            onLog?.invoke("received invalid message from peer (bad history_batch JSON)")
            return null
        }
        var tooLarge = 0
        val verified = ArrayList<ClipboardEntry>(entries.size)
        for (received in entries) {
            if (received.content.length > maxEntryContentChars) {
                tooLarge++
                continue
            }
            // Skip just the bad entry, keep processing the rest of the batch.
            verifiedAndTrusted(received)?.let(verified::add)
        }
        if (tooLarge > 0) onLog?.invoke("dropped $tooLarge entr${if (tooLarge == 1) "y" else "ies"} in a history batch - too large")
        return verified
    }

    private fun handleHistoryBatch(payload: String, from: String, head: HeadState?) {
        val verified = verifiedBatch(payload) ?: return

        // Stored as a whole and trimmed once. What comes back is the entries
        // that are new AND still there after the trim (the peer still has
        // everything deleted here - those, and any older than all this
        // device keeps, are neither stored nor applied). The newest of them
        // is the one the trim spares - after a head, the head's.
        val arrival = if (head != null) Arrival.SyncMore else Arrival.SyncByAge
        val fresh = history.addAllNew(verified, arrival) { stored -> onBatchStored?.invoke(stored, head?.groupId) }
        if (fresh.isEmpty()) return

        // A batch is the peer's whole history, oldest and newest alike. Only
        // the newest of what is new belongs on the clipboard - even when this
        // device has newer items of its own: applying them in batch order
        // left whichever came last there, not the latest copy.
        // After a head the newest is on it already, and the rest is older.
        val newest = if (head != null) null else newestOf(fresh)
        var toApply: ClipboardEntry? = null
        for (entry in fresh) {
            if (entry === newest) {
                if (startApplying(entry)) toApply = entry
            } else {
                fetchWithoutApplying(entry)
            }
        }
        // Once, last: the screen hears of the whole batch in one go, not of
        // each entry as it is dealt with.
        onBatchApplied?.invoke(BatchApplied(from, fresh, toApply))
    }

    private fun parseEntry(payload: String): ClipboardEntry? =
        untrusted { ClipboardEntry.fromJson(org.json.JSONObject(payload)) } ?: run {
            onLog?.invoke("received invalid message from peer (bad entry JSON)")
            null
        }

    private fun applyAndReport(entry: ClipboardEntry) {
        if (entry.type == ClipboardEntry.TYPE_FILE) {
            handleIncomingFileEntry(entry)
            return
        }
        onEntryApplied?.invoke(entry)
    }

    /**
     * A live file entry: apply right away if the bytes are here, otherwise the
     * item is shown at once, saying it is still transferring, and is applied
     * when they have arrived (see [startApplying]).
     */
    private fun handleIncomingFileEntry(entry: ClipboardEntry) {
        if (startApplying(entry)) {
            onEntryApplied?.invoke(entry)
        } else {
            // So the item is there, saying it is still transferring.
            onHistoryChanged?.invoke()
        }
    }

    /**
     * Gets [entry] ready to go on the clipboard and says whether it can go
     * now. Anything but a file can. A file can if these exact bytes are
     * already cached; otherwise it is remembered, to be applied once the
     * chunks finish arriving and verifying, and EVERY connected peer - not
     * just whoever handed us the entry - is asked whether it has them.
     * Tells nobody about the history: that is the caller's to do, once.
     */
    private fun startApplying(entry: ClipboardEntry): Boolean {
        if (entry.type != ClipboardEntry.TYPE_FILE) return true
        val payload = FilePayload.parse(entry.content) ?: run {
            onLog?.invoke("received malformed file entry from peer")
            return false
        }
        if (payload.isEmptyFile) {
            // Nothing to wait for, and nothing would come: most builds send
            // no chunk at all for a 0-byte file.
            try {
                fileStore.storeEmpty(payload.fileHash)
            } catch (e: Exception) {
                onLog?.invoke("couldn't store an empty file ($e)")
            }
        }
        if (fileStore.exists(payload.fileHash)) return true
        pendingEntries[payload.fileHash] = entry
        sendFileRequest(payload.fileHash, trustedConnections())
        return false
    }

    /**
     * An entry that was new but isn't the newest of its batch: it is in the
     * history already and stays off the clipboard, but a file's bytes are
     * still wanted, so the item can be opened.
     */
    private fun fetchWithoutApplying(entry: ClipboardEntry) {
        if (entry.type != ClipboardEntry.TYPE_FILE) return
        val payload = FilePayload.parse(entry.content) ?: return
        if (payload.isEmptyFile) runCatching { fileStore.storeEmpty(payload.fileHash) }
        if (fileStore.exists(payload.fileHash) || incoming.isReceiving(payload.fileHash)) return
        sendFileRequest(payload.fileHash, trustedConnections())
    }

    private fun sendFileRequest(fileHash: String, to: Collection<PeerLink>) {
        val json = Protocol.envelope(Protocol.TYPE_FILE_REQUEST, FileRequestMessage(fileHash).toJson())
        to.filter { trust.isTrusted(it.peerDeviceId) }
            .forEach { conn -> scope.launch { runCatching { conn.send(json) } } }
    }

    /**
     * Asks a peer that just connected for every file this device is still
     * missing: a newly received item's that broke off or failed, and any
     * older item's whose bytes never came - the app killed mid-transfer, say.
     * Nothing else would ever ask for them again, and the item would say
     * "Transferring…" until it was evicted.
     */
    private fun requestMissingFiles(conn: PeerLink) {
        (pendingEntries.filterValues { !history.isDeleted(it) }.keys + missingFiles())
            .filter { !fileStore.exists(it) && !incoming.isReceiving(it) }
            .forEach { sendFileRequest(it, listOf(conn)) }
    }

    /** Whether an item still waits on [fileHash]'s bytes - one just received, or an older one (see [missingFiles]). */
    private fun isWanted(fileHash: String): Boolean =
        pendingEntries[fileHash]?.let { !history.isDeleted(it) } == true || fileHash in missingFiles()

    /**
     * The files history entries point at whose bytes aren't here. A 0-byte
     * one is never missing - see [FileStore.storeEmpty].
     */
    private fun missingFiles(): Set<String> = history.all().mapNotNullTo(HashSet()) { entry ->
        if (entry.type != ClipboardEntry.TYPE_FILE) return@mapNotNullTo null
        FilePayload.parse(entry.content)
            ?.takeIf { !it.isEmptyFile && !fileStore.exists(it.fileHash) }
            ?.fileHash
    }

    /**
     * How big the signed entry says [fileHash] is, when a stream of it starts
     * - the pending entry's, or any history entry's - or null if none says. A
     * size of 0 for anything but the empty file means the descriptor didn't
     * say, not that the file is empty.
     */
    private fun expectedSizeOf(fileHash: String): Long? {
        val fromPending = pendingEntries[fileHash]?.let { FilePayload.parse(it.content) }
        val payload = fromPending ?: history.all().firstNotNullOfOrNull { entry ->
            if (entry.type != ClipboardEntry.TYPE_FILE) return@firstNotNullOfOrNull null
            FilePayload.parse(entry.content)?.takeIf { it.fileHash == fileHash }
        }
        return payload?.fileSize?.takeIf { it > 0 }
    }

    /**
     * Asks [from] for a file again after a transfer of it came to nothing -
     * failed its hash check, broke off, or was turned away - while an item
     * still wants it and nobody is sending it. Only [MAX_RETRIES] times
     * between successes: a sender whose copy is bad would otherwise be asked
     * forever. A peer connecting asks once more anyway (see [requestMissingFiles]).
     */
    private fun requestAgain(fileHash: String, from: Collection<PeerLink>) {
        val live = from.filterNot { it.isClosed }
        if (live.isEmpty() || fileStore.exists(fileHash) || incoming.isReceiving(fileHash)) return
        if (!isWanted(fileHash)) return
        val tries = retries.merge(fileHash, 1, Int::plus) ?: 1
        if (tries > MAX_RETRIES) {
            if (tries == MAX_RETRIES + 1) onLog?.invoke("giving up on a file until a device reconnects")
            return
        }
        sendFileRequest(fileHash, live)
    }

    /** Reads incrementally so memory stays bounded to one chunk regardless of file size. */
    suspend fun streamFileToPeer(conn: PeerLink, file: File, fileHash: String) {
        if (!trust.isTrusted(conn.peerDeviceId)) return
        val key = "${conn.peerDeviceId}:$fileHash"
        if (!streamingInFlight.add(key)) return // see streamingInFlight's comment
        try {
            withContext(Dispatchers.IO) {
                if (!file.exists()) return@withContext
                val totalSize = file.length()
                if (totalSize == 0L) {
                    // One empty, final chunk, as iOS sends: older Windows and
                    // HarmonyOS builds complete an empty file from it, and
                    // wait for it forever without.
                    conn.send(
                        Protocol.envelope(
                            Protocol.TYPE_FILE_CHUNK,
                            FileChunkMessage(fileHash, chunkIndex = 0, isLast = true, dataBase64 = "").toJson(),
                        ),
                    )
                    return@withContext
                }
                var sent = 0L
                var chunkIndex = 0
                file.inputStream().use { stream ->
                    val buffer = ByteArray(CHUNK_SIZE)
                    while (sent < totalSize) {
                        // Stops mid-file for a peer removed while it was streaming.
                        if (conn.isClosed || !trust.isTrusted(conn.peerDeviceId)) return@use
                        val read = stream.read(buffer)
                        if (read <= 0) break
                        sent += read
                        conn.send(
                            Protocol.envelope(
                                Protocol.TYPE_FILE_CHUNK,
                                FileChunkMessage(
                                    fileHash = fileHash,
                                    chunkIndex = chunkIndex,
                                    isLast = sent >= totalSize,
                                    dataBase64 = B64.encode(buffer.copyOfRange(0, read)),
                                ).toJson(),
                            ),
                        )
                        chunkIndex++
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // Peer disconnected mid-transfer - nothing further to do.
        } finally {
            streamingInFlight.remove(key)
        }
    }

    private suspend fun handleFileChunk(payload: String, conn: PeerLink) = withContext(Dispatchers.IO) {
        val chunk = FileChunkMessage.parse(payload) ?: return@withContext
        // Empty is a chunk too: iOS ends an empty file - or one that shrank
        // while it was sending - with one.
        val bytes = if (chunk.dataBase64.isEmpty()) ByteArray(0) else B64.decodeOrNull(chunk.dataBase64)
        if (bytes == null) return@withContext

        when (val result = incoming.receive(conn, chunk, bytes)) {
            IncomingFiles.Result.Written -> Unit
            IncomingFiles.Result.Stored -> {
                retries.remove(chunk.fileHash)
                if (!tryFulfillPendingEntry(chunk.fileHash)) onFileStored?.invoke(chunk.fileHash)
            }
            // Corrupted in transit, tampered with, or a stream with a gap.
            // The entry still waits: ask again, since another peer's copy -
            // or this one's next stream - may be intact.
            is IncomingFiles.Result.Failed -> {
                onLog?.invoke("${result.reason} - discarding")
                requestAgain(chunk.fileHash, connections.values)
            }
            // The end of a stream this device couldn't use - one already
            // under way when another sender's copy failed, say. With nobody
            // else sending it now, this one may as well start over.
            IncomingFiles.Result.Ignored -> if (chunk.isLast) requestAgain(chunk.fileHash, listOf(conn))
        }
    }

    /**
     * A blob can become available more than one way - a completed chunk
     * stream, or this device capturing the same file locally. Whichever it
     * was, an entry waiting on that hash should now be applied. False when
     * none was waiting.
     */
    fun tryFulfillPendingEntry(fileHash: String): Boolean {
        val entry = pendingEntries.remove(fileHash) ?: return false
        // Deleted while its bytes were still on the way: it must not land on
        // the clipboard now, and the bytes that just arrived are nobody's.
        if (history.isDeleted(entry)) {
            history.releaseBlobIfUnused(fileHash)
            return true
        }
        onEntryApplied?.invoke(entry)
        return true
    }

    /**
     * What a history_batch did: the entries it added ([added], the ones that
     * were new and are still in the history after the trim), and the one to
     * put on the clipboard now ([toApply]) - the newest of them, unless it is
     * a file whose bytes are still to come, which is applied when they arrive.
     */
    class BatchApplied(val from: String, val added: List<ClipboardEntry>, val toApply: ClipboardEntry?)

    /**
     * What the answer to one v2 history_request stored ([stored], the new entries that are still there after
     * the trim). [front] is the sync's convenience item - the newest of them - when the answer is to the request
     * for it, and null otherwise; [groupId] is the group the sync has made so far, if it has, and [expectedSize]
     * how many items the whole sync asked for (for the request for the convenience item).
     */
    class SyncStored(
        val stored: List<ClipboardEntry>,
        val front: ClipboardEntry?,
        val groupId: Long?,
        val expectedSize: Int,
    )

    companion object {
        const val CHUNK_SIZE = 256 * 1024

        /** See [requestAgain]. */
        private const val MAX_RETRIES = 3

        /**
         * Which of the [missing] keys (in the order of the head, newest first) a head makes worth downloading,
         * in the same order: the history keeps [cap] items, so only those of the [cap] newest by time of what
         * is here and what [missing] would add are. The first of [missing] is always wanted, though: it is the
         * item that goes on the clipboard. A head without times cannot say, so everything it offers counts
         * (up to [cap]).
         */
        internal fun wantedKeys(
            missing: List<String>,
            head: SyncHead,
            local: List<ClipboardEntry>,
            cap: Int = HistoryStore.MAX_ITEMS,
        ): List<String> {
            if (missing.isEmpty()) return emptyList()
            val times = head.times ?: return missing.take(cap)
            val timeOf = HashMap<String, Long>()
            head.keys.forEachIndexed { index, key -> timeOf.putIfAbsent(key, times.getOrElse(index) { 0L }) }
            // What is here first: of two items with the same time, the one already here keeps its place.
            val pool = local.map { it.deletionKey to (DotNetTimestamp.epochMillis(it.timestamp) ?: 0L) } +
                missing.map { it to (timeOf[it] ?: 0L) }
            val inside = pool.sortedByDescending { it.second }.take(cap).mapTo(HashSet()) { it.first }
            // Times out of order can put the first one outside the set: the total still stays within the cap.
            return missing.filterIndexed { index, key -> index == 0 || key in inside }.take(cap)
        }

        /** What [selectForRelay] picked, and how many entries it left out. */
        class RelaySelection(val entries: List<ClipboardEntry>, val skipped: Int)

        /**
         * The entries a history_batch carries: newest first, an entry bigger
         * than [Limits.MAX_RELAY_ENTRY_CHARS] never, and only as much as fits
         * in [Limits.MAX_BATCH_CHARS] in all - an inline image of a few MB is
         * no trouble to send once, but every connect sends the whole history
         * again, and the receiver holds the batch in memory several times over
         * while it reads it. Left out are still in the history here, and
         * reach the peer live when they were new. Kept in the history's own
         * order.
         */
        fun selectForRelay(
            entries: List<ClipboardEntry>,
            maxEntryChars: Int = Limits.MAX_RELAY_ENTRY_CHARS,
            maxBatchChars: Long = Limits.MAX_BATCH_CHARS.toLong(),
        ): RelaySelection {
            var budget = maxBatchChars
            // By identity: two entries that are equal are still each their own.
            val picked = Collections.newSetFromMap(java.util.IdentityHashMap<ClipboardEntry, Boolean>())
            for (entry in entries.sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }) {
                val size = entry.content.length
                if (size > maxEntryChars || size > budget) continue
                budget -= size
                picked.add(entry)
            }
            val kept = entries.filter { it in picked }
            return RelaySelection(kept, entries.size - kept.size)
        }
    }
}
