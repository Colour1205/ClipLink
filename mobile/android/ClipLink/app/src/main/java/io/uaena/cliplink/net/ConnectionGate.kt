package io.uaena.cliplink.net

/**
 * Admission control for sockets that have just connected and proved nothing.
 *
 * Every inbound connection parks a thread for its handshake - up to the
 * handshake deadline - and costs an EC key pair and a Keystore signature
 * before the peer is even looked up. Port 49000 is open to everyone on the
 * network, so a few dozen idle connections would otherwise use up the IO
 * thread pool and starve everything else the app does. The gate allows
 * [maxPending] handshakes at once, and no more than [perSourceLimit] new
 * connections per source address per [windowMs]; the rest are to be closed
 * unread.
 *
 * Plain JVM with an injectable clock, so it is unit-testable.
 */
internal class ConnectionGate(
    private val maxPending: Int = Limits.MAX_PENDING_HANDSHAKES,
    private val perSourceLimit: Int = PER_SOURCE_LIMIT,
    private val windowMs: Long = WINDOW_MS,
    private val maxSources: Int = MAX_SOURCES,
    private val clock: () -> Long = System::currentTimeMillis,
) {

    private var pending = 0
    private val recent = HashMap<String, ArrayDeque<Long>>()

    /** Handshakes currently allowed to run. */
    @get:Synchronized
    val pendingCount: Int get() = pending

    /** True if a connection from [source] may start its handshake; pair it with [leave] when that ends. */
    @Synchronized
    fun tryEnter(source: String): Boolean {
        if (pending >= maxPending) return false
        val now = clock()
        val times = recent.getOrPut(source) { ArrayDeque() }
        while (times.isNotEmpty() && now - times.first() > windowMs) times.removeFirst()
        if (times.size >= perSourceLimit) return false
        times.add(now)
        pending++
        if (recent.size > maxSources) forgetQuietSources(now)
        return true
    }

    @Synchronized
    fun leave() {
        if (pending > 0) pending--
    }

    // Forged sources can't grow this: the quiet ones go, and if that isn't enough, all do.
    private fun forgetQuietSources(now: Long) {
        recent.entries.removeAll { (_, times) -> times.isEmpty() || now - times.last() > windowMs }
        if (recent.size > maxSources) recent.clear()
    }

    companion object {
        const val PER_SOURCE_LIMIT = 20
        const val WINDOW_MS = 10_000L
        const val MAX_SOURCES = 256
    }
}
