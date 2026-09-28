package io.uaena.cliplink.engine

import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.util.Log
import io.uaena.cliplink.clipboard.Capture
import io.uaena.cliplink.clipboard.ClipboardBridge
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DeviceIdentity
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.net.Discovery
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.net.PairingInfo
import io.uaena.cliplink.net.PeerConnection
import io.uaena.cliplink.net.Protocol
import io.uaena.cliplink.net.SyncManager
import io.uaena.cliplink.store.DeviceSettings
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.PassphraseKeyStore
import io.uaena.cliplink.store.TrustStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

/**
 * Everything that isn't UI. Owns identity, discovery, the TCP listener, the
 * peer connections and the local stores, and exposes the whole thing to
 * Compose as StateFlows.
 *
 * A process-wide singleton (see ClipLinkApplication) rather than a ViewModel:
 * sync has to survive the Activity being destroyed and recreated, and the
 * foreground service needs the exact same instance the UI is looking at.
 */
class ClipLinkEngine(context: Context) {

    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val trustStore = TrustStore(appContext)
    val passphraseKeyStore = PassphraseKeyStore(appContext)
    val deviceSettings = DeviceSettings(appContext)
    val fileStore = FileStore(appContext)
    private val historyStore = HistoryStore(appContext, fileStore)
    val clipboard = ClipboardBridge(appContext, fileStore)

    private val identity = DeviceIdentity()
    private val discovery = Discovery()
    private val syncManager = SyncManager(scope, historyStore, trustStore, fileStore)

    private var serverSocket: ServerSocket? = null
    private var acceptJob: Job? = null
    private var reconnectJob: Job? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /** Peers a dial is already in flight for - stops a beacon every 2s piling up attempts. */
    private val connectingTo: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    /** Latest beacon per device id, for addresses and live "seen recently" state. */
    private val beacons = ConcurrentHashMap<String, Discovery.Beacon>()
    private val beaconSeenAt = ConcurrentHashMap<String, Long>()

    /**
     * The latest name each peer announced, by beacon or handshake - trusted
     * or not. Only ever replaced by another name, never by "unknown", so an
     * older build's nameless beacon can't blank out what we already know.
     */
    private val peerNames = ConcurrentHashMap<String, String>()

    /** The remote address of each peer's most recent connection, for the Devices tab. */
    private val connectionAddresses = ConcurrentHashMap<String, String>()

    private var pendingPairingConnection: PeerConnection? = null

    // ---- observable state -------------------------------------------------

    private val _ownDeviceId = MutableStateFlow("")
    val ownDeviceId: StateFlow<String> = _ownDeviceId.asStateFlow()

    private val _items = MutableStateFlow<List<SyncedItem>>(emptyList())
    val items: StateFlow<List<SyncedItem>> = _items.asStateFlow()

    private val _devices = MutableStateFlow<List<DeviceRow>>(emptyList())
    val devices: StateFlow<List<DeviceRow>> = _devices.asStateFlow()

    private val _connectedCount = MutableStateFlow(0)
    val connectedCount: StateFlow<Int> = _connectedCount.asStateFlow()

    private val _log = MutableStateFlow<List<LogLine>>(emptyList())
    val log: StateFlow<List<LogLine>> = _log.asStateFlow()

    private val _pairingOpen = MutableStateFlow(false)
    val pairingOpen: StateFlow<Boolean> = _pairingOpen.asStateFlow()

    private val _pairingRequest = MutableStateFlow<PairingRequest?>(null)
    val pairingRequest: StateFlow<PairingRequest?> = _pairingRequest.asStateFlow()

    private val _hasPassphrase = MutableStateFlow(false)
    val hasPassphrase: StateFlow<Boolean> = _hasPassphrase.asStateFlow()

    private val _tailscaleIp = MutableStateFlow("")
    val tailscaleIp: StateFlow<String> = _tailscaleIp.asStateFlow()

    /** The name typed on the Me screen; empty means [defaultDeviceName] is used. */
    private val _deviceNameOverride = MutableStateFlow("")
    val deviceNameOverride: StateFlow<String> = _deviceNameOverride.asStateFlow()

