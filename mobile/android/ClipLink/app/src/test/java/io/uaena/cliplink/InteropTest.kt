package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.EcdsaDer
import io.uaena.cliplink.core.Pbkdf2
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.core.fixedTimeEquals
import io.uaena.cliplink.core.toHex
import io.uaena.cliplink.net.Discovery
import io.uaena.cliplink.net.HandshakeMessage
import io.uaena.cliplink.net.PairingInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.json.JSONObject
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * Covers the three places where this port has to agree byte-for-byte with the
 * Windows daemon, and where being wrong fails SILENTLY rather than loudly:
 * signature encoding, passcode key derivation, and the signed timestamp's
 * text. All three are plain JVM code with no Android dependency, so they can
 * actually be run here rather than only on a device.
 */
class InteropTest {

    // ---- ECDSA signature encoding ----------------------------------------

    @Test
    fun `der to raw round trips for many signatures`() {
        // Many iterations on purpose: the interesting DER cases are the ones
        // where r or s happens to have its high bit set (so DER adds a 0x00
        // pad) or happens to have leading zero bytes (so DER drops them).
        // Both are value-dependent, so a single signature proves nothing.
        val keyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }
        repeat(200) { i ->
            val data = "payload-$i".toByteArray()
            val signer = Signature.getInstance("SHA256withECDSA")
            signer.initSign(keyPair.private)
            signer.update(data)
            val der = signer.sign()

            val raw = EcdsaDer.derToRaw(der)
            assertEquals("raw signature must be fixed 64 bytes", 64, raw.size)

            // The real requirement: a raw signature converted back to DER must
            // still verify. This is exactly the path a peer's signature takes.
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(keyPair.public)
            verifier.update(data)
            assertTrue("round-tripped signature #$i must verify", verifier.verify(EcdsaDer.rawToDer(raw)))
        }
    }

    @Test
    fun `raw to der pads a high-bit value so it is not read as negative`() {
        // r with the top bit set must gain a leading 0x00 in DER.
        val raw = ByteArray(64).also { it[0] = 0xFF.toByte(); it[32] = 0x01 }
        val der = EcdsaDer.rawToDer(raw)
        assertEquals("SEQUENCE tag", 0x30.toByte(), der[0])
        assertEquals("INTEGER tag for r", 0x02.toByte(), der[2])
        assertEquals("r content must be padded to 33 bytes", 33, der[3].toInt())
        assertEquals("the pad byte itself", 0x00.toByte(), der[4])
        assertTrue(raw.contentEquals(EcdsaDer.derToRaw(der)))
    }

    @Test
    fun `raw to der strips leading zeros`() {
        // r = 1 must encode as a single-byte INTEGER, not 32 bytes of padding.
        val raw = ByteArray(64).also { it[31] = 0x01; it[63] = 0x02 }
        val der = EcdsaDer.rawToDer(raw)
        assertEquals("r content length", 1, der[3].toInt())
        assertTrue(raw.contentEquals(EcdsaDer.derToRaw(der)))
    }

    // ---- PBKDF2 -----------------------------------------------------------

    @Test
    fun `pbkdf2 hmac sha256 matches the published vectors`() {
        // Standard PBKDF2-HMAC-SHA256 vectors. If this port disagrees with
        // them it disagrees with .NET's Rfc2898DeriveBytes too, and two
        // devices given the same passcode would derive different keys - which
        // presents as "auto-trust just doesn't work", with nothing logged.
        val password = "password".toByteArray()
        val salt = "salt".toByteArray()
        assertEquals(
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
            Pbkdf2.deriveSha256(password, salt, 1, 32).toHex(),
        )
        assertEquals(
            "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
            Pbkdf2.deriveSha256(password, salt, 2, 32).toHex(),
        )
        assertEquals(
            "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
            Pbkdf2.deriveSha256(password, salt, 4096, 32).toHex(),
        )
    }

    @Test
    fun `pbkdf2 derives more than one block correctly`() {
        // keyLength > 32 exercises the T_2 branch, which the 32-byte vectors
        // above never reach. The first 32 bytes must be unchanged.
        val long = Pbkdf2.deriveSha256("password".toByteArray(), "salt".toByteArray(), 1, 40)
        assertEquals(40, long.size)
        assertTrue(long.toHex().startsWith("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"))
    }

    @Test
    fun `fixed time equals behaves like equals`() {
        assertTrue(fixedTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 3)))
        assertFalse(fixedTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 4)))
        assertFalse(fixedTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2)))
    }

    // ---- .NET round-trip timestamp ---------------------------------------

    @Test
    fun `timestamp matches dotnet round trip format exactly`() {
        // The signed bytes include this text verbatim, so the shape is not
        // cosmetic: seven fractional digits, a literal Z, no offset spelling.
        val timestamp = Signing.nowAsDotNetRoundTrip()
        val pattern = Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{7}Z$")
        assertTrue("got '$timestamp'", pattern.matches(timestamp))
    }

    @Test
    fun `timestamps sort chronologically as plain strings`() {
        // The history store's eviction and the synced list's ordering both
        // compare these as strings rather than parsing them. That is only
        // valid because the format is fixed-width and always UTC.
        val early = "2026-09-22T08:00:00.0000000Z"
        val later = "2026-09-22T08:00:00.0000001Z"
        val muchLater = "2026-09-22T09:00:00.0000000Z"
        assertTrue(early < later)
        assertTrue(later < muchLater)
    }

    // ---- beacon wire format ----------------------------------------------

    @Test
    fun `beacon parses the full five field form`() {
        val beacon = Discovery.parse("49000:SOMEKEY:SOMEPROOF:100.64.0.1:1", "192.168.1.5")
        checkNotNull(beacon)
        assertEquals(49000, beacon.tcpPort)
        assertEquals("SOMEKEY", beacon.deviceId)
        assertEquals("SOMEPROOF", beacon.proof)
        assertEquals("100.64.0.1", beacon.address)
        assertTrue(beacon.pairing)
        assertEquals("192.168.1.5", beacon.senderIp)
    }

    @Test
    fun `beacon treats dash as absent and tolerates the short form`() {
        val beacon = Discovery.parse("49000:SOMEKEY:-:-:-", "10.0.0.2")
        checkNotNull(beacon)
        assertNull(beacon.proof)
        assertNull(beacon.address)
        assertFalse(beacon.pairing)

        // An older three-field beacon must still parse rather than be dropped.
        val legacy = Discovery.parse("49000:SOMEKEY:-", "10.0.0.2")
        checkNotNull(legacy)
        assertNull(legacy.address)
        assertFalse(legacy.pairing)
    }

    @Test
    fun `beacon rejects malformed input instead of throwing`() {
        assertNull(Discovery.parse("", "10.0.0.2"))
        assertNull(Discovery.parse("garbage", "10.0.0.2"))
        assertNull(Discovery.parse("notaport:KEY:-", "10.0.0.2"))
        assertNull(Discovery.parse("49000::-", "10.0.0.2"))
    }

    @Test
    fun `a real base64 device id survives beacon splitting`() {
        // Device IDs are base64 SPKI. Splitting the beacon on ':' is only safe
        // because base64's alphabet has no colon - this pins that assumption.
        val deviceId = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEq7+B3n1uW9YPk/2Zx5Qh8Ttt9Ld" +
            "3rR2mXk1vYyQwJq0aB6cD8eF1gH2iJ3kL4mN5oP6qR7sT8uV9wX0yZ1a2b3=="
        assertFalse("base64 must never contain a colon", deviceId.contains(':'))
        val beacon = Discovery.parse("49000:$deviceId:-:-:-", "10.0.0.2")
        checkNotNull(beacon)
        assertEquals(deviceId, beacon.deviceId)
    }

    // ---- JSON null fields -------------------------------------------------

    // System.Text.Json writes an unset `string?` as an explicit null, and
    // Android's org.json optString reads that back as the text "null". These
    // pin that every optional field the daemon can null out reads as absent.

    @Test
    fun `pairing info with a null address has no address`() {
        // Exactly what the daemon's get_pairing_info emits with no Tailscale IP.
        val info = PairingInfo.parse("""{"PublicKey":"K","Address":null}""")
        checkNotNull(info)
        assertEquals("K", info.publicKey)
        assertNull(info.address)

        assertNull(PairingInfo.parse("""{"PublicKey":"K","Address":"  "}""")?.address)
        assertEquals("100.64.0.1", PairingInfo.parse("""{"PublicKey":"K","Address":"100.64.0.1"}""")?.address)
    }

    @Test
    fun `handshake with a null passphrase proof has no proof`() {
        // What the daemon sends when no passcode is set.
        val handshake = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","PassphraseProof":null}""",
        )
        checkNotNull(handshake)
        assertEquals("S", handshake.signature)
        assertNull(handshake.passphraseProof)
    }

    @Test
    fun `clipboard entry with a null signature has no signature`() {
        val entry = ClipboardEntry.fromJson(
            JSONObject("""{"Content":"hi","Type":"text","DeviceId":"D","Timestamp":"T","Signature":null}"""),
        )
        checkNotNull(entry)
        assertNull(entry.signature)

        // toJson itself writes an unsigned entry's Signature as JSON null, so
        // this is also what reloading one of our own entries goes through.
        val unsigned = ClipboardEntry("hi", ClipboardEntry.TYPE_TEXT, "D", "T")
        assertEquals(unsigned, ClipboardEntry.fromJson(JSONObject(unsigned.toJson().toString())))
    }
}
