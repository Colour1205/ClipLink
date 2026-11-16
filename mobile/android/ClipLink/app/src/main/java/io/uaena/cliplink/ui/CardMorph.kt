package io.uaena.cliplink.ui

import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/*
 * A card opening into its full view, and the view closing back into it - the
 * Synced cards into an item's view, the device cards into a device's - as one
 * zoom (the sums are in ZoomMorph.kt, the same as the HarmonyOS app's):
 *
 * - The list stays on screen behind it the whole way, both ways: blurred and
 *   a little darker as the view grows, clear again as it shrinks, on the
 *   zoom's own spring. It never fades - a list fading out under the card
 *   left the card growing over an empty page.
 * - The view is laid out once, at full size, and scaled as a whole from the
 *   card's place to the page's, so its text grows with it rather than being
 *   uncovered by an edge sweeping over it. Rounded the whole way: the card's
 *   corners at the start, the screen's at the end.
 * - A picture of the card covers the view at the start and goes quickly; the
 *   view's own content comes in after it - one and then the other, never two
 *   different layouts of the same text crossfading.
 * - A picture card's picture flies on its own, from its place on the card to
 *   its place in the view, both ways.
 * - Going back gives the list the screen at once: the closing view takes no
 *   touches, and a card tapped while it shrinks opens straight away.
 */

/**
 * Where a card is and what it looks like, for the zoom that opens it. Plain
 * fields, written by the card as it is placed and drawn, and only read when a
 * zoom starts.
 */
internal class ZoomSource {
    var coordinates: LayoutCoordinates? = null

    /** What the card draws, recorded as it draws it (the card's own picture of itself). */
    var layer: GraphicsLayer? = null

    /** The card's own colour: the view starts as it and turns into the page's. */
    var color: Color = Color.Unspecified

    /** A picture card's picture, and where the card shows it. */
    var picture: ImageBitmap? = null
    var pictureCoordinates: LayoutCoordinates? = null
}

/** Every card on screen that can be opened, by [itemZoomKey] or [deviceZoomKey]. */
internal class ZoomSources {
    private val sources = HashMap<String, ZoomSource>()

    operator fun get(key: String): ZoomSource? = sources[key]

    fun put(key: String, source: ZoomSource) {
        sources[key] = source
    }

    /** Only the one put under [key] last: the grid and the list hold the same card while they swap. */
    fun remove(key: String, source: ZoomSource) {
        if (sources[key] === source) sources.remove(key)
    }
}

internal val LocalZoomSources = staticCompositionLocalOf<ZoomSources?> { null }

internal const val ITEM_ZOOM_PREFIX = "item:"
internal const val DEVICE_ZOOM_PREFIX = "device:"

internal fun itemZoomKey(listKey: String): String = ITEM_ZOOM_PREFIX + listKey

internal fun deviceZoomKey(deviceId: String): String = DEVICE_ZOOM_PREFIX + deviceId

/** The card's entry in the open-able cards, for as long as the card is on screen. Null where nothing zooms (a preview). */
@Composable
internal fun rememberZoomSource(key: String): ZoomSource? {
    val sources = LocalZoomSources.current ?: return null
    val source = remember(key) { ZoomSource() }
    DisposableEffect(sources, key, source) {
        sources.put(key, source)
        onDispose { sources.remove(key, source) }
    }
    return source
}

/**
 * The spring a card grows into its full view with, and shrinks back: the
 * HarmonyOS app's interpolatingSpring(0, 1, 328, 36) - mass 1, stiffness 328,
 * damping 36, so just short of critically damped.
 */
private val MORPH_SPRING: AnimationSpec<Float> = spring(
    dampingRatio = 36f / (2f * sqrt(328f)),
    stiffness = 328f,
    visibilityThreshold = 0.0005f,
)

/** ArkUI's Curve.Sharp, which the HarmonyOS app hands over between the card's picture and the view on. */
private val SHARP = CubicBezierEasing(0.33f, 0f, 0.67f, 1f)

/** The list behind an open view at full strength: blurred by this radius... */
internal val BACKDROP_BLUR = 24.dp

/** ...and darkened by a veil of black this strong (brightness 0.85): pushed back, not greyed out. */
private const val BACKDROP_DIM = 0.15f

