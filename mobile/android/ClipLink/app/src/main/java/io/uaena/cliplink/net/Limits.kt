package io.uaena.cliplink.net

/**
 * Everything a peer - or whoever can reach port 49000 - can make this app hold
 * in memory or on disk, and how much of it we agree to. All of these exist
 * because the app runs on a phone with a heap of a few hundred megabytes, and
 * the other end is a PC that may send, and a network that may carry, anything.
 */
object Limits {
    /** The handshake line before anything is trusted. The real one is under 1.5 KB. */
    const val MAX_HANDSHAKE_BYTES = 8 * 1024

    /** The whole handshake - connect to verdict - however slowly the peer sends it. */
    const val HANDSHAKE_DEADLINE_MS = 10_000L

    /**
     * Any line after the handshake: base64 of an encrypted envelope. A line
     * over this is read and dropped (and logged), not parsed. Sized for the
     * largest legitimate message - an inline image the clipboard bridge
     * allows (a 24 MiB PNG is 32 MiB of base64, a bit more once the entry and
     * the envelope have each escaped and wrapped it, and the line base64s it
     * once more) - while a 256 KB file chunk is a small fraction of it.
     */
    const val MAX_LINE_BYTES = 64 * 1024 * 1024

    /** An entry's content, in characters, over which the entry is dropped on arrival. */
    const val MAX_ENTRY_CONTENT_CHARS = 36 * 1024 * 1024

    /** An entry this big isn't repeated in a history_batch: it would be sent again on every connect. */
    const val MAX_RELAY_ENTRY_CHARS = 12 * 1024 * 1024

    /** What one history_batch carries, in characters of content, newest entries first. */
    const val MAX_BATCH_CHARS = 16 * 1024 * 1024

    /** What the history keeps in memory and on disk, in characters of content - see HistoryStore. */
    const val MAX_STORED_CHARS = 64L * 1024 * 1024

    /** A received file's size: the same 1 GB a file may be to send. */
    const val MAX_FILE_BYTES = 1L shl 30

    /** Files being received at once, from everyone, and from any one peer. */
    const val MAX_INCOMING_STREAMS = 8
    const val MAX_INCOMING_STREAMS_PER_PEER = 4

    /** A stream that has written nothing for this long is abandoned. */
    const val INCOMING_STREAM_IDLE_MS = 5 * 60_000L

    /** Messages one connection may have waiting for its handler; the read loop waits beyond that. */
    const val INBOX_CAPACITY = 2

    /** Sockets that have connected and not finished their handshake yet, all together. */
    const val MAX_PENDING_HANDSHAKES = 8
}
