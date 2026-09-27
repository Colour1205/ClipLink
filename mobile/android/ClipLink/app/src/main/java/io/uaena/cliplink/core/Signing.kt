package io.uaena.cliplink.core

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * One clipboard item on the wire, and the signature over it.
 *
 * TIMESTAMP IS AN OPAQUE STRING AND MUST STAY ONE. The Windows daemon signs
 * over `entry.Timestamp.ToString("o")` - .NET's round-trip format, seven
 * fractional digits. The signed bytes are that exact text. Parsing an
 * incoming timestamp into any date type and re-formatting it risks changing
 * even one character (trailing zeros, offset spelling, precision), and the
 * re-derived signing input then no longer matches what was actually signed,
 * so genuine entries fail verification. So: received timestamps are carried
 * through untouched, and locally originated ones are generated directly in
 * that format.
 */
data class ClipboardEntry(
    val content: String,
    val type: String,
    val deviceId: String,
    val timestamp: String,
    val signature: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("Content", content)
        put("Type", type)
        put("DeviceId", deviceId)
        put("Timestamp", timestamp)
        put("Signature", signature ?: JSONObject.NULL)
    }

    /** Stable identity for dedup/UI keys - matches what the history store compares. */
    val key: String get() = "$deviceId|$timestamp|$type"

    companion object {
        const val TYPE_TEXT = "text"
        const val TYPE_IMAGE = "image"
        const val TYPE_FILE = "file"

        fun fromJson(json: JSONObject): ClipboardEntry? {
            val content = json.optString("Content", "")
            val type = json.optString("Type", "")
            val deviceId = json.optString("DeviceId", "")
            val timestamp = json.optString("Timestamp", "")
            if (type.isEmpty() || deviceId.isEmpty() || timestamp.isEmpty()) return null
            val signature = json.optStringOrNull("Signature")
            return ClipboardEntry(content, type, deviceId, timestamp, signature)
        }

        fun listFromJson(array: JSONArray): List<ClipboardEntry> {
            val out = ArrayList<ClipboardEntry>(array.length())
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                fromJson(obj)?.let(out::add)
            }
            return out
        }

        fun listToJson(entries: List<ClipboardEntry>): JSONArray {
            val array = JSONArray()
            entries.forEach { array.put(it.toJson()) }
            return array
        }
    }
}

object Signing {

    private val SECONDS_FORMAT: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss").withZone(ZoneOffset.UTC)

    /**
     * Matches .NET's `DateTime.ToString("o")` for a UTC value:
     * `yyyy-MM-ddTHH:mm:ss.fffffffZ`, exactly seven fractional digits (100ns
     * ticks). Built by hand rather than with a pattern because
     * DateTimeFormatter's fractional-second fields and .NET's tick count
     * don't line up in an obvious way, and this string is signed - it has to
     * round-trip through .NET's parser and back to the identical text.
     */
    fun nowAsDotNetRoundTrip(): String {
        val now = Instant.now()
        val ticks = now.nano / 100L // 100-nanosecond units, .NET's unit
        return "${SECONDS_FORMAT.format(now)}.${ticks.toString().padStart(7, '0')}Z"
    }

    private fun signableData(entry: ClipboardEntry): ByteArray =
        "${entry.content}:${entry.type}:${entry.deviceId}:${entry.timestamp}"
            .toByteArray(Charsets.UTF_8)

    fun sign(
        identity: DeviceIdentity,
        content: String,
        type: String,
        deviceId: String,
    ): ClipboardEntry {
        val unsigned = ClipboardEntry(
            content = content,
            type = type,
            deviceId = deviceId,
            timestamp = nowAsDotNetRoundTrip(),
        )
        return unsigned.copy(signature = B64.encode(identity.sign(signableData(unsigned))))
    }

    /**
     * Verifies against `entry.deviceId` itself, which is how every caller on
     * every platform uses it - the entry claims who signed it, and the claim
     * is only worth anything because the trust store is checked separately.
     */
    fun verify(entry: ClipboardEntry): Boolean {
        val signatureBytes = B64.decodeOrNull(entry.signature) ?: return false
        return DeviceIdentity.verifyRawSignature(
            entry.deviceId,
            signableData(entry),
            signatureBytes,
        )
    }
}