/** The page's corners at the end of the zoom, on a screen that does not say what its own are. */
private val PAGE_RADIUS = 32.dp

/** Where the view's first block sits, from its top, while the zoom is small: as far in as from its sides. */
private val START_TOP = 16.dp

/** How far below the title bar a full view's first block starts (its body's top padding). */
private val BODY_TOP = 12.dp

/**
 * The zoom one card opens with: what it shows, and how far along it is. One
 * for the whole app - only one full view is ever open - and the full view is
 * drawn by [ZoomOverlay] over the page while [shown] is set.
 */
@Stable
internal class CardZoom(private val scope: CoroutineScope, private val sources: ZoomSources) {
    /** The card being shown in full ([itemZoomKey], [deviceZoomKey]), opening, open or closing; null when none is. */
    var shown by mutableStateOf<String?>(null)
        private set

    /** Shrinking back: the view is on its way out and takes no touches. */
    var closing by mutableStateOf(false)
        private set

    /** 0 at the card, 1 at the full view. */
    var p by mutableFloatStateOf(1f)
        private set

    /** How far the page behind is blurred and darkened: 0 not at all, 1 fully. */
    var backdrop by mutableFloatStateOf(0f)
        private set

    /** How much of the view's own content shows, and of the card's picture of itself over it. */
    var fade by mutableFloatStateOf(1f)
        private set
    var cover by mutableFloatStateOf(0f)
        private set

    /**
     * The view's title bar: there from the tap, all at once and in its own
     * place at the top of the page - never faded, slid or grown in - and gone
     * the moment the view starts to close.
     */
    var barShown by mutableStateOf(true)
        private set

    /**
     * The title bar is drawn where it sits in the view, as any part of it.
     * While the zoom moves it is not: the view's bar would ride and grow with
     * the zooming page, so its recording ([barLayer]) is drawn by [drawBar]
     * at its place on the page instead. Derived, so a draw that reads it is
     * redone when it flips, not on every frame of the zoom.
     */
    val barInPlace: Boolean by derivedStateOf { !active || (p >= 1f && !closing) }

    /** What the view's title bar draws, recorded as it draws it (see [zoomBar]). */
    var barLayer: GraphicsLayer? = null

    /** The view has a card to grow from and shrink to; without one it is just there (opened again after a rotation). */
    var active by mutableStateOf(false)
        private set

    /** Closing toward a card that is gone: the view fades as it shrinks to the middle. */
    var vanish by mutableStateOf(false)
        private set

    /** A picture card's picture is on its way, drawn over the view; the view's own is hidden meanwhile. */
    var flying by mutableStateOf(false)
        private set

    var card by mutableStateOf(ZoomRect.Zero)
        private set
    private var pageWidth by mutableFloatStateOf(0f)
    private var cardColor by mutableStateOf(Color.Unspecified)
    private var cardLayer by mutableStateOf<GraphicsLayer?>(null)
    private var cardHole by mutableStateOf<ZoomRect?>(null)
    private var picture by mutableStateOf<ImageBitmap?>(null)
    private var picFrom by mutableStateOf(ZoomRect.Zero)
    private var picRadius by mutableFloatStateOf(0f)

    /** The view's content rides on the card's top while small - not a picture card's, whose picture flies instead. */
    private var ridesCard by mutableStateOf(true)

    // Where things are, written as they are placed: the page the zoom runs
    // over, the full view itself (inside its scale), and its parts.
    var host: LayoutCoordinates? = null
    var view: LayoutCoordinates? = null
    var bar: LayoutCoordinates? = null
    var pictureBox: LayoutCoordinates? = null

    // Set by the page each time it is composed.
    var reduceMotion = false
    var density: Density = Density(1f)
    var screenCorner: () -> Int = { 0 }

    private var job: Job? = null

    /** The scale the view starts at: the card's width over the page's. */
    val start: Float get() = startScale(card.w, pageWidth)

    /** The view is open (or opening): it takes every touch, the page behind none. */
    val takesTouches: Boolean get() = shown != null && !closing

    /** The view fills the page, opaque: the page behind cannot be seen. */
    val coversPage: Boolean get() = shown != null && !closing && p >= 1f && fade >= 1f

