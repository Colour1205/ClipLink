package io.uaena.cliplink

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.lifecycleScope
import io.uaena.cliplink.clipboard.ClipboardBridge
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.engine.ClipLinkEngine
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.service.ClipLinkService
import io.uaena.cliplink.ui.AppActions
import io.uaena.cliplink.ui.AppState
import io.uaena.cliplink.ui.ClipLinkApp
import io.uaena.cliplink.ui.MeActions
import io.uaena.cliplink.ui.PairViewModel
import io.uaena.cliplink.ui.SyncedActions
import io.uaena.cliplink.ui.rememberLocalAddresses
import io.uaena.cliplink.ui.theme.ClipLinkTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val engine: ClipLinkEngine by lazy { ClipLinkApplication.engine() }

    /** What the Pair screen's Connect is doing - in a ViewModel so a rotation neither cancels nor loses it. */
    private val pairModel: PairViewModel by viewModels()

    /** Whether the UI has the Pair screen on show; [onStart] turns pairing mode back on if so. */
    private var pairScreenOpen = false

    private val uiPrefs by lazy { getSharedPreferences("cliplink_ui", MODE_PRIVATE) }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { granted ->
        // ACCESS_LOCAL_NETWORK being denied doesn't produce an error anywhere -
        // UDP sends fail with EPERM and TCP dials just hang - so it has to be
        // called out here or it presents as "no devices exist". Said once, not
        // on every launch for as long as it stays denied (the Synced screen's
        // status pill keeps saying it, and opens the settings).
        when (granted[Manifest.permission.ACCESS_LOCAL_NETWORK]) {
            false -> if (!uiPrefs.getBoolean(KEY_LOCAL_NETWORK_NOTICE, false)) {
                uiPrefs.edit().putBoolean(KEY_LOCAL_NETWORK_NOTICE, true).apply()
                engine.showToast(
                    "Local network access is off, so ClipLink can't find your devices. " +
                        "Turn it on in App info → Permissions → Nearby devices.",
                )
            }

            true -> uiPrefs.edit().putBoolean(KEY_LOCAL_NETWORK_NOTICE, false).apply()
            null -> Unit
        }
    }

    private val pickFileLauncher = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        // The same path as the share sheet (see ShareReceiverActivity): a
        // picked photo is synced as the file it is, streamed, size-capped.
        uri?.let { engine.shareIn(null, listOf(it)) { outcome -> engine.showToast(outcome.message) } }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        engine.start()
        // Only for a fresh launch. A recreation (rotation, dark mode, language)
        // has already asked; asking again re-fired the callback at once for a
        // permission that is permanently denied, and so its "off" notice, on
        // every rotation.
        if (savedInstanceState == null) requestPermissions()
        if (engine.deviceSettings.keepAlive) ClipLinkService.start(this)

        setContent {
            val dynamicColor = remember { mutableStateOf(engine.deviceSettings.dynamicColor) }

            ClipLinkTheme(dynamicColor = dynamicColor.value) {
                val items by engine.items.collectAsState()
                val devices by engine.devices.collectAsState()
                val connectedCount by engine.connectedCount.collectAsState()
                val discovering by engine.discoveryRunning.collectAsState()
                val ownDeviceId by engine.ownDeviceId.collectAsState()
                val pairingRequest by engine.pairingRequest.collectAsState()
                val hasPassphrase by engine.hasPassphrase.collectAsState()
                val passphraseBusy by engine.passphraseBusy.collectAsState()
                val tailscaleIp by engine.tailscaleIp.collectAsState()
                val deviceNameOverride by engine.deviceNameOverride.collectAsState()
                val defaultDeviceName by engine.defaultDeviceName.collectAsState()
                val toast by engine.toast.collectAsState()
                val log by engine.log.collectAsState()
                // Follows the network (see rememberLocalAddresses): read once
                // per device id, it showed the last network's addresses for good.
                val localAddresses = rememberLocalAddresses(engine::localAddresses)

                var keepAlive by remember { mutableStateOf(engine.deviceSettings.keepAlive) }
                var autoApply by remember { mutableStateOf(engine.deviceSettings.autoApply) }
                var autoCapture by remember { mutableStateOf(engine.deviceSettings.autoCapture) }
                val pairStatus by pairModel.status.collectAsState()

                ClipLinkApp(
                    state = AppState(
                        items = items,
                        devices = devices,
                        connectedCount = connectedCount,
                        discovering = discovering,
                        ownDeviceId = ownDeviceId,
                        deviceNameOverride = deviceNameOverride,
                        defaultDeviceName = defaultDeviceName,
                        // Recomputed on every recomposition, and the two name
                        // flows collected above are what recompose it after a
                        // rename - so the QR code never shows a stale name.
                        pairingPayload = engine.pairingPayload(),
                        pairingRequest = pairingRequest,
                        hasPassphrase = hasPassphrase,
                        passphraseBusy = passphraseBusy,
                        tailscaleIp = tailscaleIp,
                        keepAlive = keepAlive,
                        autoApply = autoApply,
                        autoCapture = autoCapture,
                        dynamicColor = dynamicColor.value,
                        localAddresses = localAddresses,
                        log = log,
                        toast = toast,
                    ),
                    pairStatus = pairStatus,
                    actions = AppActions(
                        synced = SyncedActions(
                            onCopy = { item ->
                                if (engine.applyToClipboard(item)) {
                                    engine.showToast("Copied.")
                                } else {
                                    engine.showToast("Couldn't copy that item.")
                                }
                            },
                            onShare = ::shareItem,
                            onDelete = engine::deleteItem,
                            onSyncClipboard = engine::captureAndBroadcast,
                            onPickFile = { pickFileLauncher.launch(arrayOf("*/*")) },
                        ),
                        me = MeActions(
                            onSetPassphrase = { passphrase ->
                                val changing = engine.hasPassphrase.value
                                lifecycleScope.launch {
                                    if (engine.setPassphrase(passphrase)) {
                                        engine.showToast(
                                            (if (changing) "Passcode changed" else "Passcode set") +
                                                " — matching devices will auto-trust.",
                                        )
                                    }
                                }
                            },
                            onClearPassphrase = {
                                engine.clearPassphrase()
                                engine.showToast("Passcode cleared.")
                            },
                            onSaveTailscaleIp = engine::saveTailscaleIp,
                            onSaveDeviceName = engine::saveDeviceName,
                            onKeepAliveChange = { enabled ->
                                keepAlive = enabled
                                engine.deviceSettings.keepAlive = enabled
                                if (enabled) ClipLinkService.start(this) else ClipLinkService.stop(this)
                            },
                            onAutoApplyChange = { enabled ->
                                autoApply = enabled
                                engine.deviceSettings.autoApply = enabled
                            },
                            onAutoCaptureChange = { enabled ->
                                autoCapture = enabled
                                engine.deviceSettings.autoCapture = enabled
                            },
                            onDynamicColorChange = { enabled ->
                                dynamicColor.value = enabled
                                engine.deviceSettings.dynamicColor = enabled
                            },
                            onClearHistory = engine::clearHistory,
                            onCopyDeviceId = {
                                copyPlainText(ownDeviceId)
                                engine.showToast("Device ID copied.")
                            },
                        ),
                        onTrust = { engine.trustDevice(it.deviceId) },
                        onUntrust = { engine.untrustDevice(it.deviceId) },
                        onPairingOpenChange = { open ->
                            pairScreenOpen = open
                            engine.setPairingOpen(open)
                            if (!open) pairModel.clear()
                        },
                        onPair = { raw -> pairModel.pair(raw, engine::pairWith) },
                        onAcceptPairing = engine::acceptPairing,
                        onRejectPairing = engine::rejectPairing,
                        onToastShown = engine::consumeToast,
                    ),
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // Back from the background with the Pair screen still up: it is live
        // again (see onStop).
        if (pairScreenOpen) engine.setPairingOpen(true)
    }

    override fun onStop() {
        super.onStop()
        // Pairing mode means "an untrusted peer may complete a handshake", and
        // the Pair screen's own on/off follows in-app navigation only. Left on
        // here, a phone with keep-alive on kept beaconing pairing=1 and taking
        // untrusted handshakes after the user went Home from that screen. Not
        // for a recreation, though: it is the same screen, a moment later, and
        // closing would reject a pairing request somebody is looking at.
        if (!isChangingConfigurations) engine.setPairingOpen(false)
    }

    override fun onResume() {
        super.onResume()
        // Foregrounding is the other moment besides a cold start that deserves
        // an immediate reconnect: a backgrounded app's UDP socket can be torn
        // down by the OS without any error surfacing.
        engine.onForeground()
    }

    @SuppressLint("InlinedApi")
    private fun requestPermissions() {
        val wanted = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 37) {
            wanted += Manifest.permission.ACCESS_LOCAL_NETWORK
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            wanted += Manifest.permission.POST_NOTIFICATIONS
        }
        // Only what isn't granted yet: asking for a granted one is a pointless
        // round trip, and every launch asked.
        wanted.removeAll { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        // Granted since the notice was shown: say it again if it is taken away.
        if (Manifest.permission.ACCESS_LOCAL_NETWORK !in wanted) {
            uiPrefs.edit().putBoolean(KEY_LOCAL_NETWORK_NOTICE, false).apply()
        }
        if (wanted.isNotEmpty()) {
            permissionLauncher.launch(wanted.toTypedArray())
        }
    }

    private fun shareItem(item: SyncedItem) {
        val send = Intent(Intent.ACTION_SEND).apply { addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        when (item.type) {
            ClipboardEntry.TYPE_TEXT -> {
                send.type = "text/plain"
                send.putExtra(Intent.EXTRA_TEXT, item.entry.content)
            }

            ClipboardEntry.TYPE_IMAGE -> {
                val bytes = io.uaena.cliplink.core.B64.decodeOrNull(item.entry.content) ?: return
                val hash = io.uaena.cliplink.store.FileStore.hashOf(bytes)
                if (!engine.fileStore.exists(hash)) engine.fileStore.write(hash, bytes)
                send.type = "image/png"
                send.putExtra(
                    Intent.EXTRA_STREAM,
                    engine.clipboard.contentUriFor(engine.fileStore.path(hash), "$hash.png"),
                )
            }

            ClipboardEntry.TYPE_FILE -> {
                val payload = item.filePayload ?: return
                if (!engine.fileStore.exists(payload.fileHash)) {
                    engine.showToast("That file hasn't finished transferring yet.")
                    return
                }
                send.type = ClipboardBridge.guessMimeType(payload.fileName)
                send.putExtra(
                    Intent.EXTRA_STREAM,
                    engine.clipboard.contentUriFor(
                        engine.fileStore.path(payload.fileHash),
                        payload.fileName,
                    ),
                )
            }

            else -> return
        }
        // ClipLink is a share target itself; offering it here would only
        // sync the item straight back as a new one.
        val chooser = Intent.createChooser(send, "Share").putExtra(
            Intent.EXTRA_EXCLUDE_COMPONENTS,
            arrayOf(ComponentName(this, ShareReceiverActivity::class.java)),
        )
        startActivity(chooser)
    }

    private fun copyPlainText(text: String) {
        val manager = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        manager.setPrimaryClip(ClipData.newPlainText("ClipLink", text))
    }

    private companion object {
        /** Set once the "local network access is off" toast has been shown; cleared when it is granted. */
        const val KEY_LOCAL_NETWORK_NOTICE = "local_network_notice_shown"
    }
}
