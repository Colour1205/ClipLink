package io.uaena.cliplink.ui

import android.content.ClipData
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Point
import android.view.View
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * A card's menu opens this long after the finger comes down (ms): the app's
 * own long press, well under the system's, as on HarmonyOS
 * (MENU_LONG_PRESS_MS in Index.ets).
 */
internal const val MENU_LONG_PRESS_MS = 210L

/** How small a card gets while a finger is on it. */
internal const val CARD_PRESS_SCALE = 0.95f

/** A finger that moves more than this (dp, either way) from where it came down is not pressing the card any more. */
internal const val CARD_PRESS_MOVE_SLOP_DP = 10f

/** Once the menu is open, a finger that moves this far (dp) drags the card out of the app. */
internal const val MENU_DRAG_DISTANCE_DP = 8f

/** How much the lifted picture of a card grows while its menu is open. */
private const val MENU_LIFT_SCALE = 1.1f

/** The room between the lifted card and its menu, and around the edges. */
private val MENU_GAP = 12.dp

/** Whether a finger that moved by ([dx], [dy]) dp from where it came down has left the card's press. */
internal fun leavesPress(dxDp: Float, dyDp: Float): Boolean =
    abs(dxDp) > CARD_PRESS_MOVE_SLOP_DP || abs(dyDp) > CARD_PRESS_MOVE_SLOP_DP

/**
 * A card's touch, drawn by the card itself rather than a ripple: pressed
 * ([onPress] true) from the finger coming down, until it lifts, the list
 * takes the touch over (a scroll), the finger moves more than
 * [CARD_PRESS_MOVE_SLOP_DP], or the menu opens. A lift before
 * [MENU_LONG_PRESS_MS] is a tap; holding that long opens the menu
 * ([onLongPress]), and the lift after it is not a tap. With the menu open, a
 * move of [MENU_DRAG_DISTANCE_DP] drags the card out ([onDragOut], with where
 * the finger is on the card).
 */
internal suspend fun PointerInputScope.detectCardPress(
    onPress: (Boolean) -> Unit,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
    onDragOut: (Offset) -> Unit,
) = awaitEachGesture {
    val down = awaitFirstDown()
    var pressed = true
    onPress(true)
    fun unpress() {
        if (pressed) {
            pressed = false
            onPress(false)
        }
    }
    // Where the finger is: a drag out is measured from where it was when the menu opened.
    var at = down.position
    try {
        // Until the long press: a tap, a touch the list took, or a finger that went away.
        val tapped = withTimeoutOrNull(MENU_LONG_PRESS_MS) {
            while (true) {
                val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: return@withTimeoutOrNull false
                if (change.changedToUp()) {
                    change.consume()
                    return@withTimeoutOrNull true
                }
                if (!change.pressed || change.isConsumed) return@withTimeoutOrNull false
                at = change.position
                val moved = change.position - down.position
                if (leavesPress(moved.x / density, moved.y / density)) unpress()
                if (moved.getDistance() > viewConfiguration.touchSlop) return@withTimeoutOrNull false
            }
            @Suppress("UNREACHABLE_CODE")
            false
        }
        when (tapped) {
            true -> {
                unpress()
                onTap()
            }
            false -> unpress()
            null -> {
                // The menu has the finger now: the card is back to its size at
                // once, not when the menu closes.
                unpress()
                onLongPress()
                val held = at
                val dragPx = MENU_DRAG_DISTANCE_DP.dp.toPx()
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) break // lifted on the menu: no tap
                    change.consume() // the list does not scroll under an open menu
                    if ((change.position - held).getDistance() >= dragPx) {
                        onDragOut(change.position)
                        break
                    }
                }
            }
        }
    } finally {
        unpress()
    }
}

/** One item of a card's menu. */
internal class CardMenuItem(val label: String, val icon: ImageVector, val onClick: () -> Unit)

/**
 * A card's long-press menu: a picture of the card lifted from where the card
 * is, growing from its own size to [MENU_LIFT_SCALE], over a dimmed screen,
 * with the menu beside it - below, or above when there is no room below, the
 * two moved up together when neither fits. Closes back the same way.
 * [cardBounds] is where the card is on the screen, in px.
 */
