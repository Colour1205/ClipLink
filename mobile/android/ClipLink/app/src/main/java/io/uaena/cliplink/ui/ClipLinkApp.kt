package io.uaena.cliplink.ui

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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Person
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.engine.LogLine
import io.uaena.cliplink.engine.PairingRequest
import io.uaena.cliplink.engine.SyncedItem
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
    val onPairingOpenChange: (Boolean) -> Unit,
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
    // pairing screen - and, through the pairing effect below, rejected a
    // pairing request somebody was in the middle of.
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

    // A device that left the list while its screen was open (a discovered one
    // that went quiet, or one just removed that was never heard): close the
    // screen, and forget the id so it cannot jump open if the device returns.
    LaunchedEffect(deviceDetailId, deviceDetail) {
        if (deviceDetailId != null && deviceDetail == null) deviceDetailId = null
    }

    // Pairing mode is a live signal, not a setting: this device advertises it
    // and dials strangers that advertise it only while this screen is actually
    // open, so it has to be flipped on the way in and off on every way out
    // (leaving the app is MainActivity's: no composition runs while it is
    // stopped).
    //
    // Only real transitions are reported. The first composition of a fresh
    // Activity (after a rotation, say) used to report "closed" whenever the
    // screen wasn't open - a change nobody made. An open screen is still
    // reported at once: that is a recreation restoring it. (Whether the screen
    // is open only decides what this device advertises and dials; a pairing
    // request reaches it either way.)
    var reportedPairing by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(pairing) {
        val before = reportedPairing
        reportedPairing = pairing
        if (pairing || before != null) actions.onPairingOpenChange(pairing)
    }

    // Opened by a scanner reading another device's pairing code: show the pairing
    // screen and start pairing, as if the code had been scanned in the app. (Both
    // devices still have to trust each other - the code only says where to dial.)
    LaunchedEffect(pairLink) {
        val link = pairLink ?: return@LaunchedEffect
        scanning = false
        detailKey = null
        deviceDetailId = null
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

    BackHandler(enabled = scanning || detail != null || deviceDetail != null || pairing) {
        when {
            scanning -> scanning = false
            detail != null -> detailKey = null
            deviceDetail != null -> deviceDetailId = null
            else -> pairing = false
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        bottomBar = {
            // Hidden on the sub-screens: both are full-screen tasks with their
            // own back affordance, and leaving a tab bar visible invites
            // tapping it mid-pairing, which silently cancels the pairing
            // window the other device is waiting on.
            if (detail == null && deviceDetail == null && !pairing && !scanning) {
                ShortNavigationBar {
                    Tab.entries.forEach { entry ->
                        ShortNavigationBarItem(
                            selected = tab == entry,
                            onClick = { tab = entry },
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

            AnimatedContent(
                targetState = Screen.of(scanning, detail != null, deviceDetail != null, pairing, tab),
                transitionSpec = {
                    (fadeIn(enterFade) + scaleIn(enterScale, initialScale = 0.96f)) togetherWith
                        (fadeOut(exitFade) + scaleOut(exitFade, targetScale = 1.02f)) using
                        SizeTransform(clip = false)
                },
                label = "screen",
            ) { screen ->
                saveableStateHolder.SaveableStateProvider(screen.name) {
                    when (screen) {
                        Screen.Detail -> detail?.let { opened ->
                            // The live copy: a file that finishes arriving while
                            // it's open is shown as arrived - its picture too.
                            val item = opened.item
                            DetailScreen(
                                item = item,
                                key = opened.key,
                                senderName = deviceNames[item.entry.deviceId],
                                contentPadding = padding,
                                onBack = { detailKey = null },
                                onCopy = { actions.synced.onCopy(item) },
                                onShare = { actions.synced.onShare(item) },
                                onDelete = {
                                    actions.synced.onDelete(item)
                                    detailKey = null
                                },
                            )
                        }

                        Screen.DeviceDetail -> deviceDetail?.let { opened ->
                            DeviceDetailScreen(
                                device = opened,
                                contentPadding = padding,
                                onBack = { deviceDetailId = null },
                                onTrust = { actions.onTrust(opened) },
                                onUntrust = { actions.onUntrust(opened) },
                                onBlock = { actions.onBlock(opened) },
                                onUnblock = { actions.onUnblock(opened) },
                                onCopyId = { actions.onCopyDeviceId(opened) },
                            )
                        }

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
                            onOpen = { detailKey = it.key },
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
                            onOpen = { deviceDetailId = it.deviceId },
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
    Scan, Detail, DeviceDetail, Pairing, Synced, Devices, Me;

    companion object {
        fun of(
            scanning: Boolean,
            hasDetail: Boolean,
            hasDeviceDetail: Boolean,
            pairing: Boolean,
            tab: Tab,
        ): Screen = when {
            scanning -> Scan
            hasDetail -> Detail
            hasDeviceDetail -> DeviceDetail
            pairing -> Pairing
            tab == Tab.Devices -> Devices
            tab == Tab.Me -> Me
            else -> Synced
        }
    }
}
