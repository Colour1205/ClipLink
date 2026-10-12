package io.uaena.cliplink.net

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Base64

/**
 * A pairing code as a link: `https://cliplink.uaena.io/pair/#<the pairing info>`.
 *
 * The QR code carries this instead of the bare JSON, so a phone's own camera or
 * any scanner app that reads it opens the ClipLink app if it is installed (the
 * manifest's app link claims /pair) and the website, with the downloads, if it
 * is not. The pairing info - the same {PublicKey, Address, Name} JSON as ever -
 * is the part after the #, base64url without padding. A fragment is never sent
 * to a server, so the website never sees a device's address.
 *
 * Everything that takes pairing text in (the pair-by-address box, a pasted
 * code, a scan, a link that opened the app) accepts both the link and the bare
 * JSON: [PairingInfo.parse] unwraps. "Copy pairing info" still copies the bare
 * JSON. The same format is in every platform's app (Windows PairingLink.cs,
 * HarmonyOS PairingLink.ets, iOS PairingLink.swift): change them together.
 */
object PairingLink {
    const val PREFIX = "https://cliplink.uaena.io/pair/#"

    // http or https, with or without the slash after /pair; the host in any case.
    private val LINK = Regex("^https?://cliplink\\.uaena\\.io/pair/?#(.+)$", RegexOption.IGNORE_CASE)

    fun wrap(pairingJson: String): String =
        PREFIX + Base64.getUrlEncoder().withoutPadding().encodeToString(pairingJson.toByteArray(Charsets.UTF_8))

    /** Whether the text is a ClipLink pairing link (whatever its info turns out to hold). */
    fun isLink(text: String): Boolean = LINK.matchEntire(text.trim()) != null

    /**
     * The pairing info inside a link, or the text as it was: not a ClipLink
     * pairing link, or one whose info cannot be read.
     */
    fun unwrap(text: String): String {
        val info = LINK.matchEntire(text.trim())?.groupValues?.get(1) ?: return text
        return try {
            val bytes = Base64.getUrlDecoder().decode(info)
            val json = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
            json.ifEmpty { text }
        } catch (e: IllegalArgumentException) {
            text // not base64
        } catch (e: CharacterCodingException) {
            text // not UTF-8
        }
    }
}
