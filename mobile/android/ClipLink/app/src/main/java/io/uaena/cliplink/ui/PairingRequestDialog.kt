package io.uaena.cliplink.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import io.uaena.cliplink.engine.PairingRequest

/**
 * A pairing request, asked as a modal dialog over whatever screen is open -
 * not a page of its own. (When the app is not in front the same two answers
 * come from a notification; see service/PairingNotifier.kt.)
 *
 * Trust or Ignore, and only those: Ignore closes this one request and
 * remembers nothing, so the device can ask again. Blocking is a deliberate
 * act on the Devices tab, not something to do by accident from a prompt.
 *
 * The name is whatever the peer claims, so the id's fingerprint and the
 * address sit right under it - two devices can share a name, never an id.
 */
@Composable
fun PairingRequestDialog(
    request: PairingRequest,
    onTrust: () -> Unit,
    onIgnore: () -> Unit,
) {
    AlertDialog(
        // Back counts as Ignore; a tap outside does not, since that would
        // quietly turn away a request somebody was reading.
        onDismissRequest = onIgnore,
        properties = DialogProperties(dismissOnClickOutside = false),
        title = { Text("Pair with ${request.name ?: "a device with no name"}?") },
        text = {
            Column {
                Text(
                    "It wants to pair with this phone. Only trust it if you expect this. Ignore turns " +
                        "this request away and the device can ask again; to stop a device asking, " +
                        "block it on the Devices tab.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    // "Device AB12-CD34": the fingerprint the Me screen shows for
                    // its own id (here and on iOS), so the two can be compared.
                    listOfNotNull(request.shortId, request.address).joinToString("  \u2022  "),
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = { TextButton(onClick = onTrust) { Text("Trust") } },
        dismissButton = { TextButton(onClick = onIgnore) { Text("Ignore") } },
    )
}
