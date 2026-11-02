package io.uaena.cliplink

import androidx.compose.ui.geometry.Rect
import io.uaena.cliplink.ui.CARD_PRESS_MOVE_SLOP_DP
import io.uaena.cliplink.ui.MENU_LONG_PRESS_MS
import io.uaena.cliplink.ui.leavesPress
import io.uaena.cliplink.ui.placeCardMenu
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A card's long press and its menu: the same timing as HarmonyOS, and where
 * the menu goes beside the lifted card.
 */
class CardMenuTest {

    @Test
    fun `the menu opens well before the system long press`() {
        assertEquals(210L, MENU_LONG_PRESS_MS)
    }

    @Test
    fun `a finger that moves more than ten dp either way stops pressing the card`() {
        assertFalse(leavesPress(CARD_PRESS_MOVE_SLOP_DP, -CARD_PRESS_MOVE_SLOP_DP))
        assertTrue(leavesPress(10.5f, 0f))
        assertTrue(leavesPress(0f, -10.5f))
    }

    // A 1000 x 2000 px screen, 20 px of room around everything.

    @Test
    fun `the menu goes below the lifted card when it fits`() {
        val card = Rect(100f, 200f, 900f, 400f)
        val place = placeCardMenu(card, menuWidth = 300f, menuHeight = 400f, screenWidth = 1000f, screenHeight = 2000f, gap = 20f)
        assertFalse(place.above)
        assertEquals(0f, place.shift, 0f)
        // Lifted by 1.1 about its middle: its bottom edge is at 410.
        assertEquals(430f, place.menuY, 1e-3f)
        // Its left edge is at 60 once lifted, and the menu starts there.
        assertEquals(60f, place.menuX, 1e-3f)
    }

    @Test
    fun `the menu goes above the card when there is no room below`() {
        val card = Rect(100f, 1500f, 900f, 1800f)
        val place = placeCardMenu(card, menuWidth = 300f, menuHeight = 400f, screenWidth = 1000f, screenHeight = 2000f, gap = 20f)
        assertTrue(place.above)
        assertEquals(0f, place.shift, 0f)
        assertEquals(1485f - 20f - 400f, place.menuY, 1e-3f)
    }

    @Test
    fun `a card too tall for the menu either side moves up with the menu below it`() {
        val card = Rect(0f, 300f, 1000f, 1700f)
        val place = placeCardMenu(card, menuWidth = 300f, menuHeight = 400f, screenWidth = 1000f, screenHeight = 2000f, gap = 20f)
        assertFalse(place.above)
        assertTrue(place.shift < 0f)
        // The menu ends inside the screen...
        assertEquals(2000f - 20f, place.menuY + 400f, 1e-3f)
        // ...and is kept inside its sides.
        assertEquals(20f, place.menuX, 1e-3f)
    }

    @Test
    fun `the card never goes above the top of the screen for its menu`() {
        val card = Rect(0f, 100f, 1000f, 1900f)
        val place = placeCardMenu(card, menuWidth = 300f, menuHeight = 400f, screenWidth = 1000f, screenHeight = 2000f, gap = 20f)
        val liftedTop = 1000f - 1800f * 1.1f / 2f
        assertEquals(20f, liftedTop + place.shift, 1e-3f)
    }
}