@Composable
internal fun CardMenu(
    snapshot: ImageBitmap,
    cardBounds: Rect,
    items: List<CardMenuItem>,
    open: Boolean,
    onClosed: () -> Unit,
    onDismissRequest: () -> Unit,
) {
    val closed by rememberUpdatedState(onClosed)
    val lift = remember { Animatable(0f) }
    LaunchedEffect(open) {
        if (open) {
            lift.animateTo(1f, springMotion(0.35f, 0.82f))
        } else {
            lift.animateTo(0f, springMotion(0.3f, 1f))
            closed()
        }
    }
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        // The dim and the window's own animation are this menu's to draw.
        (LocalView.current.parent as? DialogWindowProvider)?.window?.let { window ->
            window.setDimAmount(0f)
            window.setWindowAnimations(0)
        }
        var origin by remember { mutableStateOf<Offset?>(null) }
        val shape = RoundedCornerShape(CARD_RADIUS)
        Box(
            Modifier
                .fillMaxSize()
                .onPlaced { origin = it.positionOnScreen() }
                .pointerInput(Unit) { detectTapGestures { onDismissRequest() } },
        ) {
            // The screen behind dims as the card lifts.
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer { alpha = lift.value.coerceIn(0f, 1f) }
                    .background(Color.Black.copy(alpha = 0.32f)),
            )
            val at = origin ?: return@Box
            val card = cardBounds.translate(-at.x, -at.y)
            Layout(
                content = {
                    Image(
                        bitmap = snapshot,
                        contentDescription = null,
                        contentScale = ContentScale.FillBounds,
                    )
                    Surface(
                        shape = RoundedCornerShape(18.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh,
                        shadowElevation = 6.dp,
                        modifier = Modifier.widthIn(min = 180.dp, max = 280.dp),
                    ) {
                        Column(Modifier.width(IntrinsicSize.Max)) {
                            for (item in items) {
                                DropdownMenuItem(
                                    text = { Text(item.label) },
                                    leadingIcon = { Icon(item.icon, null) },
                                    onClick = item.onClick,
                                )
                            }
                        }
                    }
                },
            ) { measurables, constraints ->
                val width = constraints.maxWidth
                val height = constraints.maxHeight
                val gap = MENU_GAP.roundToPx()
                val preview = measurables[0].measure(
                    Constraints.fixed(card.width.roundToInt().coerceAtLeast(1), card.height.roundToInt().coerceAtLeast(1)),
                )
                val menu = measurables[1].measure(Constraints(maxWidth = (width - 2 * gap).coerceAtLeast(0), maxHeight = height))
                val place = placeCardMenu(
                    card = card,
                    menuWidth = menu.width.toFloat(),
                    menuHeight = menu.height.toFloat(),
                    screenWidth = width.toFloat(),
                    screenHeight = height.toFloat(),
                    gap = gap.toFloat(),
                )
                layout(width, height) {
                    // The picture lifts from the card's own place and size.
                    preview.placeWithLayer(card.left.roundToInt(), card.top.roundToInt()) {
                        val l = lift.value
                        val scale = 1f + (MENU_LIFT_SCALE - 1f) * l
                        scaleX = scale
                        scaleY = scale
                        translationY = place.shift * l
                        shadowElevation = 16.dp.toPx() * l.coerceIn(0f, 1f)
                        this.shape = shape
                        clip = true
                    }
                    menu.placeWithLayer(place.menuX.roundToInt(), place.menuY.roundToInt()) {
                        val l = lift.value.coerceIn(0f, 1f)
                        alpha = l
                        val scale = 0.9f + 0.1f * l
                        scaleX = scale
                        scaleY = scale
                        transformOrigin = TransformOrigin(0f, if (place.above) 1f else 0f)
                    }
                }
            }
        }
    }
}

/** Where a card's menu goes: at ([menuX], [menuY]), above the card or below it, the card (and the menu with it) moved down by [shift] (up when negative). */
internal data class CardMenuPlace(val menuX: Float, val menuY: Float, val above: Boolean, val shift: Float)

/**
 * Lays out a card's lifted picture and its menu as one region, in px: the
 * menu [gap] below the card as it is lifted (grown by [MENU_LIFT_SCALE] about
 * its middle), or above it when it does not fit below; when it fits neither,
 * the card moves up (or down) far enough for the menu to fit below it. The
 * menu starts at the card's left edge, kept [gap] inside the screen.
 */
internal fun placeCardMenu(
    card: Rect,
    menuWidth: Float,
    menuHeight: Float,
    screenWidth: Float,
    screenHeight: Float,
    gap: Float,
): CardMenuPlace {
    val liftedHalf = card.height * MENU_LIFT_SCALE / 2f
    val liftedTop = card.center.y - liftedHalf
    val liftedBottom = card.center.y + liftedHalf
    val liftedLeft = card.center.x - card.width * MENU_LIFT_SCALE / 2f
    val x = liftedLeft.coerceIn(gap, maxOf(gap, screenWidth - gap - menuWidth))
    return when {
        liftedBottom + gap + menuHeight <= screenHeight - gap -> CardMenuPlace(x, liftedBottom + gap, above = false, shift = 0f)
        liftedTop - gap - menuHeight >= gap -> CardMenuPlace(x, liftedTop - gap - menuHeight, above = true, shift = 0f)
        else -> {
            // Neither: the card goes up until the menu fits below it, but never above the screen's top.
            val wanted = (screenHeight - gap - menuHeight - gap) - liftedBottom
            val shift = maxOf(wanted, gap - liftedTop)
            CardMenuPlace(x, liftedBottom + shift + gap, above = false, shift = shift)
        }
    }
}

/**
 * Starts dragging a card out of the app: [picture] (the card as it looked)
 * follows the finger, held where the finger is on it ([touch], in px), and
 * [clip] (null: nothing to give yet) is what the app it is dropped in gets,
 * readable by it. Returns whether the system started the drag.
 */
internal fun startCardDrag(view: View, picture: ImageBitmap, touch: Offset, clip: ClipData?): Boolean {
    // The shadow is drawn on a software canvas, which cannot draw a hardware bitmap.
    val source = picture.asAndroidBitmap()
    val bitmap = if (source.config == Bitmap.Config.HARDWARE) source.copy(Bitmap.Config.ARGB_8888, false) else source
    val shadow = object : View.DragShadowBuilder(view) {
        override fun onProvideShadowMetrics(outShadowSize: Point, outShadowTouchPoint: Point) {
            outShadowSize.set(bitmap.width.coerceAtLeast(1), bitmap.height.coerceAtLeast(1))
            outShadowTouchPoint.set(
                touch.x.roundToInt().coerceIn(0, bitmap.width),
                touch.y.roundToInt().coerceIn(0, bitmap.height),
            )
        }

        override fun onDrawShadow(canvas: Canvas) {
            canvas.drawBitmap(bitmap, 0f, 0f, null)
        }
    }
    return try {
        view.startDragAndDrop(clip, shadow, null, View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ)
    } catch (e: Exception) {
        false
    }
}