    /** What the phone itself is called - the fallback when there is no override. */
    private val _defaultDeviceName = MutableStateFlow("")
    val defaultDeviceName: StateFlow<String> = _defaultDeviceName.asStateFlow()

    private val _discoveryRunning = MutableStateFlow(false)
    val discoveryRunning: StateFlow<Boolean> = _discoveryRunning.asStateFlow()

    private val _toast = MutableStateFlow<String?>(null)
    val toast: StateFlow<String?> = _toast.asStateFlow()

    private var cachedProof: String? = null
    private var started = false

    /**
     * Serialises discovery restarts. Cold start and onResume both trigger one,
     * and on a normal launch they fire within milliseconds of each other on
     * different coroutines - two concurrent start() calls race the socket and
     * scope fields, and the loser leaks a bound socket that then makes the
     * next bind fail with EADDRINUSE. After that nothing is ever discovered
     * again for the life of the process.
     */
    private val discoveryLock = Mutex()

    // ---- lifecycle --------------------------------------------------------

    @Synchronized
    fun start() {
        if (started) return
        started = true

        scope.launch {
            withContext(Dispatchers.IO) { identity.ensureKey() }
            val id = withContext(Dispatchers.IO) { identity.publicKeyBase64() }
            _ownDeviceId.value = id
            _tailscaleIp.value = deviceSettings.tailscaleIp
            _deviceNameOverride.value = deviceSettings.deviceNameOverride
            _defaultDeviceName.value = deviceSettings.systemDeviceName()
            refreshPassphraseState()
            refreshItems()
            refreshDevices()

            startTcpServer()
            acquireMulticastLock()
            restartDiscovery()

            // The interval timer doesn't fire immediately, and this call has to
            // run AFTER ownDeviceId is set: every tie-breaker below compares
            // against it, and running with it still empty makes every peer's
            // key read as ">= ours" and get skipped - a false "let them dial
            // us" decision, not a real one.
            reconnectOffLanPeers()
            reconnectJob = scope.launch {
                while (isActive) {
                    delay(RECONNECT_INTERVAL_MS)
                    reconnectOffLanPeers()
                }
            }
        }

        syncManager.onConnectionsChanged = { count ->
            _connectedCount.value = count
            refreshDevices()
        }
        syncManager.onLog = { message -> log(message) }
        syncManager.onEntryApplied = { entry -> onEntryReceived(entry) }
    }

    /**
     * Called when the app comes back to the foreground. A backgrounded app's
     * UDP socket can be quietly torn down by the OS, and a same-LAN reconnect
     * is entirely beacon-driven - so without restarting discovery here, a peer
     * that was fine before the app was backgrounded can take seemingly forever
     * to come back.
     */
    fun onForeground() {
        if (!started) return
        scope.launch {
            // The phone may have been renamed in system settings while away.
            // With no override set, that new name is ours from the next beacon.
            _defaultDeviceName.value = deviceSettings.systemDeviceName()
            restartDiscovery()
            reconnectOffLanPeers()
            // The only automatic capture Android permits: the clipboard is
            // readable exactly while this app has focus. Silent when there is
            // nothing new - captureAndBroadcast's echo check already
            // suppresses whatever we last applied ourselves.
            if (deviceSettings.autoCapture) captureAndBroadcast(quiet = true)
        }
    }

    fun shutdown() {
        scope.launch {
            discovery.stop()
            syncManager.closeAll()
            runCatching { serverSocket?.close() }
            acceptJob?.cancel()
            reconnectJob?.cancel()
            releaseMulticastLock()
            started = false
        }
    }

    // ---- discovery --------------------------------------------------------

