package io.uaena.cliplink.core

/**
 * IPv4 addresses, strictly. The one place that decides what text may go out
 * as this device's own address - in the beacon, where a stray ':' shifts
 * every colon-split field after it, and in the pairing code - and what is
 * accepted as one.
 *
 * IPv6 is not accepted: its text is full of colons, which the beacon format
 * can't carry without an encoding all the other platforms would have to
 * learn too. The Tailscale address this is for is the IPv4 one (`tailscale ip
 * -4`), as on Windows.
 */
object Ipv4 {

    /** [text]'s dotted-quad form, or null when it isn't one: four decimal numbers 0-255, no leading zeros, nothing else. */
    fun normalize(text: String?): String? {
        val parts = text?.trim()?.split('.') ?: return null
        if (parts.size != 4) return null
        val octets = parts.map { part ->
            if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
            if (part.length > 1 && part[0] == '0') return null // "010" is octal to some parsers, decimal to others
            part.toInt().takeIf { it in 0..255 } ?: return null
        }
        return octets.joinToString(".")
    }
}
