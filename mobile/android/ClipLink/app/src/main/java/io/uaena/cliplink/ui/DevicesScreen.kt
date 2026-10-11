package io.uaena.cliplink.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.DevicesOther
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.engine.DeviceRow

/** What a row says about its device, on the card and on the detail screen - one wording, so they cannot disagree. */
internal fun deviceStatusLabel(device: DeviceRow): String = when {
    device.blocked -> "Blocked"
    device.connected -> "Connected"
    // On the network but the link is not up yet - it is dialling us, or we are dialling it.
    device.trusted && device.online -> "Trusted — connecting…"
    // Not connected and not heard from: gone, not "waiting".
    device.trusted -> "Trusted — offline"
    device.pairing -> "Discovered — pairing mode open"
    else -> "Discovered"
}

/** A blocked device is dark gray in either theme, so it reads as switched off at a glance. */
internal val BlockedCardColor = Color(0xFF3A3A3E)
internal val BlockedAccentColor = Color(0xFF56565C)
internal val BlockedOnCardColor = Color(0xFFE3E3E8)
internal val BlockedMutedColor = Color(0xFFA9A9B2)

@Composable
fun DevicesScreen(
    devices: List<DeviceRow>,
    contentPadding: PaddingValues,
    onOpen: (DeviceRow) -> Unit,
    onTrust: (DeviceRow) -> Unit,
    onUntrust: (DeviceRow) -> Unit,
    onBlock: (DeviceRow) -> Unit,
    onUnblock: (DeviceRow) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Held by id and looked up in the live list: a row is replaced whenever
    // anything about the device changes, and an id is what a Bundle can keep.
    var confirmingBlockId by rememberSaveable { mutableStateOf<String?>(null) }
    val confirmingBlock = confirmingBlockId?.let { id -> devices.firstOrNull { it.deviceId == id } }

    Box(modifier.fillMaxSize()) {
        if (devices.isEmpty()) {
            Column(Modifier.fillMaxSize()) {
                ScreenTitle("Devices", contentPadding.calculateTopPadding())
                EmptyState(
                    icon = Icons.Outlined.DevicesOther,
                    title = "No devices yet",
                    body = "Devices on the same network show up here automatically. Tap Pair to " +
                        "add one by QR code, address, or a shared passcode.",
                )
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp,
                    end = 16.dp,
                    bottom = contentPadding.calculateBottomPadding() + 96.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                item { ScreenTitle("Devices", contentPadding.calculateTopPadding()) }
                items(devices, key = { it.deviceId }) { device ->
                    DeviceCard(
                        device = device,
                        onOpen = { onOpen(device) },
                        onTrust = { onTrust(device) },
                        onUntrust = { onUntrust(device) },
                        // Blocking a trusted device also removes it, so that one asks first.
                        onBlock = { if (device.trusted) confirmingBlockId = device.deviceId else onBlock(device) },
                        onUnblock = { onUnblock(device) },
                    )
                }
            }
        }

        ExtendedFloatingActionButton(
            onClick = onAdd,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 20.dp)
                .padding(bottom = contentPadding.calculateBottomPadding() + 16.dp),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null)
            Spacer(Modifier.width(10.dp))
            Text("Pair", fontWeight = FontWeight.SemiBold)
        }
    }

    confirmingBlock?.let { device ->
        BlockDeviceDialog(
            device = device,
            onConfirm = {
                confirmingBlockId = null
                onBlock(device)
            },
            onDismiss = { confirmingBlockId = null },
        )
    }
}

@Composable
fun ScreenTitle(text: String, topPadding: Dp) {
    Text(
        text,
        style = MaterialTheme.typography.displaySmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(start = 4.dp, end = 16.dp, top = topPadding + 12.dp, bottom = 16.dp),
    )
}

/**
 * Asked before a trusted device is blocked, because that also removes it:
 * a blocked device cannot be paired with again until it is unblocked.
 */
@Composable
fun BlockDeviceDialog(device: DeviceRow, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Block ${device.title}?") },
        text = {
            Text(
                (if (device.trusted) "It is removed from your trusted devices and stops syncing. " else "") +
                    "It can't ask to pair with this phone again, and nothing from it is shown, " +
                    "until you unblock it.",
            )
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text("Block") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The menu on a device card and on its detail screen: block it, or unblock it. */
@Composable
fun DeviceMenu(
    device: DeviceRow,
    onBlock: () -> Unit,
    onUnblock: () -> Unit,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Outlined.MoreVert, contentDescription = "More options", tint = tint)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (device.blocked) {
                DropdownMenuItem(
                    text = { Text("Unblock") },
                    leadingIcon = { Icon(Icons.Outlined.LockOpen, null) },
                    onClick = {
                        open = false
                        onUnblock()
                    },
                )
            } else {
                DropdownMenuItem(
                    text = { Text("Block") },
                    leadingIcon = { Icon(Icons.Outlined.Block, null) },
                    onClick = {
                        open = false
                        onBlock()
                    },
                )
            }
        }
    }
}

@Composable
private fun DeviceCard(
    device: DeviceRow,
    onOpen: () -> Unit,
    onTrust: () -> Unit,
    onUntrust: () -> Unit,
    onBlock: () -> Unit,
    onUnblock: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val blocked = device.blocked
    val accent = when {
        blocked -> BlockedAccentColor
        device.connected -> colors.tertiaryContainer
        device.trusted -> colors.primaryContainer
        else -> colors.surfaceContainerHighest
    }
    val onAccent = when {
        blocked -> BlockedOnCardColor
        device.connected -> colors.onTertiaryContainer
        device.trusted -> colors.onPrimaryContainer
        else -> colors.onSurfaceVariant
    }
    val primary = if (blocked) BlockedOnCardColor else colors.onSurface
    val secondary = if (blocked) BlockedMutedColor else colors.onSurfaceVariant

    Surface(
        onClick = onOpen,
        shape = RoundedCornerShape(26.dp),
        color = if (blocked) BlockedCardColor else colors.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(start = 16.dp, top = 16.dp, end = 6.dp, bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(48.dp)
                        .background(accent, RoundedCornerShape(16.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        DeviceIcon,
                        contentDescription = null,
                        tint = onAccent,
                    )
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        device.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    // One address, not the list: the one the live link is using.
                    // Every address the device can be reached at is on its
                    // detail screen, a tap away.
                    Text(
                        text = listOfNotNull(deviceStatusLabel(device), device.connectedAddress).joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = secondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                DeviceMenu(device, onBlock = onBlock, onUnblock = onUnblock, tint = secondary)
            }

            // Nothing to offer a blocked device here but the menu's Unblock.
            if (!blocked) {
                Spacer(Modifier.height(10.dp))
                Row(Modifier.padding(end = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (device.trusted) {
                        OutlinedButton(onClick = onUntrust) { Text("Remove") }
                    } else {
                        FilledTonalButton(onClick = onTrust) { Text("Trust") }
                    }
                }
            }
        }
    }
}

/** A tappable settings-style row, shared by the Me screen and pairing. */
@Composable
fun SettingRow(
    title: String,
    subtitle: String? = null,
    trailing: @Composable (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Surface(
        shape = RoundedCornerShape(22.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .padding(horizontal = 18.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                if (subtitle != null) {
                    Text(
                        subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (trailing != null) {
                Spacer(Modifier.width(12.dp))
                trailing()
            }
        }
    }
}
