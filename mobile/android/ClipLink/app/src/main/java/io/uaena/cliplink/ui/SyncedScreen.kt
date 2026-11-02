package io.uaena.cliplink.ui

import android.content.ClipData
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.SaveAlt
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.ViewAgenda
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.toSize
import androidx.compose.ui.zIndex
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.engine.displayNameOf
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

enum class SyncedLayout { List, Grid }

data class SyncedActions(
    val onCopy: (SyncedItem) -> Unit,
    val onShare: (SyncedItem) -> Unit,
    val onDelete: (SyncedItem) -> Unit,
    val onSyncClipboard: () -> Unit,
    val onPickFile: () -> Unit,
    /** A stack was opened: its group ends and its items become ordinary cards. */
    val onExpandGroup: (Long) -> Unit,
    /** A stack that was just opened was put back by the finger that opened it: it is a stack again. */
    val onCollapseGroup: (Long) -> Unit,
    /** Opens a file in the app the system picks for it. */
    val onOpenFile: (SyncedItem) -> Unit,
    /** Saves a copy of a file where the user picks. */
    val onSaveFile: (SyncedItem) -> Unit,
    /**
     * What a card dragged out of the app carries: its text, or its picture or
     * file. Null while there is nothing to give. BLOCKING (a file is copied):
     * called off the main thread.
     */
    val dragClipFor: (SyncedItem) -> ClipData?,
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
            // What the user did to a stack last counts at once, before the
            // engine's own list says so.
            val opened = remember { mutableStateMapOf<Long, Boolean>() }
            val openedNow = opened.toMap()
            val rows = remember(items, openedNow) { buildRows(items, openedNow) }
            val reduceMotion = rememberReduceMotion()
            val haptics = LocalHapticFeedback.current
            // The stack opened last, while its cards slide out of it (or back in).
            val reveal = remember { StackReveal() }
            val revealScene = reveal.scene
            LaunchedEffect(revealScene, revealScene?.collapsing, revealScene?.held) {
                val scene = revealScene ?: return@LaunchedEffect
                // Kept while the finger that popped it is down: it can still put the cards back.
                if (scene.held && !scene.collapsing) return@LaunchedEffect
                // Long enough for the last card to have settled (or to have gone back).
                delay(if (scene.collapsing) REVEAL_COLLAPSE_KEEP_MS else REVEAL_KEEP_MS)
                if (reveal.scene === scene) reveal.scene = null
            }
            // The cards move to their new places with a spring: the one a
            // stack opens and closes with while it does, the one new cards
            // come in with otherwise. With reduced motion, short and plain.
            val placement: FiniteAnimationSpec<IntOffset> = when {
                reduceMotion -> tween(if (revealScene != null) 150 else 120, easing = EaseInOut)
                revealScene != null -> springMotion(0.4f, 0.85f, IntOffset.VisibilityThreshold)
                else -> springMotion(0.3f, 0.85f, IntOffset.VisibilityThreshold)
            }
            val listState = rememberLazyListState()
            val gridState = rememberLazyStaggeredGridState()
            // A card or a stack that arrives on top while the list is at the
            // very top is shown there, growing in, with the rest moving down
            // under it. The lazy list holds on to the card that was first (by
            // its key), which would leave the new one above the screen, unseen:
            // so it is asked, before it measures the change, to stay at the top.
            val topRow = remember { arrayOfNulls<String>(1) }
            val before = topRow[0]
            topRow[0] = rows.firstOrNull()?.key
            if (before != null && before != topRow[0] && rows.indexOfFirst { it.key == before } > 0) {
                Snapshot.withoutReadObservation {
                    if (layout == SyncedLayout.List) {
                        if (listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0) {
                            listState.requestScrollToItem(0)
                        }
                    } else if (gridState.firstVisibleItemIndex == 0 && gridState.firstVisibleItemScrollOffset == 0) {
                        gridState.requestScrollToItem(0)
                    }
                }
            }
            val generation = remember { intArrayOf(0) }
            val scope = rememberCoroutineScope()
            val closing = remember { arrayOfNulls<Job>(1) }
            val callbacks = remember(actions, haptics, reduceMotion) {
                StackCallbacks(
                    // The user opened a stack: its items become ordinary cards
                    // that start where its layers were and slide out to their
                    // places, and it never stacks again (unless the finger that
                    // opened it puts it back).
                    onExpand = expand@{ stack, stretch, cardBottom, centerX, held ->
                        haptics.performHapticFeedback(TAP_HAPTIC)
                        // Popped out again before the cards put back were one
                        // stack again: they stay rows, and slide out again
                        // from wherever they had got to.
                        val current = reveal.scene
                        if (current != null && current.collapsing && current.groupId == stack.groupId && closing[0]?.isActive == true) {
                            closing[0]?.cancel()
                            current.collapsing = false
                            current.held = held
                            return@expand
                        }
                        reveal.scene = RevealScene(
                            generation = ++generation[0],
                            groupId = stack.groupId,
                            frontKey = stack.key,
                            stretch = stretch,
                            cardBottom = cardBottom,
                            frontCenterX = centerX,
                            slots = revealSlots(stack),
                            members = stack.members.mapTo(HashSet()) { it.key },
                            startedAtMs = System.currentTimeMillis(),
                        ).also { it.held = held }
                        opened[stack.groupId] = true
                        actions.onExpandGroup(stack.groupId)
                    },
                    // The finger that opened it came back up before it was
                    // lifted: the cards go back in, each sliding back to where
                    // its layer was, and then they are one stack again (the
                    // cards below moving up into the room they took). A row
                    // a lazy list has let go of runs no animation, so the
                    // cards stay rows until they are back. Only for the stack
                    // just opened.
                    onCollapse = { groupId ->
                        val scene = reveal.scene
                        if (scene != null && scene.groupId == groupId && !scene.collapsing) {
                            haptics.performHapticFeedback(TAP_HAPTIC)
                            scene.collapsing = true
                            closing[0] = scope.launch {
                                delay(if (reduceMotion) COLLAPSE_FADE_MS else COLLAPSE_SLIDE_MS)
                                opened[groupId] = false
                                actions.onCollapseGroup(groupId)
                            }
                        }
                    },
                    onLetGo = { groupId ->
                        reveal.scene?.takeIf { it.groupId == groupId }?.held = false
                    },
                )
            }
            // The front card of an opening stack is drawn above the cards
            // coming out from under it (and going back in).
            fun rowModifier(row: SyncedRow, scene: RevealScene?): Modifier =
                Modifier.zIndex(if (scene?.frontKey == row.key) 1f else 0f)

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
                                callbacks = callbacks,
                                modifier = rowModifier(row, revealScene).animateItem(
                                    fadeInSpec = null,
                                    placementSpec = placement,
                                    fadeOutSpec = null,
                                ),
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
                                callbacks = callbacks,
                                modifier = rowModifier(row, revealScene).animateItem(
                                    fadeInSpec = null,
                                    placementSpec = placement,
                                    fadeOutSpec = null,
                                ),
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

/** How long the slide of an opened stack's cards is remembered, whether or not they were all on screen. */
private const val REVEAL_KEEP_MS = 1_800L

/** How long it is remembered once the cards went back into the stack: until they are gone. */
private const val REVEAL_COLLAPSE_KEEP_MS = 700L

/** How long the cards of a stack put back take to slide back to their layers (springMotion(0.4, 0.9) is about there)... */
private const val COLLAPSE_SLIDE_MS = 380L

/** ...or to fade out, with reduced motion. */
private const val COLLAPSE_FADE_MS = 150L

/** The tick a tap gives - a card, a menu item, a stack opening or closing. */
internal val TAP_HAPTIC = HapticFeedbackType.ContextClick

/**
 * One row of the list or grid: a card, or a stack standing for a history
 * batch - both in the stack's wrapper, so a row stays the same composition
 * when its stack opens under the finger.
 */
@Composable
private fun SyncedRowContent(
    row: SyncedRow,
    deviceNames: Map<String, String?>,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    compact: Boolean,
    reveal: StackReveal,
    reduceMotion: Boolean,
    callbacks: StackCallbacks,
    modifier: Modifier = Modifier,
) {
    val front = when (row) {
        is SyncedRow.Single -> row.keyed
        is SyncedRow.Stack -> row.front
    }
    StackedCard(
        front = front,
        stack = row as? SyncedRow.Stack,
        senderName = deviceNames[front.item.entry.deviceId],
        onOpen = onOpen,
        actions = actions,
        compact = compact,
        reduceMotion = reduceMotion,
        reveal = reveal,
        callbacks = callbacks,
        modifier = modifier,
    )
}

@Composable
internal fun SyncedCard(
    keyed: KeyedItem,
    senderName: String?,
    onOpen: (KeyedItem) -> Unit,
    actions: SyncedActions,
    compact: Boolean,
    modifier: Modifier = Modifier,
    /** The last thing in the footer row, after the file's kind, given its whole width: a stack's count. */
    footerTrailing: (@Composable () -> Unit)? = null,
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
    var confirmingDelete by remember { mutableStateOf(false) }

    val haptics = LocalHapticFeedback.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val currentItem by rememberUpdatedState(item)
    val currentKeyed by rememberUpdatedState(keyed)
    val currentOnOpen by rememberUpdatedState(onOpen)
    val currentActions by rememberUpdatedState(actions)

    // The press: a little smaller while a finger is on the card, back to size
    // when it lifts, moves away or the card's menu opens. Not changed by
    // reduced motion.
    var pressed by remember { mutableStateOf(false) }
    val pressScale by animateFloatAsState(
        if (pressed) CARD_PRESS_SCALE else 1f,
        springMotion(0.25f, 0.9f),
        label = "cardPress",
    )
    // The card as it looks, for the lifted picture of its menu and the one a
    // drag out of the app carries.
    val picture = rememberGraphicsLayer()
    val placed = remember { arrayOfNulls<LayoutCoordinates>(1) }
    // The menu: open, or closing (its picture going back down) once `open` is false.
    var menu by remember { mutableStateOf<OpenMenu?>(null) }
    // What a drag out of the app would carry, got ready when the menu opens.
    val dragClip = remember { arrayOfNulls<Deferred<ClipData?>>(1) }
    // Counts long presses and drags out: a menu whose picture is ready only
    // after the card was dragged away does not open over the drag.
    val menuTurn = remember { intArrayOf(0) }

    fun tap() {
        haptics.performHapticFeedback(TAP_HAPTIC)
        currentOnOpen(currentKeyed)
    }

    fun openMenu() {
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        val target = currentItem
        dragClip[0] = scope.async(Dispatchers.IO) {
            try {
                currentActions.dragClipFor(target)
            } catch (e: Exception) {
                null
            } catch (e: OutOfMemoryError) {
                null
            }
        }
        val turn = ++menuTurn[0]
        scope.launch {
            val coords = placed[0]?.takeIf { it.isAttached } ?: return@launch
            val bounds = Rect(coords.positionOnScreen(), coords.size.toSize())
            val snapshot = try {
                picture.toImageBitmap()
            } catch (e: Exception) {
                return@launch
            }
            if (turn == menuTurn[0]) menu = OpenMenu(snapshot, bounds)
        }
    }

    fun dragOut(at: Offset) {
        // The menu goes and the card goes to the finger, carrying the item.
        menuTurn[0]++
        val shown = menu
        menu = null
        val pending = dragClip[0]
        scope.launch {
            val snapshot = shown?.snapshot ?: try {
                picture.toImageBitmap()
            } catch (e: Exception) {
                return@launch
            }
            val clip = pending?.let { withTimeoutOrNull(DRAG_CLIP_WAIT_MS) { it.await() } }
            startCardDrag(view, snapshot, at, clip)
        }
    }

    Surface(
        shape = RoundedCornerShape(CARD_RADIUS),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = modifier
            .fillMaxWidth()
            // Tapped, the card grows into the item's full view.
            .cardMorph(keyed.key)
            .onPlaced { placed[0] = it }
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
            .pointerInput(Unit) {
                detectCardPress(
                    onPress = { pressed = it },
                    onTap = ::tap,
                    onLongPress = ::openMenu,
                    onDragOut = ::dragOut,
                )
            }
            // One node, as a clickable card was: what it shows is read with it.
            .semantics(mergeDescendants = true) {
                role = Role.Button
                onClick(label = "Open") {
                    tap()
                    true
                }
                onLongClick(label = "Actions") {
                    openMenu()
                    true
                }
            }
            .drawWithContent {
                picture.record { this@drawWithContent.drawContent() }
                drawLayer(picture)
            },
    ) {
        Box {
            Column(Modifier.padding(16.dp)) {
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
                    // The time, then the sender's name (its short id while none
                    // is known) for an item from another device - the same
                    // line on every phone app. Grid cards are narrow: the name
                    // is the one part that gives way, never the time.
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            item.timeLabel,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                        if (!item.isOwn) {
                            Text(
                                " · ${displayNameOf(item.entry.deviceId, senderName)}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f, fill = false),
                            )
                        }
                    }
                    // A file's kind at the far end, picture files included.
                    fileExtensionLabel(item.filePayload?.fileName)?.let { extension ->
                        Text(
                            extension,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                    // Unweighted like the chip and the kind, so it is measured
                    // first and the name above is what gives way to it.
                    footerTrailing?.invoke()
                }
            }

        }
    }

    menu?.let { shown ->
        // Copy for text; Share for everything; Open and Save for a file; Delete last.
        fun act(action: () -> Unit): () -> Unit = {
            haptics.performHapticFeedback(TAP_HAPTIC)
            menu = shown.copy(open = false)
            action()
        }
        val items = buildList {
            if (item.type == ClipboardEntry.TYPE_TEXT) add(CardMenuItem("Copy", Icons.Outlined.ContentCopy, act { actions.onCopy(item) }))
            add(CardMenuItem("Share", Icons.Outlined.Share, act { actions.onShare(item) }))
            if (item.type == ClipboardEntry.TYPE_FILE) {
                add(CardMenuItem("Open", Icons.AutoMirrored.Outlined.OpenInNew, act { actions.onOpenFile(item) }))
                add(CardMenuItem("Save", Icons.Outlined.SaveAlt, act { actions.onSaveFile(item) }))
            }
            add(CardMenuItem("Delete", Icons.Outlined.DeleteOutline, act { confirmingDelete = true }))
        }
        CardMenu(
            snapshot = shown.snapshot,
            cardBounds = shown.bounds,
            items = items,
            open = shown.open,
            onClosed = { if (menu === shown || menu?.open == false) menu = null },
            onDismissRequest = { menu = menu?.copy(open = false) },
        )
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

/** A card's menu while it is shown: the picture it lifts, where the card is on the screen, and whether it is opening or closing. */
private data class OpenMenu(val snapshot: ImageBitmap, val bounds: Rect, val open: Boolean = true)

/** How long a drag out of the app waits for what it carries to be ready (a file being copied); after that it carries nothing. */
private const val DRAG_CLIP_WAIT_MS = 300L

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

/**
 * What a file card's footer shows of [fileName]: its extension, upper-case
 * and without the dot ("PDF"). Null for no name, no extension, or one longer
 * than [MAX_EXTENSION_LABEL] or with anything but letters and digits in it
 * ("v1.2 beta") - that is more likely part of the name than a kind.
 */
internal fun fileExtensionLabel(fileName: String?): String? =
    fileName?.substringAfterLast('.', "")
        ?.takeIf { it.isNotEmpty() && it.length <= MAX_EXTENSION_LABEL && it.all(Char::isLetterOrDigit) }
        ?.uppercase()

private const val MAX_EXTENSION_LABEL = 8

fun formatSize(bytes: Long): String = when {
    bytes >= 1_073_741_824 -> "%.1f GB".format(bytes / 1_073_741_824.0)
    bytes >= 1_048_576 -> "%.1f MB".format(bytes / 1_048_576.0)
    bytes >= 1024 -> "%.0f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}
