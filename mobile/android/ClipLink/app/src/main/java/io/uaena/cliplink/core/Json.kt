package io.uaena.cliplink.core

import kotlinx.coroutines.CancellationException
import org.json.JSONObject

/**
 * An optional string field: null when it is missing, empty, or JSON `null`.
 *
 * Use this, never `optString(name, "")`, for any field the other side may
 * leave unset. Android's org.json turns a JSON null into the four-character
 * string "null" rather than the fallback, and System.Text.Json on the Windows
 * daemon writes every unset `string?` property as an explicit null - so
 * PairingInfo.Address, HandshakeMessage.PassphraseProof and
 * ClipboardEntry.Signature would all read back as the text "null". (A pairing
 * code with no address then dials a host literally named "null".)
 */
fun JSONObject.optStringOrNull(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf { it.isNotEmpty() }

/**
 * Runs [block] on something a peer sent and gives null for whatever goes
 * wrong with it - Errors included. org.json is recursive, so a document
 * nested a few thousand levels deep throws StackOverflowError, and a huge one
 * OutOfMemoryError; neither is an Exception, so a plain `catch (e:
 * Exception)` lets them through to kill the process. A cancellation is never
 * swallowed.
 */
inline fun <T : Any> untrusted(block: () -> T?): T? = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: Throwable) {
    null
}

/**
 * Whether [json] nests objects or arrays deeper than [maxDepth] - checked by
 * a flat scan, before anything recursive touches it. Brackets inside strings
 * don't count.
 */
fun jsonNestsDeeperThan(json: CharSequence, maxDepth: Int): Boolean {
    var depth = 0
    var inString = false
    var escaped = false
    for (i in 0 until json.length) {
        val c = json[i]
        if (inString) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') inString = false
        } else when (c) {
            '"' -> inString = true
            '{', '[' -> if (++depth > maxDepth) return true
            '}', ']' -> depth--
        }
    }
    return false
}
