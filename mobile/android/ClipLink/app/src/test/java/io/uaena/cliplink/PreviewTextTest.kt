package io.uaena.cliplink

import io.uaena.cliplink.ui.CARD_TEXT_LIMIT
import io.uaena.cliplink.ui.previewTextOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** What a card (or the detail view) lays out of a text entry that may be megabytes long. */
class PreviewTextTest {

    @Test
    fun shortTextIsUntouched() {
        val text = "hello"

        assertSame(text, previewTextOf(text, CARD_TEXT_LIMIT))
    }

    @Test
    fun textExactlyAtTheLimitIsUntouched() {
        val text = "a".repeat(CARD_TEXT_LIMIT)

        assertSame(text, previewTextOf(text, CARD_TEXT_LIMIT))
    }

    @Test
    fun longTextIsCutToTheLimit() {
        val text = "a".repeat(5_000_000)

        val shown = previewTextOf(text, CARD_TEXT_LIMIT)

        assertEquals(CARD_TEXT_LIMIT, shown.length)
    }

    @Test
    fun aSurrogatePairIsNeverCutInHalf() {
        // U+1F600 is two chars; put its first half right at the cut.
        val text = "a".repeat(9) + "\uD83D\uDE00" + "b".repeat(20)

        val shown = previewTextOf(text, 10)

        assertEquals("a".repeat(9), shown)
        assertTrue(shown.none { Character.isSurrogate(it) })
    }

    @Test
    fun aPairThatFitsIsKept() {
        val text = "a".repeat(8) + "\uD83D\uDE00" + "b".repeat(20)

        assertEquals("a".repeat(8) + "\uD83D\uDE00", previewTextOf(text, 10))
    }

    @Test
    fun aZeroLimitGivesNothing() {
        assertEquals("", previewTextOf("abc", 0))
    }
}
