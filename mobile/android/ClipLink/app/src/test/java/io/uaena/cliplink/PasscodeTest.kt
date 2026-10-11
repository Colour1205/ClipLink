package io.uaena.cliplink

import io.uaena.cliplink.ui.canSetPasscode
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Me screen's passcode form: one field, any length, blank refused. */
class PasscodeTest {

    @Test
    fun aPasscodeCanBeSet() {
        assertTrue(canSetPasscode("correct horse", busy = false))
    }

    @Test
    fun aBlankPasscodeCannotBeSet() {
        assertFalse(canSetPasscode("", busy = false))
        assertFalse(canSetPasscode("   ", busy = false))
    }

    @Test
    fun aPasscodeWithSpacesAroundItCanBeSet() {
        // The engine trims before deriving the key, so this is just "secret".
        assertTrue(canSetPasscode(" secret ", busy = false))
    }

    @Test
    fun anyLengthIsAllowed() {
        // No minimum, by design - see the docs.
        assertTrue(canSetPasscode("a", busy = false))
    }

    @Test
    fun aKeyStillBeingDerivedBlocksIt() {
        assertFalse(canSetPasscode("secret", busy = true))
    }
}
