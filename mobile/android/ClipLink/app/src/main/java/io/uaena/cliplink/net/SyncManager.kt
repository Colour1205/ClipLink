package io.uaena.cliplink.net

import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.engine.shortIdOf
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.TrustStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

/**
 * Owns the set of live peer connections and everything that flows over them.
 * Mirrors Program.cs's HandleMessage / SendHistoryBatch / ClipboardChanged /
 * HandleFileChunk / HandleFileRequest / StreamFileToPeer.
 */
class SyncManager(
    private val scope: CoroutineScope,
    private val history: HistoryStore,
    private val trustStore: TrustStore,
    private val fileStore: FileStore,
) {

    private val connections = ConcurrentHashMap<String, PeerConnection>()

    /** Incoming chunk streams, one sender's per file - see [IncomingFiles]. */
    private val incoming = IncomingFiles<PeerConnection>(fileStore)

    /** Verified entries waiting on bytes that are still streaming in, keyed by hash. */
    private val pendingEntries = ConcurrentHashMap<String, ClipboardEntry>()

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

    var onEntryApplied: ((ClipboardEntry) -> Unit)? = null

    /**
     * A file's bytes arrived that no newly received entry was waiting on -
     * an older item's, asked for again (see [requestMissingFiles]). Its item
     * can stop saying it's still transferring.
     */
    var onFileStored: ((String) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null
    var onConnectionsChanged: ((Int) -> Unit)? = null

    /** A registered connection's first envelope decrypted - see [PeerConnection.onSessionProven]. */
    var onSessionProven: ((PeerConnection) -> Unit)? = null

    /** A registered connection ended - the live one for its peer or a stale one. */
    var onConnectionClosed: ((PeerConnection) -> Unit)? = null

    val connectionCount: Int get() = connections.size

    fun connectedDeviceIds(): Set<String> = connections.keys.toSet()

    fun isConnected(deviceId: String): Boolean = connections.containsKey(deviceId)

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
    fun registerConnection(conn: PeerConnection) {
        // One coroutine handles this connection's messages, one at a time and
        // in the order they arrived. A coroutine per message, as this used to
        // be, let a file's chunks overtake each other on their way to the
        // disk - and the file then failed its hash check.
        val inbox = Channel<String>(Channel.UNLIMITED)
        conn.onMessage = { message -> inbox.trySend(message) }
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
                onLog?.invoke("peer disconnected: ${shortIdOf(conn.peerDeviceId)}")
            }
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
            sendHistoryBatch(conn)
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
            previous.close()
        }
    }

    fun closeAll() {
        connections.values.toList().forEach { it.close() }
        connections.clear()
        onConnectionsChanged?.invoke(0)
    }

    /** [registerConnection]'s consumer: [conn]'s messages, in order, until it closes and they're all handled. */
    private suspend fun handleInOrder(inbox: Channel<String>, conn: PeerConnection) {
        try {
            for (message in inbox) {
                try {
                    handleMessage(message, conn)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // One bad message mustn't stop the ones after it.
                    onLog?.invoke("couldn't handle a message from ${shortIdOf(conn.peerDeviceId)} ($e)")
                }
            }
        } finally {
            // Only now: the last chunks of a file it finished sending may
            // still have been queued when the link went.
            abandonTransfersFrom(conn)
        }
    }

    /**
     * The files [conn] was still sending can't be resumed, only started
     * over - by another peer that has them, or by this one once it's back
     * (see [requestMissingFiles]).
     */
    private fun abandonTransfersFrom(conn: PeerConnection) {
        val abandoned = incoming.abandonAll(conn)
        if (abandoned.isEmpty()) return
        onLog?.invoke("${abandoned.size} file transfer(s) from ${shortIdOf(conn.peerDeviceId)} broke off")
        val others = connections.values.filter { it !== conn }
        abandoned.forEach { requestAgain(it, others) }
    }

    private suspend fun sendHistoryBatch(conn: PeerConnection) {
        runCatching {
            conn.send(
                Protocol.envelope(
                    Protocol.TYPE_HISTORY_BATCH,
                    ClipboardEntry.listToJson(history.all()).toString(),
                ),
            )
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
        for (entry in entries) {
            val json = Protocol.envelope(Protocol.TYPE_ENTRY, entry.toJson().toString())
            connections.values.forEach { conn ->
                scope.launch { runCatching { conn.send(json) } }
            }
        }
        history.addAll(entries)

        for (entry in entries) {
            if (entry.type != ClipboardEntry.TYPE_FILE) continue
            val payload = FilePayload.parse(entry.content) ?: continue
            if (!fileStore.exists(payload.fileHash)) continue
            connections.values.forEach { conn ->
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
        Signing.verified(entry)?.takeIf { trustStore.isTrusted(it.deviceId) }

    private suspend fun handleMessage(message: String, conn: PeerConnection) {
        val envelope = Envelope.parse(message) ?: run {
            onLog?.invoke("received invalid message from peer (bad JSON)")
            return
        }
        when (envelope.type) {
            Protocol.TYPE_ENTRY -> {
                val received = parseEntry(envelope.payload) ?: return
                val entry = verifiedAndTrusted(received) ?: run {
                    onLog?.invoke(
                        "dropped ${received.type} entry from ${shortIdOf(received.deviceId)} " +
                            "- failed signature/trust check",
                    )
                    return
                }
                // False for anything deleted on this device too, so a
                // deleted item is neither stored nor applied again.
                val isNew = history.add(entry)
                if (isNew) applyAndReport(entry)
            }

            Protocol.TYPE_HISTORY_BATCH -> {
                val entries = try {
                    ClipboardEntry.listFromJson(JSONArray(envelope.payload))
                } catch (e: Exception) {
                    onLog?.invoke("received invalid message from peer (bad history_batch JSON)")
                    return
                }
                for (received in entries) {
                    // Skip just the bad entry, keep processing the rest of the batch.
                    val entry = verifiedAndTrusted(received) ?: continue
                    // The peer still has everything deleted here - add()
                    // refuses those, so they skip the clipboard as well.
                    if (history.add(entry)) applyAndReport(entry)
                }
            }

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

            else -> onLog?.invoke("received message with unknown type from peer: ${envelope.type}")
        }
    }

    private fun parseEntry(payload: String): ClipboardEntry? = try {
        ClipboardEntry.fromJson(org.json.JSONObject(payload))
    } catch (e: Exception) {
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
     * Apply right away if these exact bytes are already cached; otherwise
     * remember to apply once the chunks finish arriving and verifying, and ask
     * EVERY connected peer - not just whoever handed us the entry - whether
     * they have it.
     */
    private fun handleIncomingFileEntry(entry: ClipboardEntry) {
        val payload = FilePayload.parse(entry.content) ?: run {
            onLog?.invoke("received malformed file entry from peer")
            return
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
        if (fileStore.exists(payload.fileHash)) {
            onEntryApplied?.invoke(entry)
            return
        }
        pendingEntries[payload.fileHash] = entry
        sendFileRequest(payload.fileHash, connections.values)
    }

    private fun sendFileRequest(fileHash: String, to: Collection<PeerConnection>) {
        val json = Protocol.envelope(Protocol.TYPE_FILE_REQUEST, FileRequestMessage(fileHash).toJson())
        to.forEach { conn -> scope.launch { runCatching { conn.send(json) } } }
    }

    /**
     * Asks a peer that just connected for every file this device is still
     * missing: a newly received item's that broke off or failed, and any
     * older item's whose bytes never came - the app killed mid-transfer, say.
     * Nothing else would ever ask for them again, and the item would say
     * "Transferring…" until it was evicted.
     */
    private fun requestMissingFiles(conn: PeerConnection) {
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
     * Asks [from] for a file again after a transfer of it came to nothing -
     * failed its hash check, broke off, or was turned away - while an item
     * still wants it and nobody is sending it. Only [MAX_RETRIES] times
     * between successes: a sender whose copy is bad would otherwise be asked
     * forever. A peer connecting asks once more anyway (see [requestMissingFiles]).
     */
    private fun requestAgain(fileHash: String, from: Collection<PeerConnection>) {
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
    suspend fun streamFileToPeer(conn: PeerConnection, file: File, fileHash: String) {
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
        } catch (e: Exception) {
            // Peer disconnected mid-transfer - nothing further to do.
        } finally {
            streamingInFlight.remove(key)
        }
    }

    private suspend fun handleFileChunk(payload: String, conn: PeerConnection) = withContext(Dispatchers.IO) {
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

    private companion object {
        const val CHUNK_SIZE = 256 * 1024

        /** See [requestAgain]. */
        const val MAX_RETRIES = 3
    }
}
