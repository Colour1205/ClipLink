package io.uaena.cliplink.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalUriHandler

/** The website: the downloads for Windows, Android, HarmonyOS and iOS. */
const val WEBSITE_HOST = "cliplink.uaena.io"
const val WEBSITE_URL = "https://$WEBSITE_HOST/"

/**
 * "Get ClipLink on your other devices": the website's address, a tap opens it
 * in the browser. On the Devices tab and the pairing screen, where it comes up
 * that the other device does not have ClipLink yet.
 */
@Composable
fun GetClipLinkRow() {
    val uriHandler = LocalUriHandler.current
    SettingRow(
        title = "Get ClipLink on your other devices",
        subtitle = WEBSITE_HOST,
        trailing = {
            Icon(
                Icons.AutoMirrored.Outlined.OpenInNew,
                contentDescription = "Opens the website",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        // No browser to open it with: nothing to do, and no toast for it.
        onClick = { runCatching { uriHandler.openUri(WEBSITE_URL) } },
    )
}
