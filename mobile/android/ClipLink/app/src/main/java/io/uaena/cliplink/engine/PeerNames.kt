package io.uaena.cliplink.engine

import java.util.concurrent.ConcurrentHashMap

/**
 * The names peers announced this session, kept apart by how they arrived.
 * Memory only - nothing in here is ever written to disk.
 *
 * A UDP beacon is unauthenticated: anyone on the network can send one
 * claiming any device id. So a beacon name is only ever a display label - for
 * a device that isn't trusted, or for a trusted one that has no stored name
 * yet - and never goes into the trust store, however often it repeats or
 * changes. A handshake name is shown ahead of it, but a handshake can be
 * replayed too: the trust store takes that name from its own connection, and
 * only once the session is proven - see ClipLinkEngine.rememberProvenName -
 * and one whose connection ends unproven is forgotten with it.
 *
 * Each name is only ever replaced by another name, never by "unknown", so an
 * older build's nameless beacon or handshake can't blank out what we know.
 */
internal class PeerNames {

    private val fromBeacons = ConcurrentHashMap<String, String>()
    private val fromHandshakes = ConcurrentHashMap<String, String>()

    fun heardInBeacon(deviceId: String, name: String?) {
        if (name != null) fromBeacons[deviceId] = name
    }

    /** A device left the beacon book - its beacon name goes with it, so nothing here outlives its device. */
    fun forgetBeacon(deviceId: String) {
        fromBeacons.remove(deviceId)
    }

    fun heardInHandshake(deviceId: String, name: String?) {
        if (name != null) fromHandshakes[deviceId] = name
    }

    /**
     * Takes back the [name] a handshake brought once its connection has gone
     * without proving its session: it was only that connection's to show.
     * Only if it's still the latest - a newer handshake's name stays.
     */
    fun forgetHandshake(deviceId: String, name: String?): Boolean =
        name != null && fromHandshakes.remove(deviceId, name)

    /**
     * What to call a device on screen. [storedName] - its trust record's -
     * wins; a handshake name comes next, and a beacon name stands in only
     * when there is neither.
     */
    fun display(deviceId: String, storedName: String?): String? =
        storedName ?: fromHandshakes[deviceId] ?: fromBeacons[deviceId]
}
