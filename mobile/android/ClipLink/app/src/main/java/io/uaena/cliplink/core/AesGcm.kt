package io.uaena.cliplink.core

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Session transport encryption. AES-256-GCM, no AAD.
 *
 * Wire layout is `nonce(12) || tag(16) || ciphertext`, base64. Note the
 * order: the TAG COMES BEFORE THE CIPHERTEXT. The JCA appends the tag to the
 * ciphertext instead, so both directions have to splice it - that reordering
 * is the whole reason this file is not two one-liners. Getting it wrong
 * produces an AEADBadTagException on every single message, including from a
 * peer that is behaving perfectly.
 */
object AesGcm {
    private const val NONCE_SIZE = 12
    private const val TAG_SIZE = 16
    private const val TAG_BITS = TAG_SIZE * 8
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    private val random = SecureRandom()

    fun encrypt(sessionKey: ByteArray, plaintext: String): String = B64.encode(encryptPacked(sessionKey, plaintext))

    /** [encrypt] before the base64: `nonce(12) || tag(16) || ciphertext`. */
    fun encryptPacked(sessionKey: ByteArray, plaintext: String): ByteArray {
        val nonce = ByteArray(NONCE_SIZE).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(sessionKey, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        // JCA output is ciphertext || tag.
        val output = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        val cipherTextLength = output.size - TAG_SIZE
        val packed = ByteArray(NONCE_SIZE + TAG_SIZE + cipherTextLength)
        nonce.copyInto(packed, 0)
        output.copyInto(packed, NONCE_SIZE, cipherTextLength, output.size) // tag
        output.copyInto(packed, NONCE_SIZE + TAG_SIZE, 0, cipherTextLength) // ciphertext
        return packed
    }

    /** Throws on a corrupt, forged or truncated message - the caller treats that as a dead connection. */
    fun decrypt(sessionKey: ByteArray, packedBase64: String): String =
        decryptPacked(sessionKey, B64.decode(packedBase64))

    /** [decrypt] of a line already decoded from its base64. */
    fun decryptPacked(sessionKey: ByteArray, packed: ByteArray): String {
        require(packed.size >= NONCE_SIZE + TAG_SIZE) { "packed message too short" }
        val nonce = packed.copyOfRange(0, NONCE_SIZE)
        val tag = packed.copyOfRange(NONCE_SIZE, NONCE_SIZE + TAG_SIZE)
        val cipherText = packed.copyOfRange(NONCE_SIZE + TAG_SIZE, packed.size)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(sessionKey, "AES"),
            GCMParameterSpec(TAG_BITS, nonce),
        )
        // Back to the JCA's own ciphertext || tag ordering.
        return String(cipher.doFinal(cipherText + tag), Charsets.UTF_8)
    }
}
