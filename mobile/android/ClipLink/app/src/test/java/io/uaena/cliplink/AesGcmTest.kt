package io.uaena.cliplink

import io.uaena.cliplink.core.AesGcm
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.fail
import org.junit.Test
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The session cipher splices the tag in place to save copies of large
 * messages; the wire layout, `nonce(12) || tag(16) || ciphertext`, must come
 * out exactly as the other platforms write and read it.
 */
class AesGcmTest {

    private val key = ByteArray(32).also { SecureRandom().nextBytes(it) }

    private fun jca(mode: Int, nonce: ByteArray, input: ByteArray): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            doFinal(input)
        }

    @Test
    fun `messages of every size round trip`() {
        for (text in listOf("", "x", "hello, wörld 😀", "line\nbreak", "a".repeat(100_000))) {
            val packed = AesGcm.encryptPacked(key, text)
            assertEquals(12 + 16 + text.toByteArray().size, packed.size)
            assertEquals(text, AesGcm.decryptPacked(key, packed))
        }
    }

    @Test
    fun `the packed layout is nonce then tag then ciphertext`() {
        val text = "the wire format is not negotiable"
        val packed = AesGcm.encryptPacked(key, text)
        val nonce = packed.copyOfRange(0, 12)
        val tag = packed.copyOfRange(12, 28)
        val cipherText = packed.copyOfRange(28, packed.size)

        // What a peer does: put the tag back on the end, as the JCA wants it.
        val plain = jca(Cipher.DECRYPT_MODE, nonce, cipherText + tag)
        assertEquals(text, String(plain, Charsets.UTF_8))
    }

    @Test
    fun `a message a peer packed the same way is read`() {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val text = "from another platform"
        val sealed = jca(Cipher.ENCRYPT_MODE, nonce, text.toByteArray()) // ciphertext || tag
        val cipherLength = sealed.size - 16
        val packed = nonce + sealed.copyOfRange(cipherLength, sealed.size) + sealed.copyOfRange(0, cipherLength)

        assertEquals(text, AesGcm.decryptPacked(key, packed))
    }

    @Test
    fun `a flipped bit anywhere is refused`() {
        val packed = AesGcm.encryptPacked(key, "do not tamper with this")
        for (index in listOf(0, 11, 12, 27, 28, packed.size - 1)) {
            val damaged = packed.copyOf().also { it[index] = (it[index].toInt() xor 1).toByte() }
            try {
                AesGcm.decryptPacked(key, damaged)
                fail("a change at byte $index should not decrypt")
            } catch (e: AEADBadTagException) {
                // right
            }
        }
    }

    @Test
    fun `a message too short to hold a nonce and a tag is refused`() {
        try {
            AesGcm.decryptPacked(key, ByteArray(27))
            fail("27 bytes can't be a message")
        } catch (e: IllegalArgumentException) {
            // right
        }
    }

    @Test
    fun `every encryption uses a fresh nonce`() {
        val first = AesGcm.encryptPacked(key, "same text")
        val second = AesGcm.encryptPacked(key, "same text")
        assertNotEquals(first.copyOf(12).toList(), second.copyOf(12).toList())
        assertArrayEquals(first.copyOfRange(0, 0), second.copyOfRange(0, 0))
    }
}
