package io.uaena.cliplink.ui

/**
 * Whether "Set passcode" / "Change passcode" is enabled. There is no minimum
 * length, by design (see docs): blank is the only thing refused. The engine
 * trims before deriving the key (so does every other platform), so a passcode
 * of nothing but spaces is blank. A key still being derived blocks it, so a
 * Change and a Clear can never cross.
 */
fun canSetPasscode(passcode: String, busy: Boolean): Boolean =
    !busy && passcode.isNotBlank()
