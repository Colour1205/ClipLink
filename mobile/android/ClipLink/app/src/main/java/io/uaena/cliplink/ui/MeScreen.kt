package io.uaena.cliplink.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.R
import io.uaena.cliplink.engine.LogLine
import io.uaena.cliplink.engine.shortIdOf

data class MeState(
    val ownDeviceId: String,
    /** What the user typed as this device's name; empty means [defaultDeviceName]. */
    val deviceNameOverride: String,
    val defaultDeviceName: String,
    val hasPassphrase: Boolean,
    /** A new passcode's key is still being derived; Change and Clear wait for it. */
    val passphraseBusy: Boolean,
    val tailscaleIp: String,
    val keepAlive: Boolean,
    val autoApply: Boolean,
    val autoCapture: Boolean,
    val dynamicColor: Boolean,
    val localAddresses: List<String>,
    val log: List<LogLine>,
)

data class MeActions(
    val onSetPassphrase: (String) -> Unit,
    val onClearPassphrase: () -> Unit,
    val onSaveTailscaleIp: (String) -> Unit,
    val onSaveDeviceName: (String) -> Unit,
    val onKeepAliveChange: (Boolean) -> Unit,
    val onAutoApplyChange: (Boolean) -> Unit,
    val onAutoCaptureChange: (Boolean) -> Unit,
    val onDynamicColorChange: (Boolean) -> Unit,
    val onClearHistory: () -> Unit,
    val onCopyDeviceId: () -> Unit,
)

