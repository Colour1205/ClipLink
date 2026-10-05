package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.Pbkdf2
import io.uaena.cliplink.core.fixedTimeEquals
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The shared-passcode key: type the same passcode on two devices and they
 * auto-trust each other without any QR scan.
 *
 * Every constant below must match windows/ClipLink/Engine/Crypto/PassphraseAuth.cs
 * byte for byte - a different salt, iteration count or key length derives a
 * different key from the same passcode, and the two devices then silently
 * never match.
 *
 * Security level is kept at parity with the other two platforms rather than
 * unilaterally "improved": Windows keeps this DPAPI-encrypted at rest and
 * loads it as plain bytes in-process, HarmonyOS keeps it in Preferences.
 * Private SharedPreferences is the equivalent here.
 */
class PassphraseKeyStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_passphrase_key", Context.MODE_PRIVATE)

    fun hasPassphrase(): Boolean = !prefs.getString(KEY_KEY, null).isNullOrEmpty()

    /**
     * Runs 210,000 HMAC rounds - call this off the main thread. Derives only;
     * nothing is stored until [saveKey], so a caller can drop a key that a
     * Clear overtook while it was being derived.
     */
    fun deriveKey(passphrase: String): ByteArray = Pbkdf2.deriveSha256(
        passphrase.toByteArray(Charsets.UTF_8),
        FIXED_SALT.toByteArray(Charsets.UTF_8),
        ITERATIONS,
        KEY_LEN_BYTES,
    )

    fun saveKey(key: ByteArray) {
        prefs.edit().putString(KEY_KEY, B64.encode(key)).commit()
    }

    fun clearPassphrase() = prefs.edit().remove(KEY_KEY).commit()

    fun key(): ByteArray? = B64.decodeOrNull(prefs.getString(KEY_KEY, null))

    /** HMAC-SHA256(key, deviceId), base64 - same shape as PassphraseAuth.ComputeProof. */
    fun computeProof(key: ByteArray, deviceId: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return B64.encode(mac.doFinal(deviceId.toByteArray(Charsets.UTF_8)))
    }

    fun verifyProof(key: ByteArray, deviceId: String, proofBase64: String?): Boolean {
        val actual = B64.decodeOrNull(proofBase64) ?: return false
        val expected = B64.decode(computeProof(key, deviceId))
        return fixedTimeEquals(expected, actual)
    }

    private companion object {
        const val KEY_KEY = "derived_key_base64"
        const val FIXED_SALT = "ClipboardDaemonPassphraseSaltV1"
        const val ITERATIONS = 210_000
        const val KEY_LEN_BYTES = 32
    }
}
