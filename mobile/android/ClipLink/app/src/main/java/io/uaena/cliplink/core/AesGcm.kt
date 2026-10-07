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
 *
 * The splice is done in place, in the one array that holds the message: a big
 * inline image goes through here, and each extra full copy of it is memory
 * the phone may not have.
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
        val input = plaintext.toByteArray(Charsets.UTF_8)
        val packed = ByteArray(NONCE_SIZE + cipher.getOutputSize(input.size))
        nonce.copyInto(packed, 0)
        // JCA output is ciphertext || tag, written straight after the nonce...
        val written = cipher.doFinal(input, 0, input.size, packed, NONCE_SIZE)
        val cipherTextLength = written - TAG_SIZE
        // ...and then the tag moves in front of the ciphertext.
        val tag = packed.copyOfRange(NONCE_SIZE + cipherTextLength, NONCE_SIZE + written)
        System.arraycopy(packed, NONCE_SIZE, packed, NONCE_SIZE + TAG_SIZE, cipherTextLength)
        tag.copyInto(packed, NONCE_SIZE)
        return packed
    }

    /** Throws on a corrupt, forged or truncated message - the caller treats that as a dead connection. */
    fun decrypt(sessionKey: ByteArray, packedBase64: String): String =
        decryptPacked(sessionKey, B64.decode(packedBase64))

    /**
     * [decrypt] of a line already decoded from its base64. [packed] is used as
     * scratch space - the tag is spliced to the end of it in place - so its
     * contents are unspecified afterwards; hand it a copy if it's wanted again.
     */
    fun decryptPacked(sessionKey: ByteArray, packed: ByteArray): String {
        require(packed.size >= NONCE_SIZE + TAG_SIZE) { "packed message too short" }
        val cipherTextLength = packed.size - NONCE_SIZE - TAG_SIZE
        // Back to the JCA's own ciphertext || tag ordering, in place.
        val tag = packed.copyOfRange(NONCE_SIZE, NONCE_SIZE + TAG_SIZE)
        System.arraycopy(packed, NONCE_SIZE + TAG_SIZE, packed, NONCE_SIZE, cipherTextLength)
        tag.copyInto(packed, NONCE_SIZE + cipherTextLength)

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(sessionKey, "AES"),
            GCMParameterSpec(TAG_BITS, packed, 0, NONCE_SIZE),
        )
        return String(cipher.doFinal(packed, NONCE_SIZE, cipherTextLength + TAG_SIZE), Charsets.UTF_8)
    }
}
