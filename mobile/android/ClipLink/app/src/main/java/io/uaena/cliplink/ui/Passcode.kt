package io.uaena.cliplink.ui

/**
 * Whether the two passcode fields hold the same passcode. Compared trimmed,
 * as the engine trims before deriving the key (so does every other platform):
 * a stray trailing space - an IME's autocomplete adds one - in one field must
 * not read as a mismatch between two passcodes that are, in effect, the same.
 */
fun passcodesMatch(passcode: String, confirmation: String): Boolean =
    passcode.trim() == confirmation.trim()

/**
 * Whether "Set passcode" / "Change passcode" is enabled. There is no minimum
 * length, by design (see docs): blank is the only thing refused, and a
 * mistyped one - the second field disagrees - is the other. A key still being
 * derived blocks it, so a Change and a Clear can never cross.
 */
fun canSetPasscode(passcode: String, confirmation: String, busy: Boolean): Boolean =
    !busy && passcode.isNotBlank() && passcodesMatch(passcode, confirmation)
