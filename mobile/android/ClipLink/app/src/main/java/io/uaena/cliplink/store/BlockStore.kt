package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.Base64Codec
import io.uaena.cliplink.net.Protocol
import org.json.JSONArray
import org.json.JSONObject

/** A device this one refuses to hear from, with the name it had when it was blocked - what the Devices tab shows for it. */
data class BlockedDevice(
    val deviceId: String,
    val name: String? = null,
)

/** The one question the connection code asks the block list - a seam, so the handshake can be tested with a fake. */
fun interface BlockCheck {
    fun isBlocked(deviceId: String): Boolean
}

/**
 * The devices this one has blocked. A blocked device never gets a pairing
 * prompt, is never dialled, is never trusted by a shared passcode, and its
 * handshake is refused before anything else about it is decided - so it
 * can't be a source of spam, however often it asks.
 *
 * Blocking a device is blocking its KEY. Someone who generates a new
 * identity is a new device and is not stopped by this; what it does stop is
 * the usual case, one phone or PC that keeps asking.
 *
 * Mirrors the Windows engine's BlockStore and the other ports': a list of
 * device ids with the name each had when it was blocked. Not encrypted at
 * rest, same as the trust store beside it.
 */
class BlockStore(
    context: Context,
    private val codec: Base64Codec = B64,
) : BlockCheck {

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_block_store", Context.MODE_PRIVATE)

    /** Parsed once, then kept in step with every write: [isBlocked] runs for every beacon and every handshake. */
    private var cached: List<BlockedDevice>? = null

    @Synchronized
    fun all(): List<BlockedDevice> = cached ?: load().also { cached = it }

    private fun load(): List<BlockedDevice> {
        val json = prefs.getString(DEVICES_KEY, "[]") ?: "[]"
        return try {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull { i ->
                val obj = array.optJSONObject(i) ?: return@mapNotNull null
                val deviceId = obj.optString("deviceId", "")
                if (deviceId.isEmpty()) return@mapNotNull null
                BlockedDevice(deviceId, Protocol.normalizeDeviceName(obj.optString("name", "")))
            }
        } catch (e: Exception) {
            // Corrupt value - an empty list rather than a crash on startup, the
            // policy every store here follows.
            emptyList()
        }
    }

    @Synchronized
    private fun save(devices: List<BlockedDevice>) {
        val array = JSONArray()
        devices.forEach { device ->
            array.put(
                JSONObject().apply {
                    put("deviceId", device.deviceId)
                    device.name?.let { put("name", it) }
                },
            )
        }
        prefs.edit().putString(DEVICES_KEY, array.toString()).commit()
        cached = devices
    }

    /** Blocks [deviceId]; an existing entry keeps its name when [name] is null. */
    @Synchronized
    fun block(deviceId: String, name: String? = null) {
        save(all().withBlocked(deviceId, name, codec))
    }

    @Synchronized
    fun unblock(deviceId: String) {
        save(all().withoutBlocked(deviceId, codec))
    }

    override fun isBlocked(deviceId: String): Boolean = all().isBlockedDevice(deviceId, codec)

    private companion object {
        const val DEVICES_KEY = "blocked_devices"
    }
}

/**
 * Whether two device ids are the same key, however each is spelt. The real
 * base64 decoder skips anything that isn't base64, so one key can be written
 * with a space or a dot slipped in and still decode - and verify - as itself.
 * Compared as plain text only, that would be a way round the block list, so
 * when the text differs the decoded bytes are compared too. (The handshake
 * check against our own key goes further and compares the EC points; that is
 * too heavy for something that runs on every beacon.)
 */
internal fun sameDeviceId(first: String, second: String, codec: Base64Codec = B64): Boolean {
    if (first == second) return true
    val a = codec.decodeOrNull(first) ?: return false
    val b = codec.decodeOrNull(second) ?: return false
    return a.contentEquals(b)
}

internal fun List<BlockedDevice>.isBlockedDevice(deviceId: String, codec: Base64Codec = B64): Boolean =
    any { sameDeviceId(it.deviceId, deviceId, codec) }

/** [BlockStore.block]'s merge: added if new, otherwise the name is kept unless a better one is given. */
internal fun List<BlockedDevice>.withBlocked(
    deviceId: String,
    name: String?,
    codec: Base64Codec = B64,
): List<BlockedDevice> {
    val knownName = name?.takeIf { it.isNotBlank() }
    val index = indexOfFirst { sameDeviceId(it.deviceId, deviceId, codec) }
    if (index < 0) return this + BlockedDevice(deviceId, knownName)
    return toMutableList().also { it[index] = it[index].copy(name = knownName ?: it[index].name) }
}

internal fun List<BlockedDevice>.withoutBlocked(deviceId: String, codec: Base64Codec = B64): List<BlockedDevice> =
    filterNot { sameDeviceId(it.deviceId, deviceId, codec) }
