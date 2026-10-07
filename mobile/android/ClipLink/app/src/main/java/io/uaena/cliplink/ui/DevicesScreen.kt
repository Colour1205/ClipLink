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
import androidx.compose.material.icons.outlined.DevicesOther
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.engine.DeviceRow

@Composable
fun DevicesScreen(
    devices: List<DeviceRow>,
    contentPadding: PaddingValues,
    onTrust: (DeviceRow) -> Unit,
    onUntrust: (DeviceRow) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
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
                    DeviceCard(device, onTrust = onTrust, onUntrust = onUntrust)
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
}

@Composable
fun ScreenTitle(text: String, topPadding: androidx.compose.ui.unit.Dp) {
    Text(
        text,
        style = MaterialTheme.typography.displaySmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(start = 4.dp, end = 16.dp, top = topPadding + 12.dp, bottom = 16.dp),
    )
}

@Composable
private fun DeviceCard(
    device: DeviceRow,
    onTrust: (DeviceRow) -> Unit,
    onUntrust: (DeviceRow) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val accent = when {
        device.connected -> colors.tertiaryContainer
        device.trusted -> colors.primaryContainer
        else -> colors.surfaceContainerHighest
    }
    val onAccent = when {
        device.connected -> colors.onTertiaryContainer
        device.trusted -> colors.onPrimaryContainer
        else -> colors.onSurfaceVariant
    }

    Surface(
        shape = RoundedCornerShape(26.dp),
        color = colors.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
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
                        color = colors.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val status = when {
                        device.connected -> "Connected"
                        device.trusted -> "Trusted — waiting for it"
                        device.pairing -> "Discovered — pairing mode open"
                        else -> "Discovered"
                    }
                    // Every address it's reachable at, not just one. A device
                    // can beacon from a LAN IP while advertising a Tailscale IP
                    // and having a third cached from pairing - showing one of
                    // them hides why a dial is failing.
                    Text(
                        text = (listOf(status) + device.addresses).joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (device.trusted) {
                    OutlinedButton(onClick = { onUntrust(device) }) { Text("Remove") }
                } else {
                    FilledTonalButton(onClick = { onTrust(device) }) { Text("Trust") }
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