    private val cardRadius: Float get() = with(density) { CARD_RADIUS.toPx() }

    private val pageRadius: Float
        get() = screenCorner().takeIf { it > 0 }?.toFloat() ?: with(density) { PAGE_RADIUS.toPx() }

    private fun morphSpec(): AnimationSpec<Float> =
        if (reduceMotion) tween(150, easing = EaseInOut) else MORPH_SPRING

    /**
     * Opens [key]'s card into its full view. The card is measured now; one
     * that cannot be (not on screen) opens with no zoom - the view is just
     * there, the page behind blurring as it would. A card tapped while
     * another view is still shrinking starts over from that card.
     */
    fun open(key: String) {
        job?.cancel()
        shown = key
        closing = false
        vanish = false
        val host = host?.takeIf { it.isAttached && it.size.width > 0 && it.size.height > 0 }
        val source = sources[key]
        val coords = source?.coordinates?.takeIf { it.isAttached }
        if (host == null || source == null || coords == null) {
            atRest(active = false)
            job = scope.launch { animate(backdrop, 1f, animationSpec = morphSpec()) { v, _ -> backdrop = v } }
            return
        }
        pageWidth = host.size.width.toFloat()
        card = host.localBoundingBoxOf(coords, clipBounds = false).toZoomRect()
        take(source, host)
        active = true
        p = 0f
        fade = 0f
        cover = 1f
        barShown = true
        job = scope.launch {
            // Two frames at the card first: the view is composed and laid out
            // at full size under the card's picture of itself, so where its
            // picture lands is known before anything moves.
            withFrameNanos { }
            withFrameNanos { }
            if (flying && pictureTarget() == null) noFlight()
            coroutineScope {
                launch {
                    animate(p, 1f, animationSpec = morphSpec()) { v, _ -> p = v }
                    // The picture has landed: the view's own takes over in the same place.
                    flying = false
                }
                launch { animate(backdrop, 1f, animationSpec = morphSpec()) { v, _ -> backdrop = v } }
                // The card's text goes first, the view's comes in after it.
                launch { animate(cover, 0f, animationSpec = tween(110, easing = SHARP)) { v, _ -> cover = v } }
                launch { animate(fade, 1f, animationSpec = tween(170, delayMillis = 70, easing = SHARP)) { v, _ -> fade = v } }
            }
        }
    }

    /**
     * Shrinks the view back onto its card - measured again, the list may have
     * changed under it - and lets it go once there. [gone]: the card is not
     * coming back (the item was deleted), so the view shrinks toward the
     * middle and fades, as it does for a card no longer on screen.
     */
    fun close(gone: Boolean = false) {
        val key = shown ?: return
        if (closing) return
        job?.cancel()
        closing = true
        barShown = false
        val host = host?.takeIf { it.isAttached && it.size.width > 0 && it.size.height > 0 }
        if (host != null) pageWidth = host.size.width.toFloat()
        val source = if (gone) null else sources[key]
        val coords = source?.coordinates?.takeIf { it.isAttached }
        if (host != null && source != null && coords != null) {
            card = host.localBoundingBoxOf(coords, clipBounds = false).toZoomRect()
            take(source, host)
            if (flying && pictureTarget() == null) noFlight()
            vanish = false
        } else {
            val size = host?.size
            card = vanishRect(size?.width?.toFloat() ?: pageWidth, size?.height?.toFloat() ?: 0f)
            cardLayer = null
            noFlight()
            vanish = true
        }
        active = true
        job = scope.launch {
            coroutineScope {
                // The reverse of the open: the view's content goes, then the
                // card's picture of itself comes back for it to land as.
                launch { animate(fade, 0f, animationSpec = tween(110, easing = SHARP)) { v, _ -> fade = v } }
                launch { animate(cover, 1f, animationSpec = tween(140, delayMillis = 80, easing = SHARP)) { v, _ -> cover = v } }
                launch { animate(backdrop, 0f, animationSpec = morphSpec()) { v, _ -> backdrop = v } }
                animate(p, 0f, animationSpec = morphSpec()) { v, _ -> p = v }
            }
            // Only reached when this close ran to the end: a card tapped
            // meanwhile has cancelled it and opened the zoom again.
            end()
        }
    }

