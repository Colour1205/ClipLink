package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.core.EcdsaDer
import io.uaena.cliplink.core.Pbkdf2
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.core.fixedTimeEquals
import io.uaena.cliplink.core.toHex
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.engine.PeerNames
import io.uaena.cliplink.engine.displayNameOf
import io.uaena.cliplink.engine.fingerprintOf
import io.uaena.cliplink.engine.shortIdOf
import io.uaena.cliplink.net.Discovery
import io.uaena.cliplink.net.HandshakeMessage
import io.uaena.cliplink.net.PairingInfo
import io.uaena.cliplink.net.Protocol
import io.uaena.cliplink.store.TrustedDevice
import io.uaena.cliplink.store.withName
import io.uaena.cliplink.store.withTrusted
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
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

    @Test
    fun `generated timestamp never ends in a zero digit`() {
        // A trailing zero is what the Windows daemon's JSON serializer trims
        // when it relays an entry, so avoiding one keeps the signed text
        // byte-identical for peers that only verify the raw string.
        repeat(1000) {
            val timestamp = Signing.nowAsDotNetRoundTrip()
            assertFalse("got '$timestamp'", timestamp.endsWith("0Z"))
        }
    }

    // ---- timestamps trimmed in transit by the Windows daemon ---------------

    @Test
    fun `trimmed timestamp pads back to the seven digits dotnet signed`() {
        assertEquals(
            "2026-09-26T12:34:56.1234500Z",
            DotNetTimestamp.padded("2026-09-26T12:34:56.12345Z"),
        )
    }

    @Test
    fun `fractionless timestamp pads to seven zeros`() {
        assertEquals(
            "2026-09-26T12:34:56.0000000Z",
            DotNetTimestamp.padded("2026-09-26T12:34:56Z"),
        )
    }

    @Test
    fun `padding keeps the suffix and leaves everything else alone`() {
        assertEquals(
            "2026-09-26T12:34:56.1000000+08:00",
            DotNetTimestamp.padded("2026-09-26T12:34:56.1+08:00"),
        )
        assertEquals("2026-09-26T12:34:56.0000000", DotNetTimestamp.padded("2026-09-26T12:34:56"))
        // Already seven digits: nothing was trimmed, nothing to add.
        assertNull(DotNetTimestamp.padded("2026-09-26T12:34:56.1234500Z"))
        // Not a shape .NET writes.
        assertNull(DotNetTimestamp.padded("2026-09-26T12:34:56.12345678Z"))
        assertNull(DotNetTimestamp.padded("2026-09-26 12:34:56Z"))
        assertNull(DotNetTimestamp.padded("2026-09-26T12:34:56Z\n"))
        assertNull(DotNetTimestamp.padded(""))
    }

    @Test
    fun `canonical form sorts trimmed timestamps chronologically`() {
        // As raw strings "...:56Z" sorts AFTER "...:56.5Z" because 'Z' > '.'.
        val whole = "2026-09-26T12:34:56Z"
        val half = "2026-09-26T12:34:56.5Z"
        assertTrue("raw comparison is the bug", whole > half)
        assertTrue(DotNetTimestamp.canonical(whole) < DotNetTimestamp.canonical(half))
        // And both spellings of one instant compare equal.
        assertEquals(
            DotNetTimestamp.canonical("2026-09-26T12:34:56.12345Z"),
            DotNetTimestamp.canonical("2026-09-26T12:34:56.1234500Z"),
        )
    }

    @Test
    fun `entry signed over seven digits verifies after the fraction is trimmed`() {
        val signer = TestSigner()
        val signed = signer.sign("2026-09-26T12:34:56.1234500Z")
        val received = signed.copy(timestamp = "2026-09-26T12:34:56.12345Z")

        assertFalse("the raw text alone must not verify", signer.holds(received))
        val verified = Signing.verified(received, signer::holds)
        checkNotNull(verified)
        // Stored and relayed with the signed text, so every platform verifies it.
        assertEquals("2026-09-26T12:34:56.1234500Z", verified.timestamp)
        assertEquals(signed, verified)
    }

    @Test
    fun `entry signed over seven digits verifies after the fraction is dropped`() {
        val signer = TestSigner()
        val signed = signer.sign("2026-09-26T12:34:56.0000000Z")
        val received = signed.copy(timestamp = "2026-09-26T12:34:56Z")

        assertFalse("the raw text alone must not verify", signer.holds(received))
        val verified = Signing.verified(received, signer::holds)
        checkNotNull(verified)
        assertEquals("2026-09-26T12:34:56.0000000Z", verified.timestamp)
    }

    @Test
    fun `an untrimmed timestamp verifies as received`() {
        val signer = TestSigner()
        val signed = signer.sign("2026-09-26T12:34:56.1234567Z")
        assertSame(signed, Signing.verified(signed, signer::holds))
    }

    @Test
    fun `padding never rescues a signature over different text`() {
        val signer = TestSigner()
        // Signed over the trimmed text itself, so the padded form is NOT what
        // was signed - but the raw form is, and must still verify first.
        val trimmedSigned = signer.sign("2026-09-26T12:34:56.12345Z")
        assertSame(trimmedSigned, Signing.verified(trimmedSigned, signer::holds))

        // A different instant, trimmed or not, stays rejected.
        val signed = signer.sign("2026-09-26T12:34:56.1234500Z")
        assertNull(Signing.verified(signed.copy(timestamp = "2026-09-26T12:34:56.12346Z"), signer::holds))
        // And so does another key's signature, even over the padded text.
        assertNull(Signing.verified(signed.copy(timestamp = "2026-09-26T12:34:56.12345Z"), TestSigner()::holds))
    }

    /** A plain-JVM stand-in for a peer's identity key; B64 and the keystore need Android. */
    private class TestSigner {
        private val keyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }

        fun sign(timestamp: String): ClipboardEntry {
            val unsigned = ClipboardEntry("héllo", ClipboardEntry.TYPE_TEXT, "SOMEDEVICE", timestamp)
            val signature = Signature.getInstance("SHA256withECDSA").run {
                initSign(keyPair.private)
                update(Signing.signableData(unsigned))
                sign()
            }
            return unsigned.copy(signature = signature.toHex())
        }

        fun holds(entry: ClipboardEntry): Boolean = Signature.getInstance("SHA256withECDSA").run {
            initVerify(keyPair.public)
            update(Signing.signableData(entry))
            verify(hexToBytes(checkNotNull(entry.signature)))
        }

        private fun hexToBytes(hex: String): ByteArray =
            ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
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

    // ---- beacon name field ------------------------------------------------

    @Test
    fun `beacon parses the six field form with a name`() {
        // "Colour's PC: 8 ✨" - a colon and a non-ASCII character, both of
        // which only survive the colon split because the field is base64.
        val beacon = Discovery.parse("49000:SOMEKEY:-:100.64.0.1:1:Q29sb3VyJ3MgUEM6IDgg4pyo", "192.168.1.5")
        checkNotNull(beacon)
        assertEquals("Colour's PC: 8 ✨", beacon.name)
        // ...and the fields before it are unaffected.
        assertEquals("100.64.0.1", beacon.address)
        assertTrue(beacon.pairing)
        assertEquals("192.168.1.5", beacon.senderIp)
    }

    @Test
    fun `beacon without a usable name field still parses with no name`() {
        // Five fields: every build from before names existed.
        assertNull(checkNotNull(Discovery.parse("49000:SOMEKEY:-:-:-", "10.0.0.2")).name)
        assertNull(checkNotNull(Discovery.parse("49000:SOMEKEY:-:-:1", "10.0.0.2")).name)
        assertNull(checkNotNull(Discovery.parse("49000:SOMEKEY:-", "10.0.0.2")).name)
        // Explicitly unknown, or empty.
        assertNull(checkNotNull(Discovery.parse("49000:SOMEKEY:-:-:-:-", "10.0.0.2")).name)
        assertNull(checkNotNull(Discovery.parse("49000:SOMEKEY:-:-:-:", "10.0.0.2")).name)
    }

    @Test
    fun `beacon with a malformed name keeps the beacon and drops only the name`() {
        // Not base64 at all.
        val badBase64 = Discovery.parse("49000:SOMEKEY:PROOF:-:1:@@not base64@@", "10.0.0.2")
        checkNotNull(badBase64)
        assertNull(badBase64.name)
        assertEquals("PROOF", badBase64.proof)
        assertTrue(badBase64.pairing)
        // Valid base64 of bytes that are not valid UTF-8 (FF FE FD).
        val badUtf8 = Discovery.parse("49000:SOMEKEY:-:-:-://79", "10.0.0.2")
        checkNotNull(badUtf8)
        assertNull(badUtf8.name)
        // Base64 of nothing but whitespace is no name either.
        assertNull(checkNotNull(Discovery.parse("49000:SOMEKEY:-:-:-:ICAg", "10.0.0.2")).name)
    }

    @Test
    fun `beacon build always writes six fields and round trips`() {
        val named = Discovery.build(49000, "SOMEKEY", null, null, false, "Pixel 8")
        // The pairing field is written as "-" rather than left off, so the
        // name is always at index 5 for every receiver.
        assertEquals("49000:SOMEKEY:-:-:-:UGl4ZWwgOA==", named)
        assertEquals("Pixel 8", checkNotNull(Discovery.parse(named, "10.0.0.2")).name)

        assertEquals("49000:SOMEKEY:P:100.64.0.1:1:-", Discovery.build(49000, "SOMEKEY", "P", "100.64.0.1", true, null))
        assertEquals("49000:SOMEKEY:-:-:-:-", Discovery.build(49000, "SOMEKEY", null, null, false, "   "))

        val unicode = "Colour's PC: 8 ✨"
        assertEquals(
            unicode,
            Discovery.parse(Discovery.build(49000, "SOMEKEY", null, null, false, unicode), "")?.name,
        )
    }

    @Test
    fun `device names are trimmed and capped at 64 code points`() {
        assertEquals("Pixel 8", Protocol.normalizeDeviceName("  Pixel 8 \n"))
        assertNull(Protocol.normalizeDeviceName("   "))
        assertNull(Protocol.normalizeDeviceName(""))
        assertNull(Protocol.normalizeDeviceName(null))

        assertEquals("a".repeat(64), Protocol.normalizeDeviceName("a".repeat(100)))
        assertEquals("a".repeat(64), Protocol.normalizeDeviceName("a".repeat(64)))

        // Counted in code points: 64 emoji are 128 UTF-16 units, and the cut
        // must neither stop at 32 emoji nor split a surrogate pair.
        val capped = checkNotNull(Protocol.normalizeDeviceName("😀".repeat(70)))
        assertEquals(64, capped.codePointCount(0, capped.length))
        assertEquals("😀".repeat(64), capped)

        // Capped BEFORE encoding: what goes out decodes to at most 64.
        val sent = Discovery.parse(Discovery.build(49000, "K", null, null, false, "b".repeat(80)), "")
        assertEquals("b".repeat(64), sent?.name)
    }

    @Test
    fun `device names lose control bidi and zero width characters`() {
        val unsafe = (0x00..0x1F) + (0x7F..0x9F) + 0x061C + (0x200B..0x200F) +
            (0x202A..0x202E) + (0x2066..0x2069) + 0xFEFF
        for (codePoint in unsafe) {
            val name = "a" + String(Character.toChars(codePoint)) + "b"
            assertEquals("U+%04X".format(codePoint), "ab", Protocol.normalizeDeviceName(name))
        }
        // A right-to-left override is how one name renders as another.
        assertEquals("Colour's PC", Protocol.normalizeDeviceName("\u202EColour's PC\u202C"))
        // Stripped, THEN trimmed: spaces the controls were hiding go too...
        assertEquals("Pixel 8", Protocol.normalizeDeviceName("\u200E Pixel 8 \u2069"))
        assertNull(Protocol.normalizeDeviceName("\u202E\u200B\u0007"))
        // ...then capped, so they can't use up any of the 64.
        assertEquals("a".repeat(64), Protocol.normalizeDeviceName("\u200B".repeat(10) + "a".repeat(70)))
        // Everything else is left alone: combining marks, emoji, CJK.
        assertEquals("e\u0301 😀 我", Protocol.normalizeDeviceName("e\u0301 😀 我"))

        // Every way a peer's name comes in goes through it: beacon, handshake, pairing code.
        val beaconField = java.util.Base64.getEncoder()
            .encodeToString("Pixel\u202E 8\u0000".toByteArray(Charsets.UTF_8))
        assertEquals("Pixel 8", Discovery.parse("49000:K:-:-:-:$beaconField", "10.0.0.2")?.name)
        val handshake = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"Pixel\u202E 8\n"}""",
        )
        assertEquals("Pixel 8", handshake?.deviceName)
        assertEquals("Pixel 8", PairingInfo.parse("""{"PublicKey":"K","Name":"\u2067Pixel 8\u200B"}""")?.name)
    }

    @Test
    fun `beacon name field matches the other platforms byte for byte`() {
        // Golden values from the Windows daemon's Discovery.EncodeName; the
        // HarmonyOS and iOS encoders produce the same strings.
        val colour = "Colour's PC: \uD83C\uDFA7 \u00FCn\u00EFc\u00F6d\u00E9"
        assertEquals("Q29sb3VyJ3MgUEM6IPCfjqcgw7xuw69jw7Zkw6k=", Discovery.encodeName(colour))
        assertEquals(colour, Discovery.decodeName("Q29sb3VyJ3MgUEM6IPCfjqcgw7xuw69jw7Zkw6k="))
        assertEquals("5oiR55qE5omL5py6", Discovery.encodeName("\u6211\u7684\u624B\u673A"))
        // 64 code points: 64 emoji rather than 32 (UTF-16 units)...
        assertEquals("8J+YgPCfmIDwn5iA".repeat(21) + "8J+YgA==", Discovery.encodeName("\uD83D\uDE00".repeat(70)))
        // ...and 64 code points rather than 64 visible characters.
        assertEquals("ZcyB".repeat(32), Discovery.encodeName("e\u0301".repeat(40)))
    }

    @Test
    fun `handshake and pairing code read the daemon's escaped names`() {
        // System.Text.Json escapes everything outside ASCII, and the apostrophe.
        val handshake = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","PassphraseProof":null,"DeviceName":"Colour\u0027s PC: \uD83C\uDFA7 \u00FCn\u00EFc\u00F6d\u00E9"}""",
        )
        assertEquals("Colour's PC: \uD83C\uDFA7 \u00FCn\u00EFc\u00F6d\u00E9", handshake?.deviceName)
        val pairing = PairingInfo.parse("""{"PublicKey":"K","Address":null,"Name":"\u6211\u7684\u624B\u673A"}""")
        assertEquals("\u6211\u7684\u624B\u673A", pairing?.name)
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

    // ---- device names in the handshake and pairing code --------------------

    @Test
    fun `handshake carries a device name when there is one`() {
        val handshake = HandshakeMessage.parse(
            """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"  Colour's PC  "}""",
        )
        checkNotNull(handshake)
        assertEquals("Colour's PC", handshake.deviceName)
    }

    @Test
    fun `handshake without a usable device name still parses`() {
        // Absent: every build from before names existed.
        val absent = HandshakeMessage.parse("""{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S"}""")
        checkNotNull(absent)
        assertNull(absent.deviceName)
        // Null (System.Text.Json's unset string?), empty and blank.
        for (value in listOf("null", "\"\"", "\"   \"")) {
            val handshake = HandshakeMessage.parse(
                """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":$value}""",
            )
            checkNotNull(handshake)
            assertNull("DeviceName $value", handshake.deviceName)
        }
    }

    @Test
    fun `handshake writes DeviceName only when known and round trips it`() {
        val named = HandshakeMessage("E", "I", "S", null, deviceName = "Pixel 8 ✨")
        assertEquals("Pixel 8 ✨", JSONObject(named.toJson()).getString("DeviceName"))
        assertEquals(named, HandshakeMessage.parse(named.toJson()))

        // Left off entirely rather than written as null, like PassphraseProof.
        val unnamed = HandshakeMessage("E", "I", "S", null)
        assertFalse(JSONObject(unnamed.toJson()).has("DeviceName"))
        assertNull(HandshakeMessage.parse(unnamed.toJson())?.deviceName)

        // Capped on the way out too.
        val long = HandshakeMessage("E", "I", "S", null, deviceName = "c".repeat(90))
        assertEquals("c".repeat(64), HandshakeMessage.parse(long.toJson())?.deviceName)
    }

    @Test
    fun `pairing info name is optional`() {
        assertEquals("Pixel 8", PairingInfo.parse("""{"PublicKey":"K","Address":null,"Name":"Pixel 8"}""")?.name)
        assertNull(PairingInfo.parse("""{"PublicKey":"K","Address":"100.64.0.1"}""")?.name)
        assertNull(PairingInfo.parse("""{"PublicKey":"K","Name":null}""")?.name)

        val info = PairingInfo("K", "100.64.0.1", "Pixel 8")
        assertEquals(info, PairingInfo.parse(info.toJson()))
        assertFalse(JSONObject(PairingInfo("K", null).toJson()).has("Name"))
    }

    // ---- trust record merges ------------------------------------------------

    @Test
    fun `trust updates never let an address erase a name or a name erase an address`() {
        val start = listOf(TrustedDevice("A", "10.0.0.1", "Laptop"), TrustedDevice("B"))
        // Address-only, as every call site from before names passes it.
        assertEquals(TrustedDevice("A", "10.0.0.9", "Laptop"), start.withTrusted("A", "10.0.0.9", null)[0])
        // Name only: the cached address stays.
        assertEquals(TrustedDevice("A", "10.0.0.1", "Desk"), start.withTrusted("A", null, "Desk")[0])
        // Nothing new known: nothing erased.
        assertEquals(start, start.withTrusted("A", null, null))
        assertEquals(start, start.withTrusted("A", null, "  "))
        // A new device, with or without a name.
        assertEquals(TrustedDevice("C", null, "Phone"), start.withTrusted("C", null, "Phone").last())
        assertEquals(TrustedDevice("C", "10.0.0.3", null), start.withTrusted("C", "10.0.0.3", "").last())
    }

    @Test
    fun `remembering a name only renames an already trusted device`() {
        val start = listOf(TrustedDevice("A", "10.0.0.1", "Laptop"), TrustedDevice("B", "10.0.0.2"))
        assertEquals(TrustedDevice("A", "10.0.0.1", "Desk"), start.withName("A", "Desk")?.get(0))
        assertEquals(TrustedDevice("B", "10.0.0.2", "Tablet"), start.withName("B", "Tablet")?.get(1))
        // Null means "nothing to write": same name, unknown name, or a stranger.
        assertNull(start.withName("A", "Laptop"))
        assertNull(start.withName("A", null))
        assertNull(start.withName("A", ""))
        assertNull(start.withName("Z", "Stranger"))
    }

    // ---- beacon names never reach the trust store ---------------------------

    @Test
    fun `a beacon name is shown but never persisted`() {
        val names = PeerNames()
        names.heardInBeacon("A", "Laptop")
        names.heardInBeacon("A", "Laptop") // the same name again
        names.heardInBeacon("A", "Evil twin") // and a different one
        // Unauthenticated, so nothing to write - however often it repeats or changes.
        assertNull(names.persistable("A"))
        // Shown for a device that isn't trusted, or is but has no stored name...
        assertEquals("Evil twin", names.display("A", null))
        // ...but never over a trusted device's stored name.
        assertEquals("Desk", names.display("A", "Desk"))
        assertNull(names.display("B", null))
    }

    @Test
    fun `only a handshake name is persisted and a beacon can't displace it`() {
        val names = PeerNames()
        names.heardInBeacon("A", "From a beacon")
        names.heardInHandshake("A", "Pixel 8")
        assertEquals("Pixel 8", names.persistable("A"))
        assertEquals("Pixel 8", names.display("A", null))

        // A later beacon claiming another name changes neither.
        names.heardInBeacon("A", "Spoofed")
        assertEquals("Pixel 8", names.persistable("A"))
        assertEquals("Pixel 8", names.display("A", null))
        // Nor does an older build's nameless handshake blank it out.
        names.heardInHandshake("A", null)
        assertEquals("Pixel 8", names.persistable("A"))
    }

    // ---- how an id is shown -------------------------------------------------

    @Test
    fun `an id is shown by the same fingerprint iOS shows`() {
        // SHA-256("abc") starts ba7816bf - the FIPS 180-2 test vector.
        assertEquals("BA78·16BF", fingerprintOf("abc"))
        assertEquals("Device BA78·16BF", shortIdOf("abc"))
        // Every P-256 id starts with the same 36 characters, so a prefix
        // would label these two alike; the fingerprint doesn't.
        val spkiPrefix = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE"
        assertEquals("Device E601·FFD9", displayNameOf(spkiPrefix + "aaaa", null))
        assertEquals("Device BD03·7086", displayNameOf(spkiPrefix + "bbbb", " "))
        assertEquals("Pixel 8", displayNameOf(spkiPrefix + "aaaa", "Pixel 8"))
    }

    // ---- device list order --------------------------------------------------

    @Test
    fun `device rows sort trusted first then by name then by id`() {
        fun row(id: String, name: String?, trusted: Boolean, connected: Boolean = false, seen: Long? = null) =
            DeviceRow(id, name, trusted, connected, emptyList(), pairing = false, lastSeenAtMs = seen)

        val rows = listOf(
            row("id-9", null, trusted = false),
            row("id-8", "zeta", trusted = false, connected = true, seen = 999),
            row("id-7", "Alpha", trusted = false),
            row("id-6", null, trusted = true, seen = 5),
            row("id-5", null, trusted = true, connected = true),
            row("id-4", "bravo", trusted = true),
            row("id-3", "Bravo", trusted = true, seen = 1_000_000),
            row("id-2", "alpha", trusted = true),
        )
        val expected = listOf("id-2", "id-3", "id-4", "id-5", "id-6", "id-7", "id-8", "id-9")
        assertEquals(expected, rows.sortedWith(DeviceRow.STABLE_ORDER).map { it.deviceId })
        // Any input order gives the same result - nothing depends on arrival.
        assertEquals(expected, rows.reversed().sortedWith(DeviceRow.STABLE_ORDER).map { it.deviceId })
        assertEquals(expected, rows.shuffled(java.util.Random(7)).sortedWith(DeviceRow.STABLE_ORDER).map { it.deviceId })
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
