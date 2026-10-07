package io.uaena.cliplink.engine

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.toHex
import io.uaena.cliplink.net.FilePayload
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** A history entry, plus everything the list needs that isn't on the wire. */
data class SyncedItem(
    val entry: ClipboardEntry,
    val isOwn: Boolean,
    val fileAvailable: Boolean,
    /** Where a file entry's bytes are once they're here - null until then, and for every other type. */
    val file: File? = null,
    /**
     * A key no other item in the same list has, and the same for this item
     * across refreshes: the entry's signature text (see
     * [ClipboardEntry.deletionKey]), with "#2", "#3"... after a repeat of one
     * that really is a repeat. Key a list, an image cache or a selection by
     * this, never by [ClipboardEntry.key]: that is device, timestamp and type,
     * which two different entries of one device can share.
     */
    val uniqueKey: String = entry.deletionKey,
) {
    /** [uniqueKey] - what every list and cache here keys an item by. */
    val id: String get() = uniqueKey
    val type: String get() = entry.type

    val filePayload: FilePayload?
        get() = if (entry.type == ClipboardEntry.TYPE_FILE) FilePayload.parse(entry.content) else null

    /** "Link" is a display-only refinement of a text entry, never a wire type. */
    val isLink: Boolean
        get() = entry.type == ClipboardEntry.TYPE_TEXT && LINK_PATTERN.matches(entry.content.trim())

    val preview: String
        get() = when (entry.type) {
            ClipboardEntry.TYPE_TEXT -> entry.content
            ClipboardEntry.TYPE_IMAGE -> "Image"
            ClipboardEntry.TYPE_FILE -> filePayload?.fileName ?: "File"
            else -> entry.type
        }

    val timeLabel: String
        get() = runCatching {
            TIME_FORMAT.format(Instant.parse(entry.timestamp))
        }.getOrDefault("")

    private companion object {
        val LINK_PATTERN = Regex("^(https?|ftp)://\\S+$", RegexOption.IGNORE_CASE)
        val TIME_FORMAT: DateTimeFormatter =
            DateTimeFormatter.ofPattern("HH:mm:ss").withZone(ZoneId.systemDefault())
    }
}

/**
 * [SyncedItem.uniqueKey] for each of [entries], in order: the entry's
 * signature text, and for a second (third...) entry that comes out the same,
 * that with "#2" ("#3"...) added. Signatures are what tells two entries of one
 * device apart when device, timestamp and type don't - and are the same
 * every time, so the keys survive a refresh; only entries that share a
 * signature at all (which a verified entry can't) ever need the suffix.
 */
internal fun uniqueKeysFor(entries: List<ClipboardEntry>): List<String> {
    val seen = HashMap<String, Int>()
    return entries.map { entry ->
        val base = entry.deletionKey
        val count = (seen[base] ?: 0) + 1
        seen[base] = count
        if (count == 1) base else "$base#$count"
    }
}

/** One row in the Devices tab - a trusted device, a discovered one, or both. */
data class DeviceRow(
    val deviceId: String,
    /** What the device calls itself, or null while no name has been heard for it. */
    val name: String?,
    val trusted: Boolean,
    val connected: Boolean,
    /** Every address this device is currently reachable at, LAN first. */
    val addresses: List<String>,
    /** The peer says its own pairing screen is open right now. */
    val pairing: Boolean,
    /**
     * When this device's beacon was last heard. Not part of the row's
     * identity ([equals] leaves it out): it changes with every beacon, every
     * two seconds per peer, and a row that differs each time recomposes the
     * whole Devices screen for nothing.
     */
    val lastSeenAtMs: Long?,
) {
    override fun equals(other: Any?): Boolean =
        other is DeviceRow && deviceId == other.deviceId && name == other.name && trusted == other.trusted &&
            connected == other.connected && addresses == other.addresses && pairing == other.pairing

    override fun hashCode(): Int {
        var result = deviceId.hashCode()
        result = 31 * result + (name?.hashCode() ?: 0)
        result = 31 * result + trusted.hashCode()
        result = 31 * result + connected.hashCode()
        result = 31 * result + addresses.hashCode()
        result = 31 * result + pairing.hashCode()
        return result
    }

    val shortId: String get() = shortIdOf(deviceId)

    /** The row's title: its name, else the shortened id. */
    val title: String get() = displayNameOf(deviceId, name)

    companion object {
        /**
         * Trusted first, then discovered; within each, named devices by name
         * (case-insensitive), unnamed ones after them; the id breaks every
         * tie. Deliberately nothing that changes on its own - not last-seen
         * time, not connection state, not arrival order - so a beacon or a
         * link coming up never moves a row out from under the user's thumb.
         */
        val STABLE_ORDER: Comparator<DeviceRow> =
            compareByDescending<DeviceRow> { it.trusted }
                .thenBy { it.name == null }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { it.name.orEmpty() }
                .thenBy { it.deviceId }
    }
}

/** How a peer is shown anywhere in the UI: its name, else the shortened id. */
fun displayNameOf(deviceId: String, name: String?): String =
    name?.takeIf { it.isNotBlank() } ?: shortIdOf(deviceId)

/** How an id is shown: "Device AB12·CD34", its [fingerprintOf] - the same label iOS shows. */
fun shortIdOf(deviceId: String): String = "Device ${fingerprintOf(deviceId)}"

/**
 * The first four bytes of the id's SHA-256, as "AB12·CD34". Not the id's
 * first characters: every id is a P-256 public key whose first 36 base64
 * characters are the same for every device, so those tell no two apart.
 */
fun fingerprintOf(deviceId: String): String {
    val hex = MessageDigest.getInstance("SHA-256")
        .digest(deviceId.toByteArray(Charsets.UTF_8))
        .copyOf(4).toHex().uppercase()
    return "${hex.take(4)}·${hex.takeLast(4)}"
}

/**
 * One line of the Activity log. [id] is unique per line: the list is keyed by
 * it, and the time and text alone are not - a connection that flaps logs the
 * same message twice in one second, and a Lazy list given two equal keys
 * crashes the app.
 */
data class LogLine(val id: Long, val time: String, val message: String)

/**
 * A peer that completed a handshake but isn't trusted yet - awaiting an
 * explicit decision. [name] is self-claimed, so the prompt always shows
 * [shortId] and [address] beside it: a stranger can copy a known device's
 * name, never its id.
 */
data class PairingRequest(val deviceId: String, val address: String?, val name: String? = null) {
    val shortId: String get() = shortIdOf(deviceId)
}