    /** Shows [key]'s view as it is when open, with no zoom: an open view brought back after a rotation. */
    fun showAtRest(key: String) {
        job?.cancel()
        shown = key
        closing = false
        vanish = false
        atRest(active = false)
        backdrop = 1f
    }

    /** Takes the view away at once, with nothing to watch (the page under it is changing to another). */
    fun drop() {
        job?.cancel()
        end()
    }

    private fun atRest(active: Boolean) {
        this.active = active
        p = 1f
        fade = 1f
        cover = 0f
        barShown = true
        flying = false
    }

    private fun end() {
        shown = null
        closing = false
        vanish = false
        atRest(active = false)
        backdrop = 0f
        cardLayer = null
        cardHole = null
        picture = null
    }

    /** What the zoom needs of the card: its picture of itself, its colour, and a picture card's picture. */
    private fun take(source: ZoomSource, host: LayoutCoordinates) {
        cardLayer = source.layer
        cardColor = source.color
        val bitmap = source.picture
        val pictureCoords = source.pictureCoordinates?.takeIf { it.isAttached }
        ridesCard = bitmap == null
        if (bitmap == null || pictureCoords == null) {
            noFlight()
            return
        }
        val box = host.localBoundingBoxOf(pictureCoords, clipBounds = false).toZoomRect()
        val ratio = bitmap.width.toFloat() / bitmap.height.coerceAtLeast(1)
        picture = bitmap
        // The card fits its picture whole into its box (a very long one is
        // letterboxed, and its box, not the picture, has the round corners).
        picFrom = containRect(box, ratio)
        picRadius = if (ratio >= 1f / MAX_PICTURE_HEIGHT_RATIO) with(density) { CARD_PICTURE_RADIUS.toPx() } else 0f
        // The card's picture of itself leaves the picture out: a second,
        // smaller copy growing under the flying one is just what it must not
        // look like.
        cardHole = ZoomRect(box.x - card.x, box.y - card.y, box.w, box.h)
        flying = true
    }

    private fun noFlight() {
        flying = false
        cardHole = null
    }

    /** Where the view shows the picture, fitted whole into its place there; null until that is laid out. */
    private fun pictureTarget(): ZoomRect? {
        val view = view?.takeIf { it.isAttached } ?: return null
        val box = pictureBox?.takeIf { it.isAttached } ?: return null
        val bitmap = picture ?: return null
        return containRect(view.localBoundingBoxOf(box, clipBounds = false).toZoomRect(), bitmap.width.toFloat() / bitmap.height.coerceAtLeast(1))
    }

    /** How far the view's content is moved, in its own px (see [contentShift]). */
    internal fun shift(): Float {
        if (!active || !ridesCard) return 0f
        val view = view?.takeIf { it.isAttached } ?: return 0f
        val bar = bar?.takeIf { it.isAttached } ?: return 0f
        val contentTop = view.localBoundingBoxOf(bar, clipBounds = false).bottom + with(density) { BODY_TOP.toPx() }
        return contentShift(contentTop, with(density) { START_TOP.toPx() }, p)
    }

    /** The view's own colour: the card's at the start, the page's at the end. */
    internal fun fill(page: Color): Color =
        if (!active || cardColor == Color.Unspecified) page else lerp(cardColor, page, p.coerceIn(0f, 1f))

    /** The zoom's place on the page, in the view's layer. */
    internal fun applyTo(layer: GraphicsLayerScope) = with(layer) {
        if (!active) {
            scaleX = 1f
            scaleY = 1f
            translationX = 0f
            translationY = 0f
            shape = RectangleShape
            clip = false
            alpha = 1f
            return@with
        }
        val s0 = start
        val scale = zoomScale(s0, p)
        transformOrigin = TransformOrigin(0f, 0f)
        scaleX = scale
        scaleY = scale
        translationX = zoomLerp(card.x, 0f, p)
        translationY = zoomLerp(card.y, 0f, p)
        if (p < 1f || closing) {
            val at = p.coerceIn(0f, 1f)
            shape = ZoomShape(zoomHeight(card.h, size.height, s0, at), zoomRadius(cardRadius, pageRadius, s0, at))
            clip = true
        } else {
            // Open and at rest: the whole page, square, as any page.
            shape = RectangleShape
            clip = false
        }
        alpha = if (vanish) p.coerceIn(0f, 1f) else 1f
    }

