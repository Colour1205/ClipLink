package io.uaena.cliplink.ui

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.EaseIn
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.uaena.cliplink.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/** The corners of every card in the list and the grid, and of the layers behind a stack's. */
internal val CARD_RADIUS = 26.dp

private val CARD_SHAPE = RoundedCornerShape(CARD_RADIUS)

// A layer is drawn taller than what shows: only its bottom edge is below the
// card, the rest is clipped away, so it reads as a whole card slid behind.
private val LAYER_HEIGHT = 70.dp

// The handle: a short bar, low in a touch target 240 x 56 dp centred at the
// bottom of the card. The bar sits inside the card's own bottom padding, so
// the card is no taller than an ordinary one.
private val HANDLE_WIDTH = 240.dp
private val HANDLE_HEIGHT = 56.dp
private val BAR_WIDTH = 36.dp
private val BAR_HEIGHT = 5.dp
private val BAR_BOTTOM = 8.dp

/** A pull on the handle starts once the finger has gone this far down (dp); anything else is the list's. */
private const val PULL_START_DP = 4f

/** The layers hand over to the real cards, which start exactly where the layers are: they fade out over this long, under them. */
private const val LAYER_FADE_MS = 120

/** After a finger lets go with the cards popped out, the handle (and the count it froze) stays this much longer. */
private const val HOLD_AFTER_RELEASE_MS = 320L

/** The most a lifted finger waits (ms) for cards it put back to be one stack again before the layers it held go. */
private const val RECLOSE_WAIT_MS = 1_000L

/** A row that never got laid out this soon after its stack opened (scrolled away) just shows, in place. */
private const val REVEAL_LAYOUT_WAIT_MS = 600L

/** The HarmonyOS app's springMotion(response, dampingFraction), as a Compose spring (see [springStiffness]). */
internal fun <T> springMotion(response: Float, damping: Float, visibilityThreshold: T? = null) =
    spring(dampingRatio = damping, stiffness = springStiffness(response), visibilityThreshold = visibilityThreshold)

/**
 * The stack the user opened last, while its hidden cards slide out of it (or
 * back into it): held by the screen, read by every row.
 */
@Stable
internal class StackReveal {
    var scene by mutableStateOf<RevealScene?>(null)
}

/**
 * One opening of a stack. [slots] are the cards that slide out, by key, to
 * their index (1 is the one right behind the front card); [members] are all
 * of the stack's items. The rest are positions on the screen (px, in root
 * coordinates) as they were when it opened: the front card's bottom edge and
 * its middle.
 */
internal class RevealScene(
    val generation: Int,
    val groupId: Long,
    val frontKey: String,
    val stretch: Float,
    val cardBottom: Float,
    val frontCenterX: Float,
    val slots: Map<String, Int>,
    val members: Set<String>,
    val startedAtMs: Long,
) {
    /** The finger that opened it came back up before it was lifted: the cards go back in. */
    var collapsing by mutableStateOf(false)

    /**
     * The finger that popped it open is still down, so the cards can still go
     * back in: the scene is kept however long it is held.
     */
    var held by mutableStateOf(false)
}

/** What [StackedCard] tells the screen: a stack was opened, or put back. */
internal class StackCallbacks(
    /**
     * [stretch] is how far its layers had been pulled apart (0 to 1); [cardBottom] and [centerX] are the front card's, in root px.
     * [held]: popped by a finger still down, so it can still be put back (see [onLetGo]).
     */
    val onExpand: (stack: SyncedRow.Stack, stretch: Float, cardBottom: Float, centerX: Float, held: Boolean) -> Unit,
    val onCollapse: (groupId: Long) -> Unit,
    /** The finger that popped the stack open was lifted (or the touch was taken from it): it is open for good. */
    val onLetGo: (groupId: Long) -> Unit,
)

