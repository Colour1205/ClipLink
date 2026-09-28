package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.net.Protocol
import org.json.JSONArray
import org.json.JSONObject

/** A device this one has agreed to sync with, plus the last address it was reachable at. */
data class TrustedDevice(
    val publicKey: String,
    val address: String? = null,
    /**
     * The latest display name it sent in a handshake or pairing, or null if
     * it never has. Never a name heard in a beacon - see engine/PeerNames.kt.
     */
    val name: String? = null,
)

/**
 * The list of devices allowed to send this one clipboard data. Mirrors the
 * Windows daemon's TrustStore.cs and the HarmonyOS port's TrustStore.ets,
 * including the same known gap: not encrypted at rest. That is deliberate
 * parity rather than an oversight - the trust store holds public keys, and
 * "fixing" it on one platform only would make the three implementations
 * diverge for no security gain.
 */
class TrustStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_trust_store", Context.MODE_PRIVATE)

    @Synchronized
    fun all(): List<TrustedDevice> {
        val json = prefs.getString(DEVICES_KEY, "[]") ?: "[]"
        return try {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull { i ->
                val obj = array.optJSONObject(i) ?: return@mapNotNull null
                val publicKey = obj.optString("publicKey", "")
                if (publicKey.isEmpty()) return@mapNotNull null
                val address = obj.optString("address", "").takeIf { it.isNotEmpty() }
                // Sanitised on the way out too, so a name stored by a build
                // that didn't strip control characters yet can't reach the
                // screen with them.
                val name = Protocol.normalizeDeviceName(obj.optString("name", ""))
                TrustedDevice(publicKey, address, name)
            }
        } catch (e: Exception) {
            // Corrupt value - regenerate rather than crash startup, the same
            // policy the Windows and HarmonyOS stores use.
            emptyList()
        }
    }

    @Synchronized
    private fun save(devices: List<TrustedDevice>) {
        val array = JSONArray()
        devices.forEach { device ->
            array.put(
                JSONObject().apply {
                    put("publicKey", device.publicKey)
                    device.address?.let { put("address", it) }
                    device.name?.let { put("name", it) }
                },
            )
        }
        prefs.edit().putString(DEVICES_KEY, array.toString()).commit()
    }

    /**
     * Upsert. An existing entry keeps its cached address when [address] is
     * null, so back-filling an address later never erases one - that
     * back-fill is what makes off-LAN reconnect work for a peer that was
     * originally paired in the other direction. [name] merges the same way:
     * null keeps whatever name is already stored.
     */
    @Synchronized
    fun trust(publicKey: String, address: String? = null, name: String? = null) {
        save(all().withTrusted(publicKey, address, name))
    }

    /**
     * Records the latest name an ALREADY trusted device sent in its
     * authenticated handshake - never one from a beacon, which anyone on the
     * network can forge. Never adds a device - a name heard from a stranger
     * is not a reason to trust it - never touches the address, and never
     * replaces a known name with an unknown one. Writes only on an actual
     * change, since this runs for every connection. Returns whether anything
     * changed.
     */
    @Synchronized
    fun rememberName(publicKey: String, name: String?): Boolean {
        val renamed = all().withName(publicKey, name) ?: return false
        save(renamed)
        return true
    }

    @Synchronized
    fun untrust(publicKey: String) = save(all().filterNot { it.publicKey == publicKey })

    fun isTrusted(publicKey: String): Boolean = all().any { it.publicKey == publicKey }

    fun withAddress(): List<TrustedDevice> = all().filter { !it.address.isNullOrEmpty() }

    private companion object {
        const val DEVICES_KEY = "trusted_devices"
    }
}

/**
 * [TrustStore.trust]'s merge, kept apart from SharedPreferences so the rules
 * are unit-testable: a null [address] keeps the cached one and a null or
 * blank [name] keeps the stored one, so an address update can never erase a
 * name and a name update can never erase an address.
 */
internal fun List<TrustedDevice>.withTrusted(
    publicKey: String,
    address: String?,
    name: String?,
): List<TrustedDevice> {
    val knownName = name?.takeIf { it.isNotBlank() }
    val index = indexOfFirst { it.publicKey == publicKey }
    if (index < 0) return this + TrustedDevice(publicKey, address, knownName)
    return toMutableList().also {
        it[index] = it[index].copy(
            address = address ?: it[index].address,
            name = knownName ?: it[index].name,
        )
    }
}

/**
 * [TrustStore.rememberName]'s merge: the renamed list, or null when there is
 * nothing to write - an unknown name, a device that isn't trusted, or the
 * name it already has.
 */
internal fun List<TrustedDevice>.withName(publicKey: String, name: String?): List<TrustedDevice>? {
    if (name.isNullOrBlank()) return null
    val index = indexOfFirst { it.publicKey == publicKey }
    if (index < 0 || this[index].name == name) return null
    return toMutableList().also { it[index] = it[index].copy(name = name) }
}
