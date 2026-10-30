package io.uaena.cliplink.net

import io.uaena.cliplink.core.jsonNestsDeeperThan
import io.uaena.cliplink.core.optStringOrNull
import io.uaena.cliplink.core.untrusted
import io.uaena.cliplink.store.FileNames
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import org.json.JSONArray
import org.json.JSONObject

/**
 * Wire message shapes. Every field name here is PascalCase because that is
 * what System.Text.Json produces on the Windows daemon with its default
 * settings, and all three implementations parse each other's JSON literally.
 * Renaming one to idiomatic Kotlin camelCase breaks interop silently: the
 * field just reads back as absent.
 */
object Protocol {
    const val TCP_PORT = 49000
    const val UDP_PORT = 49000

    const val TYPE_ENTRY = "entry"
    const val TYPE_HISTORY_BATCH = "history_batch"

    /**
     * Sent just before a history_batch of two or more entries: its newest entry and its keys - see
     * [HistoryHead]. Between two v2 peers it is the whole opening of a sync instead - see [SyncHead].
     */
    const val TYPE_HISTORY_HEAD = "history_head"

    /** v2 only: "send me the entries with these keys" - answered with one history_batch. See [KeyListMessage]. */
    const val TYPE_HISTORY_REQUEST = "history_request"

    /** v2 only: "these items were deleted here, delete them too". See [KeyListMessage]. */
    const val TYPE_DELETE = "delete"
    const val TYPE_FILE_CHUNK = "file_chunk"
    const val TYPE_FILE_REQUEST = "file_request"

    /** "I no longer trust you": sent when a device is removed, or its pairing request ignored. */
    const val TYPE_UNPAIR = "unpair"

    /**
     * The sync protocol this build speaks, sent in the handshake. A connection speaks v2 only when both
     * sides sent 2 or more (see [versionOf] and [PeerLink.protocol]); with anything else it behaves
     * exactly as the builds before v2 do: a head, then the whole history as one history_batch.
     */
    const val VERSION = 2

    /** Display names travel capped at this many Unicode code points, on every platform. */
    const val MAX_DEVICE_NAME_LENGTH = 64

    /** Keys in a v2 history_head (the history cap), tombstone keys in it, and keys in a history_request or delete. */
    const val MAX_HEAD_KEYS = 25
    const val MAX_HEAD_DELETED = 500
    const val MAX_REQUEST_KEYS = 100

    /** A key longer than this is not one: a signature is a few hundred characters. */
    const val MAX_KEY_CHARS = 2048

    /**
     * What the handshake's `Protocol` field says: a whole number of 2 or more is taken as it is, and
     * anything else - absent, null, text, fractions, less than 2 - means 1, the builds that do not send it.
     */
    fun versionOf(raw: Any?): Int {
        val number = (raw as? Number)?.toDouble() ?: return 1
        if (number < 2.0 || number != Math.floor(number)) return 1
        return number.coerceAtMost(Int.MAX_VALUE.toDouble()).toInt()
    }

    /** [array]'s first [limit] elements that are usable keys: non-empty strings of at most [MAX_KEY_CHARS] characters. */
    fun cleanKeys(array: JSONArray?, limit: Int): List<String> {
        val keys = ArrayList<String>()
        if (array == null) return keys
        for (i in 0 until array.length()) {
            if (keys.size >= limit) break
            validKey(array.opt(i))?.let(keys::add)
        }
        return keys
    }

    internal fun validKey(raw: Any?): String? = (raw as? String)?.takeIf { it.isNotEmpty() && it.length <= MAX_KEY_CHARS }

    fun envelope(type: String, payload: String): String =
        JSONObject().apply {
            put("Type", type)
            put("Payload", payload)
        }.toString()

    /**
     * The one sanitiser for device names: control, bidi and zero-width
     * characters ([FileNames.isUnsafeChar] - the set a received file name
     * loses too) removed, then trimmed and capped at [MAX_DEVICE_NAME_LENGTH]
     * code points, or null when nothing is left. Applied to our own name before
     * it goes out AND to every name that comes in - beacon, handshake and
     * pairing code alike. A peer's name is self-claimed untrusted text: a
     * handshake line has no length limit of its own, and a right-to-left
     * override or a zero-width character is enough to make one name render
     * as another. Counted in code points rather than UTF-16 units so the cut
     * can never split a surrogate pair.
     */
    fun normalizeDeviceName(raw: String?): String? {
        val cleaned = buildString {
            raw?.codePoints()?.forEach { if (!FileNames.isUnsafeChar(it)) appendCodePoint(it) }
        }
        val trimmed = cleaned.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.codePointCount(0, trimmed.length) <= MAX_DEVICE_NAME_LENGTH) return trimmed
        return trimmed.substring(0, trimmed.offsetByCodePoints(0, MAX_DEVICE_NAME_LENGTH))
    }
}

