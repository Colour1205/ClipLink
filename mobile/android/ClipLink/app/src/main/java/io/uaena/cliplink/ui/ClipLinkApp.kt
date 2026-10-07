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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.uaena.cliplink.engine.DeviceRow
import io.uaena.cliplink.engine.LogLine
import io.uaena.cliplink.engine.PairingRequest
import io.uaena.cliplink.engine.SyncedItem

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
    val onPairingOpenChange: (Boolean) -> Unit,
    val onPair: (String) -> Unit,
    val onAcceptPairing: () -> Unit,
    val onRejectPairing: () -> Unit,
    val onToastShown: () -> Unit,
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ClipLinkApp(state: AppState, actions: AppActions, pairStatus: String) {
    var tab by remember { mutableStateOf(Tab.Synced) }
    var pairing by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<SyncedItem?>(null) }
    var scanning by remember { mutableStateOf(false) }
    // Hoisted up here rather than remembered inside SyncedScreen itself -
    // that screen gets swapped out of composition entirely (this file's
    // single AnimatedContent below only ever has ONE of Detail/Pairing/
    // Synced/... mounted at a time), so a locally-remembered layout choice
    // was getting reset back to its default every time a card's detail
    // view closed and SyncedScreen recomposed fresh. Defaults to Grid.
    var syncedLayout by remember { mutableStateOf(SyncedLayout.Grid) }
    val snackbarHostState = remember { SnackbarHostState() }
    // Who each item came from, by name: the Devices list already holds the
    // best name known for every device (trust record, else this session's
    // handshake or beacon), and is rebuilt when one arrives, so a byline that
    // read "Device AB12·CD34" gets the name as soon as it is known.
    val deviceNames = remember(state.devices) { state.devices.associate { it.deviceId to it.name } }

    // Pairing mode is a live signal, not a setting: an untrusted peer can only
    // complete a handshake while this screen is actually open, so it has to be
    // flipped on the way in and off on every way out.
    LaunchedEffect(pairing) { actions.onPairingOpenChange(pairing) }

    LaunchedEffect(state.toast) {
        state.toast?.let {
            snackbarHostState.showSnackbar(it)
            actions.onToastShown()
        }
    }

    BackHandler(enabled = scanning || detail != null || pairing) {
        when {
            scanning -> scanning = false
            detail != null -> detail = null
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
            if (detail == null && !pairing && !scanning) {
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
                targetState = Screen.of(scanning, detail, pairing, tab),
                transitionSpec = {
                    (fadeIn(enterFade) + scaleIn(enterScale, initialScale = 0.96f)) togetherWith
                        (fadeOut(exitFade) + scaleOut(exitFade, targetScale = 1.02f)) using
                        SizeTransform(clip = false)
                },
                label = "screen",
            ) { screen ->
                when (screen) {
                    Screen.Detail -> detail?.let { opened ->
                        // The live copy: a file that finishes arriving while
                        // it's open is shown as arrived - its picture too.
                        val item = state.items.firstOrNull { it.id == opened.id } ?: opened
                        DetailScreen(
                            item = item,
                            senderName = deviceNames[item.entry.deviceId],
                            contentPadding = padding,
                            onBack = { detail = null },
                            onCopy = { actions.synced.onCopy(item) },
                            onShare = { actions.synced.onShare(item) },
                            onDelete = {
                                actions.synced.onDelete(item)
                                detail = null
                            },
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
                    )

                    Screen.Synced -> SyncedScreen(
                        items = state.items,
                        deviceNames = deviceNames,
                        connectedCount = state.connectedCount,
                        discovering = state.discovering,
                        contentPadding = padding,
                        actions = actions.synced.copy(onOpen = { detail = it }),
                        layout = syncedLayout,
                        onLayoutChange = { syncedLayout = it },
                    )

                    Screen.Devices -> DevicesScreen(
                        devices = state.devices,
                        contentPadding = padding,
                        onTrust = actions.onTrust,
                        onUntrust = actions.onUntrust,
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

            state.pairingRequest?.let { request ->
                PairingPromptCard(
                    request = request,
                    onAccept = actions.onAcceptPairing,
                    onReject = actions.onRejectPairing,
                    modifier = Modifier
                        .align(androidx.compose.ui.Alignment.BottomCenter)
                        .padding(16.dp)
                        .padding(bottom = padding.calculateBottomPadding()),
                )
            }
        }
    }
}

private enum class Screen {
    Scan, Detail, Pairing, Synced, Devices, Me;

    companion object {
        fun of(scanning: Boolean, detail: SyncedItem?, pairing: Boolean, tab: Tab): Screen = when {
            scanning -> Scan
            detail != null -> Detail
            pairing -> Pairing
            tab == Tab.Devices -> Devices
            tab == Tab.Me -> Me
            else -> Synced
        }
    }
}
