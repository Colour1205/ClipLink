package io.uaena.cliplink

import io.uaena.cliplink.ui.canSetPasscode
import io.uaena.cliplink.ui.passcodesMatch
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Me screen's passcode form: typed twice, any length, blank refused. */
class PasscodeTest {

    @Test
    fun identicalPasscodesMatch() {
        assertTrue(passcodesMatch("correct horse", "correct horse"))
    }

    @Test
    fun differentPasscodesDoNotMatch() {
        assertFalse(passcodesMatch("correct horse", "correct horsf"))
    }

    @Test
    fun caseMatters() {
        assertFalse(passcodesMatch("Secret", "secret"))
    }

    @Test
    fun aStrayTrailingSpaceIsNotAMismatch() {
        // The engine trims before deriving the key, so these are one passcode.
        assertTrue(passcodesMatch("secret ", "secret"))
    }

    @Test
    fun matchingPasscodesCanBeSet() {
        assertTrue(canSetPasscode("secret", "secret", busy = false))
    }

    @Test
    fun mismatchedPasscodesCannotBeSet() {
        assertFalse(canSetPasscode("secret", "secrte", busy = false))
        assertFalse(canSetPasscode("secret", "", busy = false))
    }

    @Test
    fun aBlankPasscodeCannotBeSetEvenIfBothAreBlank() {
        assertFalse(canSetPasscode("", "", busy = false))
        assertFalse(canSetPasscode("   ", "   ", busy = false))
    }

    @Test
    fun anyLengthIsAllowed() {
        // No minimum, by design - see the docs.
        assertTrue(canSetPasscode("a", "a", busy = false))
    }

    @Test
    fun aKeyStillBeingDerivedBlocksIt() {
        assertFalse(canSetPasscode("secret", "secret", busy = true))
    }
}