/** `{Type, Payload}` - Payload is itself a JSON *string*, not a nested object. */
data class Envelope(val type: String, val payload: String) {
    companion object {
        fun parse(json: String): Envelope? = untrusted {
            val obj = JSONObject(json)
            val type = obj.optString("Type", "")
            if (type.isEmpty()) null else Envelope(type, obj.optString("Payload", ""))
        }
    }
}

/**
 * The small message that goes ahead of a big history_batch: the sender's
 * newest entry ([newest], signed like any entry) and the key of every entry in
 * the batch that follows ([keys], newest first - a key is the entry's
 * [ClipboardEntry.deletionKey]). It lets the receiver show the newest item,
 * and how many are coming, while the batch (megabytes, with pictures) is still
 * on its way. Builds that do not know it skip the type and use the batch alone.
 */
data class HistoryHead(val newest: ClipboardEntry, val keys: List<String>) {
    fun toJson(): String = JSONObject().apply {
        put("Newest", newest.toJson())
        put("Keys", JSONArray().also { array -> keys.forEach { array.put(it) } })
    }.toString()

    companion object {
        /** The head for a batch of [entries] (any order): the newest of them, and all their keys newest first. Null for none. */
        fun forBatch(entries: List<ClipboardEntry>): HistoryHead? {
            val newestFirst = entries.sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
            val newest = newestFirst.firstOrNull() ?: return null
            return HistoryHead(newest, newestFirst.map { it.deletionKey })
        }

        /** Null for anything without a readable entry and a list of keys. */
        fun parse(json: String): HistoryHead? = untrusted {
            val obj = JSONObject(json)
            val newest = obj.optJSONObject("Newest")?.let(ClipboardEntry::fromJson)
            val array = obj.optJSONArray("Keys")
            if (newest == null || array == null) {
                null
            } else {
                val keys = ArrayList<String>(array.length())
                for (i in 0 until array.length()) {
                    (array.opt(i) as? String)?.takeIf { it.isNotEmpty() }?.let(keys::add)
                }
                HistoryHead(newest, keys)
            }
        }
    }
}

/**
 * The history_head of a v2 connection (both sides sent `Protocol` 2): the opening of a sync, and the only
 * thing sent on connect. No entry and no batch go with it - the receiver asks for what it lacks with a
 * history_request. [keys] are the [ClipboardEntry.deletionKey] of the sender's history, newest first, at
 * most [Protocol.MAX_HEAD_KEYS]; [times] are those entries' timestamps in Unix milliseconds, in the same
 * order, or null when the sender left them out (or they do not line up with the keys); [deleted] are the
 * sender's tombstone keys, most recently deleted first, at most [Protocol.MAX_HEAD_DELETED].
 *
 * A v1.5 head's `Newest` is not read here: on a v2 connection it is ignored. Unknown keys and a missing
 * Times or Deleted are fine.
 */
data class SyncHead(val keys: List<String>, val times: List<Long>?, val deleted: List<String>) {
    fun toJson(): String = JSONObject().apply {
        put("Keys", JSONArray().also { array -> keys.forEach { array.put(it) } })
        times?.let { list -> put("Times", JSONArray().also { array -> list.forEach { array.put(it) } }) }
        put("Deleted", JSONArray().also { array -> deleted.forEach { array.put(it) } })
    }.toString()

    companion object {
        /** The head for [entries] (any order) and the [deleted] keys, most recent first. */
        fun forHistory(entries: List<ClipboardEntry>, deleted: List<String>): SyncHead {
            val newestFirst = entries
                .sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
                .take(Protocol.MAX_HEAD_KEYS)
            return SyncHead(
                keys = newestFirst.map { it.deletionKey },
                times = newestFirst.map { DotNetTimestamp.epochMillis(it.timestamp) ?: 0L },
                deleted = deleted.take(Protocol.MAX_HEAD_DELETED),
            )
        }

        /** Null for anything that is not a JSON object. A missing list of keys is an empty one. */
        fun parse(json: String): SyncHead? = untrusted {
            val obj = JSONObject(json)
            // No Keys is an empty list (the head may be only its Deleted), not a bad head.
            val rawKeys = obj.optJSONArray("Keys") ?: JSONArray()
            // Times only count when they line up with the keys as sent.
            val rawTimes = obj.optJSONArray("Times")?.takeIf { it.length() == rawKeys.length() }
            val keys = ArrayList<String>()
            val times = ArrayList<Long>()
            var timesUsable = rawTimes != null
            for (i in 0 until rawKeys.length()) {
                if (keys.size >= Protocol.MAX_HEAD_KEYS) break
                // A key that cannot be used takes its time with it, so the two lists stay in step.
                val key = Protocol.validKey(rawKeys.opt(i)) ?: continue
                keys.add(key)
                if (rawTimes != null) {
                    val time = rawTimes.opt(i)
                    if (time is Number) times.add(time.toLong()) else timesUsable = false
                }
            }
            SyncHead(
                keys = keys,
                times = if (timesUsable) times else null,
                deleted = Protocol.cleanKeys(obj.optJSONArray("Deleted"), Protocol.MAX_HEAD_DELETED),
            )
        }
    }
}

