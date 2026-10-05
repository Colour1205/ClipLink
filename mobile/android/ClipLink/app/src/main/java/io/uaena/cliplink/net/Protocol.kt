package io.uaena.cliplink.net

import io.uaena.cliplink.core.optStringOrNull
import io.uaena.cliplink.store.FileNames
import io.uaena.cliplink.store.FileStore
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
    const val TYPE_FILE_CHUNK = "file_chunk"
    const val TYPE_FILE_REQUEST = "file_request"

    /** Display names travel capped at this many Unicode code points, on every platform. */
    const val MAX_DEVICE_NAME_LENGTH = 64

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
        fun parse(json: String): Envelope? = try {
            val obj = JSONObject(json)
            val type = obj.optString("Type", "")
            if (type.isEmpty()) null else Envelope(type, obj.optString("Payload", ""))
        } catch (e: Exception) {
            null
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
        fun parse(json: String): FilePayload? = try {
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
        } catch (e: Exception) {
            null
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
        fun parse(json: String): FileChunkMessage? = try {
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
        } catch (e: Exception) {
            null
        }
    }
}

/** "Does anyone have this file?" - broadcast to every peer, never just the sender. */
data class FileRequestMessage(val fileHash: String) {
    fun toJson(): String = JSONObject().apply { put("FileHash", fileHash) }.toString()

    companion object {
        fun parse(json: String): FileRequestMessage? = try {
            JSONObject(json).optString("FileHash", "")
                .takeIf(FileStore::isValidHash)
                ?.let(::FileRequestMessage)
        } catch (e: Exception) {
            null
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
) {
    fun toJson(): String = JSONObject().apply {
        put("EphemeralPublicKey", ephemeralPublicKey)
        put("IdentityPublicKey", identityPublicKey)
        put("Signature", signature)
        passphraseProof?.let { put("PassphraseProof", it) }
        Protocol.normalizeDeviceName(deviceName)?.let { put("DeviceName", it) }
    }.toString()

    companion object {
        fun parse(json: String): HandshakeMessage? = try {
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
                )
            }
        } catch (e: Exception) {
            null
        }
    }
}

/** What a QR code / manual pairing string carries. [name] is optional - older codes have none. */
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
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return null
            return try {
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
            } catch (e: Exception) {
                null
            }
        }
    }
}
