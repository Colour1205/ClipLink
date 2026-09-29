package io.uaena.cliplink.net

import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.engine.shortIdOf
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.TrustStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import java.io.RandomAccessFile
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

    /** Open write handles for incoming chunk streams, keyed by file hash. */
    private val inProgress = ConcurrentHashMap<String, RandomAccessFile>()

    /** Verified entries waiting on bytes that are still streaming in, keyed by hash. */
    private val pendingEntries = ConcurrentHashMap<String, ClipboardEntry>()

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
        conn.onMessage = { message -> scope.launch { handleMessage(message, conn) } }
        // Off the read loop - what comes of it is a trust-store write.
        conn.onSessionProven = { scope.launch(Dispatchers.IO) { onSessionProven?.invoke(conn) } }
        conn.onDisconnected = {
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
        if (conn.isClosed) return

        val previous = connections.put(conn.peerDeviceId, conn)
        onConnectionsChanged?.invoke(connections.size)
        scope.launch { sendHistoryBatch(conn) }

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
            Protocol.TYPE_FILE_CHUNK -> handleFileChunk(envelope.payload)

            Protocol.TYPE_FILE_REQUEST -> {
                val request = FileRequestMessage.parse(envelope.payload) ?: return
                if (fileStore.exists(request.fileHash)) {
                    streamFileToPeer(conn, fileStore.path(request.fileHash), request.fileHash)
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
        if (fileStore.exists(payload.fileHash)) {
            onEntryApplied?.invoke(entry)
            return
        }
        pendingEntries[payload.fileHash] = entry
        val json = Protocol.envelope(
            Protocol.TYPE_FILE_REQUEST,
            FileRequestMessage(payload.fileHash).toJson(),
        )
        connections.values.forEach { conn -> scope.launch { runCatching { conn.send(json) } } }
    }

    /** Reads incrementally so memory stays bounded to one chunk regardless of file size. */
    suspend fun streamFileToPeer(conn: PeerConnection, file: File, fileHash: String) {
        val key = "${conn.peerDeviceId}:$fileHash"
        if (!streamingInFlight.add(key)) return // see streamingInFlight's comment
        try {
            withContext(Dispatchers.IO) {
                if (!file.exists()) return@withContext
                val totalSize = file.length()
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

    private suspend fun handleFileChunk(payload: String) = withContext(Dispatchers.IO) {
        val chunk = FileChunkMessage.parse(payload) ?: return@withContext
        val bytes = B64.decodeOrNull(chunk.dataBase64) ?: return@withContext

        val handle = inProgress.getOrPut(chunk.fileHash) {
            val temp = fileStore.tempPath(chunk.fileHash)
            temp.parentFile?.mkdirs()
            temp.delete()
            RandomAccessFile(temp, "rw")
        }

        try {
            handle.write(bytes)
        } catch (e: Exception) {
            onLog?.invoke("failed writing file chunk ($e) - abandoning this transfer")
            inProgress.remove(chunk.fileHash)
            runCatching { handle.close() }
            return@withContext
        }

        if (!chunk.isLast) return@withContext

        inProgress.remove(chunk.fileHash)
        runCatching { handle.close() }

        val temp = fileStore.tempPath(chunk.fileHash)
        val actualHash = FileStore.hashOf(temp)
        if (!actualHash.equals(chunk.fileHash, ignoreCase = true)) {
            // Corrupted in transit or tampered with. The hash inside the
            // SIGNED entry is what's trusted here, never whatever bytes
            // actually turned up.
            onLog?.invoke("file transfer failed hash verification - discarding")
            temp.delete()
            pendingEntries.remove(chunk.fileHash)
            return@withContext
        }

        temp.renameTo(fileStore.path(chunk.fileHash))
        tryFulfillPendingEntry(chunk.fileHash)
    }

    /**
     * A blob can become available more than one way - a completed chunk
     * stream, or this device capturing the same file locally. Whichever it
     * was, an entry waiting on that hash should now be applied.
     */
    fun tryFulfillPendingEntry(fileHash: String) {
        val entry = pendingEntries.remove(fileHash) ?: return
        // Deleted while its bytes were still on the way: it must not land on
        // the clipboard now, and the bytes that just arrived are nobody's.
        if (history.isDeleted(entry)) {
            history.releaseBlobIfUnused(fileHash)
            return
        }
        onEntryApplied?.invoke(entry)
    }

    private companion object {
        const val CHUNK_SIZE = 256 * 1024
    }
}