/**
 * The wrapper every card of the Synced tab sits in. For an ordinary card it
 * adds nothing but the way it comes in: growing from small when it has just
 * arrived, or sliding out from where its stack's layer was when the stack it
 * was hidden in has just been opened (see [StackReveal]). For the front card
 * of a stack it adds what makes it a stack: layers peeking out below the
 * card, the "+N" count at the end of its footer row, and a handle at its
 * bottom that opens the stack.
 *
 * The pull has two parts. Up to the commit point ([COMMIT_DRAG_DP]) the stack
 * stretches against a rubber band's resistance, following the finger. There
 * (with a tick of haptic feedback, see the screen) the items become real
 * cards that start where the layers were and slide out to their places by
 * themselves - the finger still down - and stay tied to it: bring it back
 * above [RELEASE_DRAG_DP] and they slide back into the stack, as far down as
 * it goes and they pop out again. A tap on the handle opens it at once.
 *
 * Every row goes through here, so the row a stack's front card is in stays
 * the same composition when the stack opens under the finger.
 */
@Composable
internal fun StackedCard(
    front: KeyedItem,
    /** The stack [front] stands for, or null for an ordinary card. */
    stack: SyncedRow.Stack?,
    senderName: String?,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    compact: Boolean,
    reduceMotion: Boolean,
    reveal: StackReveal,
    callbacks: StackCallbacks,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val currentStack by rememberUpdatedState(stack)

    // 0 (closed) to 1 (open). While a finger is on the handle it is the rubber
    // band's stretch (it never gets past RUBBER_REACH). Only read while
    // drawing, so a pull redraws and recomposes nothing.
    val progress = remember { Animatable(0f) }
    // 0 to 1: how far the layers (and the handle) have faded out after the pop.
    val fade = remember { Animatable(0f) }
    // A finger is on the handle, or just left it: the handle and the count
    // stay even when the stack has been opened, because the stack's items -
    // and so whether this is a stack at all - change under the finger.
    var holding by remember { mutableStateOf(false) }
    var heldBehind by remember { mutableIntStateOf(0) }
    val pull = remember { PullState() }

    // The stack this row stood for last: the finger that put its cards back
    // can pop them out again before the list has made them one stack again.
    val lastStack = remember { arrayOfNulls<SyncedRow.Stack>(1) }
    if (stack != null) lastStack[0] = stack
    val behind = stack?.behindCount ?: 0
    val shownBehind = if (holding) maxOf(behind, heldBehind) else behind
    val layers = minOf(MAX_STACK_LAYERS, shownBehind)

    // A stack of another group in this row (its front was opened and the row
    // was later given a stack again): nothing of the last one's pull is left.
    LaunchedEffect(stack?.groupId) {
        val group = stack?.groupId ?: return@LaunchedEffect
        if (group != pull.openedGroup && !holding) {
            pull.opened = false
            pull.revertible = false
            fade.snapTo(0f)
            progress.snapTo(0f)
        }
    }

    // How a row comes in. A card that just arrived grows from 60% and fades in,
    // a stack's front card the same way; a card that was hidden in a stack
    // that just opened comes out of it instead (below), and so does not grow.
    val scene = reveal.scene
    val slot = scene?.slots?.get(front.key)
    val appear = remember {
        val fresh = arrivesFresh(front.item.arrivedAtMs, System.currentTimeMillis()) &&
            scene?.members?.contains(front.key) != true
        Animatable(if (fresh) 0f else 1f)
    }
    LaunchedEffect(Unit) {
        if (appear.value < 1f) {
            appear.animateTo(1f, if (reduceMotion) tween(150, easing = EaseInOut) else springMotion(0.3f, 0.85f))
        }
    }

    val revealMotion = if (slot != null) rememberRevealMotion(scene, slot, reduceMotion) else null

    val coordinates = remember { arrayOfNulls<LayoutCoordinates>(1) }

    fun cardBottomAndCentre(): Pair<Float, Float> {
        val coords = coordinates[0]?.takeIf { it.isAttached } ?: return 0f to 0f
        val at = coords.positionInRoot()
        val room = with(density) { (STACK_PEEK_DP * layers).dp.toPx() }
        return (at.y + coords.size.height - room) to (at.x + coords.size.width / 2f)
    }

    fun moveProgress(target: Float, spec: AnimationSpec<Float>?) {
        pull.progressJob?.cancel()
        pull.progressJob = scope.launch {
            if (spec == null) progress.snapTo(target) else progress.animateTo(target, spec)
        }
    }

    fun returnSpec(): AnimationSpec<Float> =
        if (reduceMotion) tween(120, easing = EaseOut) else springMotion(0.35f, 0.8f)

    // Opens the stack (the pull got to the commit point, a fast swipe, a tap,
    // or an assistive tool pressing the handle): the screen shows the items as
    // ordinary cards that start where the layers are, wherever the finger had
    // stretched them to, and slide out to their places; the layers fade out
    // under them.
    fun expand(revertible: Boolean) {
        val opening = currentStack ?: lastStack[0]?.takeIf { holding && it.groupId == pull.openedGroup } ?: return
        if (pull.opened || shownBehind < 1) return
        pull.opened = true
        pull.revertible = revertible
        pull.catchingUp = false
        pull.reclosing = false
        pull.openedGroup = opening.groupId
        pull.fadeJob?.cancel()
        pull.fadeJob = scope.launch {
            fade.animateTo(1f, tween(if (reduceMotion) 100 else LAYER_FADE_MS, easing = EaseIn))
        }
        val (cardBottom, centerX) = cardBottomAndCentre()
        callbacks.onExpand(opening, progress.value, cardBottom, centerX, revertible)
    }

    // The finger that popped the cards out came back up before it was lifted:
    // they go back into the stack, which follows the finger again.
    fun collapse(translationDp: Float) {
        if (!pull.opened || !pull.revertible) return
        pull.opened = false
        pull.revertible = false
        pull.reclosing = true
        callbacks.onCollapse(pull.openedGroup)
        // The layers come back to where the finger has them now, and keep up
        // with it from there until they have caught up.
        pull.catchingUp = true
        moveProgress(dragProgress(translationDp), returnSpec())
        pull.fadeJob?.cancel()
        pull.fadeJob = scope.launch { fade.animateTo(0f, returnSpec()) }
    }

    fun follow(translationDp: Float) {
        if (pull.opened) {
            // Popped out, finger still down: back above the release point and
            // the cards go back into the stack.
            if (pull.revertible && shouldCollapse(translationDp)) collapse(translationDp)
            return
        }
        // Past the commit point the cards pop out by themselves, finger still
        // down; before it the stack follows the finger with a rubber band's
        // resistance.
        if (reachedCommit(translationDp)) {
            expand(revertible = true)
        } else if (pull.catchingUp) {
            val job = scope.launch { progress.animateTo(dragProgress(translationDp), returnSpec()) }
            pull.progressJob?.cancel()
            pull.progressJob = job
            job.invokeOnCompletion { cause -> if (cause == null) pull.catchingUp = false }
        } else {
            moveProgress(dragProgress(translationDp), null)
        }
    }

    // The finger let go (or the gesture was taken from it): where the cards
    // are now is final. A pull that let go early springs back.
    fun release(translationDp: Float, velocityDpPerSecond: Float, cancelled: Boolean) {
        pull.catchingUp = false
        if (pull.opened) {
            if (pull.revertible) callbacks.onLetGo(pull.openedGroup)
            pull.revertible = false
        } else {
            if (!cancelled && shouldExpand(translationDp, velocityDpPerSecond)) expand(revertible = false)
            if (!pull.opened) moveProgress(0f, returnSpec())
        }
        pull.holdJob?.cancel()
        pull.holdJob = scope.launch {
            if (pull.opened) {
                delay(HOLD_AFTER_RELEASE_MS)
            } else if (pull.reclosing) {
                // Cards just put back are one stack again only once they have
                // slid back in: until then the layers (and the room they take)
                // stay, rather than going and coming back.
                withTimeoutOrNull(RECLOSE_WAIT_MS) { snapshotFlow { currentStack }.first { it != null } }
            }
            pull.reclosing = false
            // The room the layers took goes; the cards below glide up into it
            // (see the list's placement).
            holding = false
        }
    }

    val chromeAlpha = { stackChromeAlpha(progress.value, fade.value) }

    Box(
        modifier
            .fillMaxWidth()
            .onPlaced { coordinates[0] = it }
            .then(if (revealMotion != null && scene != null && slot != null) Modifier.revealFrom(revealMotion, scene, slot, density.density) else Modifier)
            .graphicsLayer {
                val a = appear.value.coerceIn(0f, 1f)
                var shown = a
                if (!reduceMotion && appear.value != 1f) {
                    val scale = 0.6f + 0.4f * appear.value
                    scaleX = scale
                    scaleY = scale
                }
                if (revealMotion != null) {
                    val motion = revealMotion
                    val start = motion.start
                    val p = motion.progress.value
                    if (start != null && !reduceMotion) {
                        translationX = start.dx * (1f - p)
                        translationY = start.dy * (1f - p)
                        val scale = start.scale + (1f - start.scale) * p
                        scaleX = scale
                        scaleY = scale
                    }
                    shown *= motion.alpha.value.coerceIn(0f, 1f)
                }
                alpha = shown
            }
            // The room the layers peek into: fixed while they move, so a pull
            // never moves the cards below.
            .padding(bottom = (STACK_PEEK_DP * layers).dp),
    ) {
        if (layers > 0) StackLayers(layers, { progress.value }, { fade.value })

        SyncedCard(
            keyed = front,
            senderName = senderName,
            onOpen = onOpen,
            actions = actions,
            compact = compact,
            footerTrailing = if (shownBehind > 0) {
                { StackBadge(shownBehind, chromeAlpha) }
            } else {
                null
            },
        )

        if (shownBehind > 0) {
            StackHandle(
                behindCount = shownBehind,
                alpha = chromeAlpha,
                onStart = {
                    pull.holdJob?.cancel()
                    pull.progressJob?.cancel()
                    heldBehind = behind
                    holding = true
                },
                onPull = ::follow,
                onRelease = ::release,
                onTap = { expand(revertible = false) },
            )
        }
    }
}