@Composable
fun MeScreen(
    state: MeState,
    actions: MeActions,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    var passphrase by remember { mutableStateOf("") }
    var tailscale by remember(state.tailscaleIp) { mutableStateOf(state.tailscaleIp) }
    var deviceName by remember(state.deviceNameOverride) { mutableStateOf(state.deviceNameOverride) }
    val shownName = state.deviceNameOverride.ifBlank { state.defaultDeviceName }
    var confirmingClear by remember { mutableStateOf(false) }
    var confirmingClearPassphrase by remember { mutableStateOf(false) }

    LazyColumn(
        contentPadding = PaddingValues(
            start = 16.dp,
            end = 16.dp,
            bottom = contentPadding.calculateBottomPadding() + 32.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier.fillMaxSize(),
    ) {
        item { ScreenTitle("Me", contentPadding.calculateTopPadding()) }

        item {
            Surface(
                shape = RoundedCornerShape(26.dp),
                color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(20.dp)) {
                    Text(
                        "This device",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                    if (shownName.isNotEmpty()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            shownName,
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    // The fingerprint a pairing prompt on the other device
                    // shows - the id's first characters are the same for
                    // every device, so they're no use for comparing.
                    Text(
                        if (state.ownDeviceId.isEmpty()) "Generating identity…" else shortIdOf(state.ownDeviceId),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                    if (state.ownDeviceId.isNotEmpty()) {
                        Text(
                            "Pairing prompts on your other devices show this ID — check that it matches.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                        )
                    }
                    if (state.localAddresses.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            state.localAddresses.joinToString("  •  "),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    TextButton(onClick = actions.onCopyDeviceId) { Text("Copy device ID") }
                }
            }
        }

        item { SectionHeader("Device name") }
        item {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        "How this device appears on your other devices. Leave it empty to use " +
                            "this phone's own name.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(14.dp))
                    OutlinedTextField(
                        value = deviceName,
                        onValueChange = { deviceName = it },
                        label = { Text("Device name") },
                        // Empty field = the phone's own name, so show which
                        // one that is rather than leave the user guessing.
                        placeholder = { Text(state.defaultDeviceName) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = { actions.onSaveDeviceName(deviceName) }) { Text("Save") }
                }
            }
        }

        item { SectionHeader("Sync") }
        item {
            SettingRow(
                title = "Send my clipboard when I open ClipLink",
                // Say why it works this way, because "why doesn't it just
                // sync like the PC does" is the obvious question.
                subtitle = "Android only lets an app read the clipboard while it's open, so this " +
                    "is the moment ClipLink can pick things up on its own.",
                trailing = {
                    Switch(
                        checked = state.autoCapture,
                        onCheckedChange = actions.onAutoCaptureChange,
                    )
                },
            )
        }
        item {
            SettingRow(
                title = "Keep syncing in the background",
                subtitle = "Runs a persistent notification so paired devices stay reachable.",
                trailing = {
                    Switch(checked = state.keepAlive, onCheckedChange = actions.onKeepAliveChange)
                },
            )
        }
        item {
            SettingRow(
                title = "Copy received items automatically",
                subtitle = "Puts whatever arrives straight onto this phone's clipboard.",
                trailing = {
                    Switch(checked = state.autoApply, onCheckedChange = actions.onAutoApplyChange)
                },
            )
        }
        item {
            SettingRow(
                title = "Use wallpaper colours",
                subtitle = "Off uses ClipLink's own palette.",
                trailing = {
                    Switch(
                        checked = state.dynamicColor,
                        onCheckedChange = actions.onDynamicColorChange,
                    )
                },
            )
        }

        item { SectionHeader("Shared passcode") }
        item {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        if (state.hasPassphrase) {
                            "A passcode is set. Any device with the same one trusts this device " +
                                "automatically, with no QR scan."
                        } else {
                            "Set the same passcode on two devices and they'll trust each other " +
                                "automatically, with no QR scan."
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(14.dp))
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = { passphrase = it },
                        label = { Text("Passcode") },
                        // Advice only - nothing is refused for being short.
                        supportingText = { Text(stringResource(R.string.passcode_length_hint)) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // No minimum length - blank is the only thing refused,
                        // and the engine trims before deriving the key. Both
                        // buttons wait out a key that is still being derived,
                        // so a Change and a Clear can never cross.
                        Button(
                            onClick = {
                                actions.onSetPassphrase(passphrase)
                                passphrase = ""
                            },
                            enabled = passphrase.isNotBlank() && !state.passphraseBusy,
                        ) {
                            Text(
                                when {
                                    state.passphraseBusy -> "Saving…"
                                    state.hasPassphrase -> "Change passcode"
                                    else -> "Set passcode"
                                },
                            )
                        }
                        if (state.hasPassphrase) {
                            TextButton(
                                onClick = { confirmingClearPassphrase = true },
                                enabled = !state.passphraseBusy,
                            ) {
                                Text("Clear")
                            }
                        }
                    }
                }
            }
        }

        item { SectionHeader("Off-network address") }
        item {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        // Worth saying plainly: this is typed in by hand because
                        // a sandboxed app genuinely cannot ask Tailscale for it.
                        "Paste this device's Tailscale IP so paired devices can reach it when " +
                            "you're not on the same Wi-Fi. There's no way for an app to read " +
                            "this from Tailscale itself.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(14.dp))
                    OutlinedTextField(
                        value = tailscale,
                        onValueChange = { tailscale = it },
                        label = { Text("Tailscale IP") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(onClick = { actions.onSaveTailscaleIp(tailscale) }) { Text("Save") }
                }
            }
        }

        item { SectionHeader("Synced history") }
        item {
            // Above the activity log rather than after it - the log runs to
            // sixty lines, and nobody would scroll past them to find this.
            SettingRow(
                title = "Clear synced history",
                subtitle = "Deletes every item from this phone. Your other devices keep theirs.",
                onClick = { confirmingClear = true },
            )
        }

        item { SectionHeader("Activity") }
        if (state.log.isEmpty()) {
            item {
                SettingRow(title = "Nothing yet", subtitle = "Connection events will appear here.")
            }
        } else {
            items(state.log, key = { "${it.time}-${it.message}" }) { line ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                ) {
                    Text(
                        line.time,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        line.message,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }

    if (confirmingClear) {
        AlertDialog(
            onDismissRequest = { confirmingClear = false },
            title = { Text("Clear synced history?") },
            text = {
                Text(
                    "Every synced item is deleted from this phone, and won't come back from " +
                        "your other devices. They keep their own copies.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingClear = false
                        actions.onClearHistory()
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingClear = false }) { Text("Cancel") }
            },
        )
    }

    if (confirmingClearPassphrase) {
        AlertDialog(
            onDismissRequest = { confirmingClearPassphrase = false },
            title = { Text("Clear passcode?") },
            text = {
                Text(
                    "New devices will need a QR code or address to pair with this phone. " +
                        "Devices that are already paired stay paired.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmingClearPassphrase = false
                        actions.onClearPassphrase()
                    },
                ) {
                    Text("Clear")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmingClearPassphrase = false }) { Text("Cancel") }
            },
        )
    }
}