    private suspend fun restartDiscovery() = discoveryLock.withLock {
        val id = _ownDeviceId.value
        if (id.isEmpty()) return@withLock

        discovery.onPeer = { beacon -> onBeacon(beacon) }
        discovery.onError = { where, error ->
            // An EPERM on send at targetSdk 37 means ACCESS_LOCAL_NETWORK was
            // denied, and the symptom (nothing is ever discovered) looks
            // identical to "no peers are running". Say which it is.
            val hint = if (error.message?.contains("EPERM", ignoreCase = true) == true) {
                " - local network permission looks denied"
            } else {
                ""
            }
            log("discovery $where failed: ${error.message}$hint")
            _discoveryRunning.value = discovery.isRunning
        }

        try {
            discovery.start(
                deviceId = id,
                tcpPort = Protocol.TCP_PORT,
                proof = { cachedProof },
                ownAddress = { _tailscaleIp.value.takeIf { it.isNotEmpty() } },
                pairingOpen = { _pairingOpen.value },
                ownName = ::ownName,
            )
            _discoveryRunning.value = true
        } catch (e: Exception) {
            // A failed bind is the one error that must never be swallowed: it
            // means no peer is ever discovered for the rest of the session,
            // which presents as "sync just doesn't work" with nothing in the
            // log to explain it. Retry once, then report.
            log("discovery failed to start (${e.message}) - retrying")
            delay(1000)
            try {
                discovery.start(
                    deviceId = id,
                    tcpPort = Protocol.TCP_PORT,
                    proof = { cachedProof },
                    ownAddress = { _tailscaleIp.value.takeIf { it.isNotEmpty() } },
                    pairingOpen = { _pairingOpen.value },
                    ownName = ::ownName,
                )
                _discoveryRunning.value = true
            } catch (retry: Exception) {
                _discoveryRunning.value = false
                log("discovery restart retry failed: ${retry.message}")
            }
        }
    }

    private fun onBeacon(beacon: Discovery.Beacon) {
        if (beacon.deviceId == _ownDeviceId.value) return // our own broadcast, looped back
        beacons[beacon.deviceId] = beacon
        beaconSeenAt[beacon.deviceId] = System.currentTimeMillis()
        recordPeerName(beacon.deviceId, beacon.name)
        refreshDevices()

        scope.launch {
            maybeAutoTrustViaPassphrase(beacon)
            maybeAutoConnect(beacon)
            maybeConnectForPairing(beacon)
        }
    }

    /**
     * The peer proved knowledge of the same passcode, so trust it without any
     * QR scan - the same thing the daemon does in its own PeerDiscovered
     * handler.
     */
    private suspend fun maybeAutoTrustViaPassphrase(beacon: Discovery.Beacon) {
        val proof = beacon.proof ?: return
        if (trustStore.isTrusted(beacon.deviceId)) return
        val key = withContext(Dispatchers.IO) { passphraseKeyStore.key() } ?: return
        if (!passphraseKeyStore.verifyProof(key, beacon.deviceId, proof)) return
        log("auto-trusting ${beacon.deviceId.take(12)}… (shared passcode)")
        trustStore.trust(beacon.deviceId, beacon.address, beacon.name ?: peerNames[beacon.deviceId])
        refreshDevices()
    }

    /**
     * Keeps a peer's latest announced name: in memory for everyone, and in
     * the trust record too when the peer is trusted. A null name (an older
     * build, or a field that didn't decode) changes nothing.
     */
    private fun recordPeerName(deviceId: String, name: String?) {
        if (name == null) return
        peerNames[deviceId] = name
        trustStore.rememberName(deviceId, name)
    }

    /** The best name we have for a peer, from this session or from its trust record. */
    private fun knownNameOf(deviceId: String): String? =
        peerNames[deviceId] ?: trustStore.all().firstOrNull { it.publicKey == deviceId }?.name

    /** Connect to an already-trusted device the moment its beacon is heard. */
    private suspend fun maybeAutoConnect(beacon: Discovery.Beacon) {
        if (syncManager.isConnected(beacon.deviceId)) return
        if (!connectingTo.add(beacon.deviceId)) return
        try {
            if (losesTieBreaker(beacon.deviceId)) return
            if (!trustStore.isTrusted(beacon.deviceId)) return
            connectToAddress(beacon.senderIp, beacon.tcpPort)
        } finally {
            connectingTo.remove(beacon.deviceId)
        }
    }

