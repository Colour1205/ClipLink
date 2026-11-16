package io.uaena.cliplink.ui

import android.view.RoundedCorner
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.plus
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ShortNavigationBar
import androidx.compose.material3.ShortNavigationBarItem
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.engine.LogLine
import io.uaena.cliplink.engine.PairingRequest
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.ui.icons.Icons
import io.uaena.cliplink.ui.icons.filled.ContentPaste
import io.uaena.cliplink.ui.icons.filled.Devices
import io.uaena.cliplink.ui.icons.filled.Person
import io.uaena.cliplink.ui.icons.outlined.ContentPaste
import io.uaena.cliplink.ui.icons.outlined.Devices
import io.uaena.cliplink.ui.icons.outlined.Person
import kotlinx.coroutines.launch

enum class Tab(val label: String, val selectedIcon: ImageVector, val icon: ImageVector) {
    Synced("Synced", Icons.Filled.ContentPaste, Icons.Outlined.ContentPaste),
    Devices("Devices", Icons.Filled.Devices, Icons.Outlined.Devices),
    Me("Me", Icons.Filled.Person, Icons.Outlined.Person),
}

/** Everything the shell renders, gathered so the Activity does the collecting. */
data class AppState(
    val items: List<SyncedItem>,
    val devices: List<DeviceRow>,
    val connectedCount: Int,
    val discovering: Boolean,
    val ownDeviceId: String,
    val deviceNameOverride: String,
    val defaultDeviceName: String,
    val pairingPayload: String,
    val pairingRequest: PairingRequest?,
    val hasPassphrase: Boolean,
    val passphraseBusy: Boolean,
    val tailscaleIp: String,
    val keepAlive: Boolean,
    val autoApply: Boolean,
    val autoCapture: Boolean,
    val dynamicColor: Boolean,
    val localAddresses: List<String>,
    val log: List<LogLine>,
    val toast: String?,
)

