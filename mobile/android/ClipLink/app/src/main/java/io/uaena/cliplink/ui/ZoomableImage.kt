package io.uaena.cliplink.ui

import androidx.compose.animation.core.animate
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateCentroidSize
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * A picture that can be pinched to zoom, dragged to pan once it is zoomed, and
 * double-tapped to jump in on the spot (or back out again).
 *
 * It lives inside the detail screen's vertical scroll, so the gesture handling
 * is deliberately selective: a single finger on a picture that isn't zoomed is
 * left alone and scrolls the page as it always did. Only a pinch, or a drag
 * once the picture is already zoomed, is claimed here - which also means a
 * zoomed picture doesn't scroll the page until it is double-tapped back out.
 *
 * Zooming happens inside the picture's own rounded frame (it is clipped, not
 * overlaid), so the layout around it never moves.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ZoomableImage(
    bitmap: ImageBitmap,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(24.dp),
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    var settling by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    // Read here, not in the gesture: a spring from the motion scheme, like the
    // rest of the app's motion, and not a raw tween.
    val settleSpec = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()

    Image(
        bitmap = bitmap,
        contentDescription = contentDescription,
        modifier = modifier
            .onSizeChanged { size = it }
            .clip(shape)
            // Both detectors sit BEFORE the graphicsLayer, so they see the
            // picture's untransformed frame: a zoomed picture is still hit
            // anywhere inside it, and gesture positions stay in layout space.
            .pointerInput(Unit) {
                detectTapGestures(
                    onDoubleTap = { tap ->
                        settling?.cancel()
                        val fromScale = scale
                        val fromOffset = offset
                        val toScale = if (fromScale > ZOOMED_THRESHOLD) 1f else DOUBLE_TAP_SCALE
                        val toOffset = zoomedAbout(tap, fromScale, fromOffset, toScale, size)
                        settling = scope.launch {
                            animate(0f, 1f, animationSpec = settleSpec) { fraction, _ ->
                                // A spring can overshoot, so both ends are
                                // clamped on every frame.
                                val nextScale = (fromScale + (toScale - fromScale) * fraction)
                                    .coerceIn(1f, MAX_SCALE)
                                scale = nextScale
                                offset = clampOffset(
                                    fromOffset + (toOffset - fromOffset) * fraction,
                                    nextScale,
                                    size,
                                )
                            }
                        }
                    },
                )
            }
            .pointerInput(Unit) {
                detectZoomAndPan(zoomed = { scale > ZOOMED_THRESHOLD }) { centroid, pan, zoom ->
                    settling?.cancel()
                    val nextScale = (scale * zoom).coerceIn(1f, MAX_SCALE)
                    offset = clampOffset(
                        zoomedAbout(centroid, scale, offset, nextScale, size) + pan,
                        nextScale,
                        size,
                    )
                    scale = nextScale
                }
            }
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = offset.x
                translationY = offset.y
            },
    )
}

/**
 * Like `detectTransformGestures`, minus rotation, and it only claims the
 * gesture when it means to: two or more fingers down, or one finger on a
 * picture that is already [zoomed]. Anything else is left unconsumed so the
 * parent's scroll gets a plain swipe - the stock detector would eat every
 * drag and make the picture a dead zone for scrolling.
 */
private suspend fun PointerInputScope.detectZoomAndPan(
    zoomed: () -> Boolean,
    onGesture: (centroid: Offset, pan: Offset, zoom: Float) -> Unit,
) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        var zoom = 1f
        var pan = Offset.Zero
        var pastTouchSlop = false
        do {
            val event = awaitPointerEvent()
            // Someone else - the page's scroll, started before a second finger
            // landed - already took this gesture.
            if (event.changes.any { it.isConsumed }) break
            val pinching = event.changes.count { it.pressed } > 1
            if (!pinching && !zoomed()) continue

            val zoomChange = event.calculateZoom()
            val panChange = event.calculatePan()
            if (!pastTouchSlop) {
                zoom *= zoomChange
                pan += panChange
                val zoomMotion = abs(1f - zoom) * event.calculateCentroidSize(useCurrent = false)
                if (zoomMotion > viewConfiguration.touchSlop || pan.getDistance() > viewConfiguration.touchSlop) {
                    pastTouchSlop = true
                }
            }
            if (pastTouchSlop) {
                if (zoomChange != 1f || panChange != Offset.Zero) {
                    onGesture(event.calculateCentroid(useCurrent = false), panChange, zoomChange)
                }
                event.changes.forEach { if (it.positionChanged()) it.consume() }
            }
        } while (event.changes.any { it.pressed })
    }
}

/** How far the picture may be shifted at [scale] before an edge of it would come inside its frame. */
private fun clampOffset(offset: Offset, scale: Float, size: IntSize): Offset {
    val maxX = size.width * (scale - 1f) / 2f
    val maxY = size.height * (scale - 1f) / 2f
    return Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
}

/**
 * The offset that takes the picture from [scale] to [newScale] while keeping
 * whatever is under [focus] under it - the pinch's midpoint, or the tap of a
 * double-tap. The layer scales about its centre, so [focus] is taken from there.
 */
private fun zoomedAbout(focus: Offset, scale: Float, offset: Offset, newScale: Float, size: IntSize): Offset {
    val fromCenter = focus - Offset(size.width / 2f, size.height / 2f)
    return clampOffset(fromCenter - (fromCenter - offset) * (newScale / scale), newScale, size)
}

private const val MAX_SCALE = 5f
private const val DOUBLE_TAP_SCALE = 2.5f

/** Above this the picture counts as zoomed - float noise from a pinch back to 1x doesn't. */
private const val ZOOMED_THRESHOLD = 1.02f