/** What a pull on one stack's handle has done so far. Plain fields: only the gesture reads them. */
private class PullState {
    /** The cards are out (popped by a pull, or opened by a tap). */
    var opened = false

    /** They were popped by a pull whose finger is still down, so they can still go back; a tap or a lifted finger makes them final. */
    var revertible = false

    /** The layers are on their way back to the finger after the cards went back in. */
    var catchingUp = false

    /** The cards were put back, and the list has not made them one stack again yet. */
    var reclosing = false
    var openedGroup = -1L
    var progressJob: Job? = null
    var fadeJob: Job? = null
    var holdJob: Job? = null
}

/**
 * The layers behind the front card, in a clipped strip just below it: only
 * what is below the card shows, so a card pressed smaller has nothing peeking
 * out around it. Farthest first, so the nearest is drawn over it.
 */
@Composable
private fun BoxScope.StackLayers(layers: Int, progress: () -> Float, fade: () -> Float) {
    val strip = ((STACK_PEEK_DP + STACK_SPREAD_DP) * layers).dp
    Box(
        Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .height(strip)
            .graphicsLayer {
                translationY = strip.toPx() - 1.dp.toPx()
                clip = true
            },
    ) {
        for (depth in layers downTo 1) StackLayer(depth, progress, fade)
    }
}

