package io.uaena.cliplink.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DevicesOther
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.SyncedItem

/**
 * The visual identity of a content type: icon plus a container/on-container
 * pair. Expressive leans on saturated container roles to separate categories
 * instead of on outlines, so each type gets a genuinely different colour
 * rather than a different grey.
 */
data class TypeStyle(
    val icon: ImageVector,
    val label: String,
    val container: Color,
    val onContainer: Color,
)

@Composable
fun typeStyleOf(item: SyncedItem): TypeStyle {
    val colors = MaterialTheme.colorScheme
    // Worked out once per entry, not on every recomposition: isLink trims a
    // copy of the whole content and runs a regex over it, and a copied file's
    // text is megabytes. The signature stands for the content (an entry can't
    // change under its signature), and is short to compare.
    val isLink = remember(item.entry.signature ?: item.entry.content) { item.isLink }
    return when {
        isLink -> TypeStyle(
            Icons.Outlined.Link,
            "Link",
            colors.tertiaryContainer,
            colors.onTertiaryContainer,
        )

        item.type == ClipboardEntry.TYPE_IMAGE -> TypeStyle(
            Icons.Outlined.Image,
            "Image",
            colors.secondaryContainer,
            colors.onSecondaryContainer,
        )

        item.type == ClipboardEntry.TYPE_FILE -> TypeStyle(
            Icons.Outlined.Description,
            "File",
            colors.surfaceContainerHighest,
            colors.onSurface,
        )

        else -> TypeStyle(
            Icons.Outlined.TextFields,
            "Text",
            colors.primaryContainer,
            colors.onPrimaryContainer,
        )
    }
}

/** The small pill that marks a card's content type. */
@Composable
fun TypeChip(style: TypeStyle, modifier: Modifier = Modifier, showLabel: Boolean = true) {
    Row(
        modifier = modifier
            .background(style.container, CircleShape)
            .padding(horizontal = if (showLabel) 10.dp else 6.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            style.icon,
            contentDescription = style.label,
            tint = style.onContainer,
            modifier = Modifier.size(14.dp),
        )
        if (showLabel) {
            Text(
                style.label,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = style.onContainer,
            )
        }
    }
}

/**
 * Live connection state. Animated rather than swapped so the transition
 * between connected and searching reads as one state changing, not two
 * different badges.
 */
@Composable
fun StatusPill(
    connectedCount: Int,
    discovering: Boolean,
    modifier: Modifier = Modifier,
    /**
     * The local-network permission is off (see [rememberLocalNetworkAccessOff]):
     * the pill says so - it would otherwise read "Looking for devices…"
     * for good, as a denial is silent - and a tap goes to [onOpenSettings].
     */
    localNetworkOff: Boolean = false,
    onOpenSettings: () -> Unit = {},
) {
    val colors = MaterialTheme.colorScheme
    val connected = connectedCount > 0
    val container by animateColorAsState(
        targetValue = when {
            localNetworkOff -> colors.errorContainer
            connected -> colors.tertiaryContainer
            discovering -> colors.surfaceContainerHigh
            else -> colors.errorContainer
        },
        animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "statusContainer",
    )
    val onContainer by animateColorAsState(
        targetValue = when {
            localNetworkOff -> colors.onErrorContainer
            connected -> colors.onTertiaryContainer
            discovering -> colors.onSurfaceVariant
            else -> colors.onErrorContainer
        },
        animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "statusContent",
    )

    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(container)
            .then(
                if (localNetworkOff) {
                    Modifier.clickable(onClickLabel = "Open app settings", role = Role.Button, onClick = onOpenSettings)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Icon(
            Icons.Filled.Circle,
            contentDescription = null,
            tint = onContainer,
            modifier = Modifier.size(8.dp),
        )
        Text(
            text = when {
                localNetworkOff -> "Local network access is off"
                connected -> "$connectedCount device${if (connectedCount == 1) "" else "s"} connected"
                discovering -> "Looking for devices…"
                else -> "Discovery off"
            },
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Medium,
            color = onContainer,
            maxLines = 1,
        )
    }
}

@Composable
fun deviceIconFor(deviceId: String): ImageVector = when {
    // Nothing on the wire says what kind of device a peer is, so this is a
    // deliberate guess rather than a fact - phones on this protocol are the
    // ones that beacon, and the daemon is always a desktop. Shown as a hint,
    // never as something the user should rely on.
    deviceId.isEmpty() -> Icons.Outlined.DevicesOther
    deviceId.hashCode() % 2 == 0 -> Icons.Outlined.Smartphone
    else -> Icons.Outlined.Computer
}

/** Shared empty state: big soft icon, a headline and one line of guidance. */
@Composable
fun EmptyState(
    icon: ImageVector,
    title: String,
    body: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(96.dp)
                .background(
                    MaterialTheme.colorScheme.surfaceContainerHigh,
                    RoundedCornerShape(32.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(44.dp),
            )
        }
        Spacer(Modifier.height(20.dp))
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/** Section label above a group of settings rows. */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(start = 8.dp, top = 24.dp, bottom = 10.dp),
    )
}

/**
 * Asks before one synced item is deleted - the same shape as the "Clear synced
 * history" confirmation, since both are undo-less and both stick.
 */
@Composable
fun ConfirmDeleteItemDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete this item?") },
        text = {
            Text(
                "It's deleted from this phone, and won't come back from your other devices. " +
                    "They keep their own copies.",
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text("Delete") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
