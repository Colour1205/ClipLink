package io.uaena.cliplink.ui

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The room at the bottom of a stack's front card for its handle: a clear touch
 * target, though the bar drawn in it is small.
 */
internal val STACK_HANDLE_ZONE = 44.dp

/** How far each layer behind the front card peeks out below it. */
private val PEEK_OFFSET = 8.dp

/** How much further each layer slides down when the stack is fully open. */
private val PEEK_SLIDE = 28.dp

/** A stack made less than this long ago has just arrived, and appears with a fade and a scale-in. */
private const val APPEAR_WINDOW_MS = 2_500L

private val CARD_SHAPE = RoundedCornerShape(26.dp)

/**
 * One card standing for the items of a history_batch: the newest in front,
 * [SyncedRow.Stack.layers] layers peeking out behind it, and a handle at the
 * bottom. Swiping down from the handle (or tapping it) opens the stack; the
 * opening follows the finger, and on release it completes or springs back.
 * Once it is open, [onExpand] is told, and the engine marks the group opened -
 * the items are ordinary cards from then on, and stay together below this one.
 */
@Composable
internal fun StackedCard(
    stack: SyncedRow.Stack,
    senderName: String?,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    compact: Boolean,
    reduceMotion: Boolean,
    onExpand: (SyncedRow.Stack) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val distancePx = with(density) { EXPAND_DISTANCE_DP.dp.toPx() }
    val peekPx = with(density) { PEEK_OFFSET.toPx() }
    val slidePx = with(density) { PEEK_SLIDE.toPx() }
    val scope = rememberCoroutineScope()
    val spatial = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()
    val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()

    // 0 is closed, 1 is open. Written by the finger and by the settling
    // spring, and only read while drawing, so a drag redraws and recomposes
    // nothing.
    var progress by remember(stack.groupId) { mutableFloatStateOf(0f) }
    var opened by remember(stack.groupId) { mutableStateOf(false) }
    var settling by remember(stack.groupId) { mutableStateOf<Job?>(null) }

    // One fade and a slight scale-in for the whole stack, however many items
    // it holds - and only for one that has just arrived, not one scrolled into
    // view or a screen coming back.
    val appear = remember(stack.groupId) {
        val fresh = System.currentTimeMillis() - stack.createdAtMs < APPEAR_WINDOW_MS
        Animatable(if (fresh) 0f else 1f)
    }
    LaunchedEffect(stack.groupId) {
        if (appear.value < 1f) appear.animateTo(1f, if (reduceMotion) tween(120) else effects)
    }

    fun settle(open: Boolean, velocityPxPerSecond: Float) {
        if (opened) return
        settling?.cancel()
        settling = scope.launch {
            val target = if (open) 1f else 0f
            if (reduceMotion) {
                progress = target
            } else {
                animate(progress, target, velocityPxPerSecond / distancePx, spatial) { value, _ -> progress = value }
            }
            if (open) {
                opened = true
                onExpand(stack)
            }
        }
    }

    Box(
        modifier
            .fillMaxWidth()
            .graphicsLayer {
                val a = appear.value
                alpha = a
                if (!reduceMotion) {
                    val scale = 0.94f + 0.06f * a
                    scaleX = scale
                    scaleY = scale
                }
            }
            .padding(bottom = PEEK_OFFSET * stack.layers),
    ) {
        // Farthest first, so the nearest layer is drawn over it.
        for (layer in stack.layers downTo 1) {
            PeekLayer(layer, peekPx, slidePx) { progress }
        }
        SyncedCard(
            keyed = stack.front,
            senderName = senderName,
            onOpen = onOpen,
            actions = actions,
            compact = compact,
            stackFooter = {
                StackFooter(
                    behindCount = stack.behindCount,
                    progress = { progress },
                    onDragStart = { settling?.cancel() },
                    onDelta = { delta ->
                        if (!opened) progress = (progress + delta / distancePx).coerceIn(0f, 1f)
                    },
                    onDragStop = { velocityPxPerSecond ->
                        val dpPerSecond = velocityPxPerSecond / density.density
                        settle(expansionCompletes(progress, dpPerSecond), velocityPxPerSecond)
                    },
                    onTap = { settle(true, 0f) },
                )
            },
        )
    }
}

