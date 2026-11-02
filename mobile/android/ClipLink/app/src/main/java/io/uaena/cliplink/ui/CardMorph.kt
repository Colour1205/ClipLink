package io.uaena.cliplink.ui

import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.core.spring
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import kotlin.math.sqrt

/**
 * What a card needs to grow into its full view and back: the screens' shared
 * transition, and the side of it (the list going, or the full view coming)
 * the card is on. Null where there is no such transition (a preview).
 */
internal class CardMorph(val shared: SharedTransitionScope, val visibility: AnimatedVisibilityScope)

internal val LocalCardMorph = compositionLocalOf<CardMorph?> { null }

/**
 * The spring a card grows into its full view with, and shrinks back: the
 * HarmonyOS app's interpolatingSpring(0, 1, 328, 36) - mass 1, stiffness 328,
 * damping 36, so just short of critically damped.
 */
private val MORPH_SPRING = spring(
    dampingRatio = 36f / (2f * sqrt(328f)),
    stiffness = 328f,
    visibilityThreshold = Rect.VisualThreshold,
)

private val Rect.Companion.VisualThreshold: Rect get() = Rect(0.5f, 0.5f, 0.5f, 0.5f)

/**
 * The card of item [key] in the list and the item's full view are one thing
 * that changes shape: opening the item, the card itself grows into the full
 * screen; closing it, the screen shrinks back into the card.
 */
@Composable
internal fun Modifier.cardMorph(key: String): Modifier {
    val morph = LocalCardMorph.current ?: return this
    return with(morph.shared) {
        this@cardMorph.sharedBounds(
            sharedContentState = rememberSharedContentState("card:$key"),
            animatedVisibilityScope = morph.visibility,
            boundsTransform = { _, _ -> MORPH_SPRING },
            clipInOverlayDuringTransition = OverlayClip(RoundedCornerShape(CARD_RADIUS)),
        )
    }
}
