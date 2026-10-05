package io.uaena.cliplink.core

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec

/**
 * This device's long-lived P-256 signing identity, held in the Android
 * Keystore so the private key never exists as bytes in this process - the
 * same posture as the HarmonyOS port's HUKS-backed key, and stronger than
 * the Windows daemon's DPAPI-encrypted file.
 *
 * The device ID *is* the public key: base64 of its X.509 SubjectPublicKeyInfo
 * DER, byte-identical to what `ECDsa.ExportSubjectPublicKeyInfo()` produces on
 * Windows and what HUKS exports on HarmonyOS, so the three platforms can
 * compare IDs as plain strings.
 */
class DeviceIdentity {

    private var cachedPublicKeyBase64: String? = null

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    /** Generates the identity key on first use; a no-op afterwards. */
    fun ensureKey() {
        val ks = keyStore()
        if (ks.containsAlias(KEY_ALIAS)) return
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            ANDROID_KEYSTORE,
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec(CURVE))
                .setDigests(KeyProperties.DIGEST_SHA256)
                // Deliberately NOT setUserAuthenticationRequired: sync has to
                // work while the phone is in a pocket. Locking signing behind
                // a biometric would mean every incoming entry stalls until the
                // user unlocks, which is not what this protocol does.
                .build(),
        )
        generator.generateKeyPair()
    }

    private fun privateKey(): PrivateKey {
        ensureKey()
        val entry = keyStore().getEntry(KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
        return entry.privateKey
    }

    /** Base64 X.509 SPKI DER - this device's ID on the wire. */
    fun publicKeyBase64(): String {
        cachedPublicKeyBase64?.let { return it }
        ensureKey()
        val certificate = keyStore().getCertificate(KEY_ALIAS)
        val encoded = B64.encode(certificate.publicKey.encoded)
        cachedPublicKeyBase64 = encoded
        return encoded
    }

    /**
     * Raw 64-byte `r || s` signature - the wire format. The JCA hands back
     * DER, hence the conversion (see [EcdsaDer]).
     */
    fun sign(data: ByteArray): ByteArray {
        val signature = Signature.getInstance(SIGNATURE_ALGORITHM)
        signature.initSign(privateKey())
        signature.update(data)
        return EcdsaDer.derToRaw(signature.sign())
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "cliplink-identity"
        private const val CURVE = "secp256r1"
        private const val SIGNATURE_ALGORITHM = "SHA256withECDSA"

        /**
         * Verifies a raw `r || s` signature against an arbitrary peer's
         * claimed identity key. Standalone rather than a method because the
         * key being checked is never this device's own.
         *
         * Returns false rather than throwing for every malformed input - a
         * hostile peer controls all of these bytes.
         */
        fun verifyRawSignature(
            peerPublicKeyBase64: String,
            data: ByteArray,
            rawSignature: ByteArray,
        ): Boolean {
            return try {
                val keyBytes = B64.decodeOrNull(peerPublicKeyBase64) ?: return false
                val publicKey: PublicKey = KeyFactory.getInstance("EC")
                    .generatePublic(X509EncodedKeySpec(keyBytes))
                val signature = Signature.getInstance(SIGNATURE_ALGORITHM)
                signature.initVerify(publicKey)
                signature.update(data)
                signature.verify(EcdsaDer.rawToDer(rawSignature))
            } catch (e: Exception) {
                false
            }
        }

        /**
         * Whether two device ids are one key, however each is spelt. B64
         * decodes text it doesn't fully understand - it skips anything that
         * isn't base64 - so comparing ids as strings only proves they're
         * different text. False when either isn't a P-256 key at all.
         */
        fun isSameKey(firstBase64: String, secondBase64: String): Boolean {
            val first = B64.decodeOrNull(firstBase64) ?: return false
            val second = B64.decodeOrNull(secondBase64) ?: return false
            return isSameKey(first, second)
        }

        /**
         * [isSameKey] of two SubjectPublicKeyInfo DERs: the same point on the
         * same curve, so even a DER written another way (explicit curve
         * parameters, say) is still the key it names.
         */
        internal fun isSameKey(firstSpki: ByteArray, secondSpki: ByteArray): Boolean = try {
            val factory = KeyFactory.getInstance("EC")
            val first = factory.generatePublic(X509EncodedKeySpec(firstSpki)) as ECPublicKey
            val second = factory.generatePublic(X509EncodedKeySpec(secondSpki)) as ECPublicKey
            first.w == second.w && first.params.curve == second.params.curve
        } catch (e: Exception) {
            false
        }
    }
}
