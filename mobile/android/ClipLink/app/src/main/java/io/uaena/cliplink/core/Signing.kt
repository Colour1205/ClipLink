package io.uaena.cliplink.core

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
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
 *
 * The one exception is a timestamp the Windows daemon has already mangled
 * in transit - see [DotNetTimestamp] and [Signing.verified]. That repair
 * only ever restores the text that was actually signed, never parses it.
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
    val key: String get() = "$deviceId|${DotNetTimestamp.canonical(timestamp)}|$type"

    /**
     * What a deletion is recorded under (see DeletedStore), spelled the same
     * on every platform: the signature text exactly as received, which no
     * relay or timestamp repair ever changes. The fallback only covers an
     * entry with no signature, and nothing unsigned is ever accepted from a
     * peer.
     */
    val deletionKey: String
        get() = signature?.takeIf { it.isNotEmpty() }
            ?: "$deviceId|$type|$timestamp|${sha256Hex(content.toByteArray(Charsets.UTF_8))}"

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

        private fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
    }
}

/**
 * The two spellings one .NET timestamp can arrive in.
 *
 * The daemon SIGNS over `Timestamp.ToString("o")`, which always writes seven
 * fractional digits ("2026-09-26T12:34:56.1234500Z"). But it SENDS entries
 * serialized by System.Text.Json, which trims trailing fractional zeros
 * ("...:56.12345Z") and drops the fraction entirely when it is zero
 * ("...:56Z"). Both are the same instant, but only the first is the signed
 * text - so a Windows entry whose tick count ends in 0 (about one in ten),
 * and any entry Windows relays in a history_batch after receiving it from a
 * device that pads with zeros, arrives in a form that does not verify as-is.
 *
 * [padded] rebuilds the seven-digit text purely by string surgery, so it
 * cannot drift the way a parse-and-reformat could.
 */
object DotNetTimestamp {

    private val PATTERN =
        Regex("""^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,7}))?(Z|[+-]\d{2}:\d{2})?$""")

    /**
     * What `ToString("o")` wrote before System.Text.Json trimmed it: the
     * fraction right-padded to seven digits, suffix unchanged. Null when
     * [timestamp] already has seven digits (nothing was trimmed) or is not a
     * shape .NET produces.
     */
    fun padded(timestamp: String): String? {
        val match = PATTERN.matchEntire(timestamp) ?: return null
        val (seconds, fraction, suffix) = match.destructured
        if (fraction.length == 7) return null
        return "$seconds.${fraction.padEnd(7, '0')}$suffix"
    }

    /**
     * The form to compare and sort on. Trimmed and untrimmed spellings of one
     * instant are then equal, and "...:56Z" no longer sorts after
     * "...:56.5Z" just because 'Z' > '.'.
     */
    fun canonical(timestamp: String): String = padded(timestamp) ?: timestamp
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
     *
     * The last digit is never 0: a zero there gets trimmed when the Windows
     * daemon re-serializes the entry (see [DotNetTimestamp]), and a peer that
     * verifies the raw text would then reject it. One extra 100ns tick is
     * invisible to the user and keeps the text byte-identical through any
     * relay. It never carries: a tick count ending in 0 is at most 9999990.
     */
    fun nowAsDotNetRoundTrip(): String {
        val now = Instant.now()
        var ticks = now.nano / 100L // 100-nanosecond units, .NET's unit
        if (ticks % 10 == 0L) ticks += 1
        return "${SECONDS_FORMAT.format(now)}.${ticks.toString().padStart(7, '0')}Z"
    }

    internal fun signableData(entry: ClipboardEntry): ByteArray =
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
     * Returns the entry exactly as its signer signed it, or null when the
     * signature does not hold. Callers must store and relay what this
     * returns rather than what arrived: when the timestamp had been trimmed
     * in transit, the returned copy carries the padded, signed text, which
     * every platform can then verify.
     *
     * Verifies against `entry.deviceId` itself, which is how every caller on
     * every platform uses it - the entry claims who signed it, and the claim
     * is only worth anything because the trust store is checked separately.
     */
    fun verified(entry: ClipboardEntry): ClipboardEntry? {
        val signatureBytes = B64.decodeOrNull(entry.signature) ?: return null
        return verified(entry) { candidate ->
            DeviceIdentity.verifyRawSignature(
                candidate.deviceId,
                signableData(candidate),
                signatureBytes,
            )
        }
    }

    /**
     * The raw-then-padded fallback on its own, with the signature check
     * passed in so it can be tested on a plain JVM (B64 and the keystore
     * both need Android).
     */
    internal fun verified(
        entry: ClipboardEntry,
        signatureHolds: (ClipboardEntry) -> Boolean,
    ): ClipboardEntry? {
        if (signatureHolds(entry)) return entry
        val padded = DotNetTimestamp.padded(entry.timestamp) ?: return null
        val restored = entry.copy(timestamp = padded)
        return if (signatureHolds(restored)) restored else null
    }
}
