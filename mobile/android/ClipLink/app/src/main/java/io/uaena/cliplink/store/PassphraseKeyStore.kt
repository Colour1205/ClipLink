package io.uaena.cliplink.store

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.Base64Codec
import io.uaena.cliplink.core.Pbkdf2
import io.uaena.cliplink.core.fixedTimeEquals
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
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
 * At rest the key is wrapped with an AES-GCM key that lives in the Android
 * Keystore (the same posture as the identity key, and what Windows does with
 * DPAPI), so what is in SharedPreferences - and in a backup of it, or a copy
 * of the app's data - is not the key itself. A key an earlier build stored in
 * the clear is wrapped the first time it is read. If the Keystore refuses, the
 * store falls back to what it always did - the key as base64 - and says so in
 * the log, rather than losing the passcode or crashing: the passcode that
 * stops working silently is worse than one stored plainly.
 */
class PassphraseKeyStore internal constructor(
    private val values: Values,
    private val wrapper: KeyWrapper?,
    private val codec: Base64Codec = B64,
) {

    constructor(context: Context) : this(
        PrefsValues(context.applicationContext.getSharedPreferences("cliplink_passphrase_key", Context.MODE_PRIVATE)),
        KeystoreKeyWrapper(),
    )

    /** Where a note goes when the Keystore couldn't be used - the Activity log. */
    @Volatile
    var onLog: ((String) -> Unit)? = null

    private val lock = Any()
    private var loaded = false
    private var cached: ByteArray? = null

    /** Whether a usable passcode key is stored - not merely something that is there but can't be read back. */
    fun hasPassphrase(): Boolean = key() != null

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

    fun saveKey(key: ByteArray) = synchronized(lock) {
        val wrapped = wrapOrNull(key)
        if (wrapped != null) {
            values.put(KEY_WRAPPED, wrapped)
            values.remove(KEY_PLAIN)
        } else {
            // The Keystore refused (or there is none): stored as before.
            values.put(KEY_PLAIN, codec.encode(key))
            values.remove(KEY_WRAPPED)
        }
        cached = key.copyOf()
        loaded = true
    }

    fun clearPassphrase(): Boolean = synchronized(lock) {
        val removedWrapped = values.remove(KEY_WRAPPED)
        val removedPlain = values.remove(KEY_PLAIN)
        cached = null
        loaded = true
        removedWrapped && removedPlain
    }

    /** The key, or null when there is none - or it can't be unwrapped, which is as good as none. Cached: no Keystore call per handshake. */
    fun key(): ByteArray? = synchronized(lock) {
        if (!loaded) {
            cached = readKey()
            loaded = true
        }
        cached?.copyOf()
    }

    private fun readKey(): ByteArray? {
        values.get(KEY_WRAPPED)?.takeIf { it.isNotEmpty() }?.let { wrapped ->
            return unwrapOrNull(wrapped)
        }
        // Stored in the clear, by a build before this one - or by this one,
        // when the Keystore wouldn't wrap it. Wrapped now if it will.
        val plain = codec.decodeOrNull(values.get(KEY_PLAIN)) ?: return null
        wrapOrNull(plain)?.let { wrapped ->
            // Only once it reads back: never leave a key that can't be recovered.
            if (unwrapOrNull(wrapped)?.contentEquals(plain) == true) {
                values.put(KEY_WRAPPED, wrapped)
                values.remove(KEY_PLAIN)
            }
        }
        return plain
    }

    private fun wrapOrNull(key: ByteArray): String? {
        val keyWrapper = wrapper ?: return null
        return try {
            WRAPPED_PREFIX + codec.encode(keyWrapper.wrap(key))
        } catch (e: Exception) {
            onLog?.invoke("passcode: couldn't protect the key with the Keystore (${e.javaClass.simpleName}) - stored as before")
            null
        }
    }

    private fun unwrapOrNull(stored: String): ByteArray? {
        val keyWrapper = wrapper
        if (keyWrapper == null || !stored.startsWith(WRAPPED_PREFIX)) return null
        return try {
            val blob = codec.decodeOrNull(stored.removePrefix(WRAPPED_PREFIX)) ?: return null
            keyWrapper.unwrap(blob)
        } catch (e: Exception) {
            // The Keystore key is gone (a restore onto another device, a
            // wiped lock screen) or the blob is damaged: no passcode, not a crash.
            onLog?.invoke("passcode: the saved key can't be unlocked (${e.javaClass.simpleName}) - set the passcode again")
            null
        }
    }

    /** HMAC-SHA256(key, deviceId), base64 - same shape as PassphraseAuth.ComputeProof. */
    fun computeProof(key: ByteArray, deviceId: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return codec.encode(mac.doFinal(deviceId.toByteArray(Charsets.UTF_8)))
    }

    fun verifyProof(key: ByteArray, deviceId: String, proofBase64: String?): Boolean {
        val actual = codec.decodeOrNull(proofBase64) ?: return false
        val expected = codec.decodeOrNull(computeProof(key, deviceId)) ?: return false
        return fixedTimeEquals(expected, actual)
    }

    /** The two strings this store keeps - a seam, so the wrapping can be tested without SharedPreferences. */
    internal interface Values {
        fun get(name: String): String?
        fun put(name: String, value: String)

        /** True when it is gone afterwards. */
        fun remove(name: String): Boolean
    }

    /** Wraps and unwraps the key bytes - the Keystore's AES-GCM, or a fake in tests. Throws if it can't. */
    internal interface KeyWrapper {
        fun wrap(plain: ByteArray): ByteArray
        fun unwrap(blob: ByteArray): ByteArray
    }

    private class PrefsValues(private val prefs: SharedPreferences) : Values {
        override fun get(name: String): String? = prefs.getString(name, null)
        override fun put(name: String, value: String) {
            prefs.edit().putString(name, value).commit()
        }

        override fun remove(name: String): Boolean = prefs.edit().remove(name).commit()
    }

    private companion object {
        /** Where earlier builds kept the key: base64, in the clear. Read once to be wrapped, and still the fallback. */
        const val KEY_PLAIN = "derived_key_base64"
        const val KEY_WRAPPED = "derived_key_wrapped"
        const val WRAPPED_PREFIX = "gcm1:"
        const val FIXED_SALT = "ClipboardDaemonPassphraseSaltV1"
        const val ITERATIONS = 210_000
        const val KEY_LEN_BYTES = 32
    }
}

/**
 * AES-256-GCM with a key that never leaves the Android Keystore. The blob is
 * `iv(12) || ciphertext || tag(16)`; the Keystore picks a fresh IV for every
 * wrap, as it must.
 */
internal class KeystoreKeyWrapper(private val alias: String = "cliplink-passcode-wrap") :
    PassphraseKeyStore.KeyWrapper {

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // Not setUserAuthenticationRequired: the key is needed in a
                // pocket, with the screen off, for the next handshake.
                .build(),
        )
        return generator.generateKey()
    }

    override fun wrap(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return cipher.iv + cipher.doFinal(plain)
    }

    override fun unwrap(blob: ByteArray): ByteArray {
        require(blob.size > IV_SIZE + TAG_BYTES) { "wrapped key too short" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BYTES * 8, blob, 0, IV_SIZE))
        return cipher.doFinal(blob, IV_SIZE, blob.size - IV_SIZE)
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
        const val TAG_BYTES = 16
    }
}