/** One layer: as wide as the card less 12 dp a side per step back, its bottom edge [STACK_PEEK_DP] further down per step, sliding apart as the stack stretches. */
@Composable
private fun StackLayer(depth: Int, progress: () -> Float, fade: () -> Float) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(LAYER_HEIGHT)
            .padding(horizontal = (STACK_LAYER_INSET_DP * depth).dp)
            .graphicsLayer {
                translationY = (depth * (STACK_PEEK_DP + progress() * STACK_SPREAD_DP)).dp.toPx() - LAYER_HEIGHT.toPx()
                alpha = stackLayerAlpha(depth, fade())
            }
            .background(MaterialTheme.colorScheme.surfaceContainerLow, CARD_SHAPE)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CARD_SHAPE),
    )
}

/**
 * The count of what is behind the front card, at the end of its footer row,
 * in the accent colour, fading out as the stack stretches. Only drawn: a tap
 * on it is a tap on the card.
 */
@Composable
private fun StackBadge(behindCount: Int, alpha: () -> Float) {
    Text(
        stringResource(R.string.stack_badge, behindCount),
        style = MaterialTheme.typography.labelMedium,
        fontSize = 12.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onPrimary,
        maxLines = 1,
        modifier = Modifier
            .graphicsLayer { this.alpha = alpha() }
            .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(12.dp))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

/**
 * The handle, centred at the bottom of the front card. A pull down that
 * starts on it opens the stack; one that starts anywhere else is the list's
 * to scroll, and so is a swipe up, so the two never fight.
 */
@Composable
private fun BoxScope.StackHandle(
    behindCount: Int,
    alpha: () -> Float,
    onStart: () -> Unit,
    onPull: (translationDp: Float) -> Unit,
    onRelease: (translationDp: Float, velocityDpPerSecond: Float, cancelled: Boolean) -> Unit,
    onTap: () -> Unit,
) {
    val description = pluralStringResource(R.plurals.stack_expand_description, behindCount, behindCount)
    val hint = stringResource(R.string.stack_expand_hint)
    val start by rememberUpdatedState(onStart)
    val pull by rememberUpdatedState(onPull)
    val release by rememberUpdatedState(onRelease)
    val tap by rememberUpdatedState(onTap)

    Box(
        Modifier
            .align(Alignment.BottomCenter)
            .width(HANDLE_WIDTH)
            .height(HANDLE_HEIGHT)
            .graphicsLayer { this.alpha = alpha() }
            .pointerInput(Unit) {
                detectStackPull(
                    onTap = { tap() },
                    onStart = { start() },
                    onPull = { pull(it) },
                    onRelease = { t, v, cancelled -> release(t, v, cancelled) },
                )
            }
            .semantics {
                contentDescription = description
                role = Role.Button
                onClick(label = hint) {
                    tap()
                    true
                }
            },
        contentAlignment = Alignment.BottomCenter,
    ) {
        Box(
            Modifier
                .padding(bottom = BAR_BOTTOM)
                .size(width = BAR_WIDTH, height = BAR_HEIGHT)
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f), RoundedCornerShape(BAR_HEIGHT / 2)),
        )
    }
}

