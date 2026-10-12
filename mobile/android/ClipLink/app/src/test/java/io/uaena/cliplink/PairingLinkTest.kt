package io.uaena.cliplink

import io.uaena.cliplink.net.PairingInfo
import io.uaena.cliplink.net.PairingLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pairing QR code is a link to the website's /pair page with the pairing info
 * after the # (see PairingLink). The vector below was made by the Windows app's
 * PairingLink.cs; every platform has to read it, and make it the same way.
 */
class PairingLinkTest {

    private val json =
        """{"PublicKey":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEexample+/key==","Address":"100.101.102.103","Name":"我的电脑 PC"}"""

    private val windowsLink =
        "https://cliplink.uaena.io/pair/#eyJQdWJsaWNLZXkiOiJNRmt3RXdZSEtvWkl6ajBDQVFZSUtvWkl6ajBEQVFjRFFnQUVleGFtcGxlKy9rZXk9PSIsIkFkZHJlc3MiOiIxMDAuMTAxLjEwMi4xMDMiLCJOYW1lIjoi5oiR55qE55S16ISRIFBDIn0"

    @Test
    fun `makes the same link the Windows app does`() {
        assertEquals(windowsLink, PairingLink.wrap(json))
    }

    @Test
    fun `reads the link the Windows app makes`() {
        assertEquals(json, PairingLink.unwrap(windowsLink))
    }

    @Test
    fun `a link and its info round trip, non-ASCII names included`() {
        val info = """{"PublicKey":"K","Name":"Pixel 8 我的"}"""
        assertEquals(info, PairingLink.unwrap(PairingLink.wrap(info)))
    }

    @Test
    fun `http, upper case and a missing slash are still the link`() {
        val info = windowsLink.removePrefix(PairingLink.PREFIX)
        assertEquals(json, PairingLink.unwrap("HTTP://CLIPLINK.UAENA.IO/pair#$info"))
        assertEquals(json, PairingLink.unwrap("  https://cliplink.uaena.io/pair/#$info\n"))
        // Padding is not needed, but not wrong either (this info needs one =).
        assertEquals(json, PairingLink.unwrap("https://cliplink.uaena.io/pair/#$info="))
    }

    @Test
    fun `anything else is left as it was`() {
        for (text in listOf(
            json,
            "192.168.1.20",
            "192.168.1.20:49000",
            "https://example.com/pair/#abc",
            "https://cliplink.uaena.io/",
            "https://cliplink.uaena.io/pair/",
            "https://cliplink.uaena.io/pair/#!!!",
            "https://cliplink.uaena.io/pair/#_w", // base64 of a lone 0xFF: not UTF-8
        )) {
            assertEquals(text, PairingLink.unwrap(text))
        }
    }

    @Test
    fun `isLink tells a pairing link from other text`() {
        assertTrue(PairingLink.isLink(windowsLink))
        assertTrue(PairingLink.isLink("https://cliplink.uaena.io/pair#abc"))
        assertFalse(PairingLink.isLink("https://cliplink.uaena.io/"))
        assertFalse(PairingLink.isLink("https://cliplink.uaena.io/download#abc"))
        assertFalse(PairingLink.isLink("https://evil.example/pair/#abc"))
        assertFalse(PairingLink.isLink(json))
    }

    @Test
    fun `the pairing info parser takes the link and the bare JSON alike`() {
        val fromLink = PairingInfo.parse(windowsLink)
        assertNotNull(fromLink)
        assertEquals("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEexample+/key==", fromLink!!.publicKey)
        assertEquals("100.101.102.103", fromLink.address)
        assertEquals("我的电脑 PC", fromLink.name)
        assertEquals(fromLink, PairingInfo.parse(json))
        assertNull(PairingInfo.parse("https://cliplink.uaena.io/pair/#!!!"))
    }

    @Test
    fun `a code made by this app reads back through the link`() {
        val made = PairingInfo("KEY", "100.64.0.1", "Pixel").toJson()
        assertEquals(PairingInfo.parse(made), PairingInfo.parse(PairingLink.wrap(made)))
    }
}
