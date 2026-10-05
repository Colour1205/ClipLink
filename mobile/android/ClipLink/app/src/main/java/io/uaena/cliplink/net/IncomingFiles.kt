package io.uaena.cliplink.net

import io.uaena.cliplink.store.FileStore
import java.io.RandomAccessFile

/**
 * The files arriving as file_chunk streams, keyed by hash exactly as the
 * stream spells it - SyncManager's bookkeeping, kept apart from sockets so it
 * can be tested off-device. [O] is whatever tells one sender from another.
 *
 * One sender per file: the first stream to start one owns it until it is
 * stored or abandoned, and every other sender's chunks for it are ignored.
 * Keyed by hash alone, two peers answering the same broadcast file_request
 * used to write their chunks into one file, which then failed its hash check.
 *
 * Calls for one sender must come one at a time, in the order its chunks
 * arrived - SyncManager handles each connection's messages on a single
 * coroutine for exactly that. Different senders' calls may overlap.
 */
internal class IncomingFiles<O : Any>(private val fileStore: FileStore) {

    /** What one chunk came to. */
    sealed interface Result {
        /** Written; more to come. */
        data object Written : Result

        /** The last one: the file is complete, checked, and in the store. */
        data object Stored : Result

        /** The transfer is abandoned and its bytes gone - [reason] says why. */
        data class Failed(val reason: String) : Result

        /**
         * Not for writing: another sender has this file, it's already here,
         * or this stream started before this device was listening for it.
         */
        data object Ignored : Result
    }

    private class Transfer<T>(val owner: T, val file: RandomAccessFile) {
        var nextIndex = 0
    }

    private val transfers = HashMap<String, Transfer<O>>()

    fun isReceiving(hash: String): Boolean = synchronized(transfers) { hash in transfers }

    fun receive(owner: O, chunk: FileChunkMessage, bytes: ByteArray): Result {
        val hash = chunk.fileHash
        // Only the lookup is locked. A transfer is only ever written by its
        // owner's calls, which never overlap; anyone else just sees it's taken.
        val transfer = synchronized(transfers) {
            val current = transfers[hash]
            if (current != null) {
                if (current.owner != owner) return Result.Ignored
                if (chunk.chunkIndex != current.nextIndex) {
                    drop(hash, current)
                    // Chunk 0 again is its sender starting over - after a
                    // stream of the same file that broke off, say - so start
                    // over with it. Never append to the old one's bytes.
                    if (chunk.chunkIndex != 0) return Result.Failed("file chunk out of order")
                }
            }
            transfers[hash] ?: run {
                // A stream whose start this device missed can never hash
                // right, and a file already here needs nothing more.
                if (chunk.chunkIndex != 0 || fileStore.exists(hash)) return Result.Ignored
                start(hash, owner) ?: return Result.Failed("couldn't create a file for an incoming transfer")
            }
        }

        try {
            transfer.file.write(bytes)
        } catch (e: Exception) {
            synchronized(transfers) { drop(hash, transfer) }
            return Result.Failed("failed writing file chunk ($e)")
        }
        transfer.nextIndex++
        if (!chunk.isLast) return Result.Written

        runCatching { transfer.file.close() }
        val temp = fileStore.tempPath(hash)
        // The hash inside the SIGNED entry is what's trusted here, never
        // whatever bytes actually turned up. Still this sender's while it's
        // checked, so no other stream can start on the same temp file.
        val verified = try {
            FileStore.hashOf(temp).equals(hash, ignoreCase = true)
        } catch (e: Exception) {
            false
        }
        val stored = verified && temp.renameTo(fileStore.path(hash))
        synchronized(transfers) { transfers.remove(hash, transfer) }
        if (stored) return Result.Stored
        temp.delete()
        return Result.Failed(
            if (verified) "couldn't store a received file" else "file transfer failed hash verification",
        )
    }

    /**
     * Abandons every transfer [owner] was sending - its link is gone, and its
     * streams can't be resumed, only started over. Returns their hashes.
     */
    fun abandonAll(owner: O): List<String> = synchronized(transfers) {
        val owned = transfers.filterValues { it.owner == owner }
        owned.forEach { (hash, transfer) -> drop(hash, transfer) }
        owned.keys.toList()
    }

    /** Under the lock. */
    private fun start(hash: String, owner: O): Transfer<O>? = try {
        val temp = fileStore.tempPath(hash)
        temp.parentFile?.mkdirs()
        temp.delete()
        Transfer(owner, RandomAccessFile(temp, "rw")).also { transfers[hash] = it }
    } catch (e: Exception) {
        null
    }

    /** Under the lock. */
    private fun drop(hash: String, transfer: Transfer<O>) {
        transfers.remove(hash, transfer)
        runCatching { transfer.file.close() }
        fileStore.tempPath(hash).delete()
    }
}