    /** The card's picture of itself, at the card's place and size, over the view (in the view's own px). */
    internal fun drawCover(scope: DrawScope) = with(scope) {
        val layer = cardLayer ?: return@with
        if (layer.isReleased) return@with
        val s0 = start
        scale(1f / s0, 1f / s0, pivot = Offset.Zero) {
            val hole = cardHole
            if (hole == null) {
                drawLayer(layer)
            } else {
                clipRect(hole.x, hole.y, hole.right, hole.bottom, ClipOp.Difference) { drawLayer(layer) }
            }
        }
    }

    /** The flying picture, on the page: from the card's place for it to the view's. */
    internal fun drawFlight(scope: DrawScope) = with(scope) {
        if (!flying) return@with
        val bitmap = picture ?: return@with
        val to = pictureTarget() ?: return@with
        val at = zoomLerp(picFrom, to, p)
        if (at.w < 1f || at.h < 1f) return@with
        val radius = zoomLerp(picRadius, 0f, p.coerceIn(0f, 1f)).coerceAtLeast(0f)
        val source = cropSource(bitmap.width, bitmap.height, at.w, at.h)
        val outline = Path().apply { addRoundRect(RoundRect(at.x, at.y, at.right, at.bottom, CornerRadius(radius))) }
        clipPath(outline) {
            drawImage(
                bitmap,
                srcOffset = IntOffset(source.x.roundToInt(), source.y.roundToInt()),
                srcSize = IntSize(source.w.roundToInt().coerceAtLeast(1), source.h.roundToInt().coerceAtLeast(1)),
                dstOffset = IntOffset(at.x.roundToInt(), at.y.roundToInt()),
                dstSize = IntSize(at.w.roundToInt(), at.h.roundToInt()),
            )
        }
    }

    /**
     * The view's title bar while the zoom moves, on the page: full size, where
     * it sits once the view is open (the view's own px are the page's then),
     * whatever size the view is meanwhile.
     */
    internal fun drawBar(scope: DrawScope) = with(scope) {
        if (!barShown || barInPlace) return@with
        val layer = barLayer?.takeIf { !it.isReleased } ?: return@with
        val view = view?.takeIf { it.isAttached } ?: return@with
        val bar = bar?.takeIf { it.isAttached } ?: return@with
        val at = view.localPositionOf(bar, Offset.Zero)
        translate(at.x, at.y) { drawLayer(layer) }
    }
}

private fun Rect.toZoomRect() = ZoomRect(left, top, width, height)

/** The zoom's shape, in the view's own px: as wide as the page, cut to [height], with round corners. */
private data class ZoomShape(val height: Float, val radius: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline =
        Outline.Rounded(RoundRect(0f, 0f, size.width, height.coerceIn(0f, size.height), CornerRadius(radius)))
}

/** A clip no point is inside: a layer cut to it takes no touches (what it draws is shown elsewhere). */
private object NoTouchShape : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline =
        Outline.Rectangle(Rect.Zero)
}

/**
 * The page behind a zoom: blurred as the view grows over it, sharp again as
 * it shrinks - never faded. Under a view that covers it, not drawn at all:
 * nothing of it can be seen, and a full-screen blur redrawn under every frame
 * of the view would cost for nothing.
 */
internal fun Modifier.zoomBackdrop(zoom: CardZoom, blurRadius: Float): Modifier = graphicsLayer {
    val covered = zoom.coversPage
    val level = zoom.backdrop.coerceIn(0f, 1f)
    alpha = if (covered) 0f else 1f
    renderEffect = if (level > 0f && !covered) {
        BlurEffect(blurRadius * level, blurRadius * level, TileMode.Clamp)
    } else {
        null
    }
    clip = true
}

/** The darkening of the page behind a zoom, over it. Takes no touches. */
@Composable
internal fun ZoomDim(zoom: CardZoom) {
    if (zoom.shown == null) return
    Spacer(
        Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = if (zoom.coversPage) 0f else BACKDROP_DIM * zoom.backdrop.coerceIn(0f, 1f) }
            .background(Color.Black),
    )
}

