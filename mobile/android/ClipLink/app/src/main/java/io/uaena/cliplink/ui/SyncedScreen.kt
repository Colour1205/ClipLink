package io.uaena.cliplink.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.snap
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.engine.displayNameOf
import kotlinx.coroutines.delay

enum class SyncedLayout { List, Grid }

data class SyncedActions(
    val onCopy: (SyncedItem) -> Unit,
    val onShare: (SyncedItem) -> Unit,
    val onDelete: (SyncedItem) -> Unit,
    val onSyncClipboard: () -> Unit,
    val onPickFile: () -> Unit,
    /** A stack was opened: its group ends and its items become ordinary cards. */
    val onExpandGroup: (Long) -> Unit,
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SyncedScreen(
    /** Each with its unique list key (see [keyedItems]) - never `SyncedItem.id`, which two items can share. */
    items: List<KeyedItem>,
    /** What each known device calls itself, by device id; an id missing here (or mapped to null) shows its short id. */
    deviceNames: Map<String, String?>,
    connectedCount: Int,
    discovering: Boolean,
    contentPadding: PaddingValues,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    layout: SyncedLayout,
    onLayoutChange: (SyncedLayout) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    // Read from the system, not the engine: a denied local-network permission
    // raises no error anywhere, so the engine can only say "looking".
    val localNetworkOff = rememberLocalNetworkAccessOff()
    Box(modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            SyncedHeader(
                connectedCount = connectedCount,
                discovering = discovering,
                localNetworkOff = localNetworkOff,
                onOpenSettings = { openAppSettings(context) },
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

            // A history batch is one stack, not a card per item (see SyncedRow).
            val rows = remember(items) { buildRows(items) }
            val reduceMotion = rememberReduceMotion()
            // The cards of stacks that were just opened, flying out of them -
            // by key, until they have settled.
            val reveal = remember { mutableStateMapOf<String, RevealSlot>() }
            LaunchedEffect(reveal.size) {
                // Whatever never got composed (scrolled away) is not kept for ever.
                if (reveal.isNotEmpty()) {
                    delay(REVEAL_KEEP_MS)
                    reveal.clear()
                }
            }
            // Cards below an opened stack, and below a deleted card, glide to
            // their new places rather than jumping.
            val glide = MaterialTheme.motionScheme.defaultSpatialSpec<IntOffset>()
            val placement = if (reduceMotion) snap<IntOffset>() else glide
            val listState = rememberLazyListState()
            val gridState = rememberLazyStaggeredGridState()
            // A stack that arrives on top while the list is at the very top is
            // brought into view. The lazy list holds on to the card that was
            // first (by its key), which would leave the new stack above the
            // screen, unseen; if it did not, there is nothing to do here.
            val topRow = remember { arrayOfNulls<String>(1) }
            LaunchedEffect(rows) {
                val before = topRow[0]
                topRow[0] = rows.firstOrNull()?.key
                if (before == null || before == topRow[0]) return@LaunchedEffect
                val added = rows.indexOfFirst { it.key == before }
                if (added <= 0 || rows.take(added).none { it is SyncedRow.Stack }) return@LaunchedEffect
                // The list measures the change on the next frames, not yet.
                withFrameNanos { }
                withFrameNanos { }
                if (layout == SyncedLayout.List) {
                    if (listState.firstVisibleItemIndex == added && listState.firstVisibleItemScrollOffset == 0) {
                        listState.animateScrollToItem(0)
                    }
                } else if (gridState.firstVisibleItemIndex == added && gridState.firstVisibleItemScrollOffset == 0) {
                    gridState.animateScrollToItem(0)
                }
            }
            val onExpand = { stack: SyncedRow.Stack ->
                reveal.putAll(revealSlots(stack, columns = if (layout == SyncedLayout.Grid) 2 else 1))
                actions.onExpandGroup(stack.groupId)
            }

            AnimatedContent(
                targetState = layout,
                transitionSpec = { fadeIn(enterFade) togetherWith fadeOut(exitFade) },
                label = "syncedLayout",
            ) { current ->
                when (current) {
                    SyncedLayout.List -> LazyColumn(
                        state = listState,
                        contentPadding = listPadding,
                        verticalArrangement = Arrangement.spacedBy(CARD_GAP),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(rows, key = { it.key }) { row ->
                            SyncedRowContent(
                                row = row,
                                deviceNames = deviceNames,
                                onOpen = onOpen,
                                actions = actions,
                                compact = false,
                                reveal = reveal,
                                reduceMotion = reduceMotion,
                                onExpand = onExpand,
                                modifier = Modifier.animateItem(fadeInSpec = null, placementSpec = placement, fadeOutSpec = null),
                            )
                        }
                    }

                    SyncedLayout.Grid -> LazyVerticalStaggeredGrid(
                        columns = StaggeredGridCells.Fixed(2),
                        state = gridState,
                        contentPadding = listPadding,
                        verticalItemSpacing = CARD_GAP,
                        horizontalArrangement = Arrangement.spacedBy(CARD_GAP),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(rows, key = { it.key }) { row ->
                            SyncedRowContent(
                                row = row,
                                deviceNames = deviceNames,
                                onOpen = onOpen,
                                actions = actions,
                                compact = true,
                                reveal = reveal,
                                reduceMotion = reduceMotion,
                                onExpand = onExpand,
                                modifier = Modifier.animateItem(fadeInSpec = null, placementSpec = placement, fadeOutSpec = null),
                            )
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
    localNetworkOff: Boolean,
    onOpenSettings: () -> Unit,
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
            StatusPill(
                connectedCount,
                discovering,
                localNetworkOff = localNetworkOff,
                onOpenSettings = onOpenSettings,
            )
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

/** How long the fly-out of an opened stack's cards is remembered, whether or not they were all on screen. */
private const val REVEAL_KEEP_MS = 3_000L

/** One row of the list or grid: a card, or a stack standing for a history batch. */
@Composable
private fun SyncedRowContent(
    row: SyncedRow,
    deviceNames: Map<String, String?>,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    compact: Boolean,
    reveal: SnapshotStateMap<String, RevealSlot>,
    reduceMotion: Boolean,
    onExpand: (SyncedRow.Stack) -> Unit,
    modifier: Modifier = Modifier,
) {
    when (row) {
        is SyncedRow.Single -> SyncedCard(
            keyed = row.keyed,
            senderName = deviceNames[row.keyed.item.entry.deviceId],
            onOpen = onOpen,
            actions = actions,
            compact = compact,
            modifier = modifier.revealIn(reveal[row.key], reduceMotion) { reveal.remove(row.key) },
        )

        is SyncedRow.Stack -> StackedCard(
            stack = row,
            senderName = deviceNames[row.front.item.entry.deviceId],
            onOpen = onOpen,
            actions = actions,
            compact = compact,
            reduceMotion = reduceMotion,
            onExpand = onExpand,
            modifier = modifier,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun SyncedCard(
    keyed: KeyedItem,
    senderName: String?,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    compact: Boolean,
    modifier: Modifier = Modifier,
    /** Drawn over the bottom of the card, in the room [STACK_HANDLE_ZONE] leaves there: a stack's handle and count. */
    stackFooter: (@Composable BoxScope.() -> Unit)? = null,
) {
    val item = keyed.item
    // The picture of an image file (a photo sent from a phone), once its bytes
    // are here: such a card is an image card, footer included. Until then, and
    // for any other file, it is a file card.
    val thumbnail = if (item.type == ClipboardEntry.TYPE_FILE) {
        rememberFileThumbnail(item, if (compact) 480 else 900)
    } else {
        null
    }
    val style = typeStyleOf(item, showsPicture = thumbnail != null)
    var menuOpen by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(26.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = modifier.fillMaxWidth(),
    ) {
        Box {
            Column(
                Modifier
                    .combinedClickable(
                        onClick = { onOpen(keyed) },
                        onLongClick = { menuOpen = true },
                    )
                    .padding(
                        start = 16.dp,
                        top = 16.dp,
                        end = 16.dp,
                        // The handle of a stack sits in its own room below.
                        bottom = if (stackFooter != null) STACK_HANDLE_ZONE else 16.dp,
                    ),
            ) {
                when {
                    item.type == ClipboardEntry.TYPE_IMAGE -> ImagePreview(keyed.key, item, compact)
                    // The picture alone: its name is no part of the card, as an
                    // inline image has none (talkback still reads it).
                    thumbnail != null -> PreviewImage(thumbnail, item.filePayload?.fileName ?: "Synced image")
                    item.type == ClipboardEntry.TYPE_FILE -> FileRow(item, style)
                    else -> Text(
                        // Only what the card can show: Text measures all it is
                        // given, and a multi-megabyte copy is one entry.
                        previewTextOf(item.preview, CARD_TEXT_LIMIT),
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

            stackFooter?.invoke(this)

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
private fun ImagePreview(key: String, item: SyncedItem, compact: Boolean) {
    // Decoded off the main thread, and a failure remembered (see ImageCache).
    when (val image = rememberInlineImage(key, item.entry.content, if (compact) 480 else 900)) {
        ImageState.Loading -> Box(
            Modifier
                .fillMaxWidth()
                .height(if (compact) 120.dp else 180.dp)
                .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(16.dp)),
        )

        ImageState.Failed -> Text(
            "Image (couldn't be decoded)",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        is ImageState.Ready -> PreviewImage(image.bitmap, "Synced image")
    }
}

/**
 * A card's picture: as wide as the card and as tall as the picture is, whole,
 * never cropped. One taller than [MAX_PICTURE_HEIGHT_RATIO] times its width
 * (a very long screenshot) gets a box of that height and is fitted into it.
 */
@Composable
private fun PreviewImage(bitmap: ImageBitmap, contentDescription: String) {
    val ratio = (bitmap.width.toFloat() / bitmap.height.coerceAtLeast(1)).coerceAtLeast(1f / MAX_PICTURE_HEIGHT_RATIO)
    Image(
        bitmap = bitmap,
        contentDescription = contentDescription,
        contentScale = ContentScale.Fit,
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(ratio)
            .clip(RoundedCornerShape(16.dp)),
    )
}

private const val MAX_PICTURE_HEIGHT_RATIO = 3f

/** A file with no picture to show - any file but an image one whose bytes are here and decoded - as its card. */
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
