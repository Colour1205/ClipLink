package io.uaena.cliplink.core

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
