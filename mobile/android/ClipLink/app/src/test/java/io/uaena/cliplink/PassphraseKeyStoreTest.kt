package io.uaena.cliplink

import io.uaena.cliplink.core.Base64Codec
import io.uaena.cliplink.store.PassphraseKeyStore
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * The passcode key at rest: wrapped by a Keystore key (a fake here), a
 * plaintext key from an earlier build wrapped on first read, and a Keystore
 * that fails falling back to the old behaviour with a note - never a lost
 * passcode, never a crash.
 */
class PassphraseKeyStoreTest {

    private class MemoryValues : PassphraseKeyStore.Values {
        val map = mutableMapOf<String, String>()
        override fun get(name: String): String? = map[name]
        override fun put(name: String, value: String) {
            map[name] = value
        }

        override fun remove(name: String): Boolean {
            map.remove(name)
            return true
        }
    }

    private val codec = object : Base64Codec {
        override fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
        override fun decodeOrNull(text: String?): ByteArray? =
            if (text.isNullOrEmpty()) null else try { Base64.getDecoder().decode(text) } catch (e: IllegalArgumentException) { null }
    }

    /** XOR with a pad: not secure, but a blob that is visibly not the key, and one that a different wrapper can't open. */
    private class XorWrapper(private val pad: Byte = 0x5A, var failWrap: Boolean = false, var failUnwrap: Boolean = false) :
        PassphraseKeyStore.KeyWrapper {
        var wraps = 0
        var unwraps = 0
        override fun wrap(plain: ByteArray): ByteArray {
            if (failWrap) throw java.security.ProviderException("keystore says no")
            wraps++
            return byteArrayOf(0x01) + ByteArray(plain.size) { (plain[it].toInt() xor pad.toInt()).toByte() }
        }

        override fun unwrap(blob: ByteArray): ByteArray {
            if (failUnwrap) throw java.security.GeneralSecurityException("key permanently invalidated")
            unwraps++
            return ByteArray(blob.size - 1) { (blob[it + 1].toInt() xor pad.toInt()).toByte() }
        }
    }

    private val key = ByteArray(32) { (it * 3 + 1).toByte() }
    private val keyBase64 = Base64.getEncoder().encodeToString(key)
    private val logs = mutableListOf<String>()

    private fun store(values: MemoryValues, wrapper: PassphraseKeyStore.KeyWrapper?) =
        PassphraseKeyStore(values, wrapper, codec).also { it.onLog = { message -> logs.add(message) } }

    @Test
    fun `a saved key is stored wrapped, not as the key`() {
        val values = MemoryValues()
        val store = store(values, XorWrapper())

        store.saveKey(key)

        assertEquals(setOf("derived_key_wrapped"), values.map.keys)
        assertFalse(values.map.values.any { it.contains(keyBase64) })
        assertArrayEquals(key, store.key())
        assertTrue(store.hasPassphrase())
        // A fresh instance - the next launch - reads it back through the wrapper.
        assertArrayEquals(key, store(values, XorWrapper()).key())
    }

    @Test
    fun `a key an earlier build stored in the clear is wrapped on first read and the plain copy removed`() {
        val values = MemoryValues().apply { put("derived_key_base64", keyBase64) }
        val wrapper = XorWrapper()

        assertArrayEquals(key, store(values, wrapper).key())

        assertEquals(setOf("derived_key_wrapped"), values.map.keys)
        assertFalse(values.map.containsKey("derived_key_base64"))
        // And it still reads, from the wrapped copy alone.
        assertArrayEquals(key, store(values, XorWrapper()).key())
    }

    @Test
    fun `the plain copy stays if the wrapped one wouldn't read back`() {
        val values = MemoryValues().apply { put("derived_key_base64", keyBase64) }
        // Wraps fine, but unwrap hands back something else: never swap a good key for that.
        val lying = object : PassphraseKeyStore.KeyWrapper {
            override fun wrap(plain: ByteArray) = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
            override fun unwrap(blob: ByteArray) = ByteArray(32)
        }
        assertArrayEquals(key, store(values, lying).key())
        assertTrue(values.map.containsKey("derived_key_base64"))
        assertFalse(values.map.containsKey("derived_key_wrapped"))
    }

    @Test
    fun `when the Keystore refuses to wrap, the key is stored as before and the failure is logged`() {
        val values = MemoryValues()
        val store = store(values, XorWrapper(failWrap = true))

        store.saveKey(key)

        assertEquals(setOf("derived_key_base64"), values.map.keys)
        assertArrayEquals(key, store.key()) // works - the passcode is not lost
        assertTrue(logs.any { it.contains("Keystore") })
        // An existing plain key with a Keystore that refuses is simply used.
        val plain = MemoryValues().apply { put("derived_key_base64", keyBase64) }
        assertArrayEquals(key, store(plain, XorWrapper(failWrap = true)).key())
        assertTrue(plain.map.containsKey("derived_key_base64"))
    }

    @Test
    fun `with no Keystore at all the store still works`() {
        val values = MemoryValues()
        val store = store(values, null)
        store.saveKey(key)
        assertEquals(setOf("derived_key_base64"), values.map.keys)
        assertArrayEquals(key, store(values, null).key())
    }

    @Test
    fun `a wrapped key the Keystore can't open reads as no passcode, not a crash`() {
        val values = MemoryValues()
        store(values, XorWrapper()).saveKey(key)

        val broken = store(values, XorWrapper(failUnwrap = true))
        assertNull(broken.key())
        assertFalse(broken.hasPassphrase())
        assertTrue(logs.any { it.contains("can't be unlocked") })
        // Setting a passcode again repairs it.
        broken.saveKey(key)
        assertArrayEquals(key, store(values, XorWrapper()).key())
    }

    @Test
    fun `garbage in the wrapped value reads as no passcode`() {
        val values = MemoryValues().apply { put("derived_key_wrapped", "gcm1:!!!not base64!!!") }
        assertNull(store(values, XorWrapper()).key())
        values.put("derived_key_wrapped", "something else entirely")
        assertNull(store(values, XorWrapper()).key())
    }

    @Test
    fun `clearing removes the key from both places and from memory`() {
        val values = MemoryValues().apply { put("derived_key_base64", keyBase64) }
        val store = store(values, XorWrapper())
        assertNotNull(store.key())

        assertTrue(store.clearPassphrase())

        assertTrue(values.map.isEmpty())
        assertNull(store.key())
        assertFalse(store.hasPassphrase())
    }

    @Test
    fun `the key is unwrapped once, not on every handshake`() {
        val values = MemoryValues()
        val wrapper = XorWrapper()
        store(values, wrapper).saveKey(key)

        val store = store(values, wrapper)
        repeat(50) { store.key() }
        assertEquals(1, wrapper.unwraps)
    }

    @Test
    fun `a returned key can't be used to change the stored one`() {
        val store = store(MemoryValues(), XorWrapper())
        store.saveKey(key)
        store.key()!!.fill(0)
        assertArrayEquals(key, store.key())
    }

    @Test
    fun `proofs still match the daemon's shape`() {
        val store = store(MemoryValues(), XorWrapper())
        val proof = store.computeProof(key, "device-id")
        assertTrue(store.verifyProof(key, "device-id", proof))
        assertFalse(store.verifyProof(key, "other-device", proof))
        assertFalse(store.verifyProof(key, "device-id", null))
        assertFalse(store.verifyProof(key, "device-id", "!!"))
    }
}
