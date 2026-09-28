package io.uaena.cliplink.engine

import java.util.concurrent.ConcurrentHashMap

/**
 * The names peers announced this session, kept apart by how they arrived.
 * Memory only - nothing in here is ever written to disk by itself.
 *
 * A UDP beacon is unauthenticated: anyone on the network can send one
 * claiming any device id. So a beacon name is only ever a display label - for
 * a device that isn't trusted, or for a trusted one that has no stored name
 * yet - and never goes into the trust store, however often it repeats or
 * changes. Only a name from an authenticated handshake may be persisted.
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

    fun heardInHandshake(deviceId: String, name: String?) {
        if (name != null) fromHandshakes[deviceId] = name
    }

    /** The name that may go into the trust store - a handshake's, never a beacon's. */
    fun persistable(deviceId: String): String? = fromHandshakes[deviceId]

    /**
     * What to call a device on screen. [storedName] - its trust record's -
     * wins; a handshake name comes next, and a beacon name stands in only
     * when there is neither.
     */
    fun display(deviceId: String, storedName: String?): String? =
        storedName ?: fromHandshakes[deviceId] ?: fromBeacons[deviceId]
}
