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
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * A picture that can be pinched to zoom, dragged to pan once it is zoomed, and
 * double-tapped to jump in on the spot (or back out again).
 *
 * The picture is laid out to fit ([ContentScale.Fit], centred) inside whatever
 * area [modifier] gives it - hand it the whole remaining screen and it uses all
 * of it, tall or wide. Zooming happens inside that area (it is clipped to
 * [shape], not overlaid), so the layout around it never moves, and the pan
 * limits are the picture's own edges rather than the area's: a tall picture
 * in a wide area doesn't drift off into the empty margins.
 *
 * The gesture handling is selective: a single finger on a picture that isn't
 * zoomed is left unclaimed, so a parent that scrolls still scrolls over it.
 * Only a pinch, or a drag once the picture is already zoomed, is claimed here.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ZoomableImage(
    bitmap: ImageBitmap,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    shape: Shape = RectangleShape,
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var frame by remember { mutableStateOf(IntSize.Zero) }
    var settling by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    val currentBitmap by rememberUpdatedState(bitmap)
    // Read here, not in the gesture: a spring from the motion scheme, like the
    // rest of the app's motion, and not a raw tween.
    val settleSpec = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()

    Image(
        bitmap = bitmap,
        contentDescription = contentDescription,
        contentScale = ContentScale.Fit,
        modifier = modifier
            .onSizeChanged { frame = it }
            .clip(shape)
            // Both detectors sit BEFORE the graphicsLayer, so they see the
            // frame untransformed: a zoomed picture is still hit anywhere
            // inside it, and gesture positions stay in layout space.
            .pointerInput(Unit) {
                detectTapGestures(
                    onDoubleTap = { tap ->
                        val picture = fittedSize(currentBitmap, frame)
                        if (picture == Size.Zero) return@detectTapGestures
                        settling?.cancel()
                        val fromScale = scale
                        val fromOffset = offset
                        // In, far enough to fill the frame's long side (or
                        // 2.5x, if that is more); a second double-tap is out.
                        val fill = max(frame.width / picture.width, frame.height / picture.height)
                        val toScale = if (fromScale > ZOOMED_THRESHOLD) {
                            1f
                        } else {
                            fill.coerceIn(DOUBLE_TAP_SCALE, MAX_SCALE)
                        }
                        val toOffset = zoomedAbout(tap, fromScale, fromOffset, toScale, picture, frame)
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
                                    picture,
                                    frame,
                                )
                            }
                        }
                    },
                )
            }
            .pointerInput(Unit) {
                detectZoomAndPan(zoomed = { scale > ZOOMED_THRESHOLD }) { centroid, pan, zoom ->
                    val picture = fittedSize(currentBitmap, frame)
                    if (picture == Size.Zero) return@detectZoomAndPan
                    settling?.cancel()
                    val nextScale = (scale * zoom).coerceIn(1f, MAX_SCALE)
                    offset = clampOffset(
                        zoomedAbout(centroid, scale, offset, nextScale, picture, frame) + pan,
                        nextScale,
                        picture,
                        frame,
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
 * picture that is already [zoomed]. Anything else is left unconsumed so a
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
            // Someone else - a parent's scroll, started before a second finger
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

/** The size [bitmap] is drawn at inside [frame] by [ContentScale.Fit] - what the user actually sees of it. */
private fun fittedSize(bitmap: ImageBitmap, frame: IntSize): Size {
    if (frame.width <= 0 || frame.height <= 0 || bitmap.width <= 0 || bitmap.height <= 0) return Size.Zero
    val fit = min(frame.width.toFloat() / bitmap.width, frame.height.toFloat() / bitmap.height)
    return Size(bitmap.width * fit, bitmap.height * fit)
}

/**
 * How far the picture may be shifted at [scale] before an edge of it would
 * come inside the frame. Zero on an axis where the zoomed picture still
 * doesn't reach the frame's sides - it stays centred there.
 */
private fun clampOffset(offset: Offset, scale: Float, picture: Size, frame: IntSize): Offset {
    val maxX = max(0f, (picture.width * scale - frame.width) / 2f)
    val maxY = max(0f, (picture.height * scale - frame.height) / 2f)
    return Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
}

/**
 * The offset that takes the picture from [scale] to [newScale] while keeping
 * whatever is under [focus] under it - the pinch's midpoint, or the tap of a
 * double-tap. The layer scales about the frame's centre, so [focus] is taken
 * from there.
 */
private fun zoomedAbout(
    focus: Offset,
    scale: Float,
    offset: Offset,
    newScale: Float,
    picture: Size,
    frame: IntSize,
): Offset {
    val fromCenter = focus - Offset(frame.width / 2f, frame.height / 2f)
    return clampOffset(fromCenter - (fromCenter - offset) * (newScale / scale), newScale, picture, frame)
}

private const val MAX_SCALE = 5f
private const val DOUBLE_TAP_SCALE = 2.5f

/** Above this the picture counts as zoomed - float noise from a pinch back to 1x doesn't. */
private const val ZOOMED_THRESHOLD = 1.02f
