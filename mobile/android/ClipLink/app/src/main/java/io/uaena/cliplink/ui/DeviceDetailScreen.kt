package io.uaena.cliplink.ui

import android.text.format.DateUtils
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.engine.fingerprintOf

/**
 * One device in full: everything the card leaves out. The card shows the one
 * address its live link is using; this lists every address the device can be
 * reached at, and the rest of what is known about it.
 *
 * Laid out like the item preview - Back, a chip, a menu on top; scrolling
 * cards; the actions at the bottom - and opened and closed the same way.
 */
@Composable
fun DeviceDetailScreen(
    device: DeviceRow,
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    onTrust: () -> Unit,
    onUntrust: () -> Unit,
    onBlock: () -> Unit,
    onUnblock: () -> Unit,
    onCopyId: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val blocked = device.blocked
    var confirmingBlock by rememberSaveable { mutableStateOf(false) }

    val chipContainer = when {
        blocked -> BlockedAccentColor
        device.connected -> colors.tertiaryContainer
        device.trusted -> colors.primaryContainer
        else -> colors.surfaceContainerHighest
    }
    val chipContent = when {
        blocked -> BlockedOnCardColor
        device.connected -> colors.onTertiaryContainer
        device.trusted -> colors.onPrimaryContainer
        else -> colors.onSurfaceVariant
    }
    val cardColor = if (blocked) BlockedCardColor else colors.surfaceContainerLow
    val primary = if (blocked) BlockedOnCardColor else colors.onSurface
    val secondary = if (blocked) BlockedMutedColor else colors.onSurfaceVariant

    Column(
        modifier
            .fillMaxSize()
            .padding(
                top = contentPadding.calculateTopPadding(),
                bottom = contentPadding.calculateBottomPadding(),
            ),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(start = 4.dp, end = 4.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Spacer(Modifier.width(4.dp))
            TypeChip(
                TypeStyle(
                    icon = if (blocked) Icons.Outlined.Block else DeviceIcon,
                    label = deviceStatusLabel(device),
                    container = chipContainer,
                    onContainer = chipContent,
                ),
            )
            Spacer(Modifier.weight(1f))
            DeviceMenu(
                device = device,
                onBlock = { if (device.trusted) confirmingBlock = true else onBlock() },
                onUnblock = onUnblock,
            )
        }

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(shape = RoundedCornerShape(24.dp), color = cardColor, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(56.dp)
                            .background(chipContainer, RoundedCornerShape(18.dp)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(DeviceIcon, contentDescription = null, tint = chipContent)
                    }
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(
                            device.title,
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = primary,
                        )
                        Text(
                            deviceStatusLabel(device),
                            style = MaterialTheme.typography.bodyMedium,
                            color = secondary,
                        )
                    }
                }
            }

            Surface(shape = RoundedCornerShape(24.dp), color = cardColor, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp)) {
                    Text(
                        "Can connect at",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = secondary,
                    )
                    Spacer(Modifier.height(10.dp))
                    if (device.addresses.isEmpty()) {
                        Text(
                            "No address is known yet. One appears here once this device is heard on your network.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = secondary,
                        )
                    }
                    device.addresses.forEach { address ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            SelectionContainer(Modifier.weight(1f)) {
                                Text(
                                    address,
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontFamily = FontFamily.Monospace,
                                    color = primary,
                                )
                            }
                            // The one address the live link is using - the one
                            // the card shows.
                            if (address == device.connectedAddress) {
                                Text(
                                    "In use",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    color = colors.onTertiaryContainer,
                                    modifier = Modifier
                                        .background(colors.tertiaryContainer, CircleShape)
                                        .padding(horizontal = 10.dp, vertical = 4.dp),
                                )
                            }
                        }
                    }
                }
            }

            Surface(shape = RoundedCornerShape(24.dp), color = cardColor, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    DetailRow("Status", deviceStatusLabel(device), primary, secondary)
                    DetailRow("Last heard", lastHeardText(device), primary, secondary)
                    // From the id, so it is the same on every device that shows it - a
                    // name is whatever the device calls itself, a fingerprint cannot be copied.
                    DetailRow("Fingerprint", fingerprintOf(device.deviceId), primary, secondary, mono = true)
                    Column {
                        Text(
                            "Device ID",
                            style = MaterialTheme.typography.labelMedium,
                            color = secondary,
                        )
                        Spacer(Modifier.height(4.dp))
                        SelectionContainer {
                            Text(
                                device.deviceId,
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                                color = primary,
                            )
                        }
                    }
                }
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                blocked -> Button(onClick = onUnblock) { Text("Unblock") }
                device.trusted -> OutlinedButton(onClick = onUntrust) { Text("Remove") }
                else -> Button(onClick = onTrust) { Text("Trust") }
            }
            OutlinedButton(onClick = onCopyId) {
                Icon(Icons.Outlined.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Copy ID")
            }
        }
    }

    if (confirmingBlock) {
        BlockDeviceDialog(
            device = device,
            onConfirm = {
                confirmingBlock = false
                onBlock()
            },
            onDismiss = { confirmingBlock = false },
        )
    }
}

@Composable
private fun DetailRow(
    label: String,
    value: String,
    primary: Color,
    secondary: Color,
    mono: Boolean = false,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = secondary,
            modifier = Modifier.weight(1f),
        )
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = if (mono) FontFamily.Monospace else null,
            color = primary,
        )
    }
}

/**
 * When the device was last heard, but only for one that is not there: the
 * row's time is not part of its identity (it changes with every beacon, and a
 * row that differed each time would redraw the whole list), so for a device
 * that is on the network it would only ever read as stale. "Now" is the
 * truth for those; the time is the truth for one that went quiet.
 */
private fun lastHeardText(device: DeviceRow): String {
    if (device.online) return "Now"
    val at = device.lastSeenAtMs ?: return "Not since ClipLink started"
    return DateUtils.getRelativeTimeSpanString(at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
}