    /**
     * The untrusted sibling of [maybeAutoConnect]. Only attempts a handshake
     * when BOTH this device's pairing screen is open AND the beacon says the
     * sender's is - two independent, live "I'm expecting to pair right now"
     * signals rather than one side's assumption.
     */
    private suspend fun maybeConnectForPairing(beacon: Discovery.Beacon) {
        if (!_pairingOpen.value || !beacon.pairing) return
        if (syncManager.isConnected(beacon.deviceId)) return
        if (_pairingRequest.value != null) return // already awaiting a decision
        if (!connectingTo.add(beacon.deviceId)) return
        try {
            if (losesTieBreaker(beacon.deviceId)) return
            if (trustStore.isTrusted(beacon.deviceId)) return // maybeAutoConnect's job
            connectToAddress(beacon.senderIp, beacon.tcpPort)
        } finally {
            connectingTo.remove(beacon.deviceId)
        }
    }

    /**
     * Only the smaller-public-key side dials, so two devices that hear each
     * other don't open two connections at once.
     *
     * Kotlin's String.compareTo is ordinal over UTF-16 code units, matching
     * the HarmonyOS side's JS comparison and the Windows daemon's
     * string.CompareOrdinal exactly. Keep it ordinal: the daemon used to use
     * culture-sensitive String.CompareTo, which orders some key pairs the
     * other way around (ICU sorts 'k' before 'Q'), and against it either both
     * sides dialled or neither did.
     */
    private fun losesTieBreaker(peerDeviceId: String): Boolean =
        peerDeviceId >= _ownDeviceId.value

    // ---- TCP --------------------------------------------------------------