/**
 * A pull down on the handle: claimed once the finger has moved [PULL_START_DP]
 * down (more down than sideways), then followed - [onPull] with how far down
 * it is from where it came down, in dp - until it lifts ([onRelease] with the
 * speed it left at) or is taken away (cancelled). A press that does not move
 * is a tap. Anything else is left to the list.
 */
private suspend fun PointerInputScope.detectStackPull(
    onTap: () -> Unit,
    onStart: () -> Unit,
    onPull: (Float) -> Unit,
    onRelease: (Float, Float, Boolean) -> Unit,
) {
    val startPx = PULL_START_DP.dp.toPx()
    awaitEachGesture {
        val down = awaitFirstDown()
        val tracker = VelocityTracker()
        tracker.addPointerInputChange(down)
        var pulling = false
        var ended = false
        var translationDp = 0f
        try {
            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (change.changedToUpIgnoreConsumed()) {
                    if (pulling) {
                        tracker.addPointerInputChange(change)
                        change.consume()
                        ended = true
                        onRelease(translationDp, tracker.calculateVelocity().y / density, false)
                    } else if (!change.isConsumed) {
                        change.consume()
                        onTap()
                    }
                    break
                }
                val moved = change.position - down.position
                if (!pulling) {
                    // The list started scrolling, or the finger went anywhere but down.
                    if (change.isConsumed) break
                    if (moved.y >= startPx && moved.y >= abs(moved.x)) {
                        pulling = true
                        onStart()
                    } else if (moved.getDistance() > viewConfiguration.touchSlop) {
                        break
                    }
                }
                if (pulling) {
                    tracker.addPointerInputChange(change)
                    change.consume()
                    translationDp = moved.y / density
                    onPull(translationDp)
                }
            }
        } finally {
            if (pulling && !ended) onRelease(0f, 0f, true)
        }
    }
}