/** A layer behind the front card: narrower, a little dimmer, and sliding apart and away as the stack opens. */
@Composable
private fun BoxScope.PeekLayer(layer: Int, peekPx: Float, slidePx: Float, progress: () -> Float) {
    val base = MaterialTheme.colorScheme.surfaceContainerLow
    Surface(
        shape = CARD_SHAPE,
        color = Color.Black.copy(alpha = 0.05f * layer).compositeOver(base),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
        modifier = Modifier
            .matchParentSize()
            .graphicsLayer {
                val p = progress().coerceIn(0f, 1f)
                translationY = layer * (peekPx + p * slidePx)
                val narrower = 1f - layer * 0.05f * (1f - p)
                scaleX = narrower
                alpha = 1f - p
            },
    ) {}
}

/** The handle, centred at the bottom of the front card, and the count of what is behind it at the end. Both fade out as the stack opens. */
@Composable
private fun BoxScope.StackFooter(
    behindCount: Int,
    progress: () -> Float,
    onDragStart: () -> Unit,
    onDelta: (Float) -> Unit,
    onDragStop: (Float) -> Unit,
    onTap: () -> Unit,
) {
    val description = pluralStringResource(R.plurals.stack_expand_description, behindCount, behindCount)
    val hint = stringResource(R.string.stack_expand_hint)
    val currentDelta by rememberUpdatedState(onDelta)
    val dragState = rememberDraggableState { delta -> currentDelta(delta) }

    Box(
        Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .height(STACK_HANDLE_ZONE)
            .graphicsLayer { alpha = 1f - progress().coerceIn(0f, 1f) },
    ) {
        // The touch target: as tall as the zone and up to 128 dp wide (about half the card, so it
        // stays clear of the count in a narrow grid card), around a bar that is much smaller.
        Box(
            Modifier
                .align(Alignment.Center)
                .fillMaxWidth(0.5f)
                .widthIn(max = 128.dp)
                .fillMaxHeight()
                .clip(RoundedCornerShape(16.dp))
                .draggable(
                    state = dragState,
                    orientation = Orientation.Vertical,
                    onDragStarted = { onDragStart() },
                    onDragStopped = { velocity -> onDragStop(velocity) },
                )
                .clickable(onClickLabel = hint, role = Role.Button, onClick = onTap)
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size(width = 36.dp, height = 4.dp)
                    .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f), CircleShape),
            )
        }
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.secondaryContainer,
            contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = 12.dp),
        ) {
            Text(
                stringResource(R.string.stack_badge, behindCount),
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp),
            )
        }
    }
}

/**
 * Makes a card that was hidden in a stack fly out of it and settle into its
 * place with a spring, after [RevealSlot.delayMs]; [onDone] when it has. With
 * no [slot] the card is left as it is. With reduced motion it only fades in.
 */
@Composable
internal fun Modifier.revealIn(slot: RevealSlot?, reduceMotion: Boolean, onDone: () -> Unit): Modifier {
    if (slot == null) return this
    val spatial = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()
    val gapPx = with(LocalDensity.current) { CARD_GAP.toPx() }
    val progress = remember { Animatable(0f) }
    var heightPx by remember { mutableIntStateOf(0) }
    val finished by rememberUpdatedState(onDone)
    LaunchedEffect(Unit) {
        if (reduceMotion) {
            progress.animateTo(1f, tween(120))
        } else {
            delay(slot.delayMs.toLong())
            progress.animateTo(1f, spatial)
        }
        finished()
    }
    return this
        .onSizeChanged { heightPx = it.height }
        .graphicsLayer {
            val p = progress.value
            alpha = if (reduceMotion) p.coerceIn(0f, 1f) else (p * 2f).coerceIn(0f, 1f)
            if (!reduceMotion) {
                translationY = -(1f - p) * slot.stepsAbove * (heightPx + gapPx)
                val scale = 0.9f + 0.1f * p
                scaleX = scale
                scaleY = scale
            }
        }
}

/** The space between cards in the list and the grid. */
internal val CARD_GAP = 12.dp

/**
 * Whether the system's animations are off (Developer options, or "Remove
 * animations" in Accessibility): the animator duration scale is 0. Followed
 * live.
 */
@Composable
internal fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    var reduce by remember { mutableStateOf(animationsOff(context)) }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                reduce = animationsOff(context)
            }
        }
        val resolver = context.contentResolver
        runCatching {
            resolver.registerContentObserver(
                Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
                false,
                observer,
            )
        }
        onDispose { runCatching { resolver.unregisterContentObserver(observer) } }
    }
    return reduce
}

private fun animationsOff(context: Context): Boolean = try {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
} catch (e: Exception) {
    false
}
