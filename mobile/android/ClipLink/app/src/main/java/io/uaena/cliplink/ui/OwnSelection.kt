package io.uaena.cliplink.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.LocalClipboard

/**
 * Puts a text on the clipboard as ClipLink's own clip (see
 * ClipboardBridge.copyText), provided by the Activity. Null where nothing
 * provides it - a preview: the selection then copies as Compose does.
 */
val LocalOwnCopy = staticCompositionLocalOf<((String) -> Unit)?> { null }

/**
 * A [SelectionContainer] whose Copy is ClipLink's own: what is copied out of
 * an item, or a device's id or address, is labelled and recorded like a card's
 * Copy. Compose's own clipboard labels it "plain text", and the next time the
 * app came forward the capture took it for a fresh copy from another app - a
 * received item selected whole and copied went out again as a second card.
 *
 * Only around static text: Compose's text fields reach for the platform's
 * clipboard manager through the clipboard itself, which only its own
 * clipboard gives them.
 */
@Composable
fun OwnSelectionContainer(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val copy = LocalOwnCopy.current
    val platform = LocalClipboard.current
    val clipboard = remember(copy, platform) { if (copy == null) platform else OwnClipboard(platform, copy) }
    // A full view shrinking back into its card lets go of what was selected in
    // it. The selection's handles and its Copy bar are windows of their own,
    // not part of the view: they stayed where they were, over the list the
    // view had handed the screen back to, until it had gone - and took the
    // taps meant for the cards under them. (A Box lays the text out as the
    // container does, one child over another from the top start.)
    val letGo = LocalZoomView.current?.zoom?.closing == true
    CompositionLocalProvider(LocalClipboard provides clipboard) {
        if (letGo) Box(modifier) { content() } else SelectionContainer(modifier) { content() }
    }
}

/** The platform's clipboard, with plain text written through [copy] instead. */
private class OwnClipboard(private val platform: Clipboard, private val copy: (String) -> Unit) : Clipboard {
    override suspend fun getClipEntry(): ClipEntry? = platform.getClipEntry()

    override suspend fun setClipEntry(clipEntry: ClipEntry?) {
        val data = clipEntry?.clipData
        val text = data?.takeIf { it.itemCount == 1 && it.getItemAt(0).uri == null }?.getItemAt(0)?.text?.toString()
        if (text != null) copy(text) else platform.setClipEntry(clipEntry)
    }

    @Deprecated("Use platform-specific extension to get platform reference")
    @Suppress("DEPRECATION")
    override val nativeClipboard: android.content.ClipboardManager
        get() = platform.nativeClipboard
}