/** What a full view needs of the zoom it is shown in (see [zoomBar], [zoomBody], [zoomPicture]). */
internal class ZoomView(val zoom: CardZoom, val page: Color)

internal val LocalZoomView = staticCompositionLocalOf<ZoomView?> { null }

/**
 * The full view of the card [CardZoom.shown], over everything [ZoomOverlay]
 * is put after, zoomed from its card ([content] draws the view itself).
 *
 * While the view closes it must take no touches - the page behind has them
 * at once - yet still be drawn on top. Compose sends a touch to whatever is
 * on top where it lands, so the view is laid out in a layer cut to nothing
 * (no touch is inside it), what it draws is recorded, and the recording is
 * drawn over the page by a sibling that takes no touches either.
 */
@Composable
internal fun ZoomOverlay(zoom: CardZoom, page: Color, content: @Composable (key: String) -> Unit) {
    val key = zoom.shown ?: return
    val recorded = rememberGraphicsLayer()
    val zoomView = remember(zoom, page) { ZoomView(zoom, page) }
    Box(
        Modifier
            .fillMaxSize()
            .then(
                if (zoom.takesTouches) {
                    // Every touch on the screen is the view's while it is
                    // open, not just those on its buttons: one on a bare part
                    // of it must never reach a card underneath.
                    Modifier.pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent() } }
                } else {
                    Modifier
                        .graphicsLayer {
                            shape = NoTouchShape
                            clip = true
                        }
                        .clearAndSetSemantics { }
                },
            )
            .drawWithContent { recorded.record { this@drawWithContent.drawContent() } },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { zoom.applyTo(this) }
                .onPlaced { zoom.view = it },
        ) {
            // Own layers, here and below: a frame of the zoom redraws them,
            // not the whole view.
            Spacer(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer { }
                    .drawBehind { drawRect(zoom.fill(page)) },
            )
            CompositionLocalProvider(LocalZoomView provides zoomView) {
                key(key) { content(key) }
            }
            Spacer(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer { alpha = zoom.cover.coerceIn(0f, 1f) }
                    .drawBehind { zoom.drawCover(this) },
            )
        }
        Spacer(
            Modifier
                .fillMaxSize()
                .graphicsLayer { }
                .drawBehind { zoom.drawFlight(this) },
        )
        Spacer(
            Modifier
                .fillMaxSize()
                .graphicsLayer { }
                .drawBehind { zoom.drawBar(this) },
        )
    }
    Spacer(
        Modifier
            .fillMaxSize()
            .drawBehind { drawLayer(recorded) },
    )
}

/**
 * A full view's title bar: there at once from the tap, in its own place at
 * the top of the page, never sliding, growing or fading in - while the zoom
 * moves, what it draws is recorded and drawn there by [CardZoom.drawBar]
 * rather than here, inside the zooming view - and gone at once on close.
 * (Its buttons take taps once the view is open, where they are drawn.)
 */
@Composable
internal fun Modifier.zoomBar(): Modifier {
    val view = LocalZoomView.current ?: return this
    val zoom = view.zoom
    val recorded = rememberGraphicsLayer()
    DisposableEffect(zoom, recorded) {
        zoom.barLayer = recorded
        onDispose { if (zoom.barLayer === recorded) zoom.barLayer = null }
    }
    return this
        .onPlaced { zoom.bar = it }
        .drawWithContent {
            recorded.record { this@drawWithContent.drawContent() }
            if (zoom.barShown && zoom.barInPlace) drawLayer(recorded)
        }
}

/**
 * A part of a full view below its title bar: comes in once the card's
 * picture of itself has gone, and rides on the card's top while the zoom is
 * small.
 */
@Composable
internal fun Modifier.zoomBody(): Modifier {
    val view = LocalZoomView.current ?: return this
    return this.graphicsLayer {
        alpha = view.zoom.fade.coerceIn(0f, 1f)
        translationY = view.zoom.shift()
    }
}

/** A full view's picture: where the card's picture flies to, hidden while it flies. */
@Composable
internal fun Modifier.zoomPicture(): Modifier {
    val view = LocalZoomView.current ?: return this
    return this
        .onPlaced { view.zoom.pictureBox = it }
        .graphicsLayer { alpha = if (view.zoom.flying) 0f else 1f }
}
