package io.uaena.cliplink.engine

import io.uaena.cliplink.net.Discovery

/**
 * The beacons heard lately, one per device id: where each peer can be
 * reached and what it says about itself, for the Devices tab and for dialling.
 *
 * Beacons are unauthenticated UDP, so anyone on the network can make up
 * device ids by the thousand. Nothing here grows without bound for that, and
 * nothing here stays after its device has gone:
 *  - a device that hasn't been heard for [maxAgeMs] is forgotten (see
 *    [prune]) - unless it is protected, which is for the caller to say (a
 *    trusted or connected device): that one keeps its last known addresses,
 *    and just no longer counts as "here" (see [isRecent]);
 *  - past [maxEntries] devices a new one that isn't protected is refused
 *    until there is room again.
 * The Windows engine does the same (30 s listing window, 256 devices).
 *
 * Plain JVM, with an injectable clock, so it is unit-testable.
 */
internal class BeaconBook(
    private val maxEntries: Int = MAX_ENTRIES,
    private val maxAgeMs: Long = MAX_AGE_MS,
    private val clock: () -> Long = System::currentTimeMillis,
) {

    /** What [record] did with a beacon. */
    enum class Recorded {
        /** No room for one more unprotected device - nothing was kept. */
        Rejected,

        /** Already known, and nothing the Devices tab shows has changed - only the time it was last heard. */
        Refreshed,

        /** A new device, or one whose address, name or pairing state differs: the list has to be rebuilt. */
        Changed,
    }

    private class Seen(var beacon: Discovery.Beacon, var at: Long)

    private val seen = LinkedHashMap<String, Seen>()

    /**
     * Notes [beacon]. [isProtected] says which device ids are trusted or
     * connected: those are always admitted and never forgotten for being quiet.
     */
    @Synchronized
    fun record(beacon: Discovery.Beacon, isProtected: (String) -> Boolean): Recorded {
        val now = clock()
        val known = seen[beacon.deviceId]
        if (known != null) {
            val changed = known.beacon.visiblyDiffersFrom(beacon)
            known.beacon = beacon
            known.at = now
            return if (changed) Recorded.Changed else Recorded.Refreshed
        }
        if (seen.size >= maxEntries) {
            // Room by dropping the long-quiet before refusing anyone.
            removeStale(now, isProtected)
            if (seen.size >= maxEntries) {
                if (!isProtected(beacon.deviceId)) return Recorded.Rejected
                // A protected device gets in by pushing out the quietest unprotected one, if any.
                val victim = seen.entries.filter { !isProtected(it.key) }.minByOrNull { it.value.at }
                victim?.let { seen.remove(it.key) }
            }
        }
        seen[beacon.deviceId] = Seen(beacon, now)
        return Recorded.Changed
    }

    @Synchronized
    fun get(deviceId: String): Discovery.Beacon? = seen[deviceId]?.beacon

    /** When [deviceId] was last heard (ms since the epoch), or null. */
    @Synchronized
    fun lastSeenAt(deviceId: String): Long? = seen[deviceId]?.at

    /** Whether [deviceId] was heard within the listing window. */
    @Synchronized
    fun isRecent(deviceId: String): Boolean = seen[deviceId]?.let { clock() - it.at <= maxAgeMs } == true

    @Synchronized
    fun ids(): List<String> = seen.keys.toList()

    @Synchronized
    fun size(): Int = seen.size

    /**
     * Forgets every unprotected device that hasn't been heard for the listing
     * window. Returns who went, so whatever else is kept per device can go too.
     */
    @Synchronized
    fun prune(isProtected: (String) -> Boolean): List<String> = removeStale(clock(), isProtected)

    private fun removeStale(now: Long, isProtected: (String) -> Boolean): List<String> {
        val stale = seen.entries.filter { now - it.value.at > maxAgeMs && !isProtected(it.key) }.map { it.key }
        stale.forEach(seen::remove)
        return stale
    }

    // The port and the sender's address are what a dial needs, and may
    // change too - but only what the screen shows asks for a new list.
    private fun Discovery.Beacon.visiblyDiffersFrom(other: Discovery.Beacon): Boolean =
        senderIp != other.senderIp || address != other.address || pairing != other.pairing || name != other.name

    companion object {
        /** An unprotected device drops off the list this long after its last beacon (they come every 2 s). */
        const val MAX_AGE_MS = 30_000L

        /** Devices remembered at once. */
        const val MAX_ENTRIES = 64
    }
}
