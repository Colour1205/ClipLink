package io.uaena.cliplink.ui

/*
 * The arithmetic of the zoom a card opens into its full view with, and closes
 * back by (see CardZoom), kept apart from Compose so the unit tests can run it.
 * The HarmonyOS app's ZoomMorph.ets does the same sums.
 *
 * The full view is laid out once, at full size, and the whole of it is scaled
 * down onto the tapped card and up again: its text grows with the card instead
 * of being uncovered by a shape that grows over it. One uniform scale, so
 * nothing is ever squashed: the scale follows the card's width, and the view's
 * height is cut to the card's at the start and grows to the page's. A picture
 * flies on its own, from where it sits on the card to where it sits in the
 * full view.
 *
 * Everything is in px, from the top-left of the page the zoom runs over; p is
 * 0 at the card and 1 at the full view.
 */

/** A rectangle in px. */
internal data class ZoomRect(val x: Float, val y: Float, val w: Float, val h: Float) {
    val right: Float get() = x + w
    val bottom: Float get() = y + h

    companion object {
        val Zero = ZoomRect(0f, 0f, 0f, 0f)
    }
}

/** Where a value is at [p]. */
internal fun zoomLerp(from: Float, to: Float, p: Float): Float = from + (to - from) * p

internal fun zoomLerp(from: ZoomRect, to: ZoomRect, p: Float): ZoomRect = ZoomRect(
    zoomLerp(from.x, to.x, p),
    zoomLerp(from.y, to.y, p),
    zoomLerp(from.w, to.w, p),
    zoomLerp(from.h, to.h, p),
)

/** The card's width over the page's: the scale the full view starts at. */
internal fun startScale(cardWidth: Float, pageWidth: Float): Float =
    if (pageWidth <= 0f || cardWidth <= 0f) 1f else cardWidth / pageWidth

internal fun zoomScale(start: Float, p: Float): Float = zoomLerp(start, 1f, p)

/**
 * The view's height before it is scaled: the card's height at the start (in
 * the view's own, unscaled px), the page's at the end.
 */
internal fun zoomHeight(cardHeight: Float, pageHeight: Float, start: Float, p: Float): Float =
    zoomLerp(cardHeight / start, pageHeight, p)

/**
 * The corner radius before it is scaled, so that on screen it is the card's
 * at the start and the page's at the end - rounded the whole way, never sharp.
 */
internal fun zoomRadius(cardRadius: Float, pageRadius: Float, start: Float, p: Float): Float =
    zoomLerp(cardRadius / start, pageRadius, p)

/**
 * How far the full view's content is moved down (negative: up), in the view's
 * unscaled px, so that while the zoom is small its first block rides on the
 * card's top - at [startTop] from the view's top - rather than sitting below
 * the view's title bar, cut off; in its own place, [contentTop], at the end.
 */
internal fun contentShift(contentTop: Float, startTop: Float, p: Float): Float =
    zoomLerp(startTop - contentTop, 0f, p)

/**
 * The rectangle a picture of this width-over-height [ratio] is drawn in when
 * it is fitted whole into [box] (ContentScale.Fit): centred, as big as fits.
 */
internal fun containRect(box: ZoomRect, ratio: Float): ZoomRect {
    if (ratio <= 0f || box.w <= 0f || box.h <= 0f) return box
    if (box.w / box.h > ratio) {
        val w = box.h * ratio
        return ZoomRect(box.x + (box.w - w) / 2f, box.y, w, box.h)
    }
    val h = box.w / ratio
    return ZoomRect(box.x, box.y + (box.h - h) / 2f, box.w, h)
}

/**
 * The part of a [width] x [height] picture that fills a [boxWidth] x
 * [boxHeight] box when it is cropped to it (ContentScale.Crop): the middle of
 * the picture, at the box's shape. The flying picture is drawn this way, so
 * a box a pixel off the picture's own shape never squashes it.
 */
internal fun cropSource(width: Int, height: Int, boxWidth: Float, boxHeight: Float): ZoomRect {
    if (width <= 0 || height <= 0 || boxWidth <= 0f || boxHeight <= 0f) {
        return ZoomRect(0f, 0f, width.toFloat(), height.toFloat())
    }
    val box = boxWidth / boxHeight
    val picture = width.toFloat() / height
    return if (picture > box) {
        val w = height * box
        ZoomRect((width - w) / 2f, 0f, w, height.toFloat())
    } else {
        val h = width / box
        ZoomRect(0f, (height - h) / 2f, width.toFloat(), h)
    }
}

/**
 * Where a view closing toward no card (it is gone, or was never measured)
 * shrinks to as it fades: the middle of the page.
 */
internal fun vanishRect(pageWidth: Float, pageHeight: Float): ZoomRect =
    ZoomRect(pageWidth * 0.3f, pageHeight * 0.35f, pageWidth * 0.4f, pageHeight * 0.3f)
