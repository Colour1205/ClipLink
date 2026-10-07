package io.uaena.cliplink.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalFloatingToolbar
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.ToggleButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.engine.displayNameOf

enum class SyncedLayout { List, Grid }

data class SyncedActions(
    val onOpen: (SyncedItem) -> Unit,
    val onCopy: (SyncedItem) -> Unit,
    val onShare: (SyncedItem) -> Unit,
    val onDelete: (SyncedItem) -> Unit,
    val onSyncClipboard: () -> Unit,
    val onPickFile: () -> Unit,
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SyncedScreen(
    items: List<SyncedItem>,
    /** What each known device calls itself, by device id; an id missing here (or mapped to null) shows its short id. */
    deviceNames: Map<String, String?>,
    connectedCount: Int,
    discovering: Boolean,
    contentPadding: PaddingValues,
    actions: SyncedActions,
    layout: SyncedLayout,
    onLayoutChange: (SyncedLayout) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            SyncedHeader(
                connectedCount = connectedCount,
                discovering = discovering,
                layout = layout,
                onLayoutChange = onLayoutChange,
                topPadding = contentPadding.calculateTopPadding(),
            )

            if (items.isEmpty()) {
                EmptyState(
                    icon = Icons.Outlined.Inbox,
                    title = "Nothing synced yet",
                    body = "Copy something on a paired device, or tap the paste button below to " +
                        "send what's on this phone's clipboard.",
                )
                return@Column
            }

            // Content padding, not Modifier.padding: the grid has to scroll
            // BEHIND the navigation bar and the floating toolbar rather than
            // stop short of them, while its first and last items still clear
            // both.
            val listPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = 4.dp,
                bottom = contentPadding.calculateBottomPadding() + 96.dp,
            )

            // Hoisted: transitionSpec is not a @Composable lambda, so the
            // motion scheme has to be read out here rather than inside it.
            val enterFade = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
            val exitFade = MaterialTheme.motionScheme.fastEffectsSpec<Float>()

            AnimatedContent(
                targetState = layout,
                transitionSpec = { fadeIn(enterFade) togetherWith fadeOut(exitFade) },
                label = "syncedLayout",
            ) { current ->
                when (current) {
                    SyncedLayout.List -> LazyColumn(
                        contentPadding = listPadding,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(items, key = { it.id }) { item ->
                            SyncedCard(item, deviceNames[item.entry.deviceId], actions, compact = false)
                        }
                    }

                    SyncedLayout.Grid -> LazyVerticalStaggeredGrid(
                        columns = StaggeredGridCells.Fixed(2),
                        contentPadding = listPadding,
                        verticalItemSpacing = 12.dp,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(items, key = { it.id }) { item ->
                            SyncedCard(item, deviceNames[item.entry.deviceId], actions, compact = true)
                        }
                    }
                }
            }
        }

        HorizontalFloatingToolbar(
            expanded = true,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = contentPadding.calculateBottomPadding() + 12.dp),
        ) {
            FilledIconButton(onClick = actions.onSyncClipboard) {
                Icon(Icons.Outlined.ContentPaste, contentDescription = "Sync this device's clipboard")
            }
            IconButton(onClick = actions.onPickFile) {
                Icon(Icons.Outlined.OpenInNew, contentDescription = "Send a file")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun SyncedHeader(
    connectedCount: Int,
    discovering: Boolean,
    layout: SyncedLayout,
    onLayoutChange: (SyncedLayout) -> Unit,
    topPadding: androidx.compose.ui.unit.Dp,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 16.dp)
            .padding(top = topPadding + 12.dp, bottom = 12.dp),
    ) {
        Text(
            "Synced",
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(12.dp))
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            StatusPill(connectedCount, discovering)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ToggleButton(
                    checked = layout == SyncedLayout.List,
                    onCheckedChange = { onLayoutChange(SyncedLayout.List) },
                ) {
                    Icon(
                        Icons.Outlined.ViewAgenda,
                        contentDescription = "List view",
                        modifier = Modifier.size(18.dp),
                    )
                }
                ToggleButton(
                    checked = layout == SyncedLayout.Grid,
                    onCheckedChange = { onLayoutChange(SyncedLayout.Grid) },
                ) {
                    Icon(
                        Icons.Outlined.GridView,
                        contentDescription = "Grid view",
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SyncedCard(item: SyncedItem, senderName: String?, actions: SyncedActions, compact: Boolean) {
    val style = typeStyleOf(item)
    var menuOpen by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(26.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box {
            Column(
                Modifier
                    .combinedClickable(
                        onClick = { actions.onOpen(item) },
                        onLongClick = { menuOpen = true },
                    )
                    .padding(16.dp),
            ) {
                when {
                    item.type == ClipboardEntry.TYPE_IMAGE -> ImagePreview(item, compact)
                    item.type == ClipboardEntry.TYPE_FILE -> FileContent(item, style, compact)
                    else -> Text(
                        item.preview,
                        style = if (compact) {
                            MaterialTheme.typography.bodyMedium
                        } else {
                            MaterialTheme.typography.bodyLarge
                        },
                        color = MaterialTheme.colorScheme.onSurface,
                        // Generous in grid view because a text card's whole
                        // job is showing the text - clipping it to two lines
                        // to make room for a big type icon wastes the card.
                        maxLines = if (compact) 12 else 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                Spacer(Modifier.height(14.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // In grid view the chip drops its label and sits beside the
                    // timestamp instead of taking a line of its own.
                    TypeChip(style, showLabel = !compact)
                    Text(
                        item.timeLabel,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.weight(1f))
                    if (!item.isOwn) {
                        // The sender's name (its short id while none is known).
                        // Grid cards are narrow, so there the name stands alone:
                        // with "from " in front it was cut to "from ...".
                        val sender = displayNameOf(item.entry.deviceId, senderName)
                        Text(
                            if (compact) sender else "from $sender",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text("Copy") },
                    leadingIcon = { Icon(Icons.Outlined.ContentCopy, null) },
                    onClick = {
                        menuOpen = false
                        actions.onCopy(item)
                    },
                )
                DropdownMenuItem(
                    text = { Text("Share") },
                    leadingIcon = { Icon(Icons.Outlined.Share, null) },
                    onClick = {
                        menuOpen = false
                        actions.onShare(item)
                    },
                )
                DropdownMenuItem(
                    text = { Text("Delete") },
                    leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null) },
                    onClick = {
                        menuOpen = false
                        confirmingDelete = true
                    },
                )
            }
        }
    }

    if (confirmingDelete) {
        ConfirmDeleteItemDialog(
            onConfirm = {
                confirmingDelete = false
                actions.onDelete(item)
            },
            onDismiss = { confirmingDelete = false },
        )
    }
}

@Composable
private fun ImagePreview(item: SyncedItem, compact: Boolean) {
    val bitmap = remember(item.id, compact) {
        ImageCache.fromBase64(item.id, item.entry.content, if (compact) 480 else 900)
    }
    if (bitmap == null) {
        Text(
            "Image (couldn't be decoded)",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }
    PreviewImage(bitmap, "Synced image", compact)
}

@Composable
private fun PreviewImage(bitmap: ImageBitmap, contentDescription: String, compact: Boolean) {
    Image(
        bitmap = bitmap,
        contentDescription = contentDescription,
        contentScale = ContentScale.FillWidth,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = if (compact) 260.dp else 340.dp)
            .clip(RoundedCornerShape(16.dp)),
    )
}

/**
 * An image file shows its picture, as an inline image does, with its name
 * under it. Any other file - and an image one until its bytes are here and
 * decoded - is its file card.
 */
@Composable
private fun FileContent(item: SyncedItem, style: TypeStyle, compact: Boolean) {
    val thumbnail = rememberFileThumbnail(item, if (compact) 480 else 900)
    if (thumbnail == null) {
        FileRow(item, style)
        return
    }
    val name = item.filePayload?.fileName ?: "Image"
    PreviewImage(thumbnail, name, compact)
    Spacer(Modifier.height(10.dp))
    Text(
        name,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun FileRow(item: SyncedItem, style: TypeStyle) {
    val payload = item.filePayload
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(44.dp)
                .background(style.container, RoundedCornerShape(14.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(style.icon, contentDescription = null, tint = style.onContainer)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                payload?.fileName ?: "File",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = when {
                    !item.fileAvailable -> "Transferring…"
                    payload != null -> formatSize(payload.fileSize)
                    else -> ""
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

fun formatSize(bytes: Long): String = when {
    bytes >= 1_073_741_824 -> "%.1f GB".format(bytes / 1_073_741_824.0)
    bytes >= 1_048_576 -> "%.1f MB".format(bytes / 1_048_576.0)
    bytes >= 1024 -> "%.0f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}
