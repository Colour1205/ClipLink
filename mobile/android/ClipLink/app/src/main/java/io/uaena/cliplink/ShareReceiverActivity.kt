package io.uaena.cliplink

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.service.ClipLinkService
import io.uaena.cliplink.share.ShareOutcome
import io.uaena.cliplink.ui.theme.ClipLinkTheme
import kotlinx.coroutines.delay

/**
 * "Share to ClipLink" from any app's share sheet: text, one file or many.
 *
 * Its own translucent, out-of-recents activity rather than MainActivity, so
 * a share never opens the whole app (Compose UI, permission prompts) inside
 * the sending app's task. It copies what was shared while it still holds
 * the read grant, hands it to the engine, says what happened in a toast and
 * finishes - the user never leaves the app they shared from.
 *
 * EXPORTED AND SILENT, ON PURPOSE. Being a share target means being exported
 * (the system's share sheet has to be able to start it), so ANY app on this
 * phone can fire a SEND intent at it, and whatever it carries is signed with
 * this phone's key and sent to every paired device - where, with "Copy
 * received items automatically" on, it also lands on the clipboard - with no
 * confirmation here. That is the same reach every share target (a messenger,
 * a notes app) gives every other app, and a prompt on each share would defeat
 * the one-tap "share to ClipLink" this screen exists for. It is a documented
 * trade-off, not an oversight: do not "fix" it by un-exporting the activity
 * (that removes ClipLink from the share sheet altogether).
 */
class ShareReceiverActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Recreated, or relaunched from history: this share was already
        // handled by the first instance (whose copy carries on without it),
        // and a relaunch carries no fresh grant to read anything with.
        if (savedInstanceState != null || (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            finish()
            return
        }

        val engine = ClipLinkApplication.engine()
        engine.start()
        // With keep-alive on, the service is what keeps the process - and
        // the upload to the peers - going once this activity is gone.
        if (engine.deviceSettings.keepAlive) runCatching { ClipLinkService.start(this) }

        val uris = engine.shareIntake.sharedUris(intent)
        val text = engine.shareIntake.sharedText(intent)
        if (uris.isEmpty() && text.isNullOrBlank()) {
            finishWith(ShareOutcome().message, Toast.LENGTH_SHORT)
            return
        }

        // Nothing is drawn for a quick share. A big file takes a while to
        // copy, though, and meanwhile this invisible window is what the user
        // is touching - so after a moment it says what it's doing.
        setContent {
            ClipLinkTheme(dynamicColor = engine.deviceSettings.dynamicColor) {
                var showProgress by remember { mutableStateOf(false) }
                LaunchedEffect(Unit) {
                    delay(PROGRESS_DELAY_MS)
                    showProgress = true
                }
                if (showProgress) SendingCard()
            }
        }

        engine.shareIn(text, uris) { outcome ->
            val problems = outcome.failed || outcome.unreadable > 0 || outcome.tooLarge.isNotEmpty() ||
                outcome.skipped > 0
            finishWith(outcome.message, if (problems) Toast.LENGTH_LONG else Toast.LENGTH_SHORT)
        }
    }

    /**
     * An application-context toast: MainActivity's snackbar isn't on screen,
     * and this activity is gone a moment later.
     */
    private fun finishWith(message: String, duration: Int) {
        Toast.makeText(applicationContext, message, duration).show()
        finish()
    }

    private companion object {
        const val PROGRESS_DELAY_MS = 500L
    }
}

@Composable
private fun SendingCard() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            shadowElevation = 6.dp,
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 3.dp)
                Text("Adding to ClipLink…", style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}
