package io.uaena.cliplink.ui

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.engine.displayNameOf

@Composable
fun DetailScreen(
    item: SyncedItem,
    /** The item's unique list key (see [keyedItems]): what its picture is cached under. */
    key: String,
    /** What the sending device calls itself, or null while no name is known (its short id is shown then). */
    senderName: String?,
    contentPadding: PaddingValues,
    onBack: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val style = typeStyleOf(item)
    val payload = item.filePayload
    val origin = if (item.isOwn) "Sent from this device" else "From ${displayNameOf(item.entry.deviceId, senderName)}"
    // The item's picture, if it has one: an inline image, or the picture of an
    // image file once its bytes are here (a file card until then).
    val picture = when (item.type) {
        ClipboardEntry.TYPE_IMAGE -> remember(key) {
            ImageCache.fromBase64(key, item.entry.content, DETAIL_IMAGE_EDGE)
        }

        ClipboardEntry.TYPE_FILE -> rememberFileThumbnail(item, DETAIL_IMAGE_EDGE)
        else -> null
    }
    var menuOpen by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }

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
            TypeChip(style)
            Spacer(Modifier.weight(1f))
            Text(
                item.timeLabel,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            // A menu rather than a bare bin icon: the delete has no undo, so it
            // gets the same labelled "Delete" item, and the same confirmation,
            // as the long-press menu on the card.
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Outlined.MoreVert, contentDescription = "More options")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
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

        if (picture != null) {
            // The picture is the whole point of an image item, so it gets
            // everything between the top bar and the buttons - edge to edge,
            // fitted and centred, no card or margins around it. Only the system
            // bars' side insets are kept (they matter in landscape).
            val direction = LocalLayoutDirection.current
            val left = contentPadding.calculateLeftPadding(direction)
            val right = contentPadding.calculateRightPadding(direction)
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(
                        start = if (direction == LayoutDirection.Ltr) left else right,
                        end = if (direction == LayoutDirection.Ltr) right else left,
                    ),
            ) {
                ZoomableImage(
                    bitmap = picture,
                    contentDescription = payload?.fileName ?: "Synced image",
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                if (payload != null) {
                    // The file card, as two lines under the picture: the card
                    // itself would take a good part of the room the picture is
                    // meant to have.
                    SelectionContainer {
                        Text(
                            payload.fileName,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Text(
                        "${formatSize(payload.fileSize)} · $origin",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Text(
                        origin,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else {
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                when (item.type) {
                    ClipboardEntry.TYPE_IMAGE -> {
                        // No picture: it didn't decode.
                        Text(
                            "This image couldn't be decoded.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }

                    ClipboardEntry.TYPE_FILE -> {
                        // A file with no picture of it (yet): just its card.
                        Surface(
                            shape = RoundedCornerShape(24.dp),
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                Modifier.padding(20.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Box(
                                    Modifier
                                        .size(56.dp)
                                        .background(style.container, RoundedCornerShape(18.dp)),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(style.icon, contentDescription = null, tint = style.onContainer)
                                }
                                Spacer(Modifier.width(16.dp))
                                // Selectable, so a file name can be copied out.
                                SelectionContainer {
                                    Column {
                                        Text(
                                            payload?.fileName ?: "File",
                                            style = MaterialTheme.typography.titleMedium,
                                            fontWeight = FontWeight.SemiBold,
                                            color = MaterialTheme.colorScheme.onSurface,
                                        )
                                        Text(
                                            if (!item.fileAvailable) {
                                                "Still transferring…"
                                            } else {
                                                formatSize(payload?.fileSize ?: 0L)
                                            },
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    }

                    else -> {
                        Surface(
                            shape = RoundedCornerShape(24.dp),
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            // Long-press to select, then the system toolbar's Copy /
                            // Select all / Share - for taking part of a long text
                            // rather than all of it (the Copy button below takes
                            // all of it).
                            SelectionContainer {
                                Text(
                                    item.entry.content,
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.padding(20.dp),
                                )
                            }
                        }
                    }
                }

                Spacer(Modifier.height(20.dp))
                Text(
                    origin,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(onClick = onCopy) {
                Icon(Icons.Outlined.ContentCopy, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Copy")
            }
            OutlinedButton(onClick = onShare) {
                Icon(Icons.Outlined.Share, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Share")
            }
        }
    }

    if (confirmingDelete) {
        ConfirmDeleteItemDialog(
            onConfirm = {
                confirmingDelete = false
                onDelete()
            },
            onDismiss = { confirmingDelete = false },
        )
    }
}

/**
 * The longest side a picture is decoded to for the detail view - well past the
 * 1600 it used to be, so pinching in shows real detail rather than a
 * magnified blur. A square picture at this size is ~23 MB, so it is the most
 * a single decode here is allowed to cost (the cache's budget is 24 MB).
 */
private const val DETAIL_IMAGE_EDGE = 2400
