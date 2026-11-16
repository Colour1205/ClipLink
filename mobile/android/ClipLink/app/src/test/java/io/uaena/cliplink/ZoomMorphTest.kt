package io.uaena.cliplink

import io.uaena.cliplink.ui.ZoomRect
import io.uaena.cliplink.ui.containRect
import io.uaena.cliplink.ui.contentShift
import io.uaena.cliplink.ui.cropSource
import io.uaena.cliplink.ui.startScale
import io.uaena.cliplink.ui.vanishRect
import io.uaena.cliplink.ui.zoomHeight
import io.uaena.cliplink.ui.zoomLerp
import io.uaena.cliplink.ui.zoomRadius
import io.uaena.cliplink.ui.zoomScale
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The zoom a card opens into its full view with: the view starts exactly on
 * the card and ends exactly on the page, one uniform scale, never a sharp
 * corner - the same sums as the HarmonyOS app's ZoomMorph.test.ets.
 */
class ZoomMorphTest {

    private val eps = 1e-3f

    // A grid card on a 1080 x 2400 page.
    private val card = ZoomRect(42f, 300f, 486f, 400f)
    private val pageW = 1080f
    private val pageH = 2400f

    @Test
    fun theScaleFollowsTheCardsWidth() {
        val s0 = startScale(card.w, pageW)
        assertEquals(0.45f, s0, eps)
        assertEquals(s0, zoomScale(s0, 0f), eps)
        assertEquals(1f, zoomScale(s0, 1f), eps)
        // On screen the view is exactly as wide as the card at the start.
        assertEquals(card.w, pageW * zoomScale(s0, 0f), eps)
    }

    @Test
    fun anUnmeasuredCardOrPageDoesNotScale() {
        assertEquals(1f, startScale(0f, pageW), eps)
        assertEquals(1f, startScale(card.w, 0f), eps)
    }

    @Test
    fun theHeightIsTheCardsAtTheStartAndThePagesAtTheEnd() {
        val s0 = startScale(card.w, pageW)
        // On screen (scaled), the card's own height.
        assertEquals(card.h, zoomHeight(card.h, pageH, s0, 0f) * zoomScale(s0, 0f), eps)
        assertEquals(pageH, zoomHeight(card.h, pageH, s0, 1f), eps)
    }

    @Test
    fun theCornersAreRoundedTheWholeWay() {
        val s0 = startScale(card.w, pageW)
        val cardRadius = 68f
        val pageRadius = 84f
        assertEquals(cardRadius, zoomRadius(cardRadius, pageRadius, s0, 0f) * zoomScale(s0, 0f), eps)
        assertEquals(pageRadius, zoomRadius(cardRadius, pageRadius, s0, 1f), eps)
        for (step in 0..20) {
            val p = step / 20f
            val onScreen = zoomRadius(cardRadius, pageRadius, s0, p) * zoomScale(s0, p)
            assert(onScreen >= minOf(cardRadius, pageRadius) - eps) { "radius $onScreen at $p" }
        }
    }

    @Test
    fun theContentRidesOnTheCardsTopThenSettlesInItsPlace() {
        // First block 240 px down the view (below its title bar); 42 px from the top while small.
        assertEquals(42f - 240f, contentShift(240f, 42f, 0f), eps)
        assertEquals(0f, contentShift(240f, 42f, 1f), eps)
        assertEquals((42f - 240f) / 2f, contentShift(240f, 42f, 0.5f), eps)
    }

    @Test
    fun aPictureFitsWholeIntoItsBox() {
        val box = ZoomRect(10f, 20f, 400f, 300f)
        // Wider than the box: full width, centred vertically.
        assertEquals(ZoomRect(10f, 70f, 400f, 200f), containRect(box, 2f))
        // Taller than the box: full height, centred horizontally.
        assertEquals(ZoomRect(135f, 20f, 150f, 300f), containRect(box, 0.5f))
        // Nothing to fit: the box itself.
        assertEquals(box, containRect(box, 0f))
        assertEquals(ZoomRect.Zero, containRect(ZoomRect.Zero, 1.5f))
    }

    @Test
    fun theFlyingPictureIsCroppedToItsBoxNeverSquashed() {
        // A 400 x 200 picture into a square box: its middle 200 x 200.
        assertEquals(ZoomRect(100f, 0f, 200f, 200f), cropSource(400, 200, 50f, 50f))
        // Into a box of its own shape: the whole of it.
        assertEquals(ZoomRect(0f, 0f, 400f, 200f), cropSource(400, 200, 100f, 50f))
        // A tall one into a wide box: a band across its middle.
        assertEquals(ZoomRect(0f, 150f, 200f, 100f), cropSource(200, 400, 100f, 50f))
        assertEquals(ZoomRect(0f, 0f, 400f, 200f), cropSource(400, 200, 0f, 50f))
    }

    @Test
    fun aViewWithNoCardShrinksToTheMiddle() {
        val to = vanishRect(pageW, pageH)
        assertEquals(pageW / 2f, to.x + to.w / 2f, eps)
        assertEquals(pageH / 2f, to.y + to.h / 2f, eps)
    }

    @Test
    fun rectanglesMoveInAStraightLine() {
        val from = ZoomRect(0f, 0f, 100f, 100f)
        val to = ZoomRect(100f, 200f, 300f, 500f)
        assertEquals(from, zoomLerp(from, to, 0f))
        assertEquals(to, zoomLerp(from, to, 1f))
        assertEquals(ZoomRect(50f, 100f, 200f, 300f), zoomLerp(from, to, 0.5f))
    }
}