/**
 * `{"Keys":[...]}` - the payload of a history_request ("send me these") and of a delete ("these were
 * deleted"). At most [Protocol.MAX_REQUEST_KEYS] keys: a parser keeps the first of them and skips what is
 * not a usable key, a sender splits a longer list into several messages.
 */
data class KeyListMessage(val keys: List<String>) {
    fun toJson(): String = JSONObject().apply {
        put("Keys", JSONArray().also { array -> keys.forEach { array.put(it) } })
    }.toString()

    companion object {
        /** Null for anything that is not an object with a list of keys. */
        fun parse(json: String): KeyListMessage? = untrusted {
            val array = JSONObject(json).optJSONArray("Keys") ?: return@untrusted null
            KeyListMessage(Protocol.cleanKeys(array, Protocol.MAX_REQUEST_KEYS))
        }
    }
}

/**
 * What `ClipboardEntry.Content` holds when `Type == "file"` - a descriptor, never bytes.
 *
 * Every parser here refuses a FileHash that isn't 64 hex digits (see
 * [FileStore.isValidHash]): the hash becomes a path into the FileStore, and
 * a peer's "../shared_prefs/..." must never get that far. [parse] also
 * passes the sender's FileName through [FileNames.safe]: it names a file here
 * (see ClipboardBridge.contentUriFor), and it is shown as the item's title,
 * where a right-to-left override would make "invoice\u202Etxt.exe" read as
 * "invoiceexe.txt". Only the parsed copy changes - the signed entry is stored
 * and relayed exactly as it arrived.
 */
data class FilePayload(
    val fileName: String,
    val fileHash: String,
    val fileSize: Long,
) {
    /**
     * A 0-byte file, whose bytes are known without asking anyone - see
     * [FileStore.storeEmpty]. Its hash as well as its size, so an entry can't
     * make an empty blob of anything but the one hash an empty file has.
     */
    val isEmptyFile: Boolean
        get() = fileSize == 0L && fileHash.equals(FileStore.EMPTY_FILE_HASH, ignoreCase = true)

    fun toJson(): String = JSONObject().apply {
        put("FileName", fileName)
        put("FileHash", fileHash)
        put("FileSize", fileSize)
    }.toString()

    companion object {
        fun parse(json: String): FilePayload? = untrusted {
            val obj = JSONObject(json)
            val hash = obj.optString("FileHash", "")
            if (!FileStore.isValidHash(hash)) {
                null
            } else {
                FilePayload(
                    fileName = FileNames.safe(obj.optString("FileName", ""), "file"),
                    fileHash = hash,
                    fileSize = obj.optLong("FileSize", 0L),
                )
            }
        }
    }
}

data class FileChunkMessage(
    val fileHash: String,
    val chunkIndex: Int,
    val isLast: Boolean,
    val dataBase64: String,
) {
    fun toJson(): String = JSONObject().apply {
        put("FileHash", fileHash)
        put("ChunkIndex", chunkIndex)
        put("IsLast", isLast)
        put("DataBase64", dataBase64)
    }.toString()

    companion object {
        fun parse(json: String): FileChunkMessage? = untrusted {
            val obj = JSONObject(json)
            val hash = obj.optString("FileHash", "")
            if (!FileStore.isValidHash(hash)) {
                null
            } else {
                FileChunkMessage(
                    fileHash = hash,
                    chunkIndex = obj.optInt("ChunkIndex", 0),
                    isLast = obj.optBoolean("IsLast", false),
                    dataBase64 = obj.optString("DataBase64", ""),
                )
            }
        }
    }
}

/** "Does anyone have this file?" - broadcast to every peer, never just the sender. */
data class FileRequestMessage(val fileHash: String) {
    fun toJson(): String = JSONObject().apply { put("FileHash", fileHash) }.toString()