/** How one card of an opened stack is coming out of it (or going back in). */
@Stable
internal class RevealMotion {
    /** 0 where its layer was, 1 in its place. */
    val progress = Animatable(0f)

    /** It is invisible at first, and fades in as it slides out from under the front card. */
    val alpha = Animatable(0f)

    /** Where it starts relative to its place, once its place is known (it has been laid out). */
    var start by mutableStateOf<RevealStart?>(null)

    /** Its slide out has begun (or it was shown without one). */
    var started = false
}

/**
 * The slide of the card [index] of an opened stack: once its row has been
 * laid out (see [revealFrom]), it is put where its layer was, and after one
 * frame it springs to its place, each 30 ms after the one before, fading in
 * 90 ms later. If the finger brings the cards back in, it slides back to where
 * it started. With reduced motion it only fades.
 */
@Composable
private fun rememberRevealMotion(scene: RevealScene, index: Int, reduceMotion: Boolean): RevealMotion {
    val motion = remember(scene.generation) { RevealMotion() }
    LaunchedEffect(scene.generation, scene.collapsing) {
        if (scene.collapsing) {
            when {
                reduceMotion -> motion.alpha.animateTo(0f, tween(150, easing = EaseInOut))
                // Still waiting to be laid out: it never moved, it just goes.
                motion.start == null -> motion.alpha.snapTo(0f)
                else -> motion.progress.animateTo(0f, springMotion(0.4f, 0.9f))
            }
            return@LaunchedEffect
        }
        if (motion.started) {
            // Popped out again before it was back in the stack: to its place from where it is.
            launch { motion.alpha.animateTo(1f, tween(160, easing = EaseOut)) }
            if (reduceMotion) motion.progress.snapTo(1f) else motion.progress.animateTo(1f, springMotion(0.45f, 0.8f))
            return@LaunchedEffect
        }
        motion.started = true
        if (reduceMotion) {
            motion.progress.snapTo(1f)
            motion.alpha.animateTo(1f, tween(150, easing = EaseInOut))
            return@LaunchedEffect
        }
        val wait = REVEAL_LAYOUT_WAIT_MS - (System.currentTimeMillis() - scene.startedAtMs)
        val placed = withTimeoutOrNull(wait.coerceAtLeast(0L)) { snapshotFlow { motion.start }.first { it != null } }
        if (placed == null) {
            // Never laid out in time (it was scrolled away): it just shows, in place.
            motion.progress.snapTo(1f)
            motion.alpha.snapTo(1f)
            return@LaunchedEffect
        }
        delay(24) // one frame where the layer was, then the slide
        val stagger = staggerDelayMs(index).toLong()
        launch {
            delay(stagger + 90)
            motion.alpha.animateTo(1f, tween(160, easing = EaseOut))
        }
        delay(stagger)
        motion.progress.animateTo(1f, springMotion(0.45f, 0.8f))
    }
    return motion
}

/** Works out where [motion] starts once the row is laid out (before any of its own transforms). */
private fun Modifier.revealFrom(motion: RevealMotion, scene: RevealScene, index: Int, density: Float): Modifier =
    onPlaced { coords ->
        if (motion.start != null || coords.size.width == 0 || scene.collapsing) return@onPlaced
        val at = coords.positionInRoot()
        motion.start = revealStart(
            index = index,
            stretch = scene.stretch,
            frontCenterX = scene.frontCenterX,
            cardBottom = scene.cardBottom,
            ownLeft = at.x,
            ownTop = at.y,
            ownWidth = coords.size.width.toFloat(),
            ownHeight = coords.size.height.toFloat(),
            density = density,
        )
    }

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

/** The space between cards in the list and the grid. */
internal val CARD_GAP = 12.dp