    private fun startTcpServer() {
        acceptJob = scope.launch(Dispatchers.IO) {
            try {
                val server = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(Protocol.TCP_PORT))
                }
                serverSocket = server
                while (isActive) {
                    val socket = try {
                        server.accept()
                    } catch (e: Exception) {
                        if (server.isClosed) return@launch
                        continue
                    }
                    launch { acceptConnection(socket) }
                }
            } catch (e: Exception) {
                log("TCP server error: ${e.message}")
            }
        }
    }

    private suspend fun acceptConnection(socket: Socket) {
        // Captured BEFORE the handshake: without an address for whoever just
        // dialled us, a device that only ever gets dialled could never
        // reconnect off-LAN on its own, only ever be reconnected to.
        val remoteAddress = socket.inetAddress?.hostAddress
        val conn = PeerConnection.create(
            socket = socket,
            identity = identity,
            trustStore = trustStore,
            passphraseKeyStore = passphraseKeyStore,
            pairingModeOpen = _pairingOpen.value,
            ownName = ownName(),
        ) ?: return
        handleNewConnection(conn, remoteAddress)
    }

    /** Returns whether a connection was established - not whether pairing succeeded. */
    private suspend fun connectToAddress(address: String, port: Int): Boolean =
        withContext(Dispatchers.IO) {
            val socket = Socket()
            try {
                // An explicit short timeout matters on targetSdk 37: when
                // ACCESS_LOCAL_NETWORK is denied, a LAN connect doesn't fail,
                // it HANGS. The default would park this coroutine for minutes.
                socket.connect(InetSocketAddress(address, port), CONNECT_TIMEOUT_MS)
            } catch (e: Exception) {
                runCatching { socket.close() }
                return@withContext false
            }
            val conn = PeerConnection.create(
                socket = socket,
                identity = identity,
                trustStore = trustStore,
                passphraseKeyStore = passphraseKeyStore,
                pairingModeOpen = _pairingOpen.value,
                ownName = ownName(),
            ) ?: return@withContext false
            handleNewConnection(conn, address)
            true
        }

    /**
     * The single funnel for every freshly created connection, whichever of
     * the three paths made it (incoming TCP, beacon dial, manual address).
     */
    private fun handleNewConnection(conn: PeerConnection, address: String?) {
        if (!conn.wasAlreadyTrusted) {
            if (_pairingRequest.value != null) {
                // Already prompting for a different candidate. Don't juggle
                // two - whoever came second just doesn't pair this round.
                conn.close()
                return
            }
            pendingPairingConnection = conn
            recordPeerName(conn.peerDeviceId, conn.peerName) // in memory only - not trusted
            _pairingRequest.value = PairingRequest(
                conn.peerDeviceId,
                address,
                conn.peerName ?: peerNames[conn.peerDeviceId],
            )
            return
        }

        // Registered FIRST, before the trust-store write and the log line
        // below. Those are conveniences; starting the read loop is not. In the
        // other order, one throw leaves the link unregistered and unlistened
        // while the peer redials every two seconds forever.
        syncManager.registerConnection(conn)

        (conn.remoteAddress ?: address)?.let { connectionAddresses[conn.peerDeviceId] = it }
        if (conn.newlyTrustedViaPassphrase) {
            trustStore.trust(conn.peerDeviceId, address, conn.peerName ?: peerNames[conn.peerDeviceId])
            log("auto-paired via passcode: ${conn.peerDeviceId.take(12)}…")
        } else {
            // Already trusted, but we may have just learned a real address -
            // back-fill it. This is what repairs a trust record written before
            // the accept path captured addresses at all, which would otherwise
            // be permanently stuck with nothing to dial off-LAN.
            if (address != null) trustStore.trust(conn.peerDeviceId, address)
            log("connected: ${conn.peerDeviceId.take(12)}…")
        }
        // After the trust writes, so the record exists: this is what picks up
        // a trusted peer that has been renamed since we last heard from it.
        recordPeerName(conn.peerDeviceId, conn.peerName)
        refreshDevices()
    }

    fun acceptPairing() {
        val conn = pendingPairingConnection ?: return
        val request = _pairingRequest.value
        pendingPairingConnection = null
        _pairingRequest.value = null
        trustStore.trust(conn.peerDeviceId, request?.address, request?.name ?: conn.peerName)
        conn.remoteAddress?.let { connectionAddresses[conn.peerDeviceId] = it }
        log("paired: ${conn.peerDeviceId.take(12)}…")
        syncManager.registerConnection(conn)
        refreshDevices()
        showToast("Paired.")
    }

    fun rejectPairing() {
        pendingPairingConnection?.close()
        pendingPairingConnection = null
        _pairingRequest.value = null
    }

    /**
     * Dials trusted peers whose only known address is a cached one - e.g. a
     * Tailscale IP - since no LAN beacon will ever arrive from them.
     */
    private suspend fun reconnectOffLanPeers() {
        val own = _ownDeviceId.value
        if (own.isEmpty()) return
        for (device in trustStore.withAddress()) {
            val address = device.address ?: continue
            if (device.publicKey == own) continue
            if (syncManager.isConnected(device.publicKey)) continue
            if (losesTieBreaker(device.publicKey)) continue
            if (!connectingTo.add(device.publicKey)) continue
            try {
                // A cached address is whatever the peer ADVERTISES for itself,
                // which is its Tailscale IP when it has one - useless if
                // Tailscale isn't up on THIS device. Any LAN address we've
                // actually heard a beacon from is both likelier to work and
                // cheaper, so it goes first.
                for (candidate in addressCandidatesFor(device.publicKey, address)) {
                    if (connectToAddress(candidate, Protocol.TCP_PORT)) break
                }
            } finally {
                connectingTo.remove(device.publicKey)
            }
        }
    }

    private fun addressCandidatesFor(deviceId: String, advertised: String?): List<String> {
        val candidates = LinkedHashSet<String>()
        beacons[deviceId]?.senderIp?.takeIf { it.isNotEmpty() }?.let(candidates::add)
        advertised?.takeIf { it.isNotEmpty() }?.let(candidates::add)
        return candidates.toList()
    }

    // ---- pairing ----------------------------------------------------------

    fun setPairingOpen(open: Boolean) {
        _pairingOpen.value = open
        if (!open) rejectPairing()
    }

    fun pairingPayload(): String =
        PairingInfo(_ownDeviceId.value, _tailscaleIp.value.takeIf { it.isNotEmpty() }, ownName()).toJson()

    /**
     * The name that goes on the wire - beacon, handshake and pairing code:
     * the override if one is set, else what the phone calls itself. Read
     * fresh each time, so a rename takes effect from the next beacon and the
     * next handshake without restarting anything.
     */
    private fun ownName(): String? =
        Protocol.normalizeDeviceName(_deviceNameOverride.value.ifBlank { _defaultDeviceName.value })

    /**
     * Dials a scanned or typed-in peer. Deliberately never writes trust by
     * itself: it only finds the other device's address, and the normal
     * accept/reject prompt decides. That prompt only appears when this
     * device's pairing screen is open, and the connection only completes when
     * the other device's is too - so possessing someone's code can't
     * unilaterally trust them.
     */
    suspend fun pairWith(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return "Enter a pairing code or address first."

        val info = PairingInfo.parse(trimmed)
        if (info != null) {
            // The full {PublicKey,Address} JSON another device's pairing
            // screen shows/copies - if this is our own, or genuinely
            // carries no address (LAN-only device, meant to be found via
            // its beacon instead), there's nothing to dial.
            if (info.publicKey == _ownDeviceId.value) return "That's this device's own code."
            val candidates = addressCandidatesFor(info.publicKey, info.address)
            if (candidates.isEmpty()) {
                return "${displayNameOf(info.publicKey, info.name)} has no address in its code. " +
                    "If it's on the same network, keep this screen open and its beacon will " +
                    "pair automatically."
            }
            for (candidate in candidates) {
                if (connectToAddress(candidate, Protocol.TCP_PORT)) {
                    return "Reached $candidate - accept the prompt on both devices to finish."
                }
            }
            return "Couldn't reach ${candidates.joinToString(", ")}."
        }

        // Not JSON - PairScreen's own hint text invites "just its IP
        // address if it's reachable", so treat the raw input AS that
        // address directly rather than (as this used to) silently
        // misreading it as a bare device key with nowhere to dial.
        if (connectToAddress(trimmed, Protocol.TCP_PORT)) {
            return "Reached $trimmed - accept the prompt on both devices to finish."
        }
        return "Couldn't reach $trimmed."
    }

    suspend fun setPassphrase(passphrase: String): Boolean = withContext(Dispatchers.Default) {
        if (passphrase.isBlank()) return@withContext false
        // 210,000 HMAC rounds - never on the main thread. Trimmed like
        // HarmonyOS and Windows do, so a stray space on one device can't
        // silently derive a different key.
        passphraseKeyStore.setPassphrase(passphrase.trim())
        refreshPassphraseState()
        true
    }

    fun clearPassphrase() {
        passphraseKeyStore.clearPassphrase()
        scope.launch { refreshPassphraseState() }
    }

    private suspend fun refreshPassphraseState() = withContext(Dispatchers.IO) {
        val has = passphraseKeyStore.hasPassphrase()
        _hasPassphrase.value = has
        val id = _ownDeviceId.value
        cachedProof = if (has && id.isNotEmpty()) {
            passphraseKeyStore.key()?.let { passphraseKeyStore.computeProof(it, id) }
        } else {
            null
        }
    }

    fun saveTailscaleIp(ip: String) {
        val trimmed = ip.trim()
        deviceSettings.tailscaleIp = trimmed
        _tailscaleIp.value = trimmed
        showToast(if (trimmed.isEmpty()) "Tailscale IP cleared." else "Tailscale IP saved.")
    }

    /** Blank clears the override, and the phone's own name is used again. */
    fun saveDeviceName(name: String) {
        // Stored already capped, so the field shows exactly what peers will.
        val normalized = Protocol.normalizeDeviceName(name).orEmpty()
        deviceSettings.deviceNameOverride = normalized
        _deviceNameOverride.value = normalized
        showToast(
            if (normalized.isEmpty()) {
                "Using this phone's name, “${_defaultDeviceName.value}”."
            } else {
                "Device name saved."
            },
        )
    }

    fun trustDevice(deviceId: String) {
        val beacon = beacons[deviceId]
        trustStore.trust(deviceId, beacon?.senderIp, peerNames[deviceId])
        refreshDevices()
        scope.launch { beacon?.let { connectToAddress(it.senderIp, it.tcpPort) } }
    }

    fun untrustDevice(deviceId: String) {
        val label = displayNameOf(deviceId, knownNameOf(deviceId)) // before the record goes
        trustStore.untrust(deviceId)
        refreshDevices()
        // Explicit confirmation matters: a just-untrusted device that is still
        // beaconing doesn't vanish from the list, it reappears as "discovered"
        // with a Trust button - so without this, Remove looks like it did
        // nothing at all.
        log("untrusted ${deviceId.take(12)}…")
        showToast("Removed $label")
    }

    // ---- clipboard --------------------------------------------------------

    /**
     * Reads the system clipboard and syncs it. Only works while the app is in
     * the foreground - that is an Android 10+ platform rule, not a choice
     * here.
     */
    fun captureAndBroadcast(quiet: Boolean = false) {
        scope.launch {
            when (val capture = clipboard.capture()) {
                // `quiet` is for the automatic on-open capture: an unprompted
                // "nothing to sync" every time the app opens is noise, but the
                // same message after a deliberate button press is the answer.
                null -> if (!quiet) showToast("Nothing on the clipboard to sync.")
                is Capture.Text -> broadcastText(capture.text, quiet)
                is Capture.Image -> broadcastImage(capture.pngBytes, quiet)
                is Capture.Payload -> broadcastFile(capture.fileName, capture.bytes, quiet)
            }
        }
    }

    /** The share-sheet path: push something from another app without switching to this one. */
    fun shareIn(text: String?, uri: Uri?) {
        scope.launch {
            when {
                uri != null -> {
                    val bytes = withContext(Dispatchers.IO) { clipboard.readBytes(uri) }
                    if (bytes == null) {
                        showToast("Couldn't read that file.")
                        return@launch
                    }
                    val mime = clipboard.mimeTypeOf(uri) ?: ""
                    if (mime.startsWith("image/")) {
                        broadcastImage(bytes)
                    } else {
                        broadcastFile(clipboard.displayName(uri), bytes)
                    }
                }

                !text.isNullOrEmpty() -> broadcastText(text)
                else -> showToast("Nothing to share.")
            }
        }
    }

    private suspend fun broadcastText(text: String, quiet: Boolean = false) {
        val hash = FileStore.hashOf(text.toByteArray(Charsets.UTF_8))
        if (hash == clipboard.lastKnownHash) return alreadySynced(quiet)
        clipboard.noteLocalHash(hash)
        broadcast(Signing.sign(identity, text, ClipboardEntry.TYPE_TEXT, _ownDeviceId.value))
        if (!quiet) showToast("Synced text.")
    }

    private suspend fun broadcastImage(pngBytes: ByteArray, quiet: Boolean = false) {
        val hash = FileStore.hashOf(pngBytes)
        if (hash == clipboard.lastKnownHash) return alreadySynced(quiet)
        clipboard.noteLocalHash(hash)
        // Images travel inline as base64 in the entry itself, matching the
        // other two platforms - they are NOT sent through the file-chunk path.
        val content = B64.encode(pngBytes)
        broadcast(Signing.sign(identity, content, ClipboardEntry.TYPE_IMAGE, _ownDeviceId.value))
        if (!quiet) showToast("Synced image.")
    }

    private suspend fun broadcastFile(fileName: String, bytes: ByteArray, quiet: Boolean = false) {
        val hash = FileStore.hashOf(bytes)
        if (hash == clipboard.lastKnownHash) return alreadySynced(quiet)
        clipboard.noteLocalHash(hash)
        // The bytes must be in the store BEFORE the entry goes out: the
        // receiver broadcasts a file_request the instant it sees an entry it
        // has no bytes for, and that request can come back before this
        // coroutine would otherwise have written them.
        withContext(Dispatchers.IO) { fileStore.write(hash, bytes) }
        val payload = FilePayload(fileName, hash, bytes.size.toLong()).toJson()
        broadcast(Signing.sign(identity, payload, ClipboardEntry.TYPE_FILE, _ownDeviceId.value))
        syncManager.tryFulfillPendingEntry(hash)
        if (!quiet) showToast("Synced $fileName.")
    }

    /**
     * The clipboard already holds what we last sent or applied, so there is
     * nothing to do. Silent for the automatic capture, but a deliberate tap on
     * the paste button gets an answer - otherwise the button looks broken,
     * which is exactly how the HarmonyOS paste button read before it was fixed.
     */
    private fun alreadySynced(quiet: Boolean) {
        if (!quiet) showToast("Already synced.")
    }

    private suspend fun broadcast(entry: ClipboardEntry) {
        syncManager.broadcastEntry(entry)
        refreshItems()
        log("sent ${entry.type} to ${syncManager.connectionCount} peer(s)")
    }

    private fun onEntryReceived(entry: ClipboardEntry) {
        refreshItems()
        log("received ${entry.type} from ${entry.deviceId.take(12)}…")
        if (deviceSettings.autoApply) {
            if (clipboard.apply(entry)) showToast("Copied ${entry.type} from a paired device.")
        }
    }

    fun applyToClipboard(item: SyncedItem): Boolean = clipboard.apply(item.entry)

    fun deleteItem(item: SyncedItem) {
        historyStore.remove(item.entry)
        refreshItems()
    }

    fun clearHistory() {
        historyStore.clear()
        refreshItems()
        showToast("History cleared.")
    }

    // ---- derived state ----------------------------------------------------

    private fun refreshItems() {
        val own = _ownDeviceId.value
        _items.value = historyStore.all()
            // .NET round-trip format sorts chronologically once canonicalised.
            .sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
            .map { entry ->
                SyncedItem(
                    entry = entry,
                    isOwn = entry.deviceId == own,
                    fileAvailable = entry.type != ClipboardEntry.TYPE_FILE ||
                        FilePayload.parse(entry.content)?.let { fileStore.exists(it.fileHash) } == true,
                )
            }
    }

    fun refreshDevices() {
        val connected = syncManager.connectedDeviceIds()
        val trusted = trustStore.all()
        val ids = LinkedHashSet<String>()
        trusted.forEach { ids.add(it.publicKey) }
        beacons.keys.forEach(ids::add)

        _devices.value = ids.map { id ->
            val beacon = beacons[id]
            val trustedEntry = trusted.firstOrNull { it.publicKey == id }
            // Every address this peer is reachable at, not just one: the LAN
            // address it beaconed from, the one its last connection came
            // from, whatever it advertises for itself, and whatever we cached
            // at pairing time can all differ, and a device card that shows
            // only one of them hides why a dial is failing.
            val addresses = LinkedHashSet<String>().apply {
                beacon?.senderIp?.takeIf { it.isNotEmpty() }?.let(::add)
                connectionAddresses[id]?.takeIf { it.isNotEmpty() }?.let(::add)
                beacon?.address?.takeIf { it.isNotEmpty() }?.let(::add)
                trustedEntry?.address?.takeIf { it.isNotEmpty() }?.let(::add)
            }
            DeviceRow(
                deviceId = id,
                name = peerNames[id] ?: trustedEntry?.name,
                trusted = trustedEntry != null,
                connected = connected.contains(id),
                addresses = addresses.toList(),
                pairing = beacon?.pairing == true,
                lastSeenAtMs = beaconSeenAt[id],
            )
        }.sortedWith(DeviceRow.STABLE_ORDER)
    }

    fun localAddresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filter { !it.isLoopbackAddress && it.hostAddress?.contains(':') == false }
            .mapNotNull { it.hostAddress }
    } catch (e: Exception) {
        emptyList()
    }

    // ---- misc -------------------------------------------------------------

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        runCatching {
            val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("cliplink-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseMulticastLock() {
        runCatching { multicastLock?.takeIf { it.isHeld }?.release() }
        multicastLock = null
    }

    fun showToast(message: String) {
        _toast.value = message
    }

    fun consumeToast() {
        _toast.value = null
    }

    private fun log(message: String) {
        Log.i(TAG, message)
        // Second precision, not minute: two events inside the same minute are
        // indistinguishable otherwise, which is useless for watching a
        // connect/disconnect flap.
        val line = LogLine(LocalTime.now().format(LOG_TIME_FORMAT), message)
        _log.update { existing -> (listOf(line) + existing).take(MAX_LOG_LINES) }
    }

    private companion object {
        const val TAG = "ClipLinkNet"
        const val MAX_LOG_LINES = 60
        const val RECONNECT_INTERVAL_MS = 30_000L
        const val CONNECT_TIMEOUT_MS = 3_000
        val LOG_TIME_FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")
    }
}