    companion object {
        fun parse(json: String): FileRequestMessage? = untrusted {
            JSONObject(json).optString("FileHash", "")
                .takeIf(FileStore::isValidHash)
                ?.let(::FileRequestMessage)
        }
    }
}

/**
 * The one unencrypted line each side writes before anything else. Both sides
 * write first and then read - there is no client/server role in the
 * handshake.
 */
data class HandshakeMessage(
    val ephemeralPublicKey: String,
    val identityPublicKey: String,
    val signature: String,
    val passphraseProof: String?,
    /**
     * The sender's display name. Optional on the wire - older builds neither
     * send it nor expect it - and self-claimed, so it is only ever a label,
     * never part of any trust decision.
     */
    val deviceName: String? = null,
    /**
     * The sync protocol the sender speaks - see [Protocol.VERSION]; 1 when the field is absent. Not signed
     * (the signature covers only the ephemeral key, as before), so a man in the middle can strip it. That
     * only makes the connection speak v1, which is the safe fallback, never anything worse.
     */
    val protocol: Int = Protocol.VERSION,
) {
    fun toJson(): String = JSONObject().apply {
        put("EphemeralPublicKey", ephemeralPublicKey)
        put("IdentityPublicKey", identityPublicKey)
        put("Signature", signature)
        passphraseProof?.let { put("PassphraseProof", it) }
        Protocol.normalizeDeviceName(deviceName)?.let { put("DeviceName", it) }
        put("Protocol", protocol)
    }.toString()

    companion object {
        /** The real handshake is flat. Anything nested deeper than this is refused before org.json recurses into it. */
        private const val MAX_NESTING = 8

        /**
         * Null for anything that isn't a handshake - and never throws, Errors
         * included: this runs on a line from a stranger, before any trust
         * check, and a StackOverflowError from deeply nested JSON would not be
         * caught by `catch (e: Exception)`.
         */
        fun parse(json: String): HandshakeMessage? = untrusted {
            if (jsonNestsDeeperThan(json, MAX_NESTING)) return@untrusted null
            val obj = JSONObject(json)
            val ephemeral = obj.optString("EphemeralPublicKey", "")
            val identity = obj.optString("IdentityPublicKey", "")
            val signature = obj.optString("Signature", "")
            if (ephemeral.isEmpty() || identity.isEmpty() || signature.isEmpty()) {
                null
            } else {
                HandshakeMessage(
                    ephemeralPublicKey = ephemeral,
                    identityPublicKey = identity,
                    signature = signature,
                    passphraseProof = obj.optStringOrNull("PassphraseProof"),
                    deviceName = Protocol.normalizeDeviceName(obj.optStringOrNull("DeviceName")),
                    protocol = Protocol.versionOf(obj.opt("Protocol")),
                )
            }
        }
    }
}

/**
 * What a QR code / manual pairing string carries. [name] is optional - older
 * codes have none. The QR code wraps it as a link (see [PairingLink]); [parse]
 * takes the link or the bare JSON.
 */
data class PairingInfo(val publicKey: String, val address: String?, val name: String? = null) {
    fun toJson(): String = JSONObject().apply {
        put("PublicKey", publicKey)
        address?.takeIf { it.isNotEmpty() }?.let { put("Address", it) }
        Protocol.normalizeDeviceName(name)?.let { put("Name", it) }
    }.toString()

    companion object {
        /**
         * Only recognizes the {PublicKey,Address} JSON payload a pairing
         * screen's QR/"copy pairing info" produces - returns null for
         * anything else (including a bare address), rather than guessing.
         * A bare non-JSON string used to be treated as a bare public key
         * (matching the Windows daemon's legacy trust_device CLI
         * convention), but that's wrong for THIS app: PairScreen's own
         * hint text explicitly invites "just its IP address if it's
         * reachable", and there was never anything useful to do with a
         * bare key alone anyway (no address means nothing to dial). See
         * ClipLinkEngine.pairWith for how a non-JSON input is actually
         * handled - as a literal address, not a key.
         */
        fun parse(raw: String): PairingInfo? {
            // A pairing link (what the QR code carries) holds the JSON.
            val trimmed = PairingLink.unwrap(raw).trim()
            if (trimmed.isEmpty()) return null
            return untrusted {
                val obj = JSONObject(trimmed)
                val key = obj.optString("PublicKey", "")
                if (key.isEmpty()) {
                    null
                } else {
                    PairingInfo(
                        key,
                        obj.optStringOrNull("Address")?.takeIf { it.isNotBlank() },
                        Protocol.normalizeDeviceName(obj.optStringOrNull("Name")),
                    )
                }
            }
        }
    }
}
