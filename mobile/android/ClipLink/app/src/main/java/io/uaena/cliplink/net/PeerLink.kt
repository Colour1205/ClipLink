package io.uaena.cliplink.net

import java.util.concurrent.atomic.AtomicLong

/**
 * What SyncManager needs from a connection: the live link to one peer, as
 * [PeerConnection] provides it. An interface so the message handling can be
 * tested with a fake - a real connection wants a socket and the Keystore.
 */
interface PeerLink {
    val peerDeviceId: String

    /** What the peer's handshake said it is called - null from builds that don't send one. */
    val peerName: String?

    val isClosed: Boolean

    /** Whether a line has decrypted with the session key yet - see [PeerConnection.onSessionProven]. */
    val isSessionProven: Boolean

    /** Why the link ended, once it has: "IOException: Connection reset", "no data from the peer for 9s"... */
    val closeReason: String?

    /**
     * Called on the read loop for every decrypted message. It may suspend:
     * while it does, nothing more is read, so a handler that can't keep up
     * slows the peer down through TCP instead of piling messages up here.
     */
    var onMessage: (suspend (String) -> Unit)?

    /** Fires once, when the link ends for any reason. */
    var onDisconnected: (() -> Unit)?

    var onSessionProven: (() -> Unit)?

    /** Sends one message; throws if the link is dead. */
    suspend fun send(message: String)

    /** Starts reading and the heartbeat. */
    fun listen()

    /** Idempotent. [reason] is kept as [closeReason] if this is what ended the link. */
    fun close(reason: String = "closed locally")
}

/**
 * Whether a link has gone quiet, kept apart from the sockets so it is
 * testable with a fake clock.
 *
 * Silence is judged from the last time ANY bytes arrived, not the last
 * message handled: a peer streaming a big file is alive however long its
 * messages wait to be handled. And while the read loop is parked waiting for
 * the handler (see [PeerLink.onMessage]) it isn't reading at all, so silence
 * means nothing then - for a bounded while: [isDead]'s grace.
 */
internal class Liveness(private val clock: () -> Long = System::currentTimeMillis) {

    private val lastActivity = AtomicLong(clock())

    @Volatile
    private var blockedSince = 0L

    /** Bytes (or anything else proving the peer is there) just arrived. */
    fun heard() = lastActivity.set(clock())

    /** The read loop is about to wait for its handler. */
    fun readerBlocked() {
        blockedSince = clock()
    }

    /** The handler took the message: reading resumes, and silence is counted from now. */
    fun readerResumed() {
        blockedSince = 0L
        heard()
    }

    /** True when nothing has arrived for more than [timeoutMs] - not counting up to [graceMs] spent waiting on the handler. */
    fun isDead(timeoutMs: Long, graceMs: Long): Boolean {
        val now = clock()
        val blocked = blockedSince
        if (blocked != 0L && now - blocked <= graceMs) return false
        return now - lastActivity.get() > timeoutMs
    }
}