data class AppActions(
    val synced: SyncedActions,
    val me: MeActions,
    val onTrust: (DeviceRow) -> Unit,
    val onUntrust: (DeviceRow) -> Unit,
    val onBlock: (DeviceRow) -> Unit,
    val onUnblock: (DeviceRow) -> Unit,
    val onCopyDeviceId: (DeviceRow) -> Unit,
    val onPairingScreenChange: (Boolean) -> Unit,
    val onPair: (String) -> Unit,
    val onAcceptPairing: () -> Unit,
    val onRejectPairing: () -> Unit,
    val onToastShown: () -> Unit,
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ClipLinkApp(
    state: AppState,
    actions: AppActions,
    pairStatus: String,
    /** A pairing link the app was opened with (a scanner read a pairing QR code), until taken up. */
    pairLink: String? = null,
    onPairLinkTaken: () -> Unit = {},
    /** The Synced tab's layout the last time it was changed (kept by the caller across launches). */
    initialSyncedLayout: SyncedLayout = SyncedLayout.Grid,
    onSyncedLayoutChange: (SyncedLayout) -> Unit = {},
) {
    // All of this is rememberSaveable: the Activity is destroyed and rebuilt
    // for a rotation, a dark-mode or a language switch, and everything held in
    // plain remember went back to the Synced tab, closed the open item and the
    // pairing screen.
    var tab by rememberSaveable { mutableStateOf(Tab.Synced) }
    var pairing by rememberSaveable { mutableStateOf(false) }
    // The open item is held by its key and looked up in the live list below,
    // never as the item itself: a file that finishes arriving while it is open
    // shows as arrived, and the key is something a Bundle can hold.
    var detailKey by rememberSaveable { mutableStateOf<String?>(null) }
    // The open device, held the same way: by id, looked up in the live list.
    var deviceDetailId by rememberSaveable { mutableStateOf<String?>(null) }
    var scanning by rememberSaveable { mutableStateOf(false) }
    // Hoisted up here rather than remembered inside SyncedScreen itself -
    // that screen gets swapped out of composition entirely (this file's
    // single AnimatedContent below only ever has ONE of Detail/Pairing/
    // Synced/... mounted at a time), so a locally-remembered layout choice
    // was getting reset back to its default every time a card's detail
    // view closed and SyncedScreen recomposed fresh. Starts as it was left
    // (initialSyncedLayout), and each change is handed to the caller to keep.
    var syncedLayout by rememberSaveable { mutableStateOf(initialSyncedLayout) }
    // Keeps each screen's own rememberSaveable state (typed text, dialogs,
    // scroll position) while another screen is on show - the pairing screen
    // is swapped out for the scanner and back, and its typed address with it.
    val saveableStateHolder = rememberSaveableStateHolder()
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    // Who each item came from, by name: the Devices list already holds the
    // best name known for every device (trust record, else this session's
    // handshake or beacon), and is rebuilt when one arrives, so a byline that
    // read "Device AB12·CD34" gets the name as soon as it is known.
    val deviceNames = remember(state.devices) { state.devices.associate { it.deviceId to it.name } }
    val items = remember(state.items) { keyedItems(state.items) }
    val detail = detailKey?.let { key -> items.firstOrNull { it.key == key } }
    val deviceDetail = deviceDetailId?.let { id -> state.devices.firstOrNull { it.deviceId == id } }

    // An open item or device is not a page of its own: its card zooms into
    // it, over the page it was on, which stays on screen behind it (see
    // CardZoom). Every card that can be opened says where it is here.
    val zoomSources = remember { ZoomSources() }
    val zoom = remember(scope) { CardZoom(scope, zoomSources) }
    val reduceMotion = rememberReduceMotion()
    val density = LocalDensity.current
    val view = LocalView.current
    SideEffect {
        zoom.reduceMotion = reduceMotion
        zoom.density = density
        zoom.screenCorner = {
            view.rootWindowInsets?.getRoundedCorner(RoundedCorner.POSITION_TOP_LEFT)?.radius ?: 0
        }
    }

    fun openItem(keyed: KeyedItem) {
        detailKey = keyed.key
        zoom.open(itemZoomKey(keyed.key))
    }

    // The list has the screen back at once: the view shrinking back into its
    // card takes no touches, and the back gesture is the list's again.
    //
    // Text selected in the view lets go as it starts to close (see
    // OwnSelectionContainer), and its Copy bar goes here, now, rather than a
    // frame later with the selection: that bar is a window of its own over
    // the list, and while it was on its way out it swallowed the tap meant
    // for the card under it.
    val textToolbar = LocalTextToolbar.current
    fun closeItem(gone: Boolean = false) {
        textToolbar.hide()
        detailKey = null
        zoom.close(gone)
    }

    fun openDevice(device: DeviceRow) {
        deviceDetailId = device.deviceId
        zoom.open(deviceZoomKey(device.deviceId))
    }

    fun closeDevice(gone: Boolean = false) {
        textToolbar.hide()
        deviceDetailId = null
        zoom.close(gone)
    }

    // An item open when the Activity was rebuilt (a rotation) shows again as
    // it was, with no zoom - once the list holds it, which at a cold start is
    // a moment after the first frame. One that leaves the list while it is
    // open (deleted on another device) closes, toward the middle: its card is
    // gone.
    LaunchedEffect(detailKey, detail != null) {
        val key = detailKey ?: return@LaunchedEffect
        if (detail != null) {
            if (zoom.shown != itemZoomKey(key)) zoom.showAtRest(itemZoomKey(key))
        } else if (zoom.shown == itemZoomKey(key)) {
            closeItem(gone = true)
        }
    }

    // A device that left the list while its screen was open (a discovered one
    // that went quiet, or one just removed that was never heard): close the
    // screen, and forget the id so it cannot jump open if the device returns.
    LaunchedEffect(deviceDetailId, deviceDetail != null) {
        val id = deviceDetailId ?: return@LaunchedEffect
        if (deviceDetail != null) {
            if (zoom.shown != deviceZoomKey(id)) zoom.showAtRest(deviceZoomKey(id))
        } else if (zoom.shown == deviceZoomKey(id)) {
            closeDevice(gone = true)
        } else {
            deviceDetailId = null
        }
    }

    // Tells the caller when the pairing screen opens and when it closes, whichever
    // way that happens (the back arrow, the system back, a pairing link).
    //
    // Only real transitions are reported. The first composition of a fresh
    // Activity (after a rotation, say) is the same screen restored, not one
    // opening or closing - reporting it "closed" whenever the screen wasn't open
    // was a change nobody made.
    var reportedPairing by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(pairing) {
        val before = reportedPairing
        reportedPairing = pairing
        if (before != null) actions.onPairingScreenChange(pairing)
    }

    // Opened by a scanner reading another device's pairing code: show the pairing
    // screen and start pairing, as if the code had been scanned in the app. (Both
    // devices still have to trust each other - the code only says where to dial.)
    LaunchedEffect(pairLink) {
        val link = pairLink ?: return@LaunchedEffect
        scanning = false
        detailKey = null
        deviceDetailId = null
        zoom.drop()
        pairing = true
        actions.onPair(link)
        onPairLinkTaken()
    }

    LaunchedEffect(state.toast) {
        state.toast?.let {
            snackbarHostState.showSnackbar(it)
            actions.onToastShown()
        }
    }

    BackHandler(enabled = scanning || detailKey != null || deviceDetailId != null || pairing) {
        when {
            scanning -> scanning = false
            detailKey != null -> closeItem()
            deviceDetailId != null -> closeDevice()
            else -> pairing = false
        }
    }

    // Open: an item's or a device's full view covers the page.
    val viewOpen = detailKey != null || deviceDetailId != null
    // Hidden on the pairing and scanning screens: they are full-screen tasks
    // with their own back affordance. Under an open item or device it stays,
    // covered (and blurred on the way): taking it away would move the list
    // under the card as it opens.
    val tabBarShown = !pairing && !scanning
    var tabBarHeight by remember { mutableIntStateOf(0) }

    // The page the open views zoom over. The snackbar is above them all: a
    // view's own Copy says it was done.
    Box(
        Modifier
            .fillMaxSize()
            .onPlaced { zoom.host = it },
    ) {
        CompositionLocalProvider(LocalZoomSources provides zoomSources) {
            Scaffold(
                modifier = Modifier
                    .zoomBackdrop(zoom, with(density) { BACKDROP_BLUR.toPx() })
                    // Under an open view, nothing of the page is there to be read out.
                    .then(if (viewOpen) Modifier.clearAndSetSemantics { } else Modifier),
                bottomBar = {
                    if (tabBarShown) {
                        ShortNavigationBar(Modifier.onSizeChanged { tabBarHeight = it.height }) {
                            Tab.entries.forEach { entry ->
                                ShortNavigationBarItem(
                                    selected = tab == entry,
                                    onClick = {
                                        // Tapped while a view shrinks back into its
                                        // card: that card is leaving with its page.
                                        if (zoom.closing) zoom.drop()
                                        tab = entry
                                    },
                                    icon = {
                                        Icon(
                                            if (tab == entry) entry.selectedIcon else entry.icon,
                                            contentDescription = entry.label,
                                        )
                                    },
                                    label = {
                                        Text(
                                            entry.label,
                                            fontWeight = if (tab == entry) FontWeight.SemiBold else FontWeight.Normal,
                                        )
                                    },
                                )
                            }
                        }
                    }
                },
                // contentWindowInsets is deliberately left at its default (systemBars)
                // so these padding values actually describe the safe area: top is the
                // status bar, bottom is the navigation bar or the tab bar, whichever
                // is taller. Each screen then feeds them to its scrollable as CONTENT
                // padding rather than wrapping itself in Modifier.padding - which is
                // what makes lists scroll BEHIND the bars while their first and last
                // items still clear them. Zeroing this out drops the status-bar offset
                // and the first row renders under the clock.
            ) { padding ->
                Box(Modifier.fillMaxSize()) {
                    // Springs from the expressive motion scheme, never a raw tween -
                    // reaching for a tween here is exactly how a UI quietly stops
                    // feeling expressive while still compiling. Read out here because
                    // transitionSpec is not itself a @Composable lambda.
                    val enterScale = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()
                    val enterFade = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
                    val exitFade = MaterialTheme.motionScheme.fastEffectsSpec<Float>()

                    // An open item or device is not one of these: its card zooms into
                    // it over the page (see ZoomOverlay below).
                    AnimatedContent(
                        targetState = Screen.of(scanning, pairing, tab),
                        transitionSpec = {
                            (fadeIn(enterFade) + scaleIn(enterScale, initialScale = 0.96f)) togetherWith
                                (fadeOut(exitFade) + scaleOut(exitFade, targetScale = 1.02f)) using
                                SizeTransform(clip = false)
                        },
                        label = "screen",
                    ) { screen ->
                        saveableStateHolder.SaveableStateProvider(screen.name) {
                            when (screen) {
                                Screen.Pairing -> PairScreen(
                                    payload = state.pairingPayload,
                                    status = pairStatus,
                                    contentPadding = padding,
                                    onBack = { pairing = false },
                                    onPair = actions.onPair,
                                    onScan = { scanning = true },
                                )

                                Screen.Scan -> ScanScreen(
                                    contentPadding = padding,
                                    onBack = { scanning = false },
                                    onResult = { text ->
                                        scanning = false
                                        actions.onPair(text)
                                    },
                                    onUnavailable = { message ->
                                        scanning = false
                                        scope.launch { snackbarHostState.showSnackbar(message) }
                                    },
                                )

                                Screen.Synced -> SyncedScreen(
                                    items = items,
                                    deviceNames = deviceNames,
                                    connectedCount = state.connectedCount,
                                    discovering = state.discovering,
                                    contentPadding = padding,
                                    onOpen = ::openItem,
                                    actions = actions.synced,
                                    layout = syncedLayout,
                                    onLayoutChange = {
                                        syncedLayout = it
                                        onSyncedLayoutChange(it)
                                    },
                                )

                                Screen.Devices -> DevicesScreen(
                                    devices = state.devices,
                                    contentPadding = padding,
                                    onOpen = ::openDevice,
                                    onTrust = actions.onTrust,
                                    onUntrust = actions.onUntrust,
                                    onBlock = actions.onBlock,
                                    onUnblock = actions.onUnblock,
                                    onAdd = { pairing = true },
                                )

                                Screen.Me -> MeScreen(
                                    state = MeState(
                                        ownDeviceId = state.ownDeviceId,
                                        deviceNameOverride = state.deviceNameOverride,
                                        defaultDeviceName = state.defaultDeviceName,
                                        hasPassphrase = state.hasPassphrase,
                                        passphraseBusy = state.passphraseBusy,
                                        tailscaleIp = state.tailscaleIp,
                                        keepAlive = state.keepAlive,
                                        autoApply = state.autoApply,
                                        autoCapture = state.autoCapture,
                                        dynamicColor = state.dynamicColor,
                                        localAddresses = state.localAddresses,
                                        log = state.log,
                                    ),
                                    actions = actions.me,
                                    contentPadding = padding,
                                )
                            }
                        }
                    }

                }
            }
        }

        ZoomDim(zoom)

        // The open item or device, zoomed from its card. The live copy, looked
        // up by key: a file that finishes arriving while it's open is shown as
        // arrived - its picture too. Kept from the last time it was found
        // while it closes after leaving the list.
        val systemBars = WindowInsets.systemBars.asPaddingValues()
        val lastShown = remember { arrayOfNulls<Any>(1) }
        ZoomOverlay(zoom, page = MaterialTheme.colorScheme.background) { shown ->
            if (shown.startsWith(ITEM_ZOOM_PREFIX)) {
                val key = shown.removePrefix(ITEM_ZOOM_PREFIX)
                val opened = items.firstOrNull { it.key == key }?.also { lastShown[0] = it }
                    ?: (lastShown[0] as? KeyedItem)?.takeIf { it.key == key }
                opened?.let {
                    val item = it.item
                    DetailScreen(
                        item = item,
                        key = it.key,
                        senderName = deviceNames[item.entry.deviceId],
                        contentPadding = systemBars,
                        onBack = { closeItem() },
                        onCopy = { actions.synced.onCopy(item) },
                        onShare = { actions.synced.onShare(item) },
                        onDelete = {
                            actions.synced.onDelete(item)
                            closeItem(gone = true)
                        },
                    )
                }
            } else {
                val id = shown.removePrefix(DEVICE_ZOOM_PREFIX)
                val opened = state.devices.firstOrNull { it.deviceId == id }?.also { lastShown[0] = it }
                    ?: (lastShown[0] as? DeviceRow)?.takeIf { it.deviceId == id }
                opened?.let { device ->
                    DeviceDetailScreen(
                        device = device,
                        contentPadding = systemBars,
                        onBack = { closeDevice() },
                        onTrust = { actions.onTrust(device) },
                        onUntrust = { actions.onUntrust(device) },
                        onBlock = { actions.onBlock(device) },
                        onUnblock = { actions.onUnblock(device) },
                        onCopyId = { actions.onCopyDeviceId(device) },
                    )
                }
            }
        }

        // Where the Scaffold would put it: above the tab bar while that is
        // what's at the bottom, else just above the system's navigation bar.
        SnackbarHost(
            snackbarHostState,
            Modifier
                .align(Alignment.BottomCenter)
                .then(
                    if (tabBarShown && !viewOpen) {
                        Modifier.padding(bottom = with(density) { tabBarHeight.toDp() })
                    } else {
                        Modifier.windowInsetsPadding(WindowInsets.systemBars.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
                    },
                ),
        )
    }

    // A modal over whatever is open - not a page of its own. (With the app out
    // of view, the same two answers come from a notification.)
    state.pairingRequest?.let { request ->
        PairingRequestDialog(
            request = request,
            onTrust = actions.onAcceptPairing,
            onIgnore = actions.onRejectPairing,
        )
    }
}

private enum class Screen {
    Scan, Pairing, Synced, Devices, Me;

    companion object {
        fun of(
            scanning: Boolean,
            pairing: Boolean,
            tab: Tab,
        ): Screen = when {
            scanning -> Scan
            pairing -> Pairing
            tab == Tab.Devices -> Devices
            tab == Tab.Me -> Me
            else -> Synced
        }
    }
}
