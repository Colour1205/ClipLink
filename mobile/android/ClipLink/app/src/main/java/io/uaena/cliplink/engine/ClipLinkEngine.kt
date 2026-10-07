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
import io.uaena.cliplink.core.Ipv4
import io.uaena.cliplink.core.Signing
import io.uaena.cliplink.core.describeError
import io.uaena.cliplink.net.ConnectionGate
import io.uaena.cliplink.net.Discovery
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.net.PairingInfo
import io.uaena.cliplink.net.PeerConnection
import io.uaena.cliplink.net.PeerLink
import io.uaena.cliplink.net.Protocol
import io.uaena.cliplink.net.SyncManager
import io.uaena.cliplink.share.ShareIntake
import io.uaena.cliplink.share.ShareOutcome
import io.uaena.cliplink.store.DeletedStore
import io.uaena.cliplink.store.DeviceSettings
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.PassphraseKeyStore
import io.uaena.cliplink.store.TrustStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
 *
 * Nothing in here is allowed to take the process down. Every coroutine runs
 * under [crashGuard], which logs what escaped and carries on, the loops that
 * must keep going (reconnecting, accepting, housekeeping) catch their own
 * failures per pass, and a failure that matters to the user - the listener
 * down, the identity key unavailable - is shown through [serverFault].
 */
class ClipLinkEngine(context: Context) {

    private val appContext = context.applicationContext

    /**
     * What an exception nobody caught - an Error included: a StackOverflowError
     * from a hostile document, an OutOfMemoryError from a huge one, a Keystore
     * ProviderException - comes to. On a plain scope it would reach the
     * thread's uncaught-exception handler and kill the app.
     */
    private val crashGuard = CoroutineExceptionHandler { _, error ->
        Log.e(TAG, "uncaught in a coroutine", error)
        log("internal error: ${describeError(error)}")
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + crashGuard)

    val trustStore = TrustStore(appContext)
    val passphraseKeyStore = PassphraseKeyStore(appContext)
    val deviceSettings = DeviceSettings(appContext)
    val fileStore = FileStore(appContext)
    private val historyStore = HistoryStore(appContext, fileStore, DeletedStore(appContext))
    val clipboard = ClipboardBridge(appContext, fileStore)
    val shareIntake = ShareIntake(appContext, fileStore)

    private val identity = DeviceIdentity()
    private val discovery = Discovery()
    private val syncManager = SyncManager(scope, historyStore, trustStore, fileStore)

    /** Caps the sockets that have connected and not yet proved anything - see [admit]. */
    private val handshakeGate = ConnectionGate()

    private var serverSocket: ServerSocket? = null
    private var acceptJob: Job? = null
    private var reconnectJob: Job? = null
    private var housekeepingJob: Job? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /** Peers a dial is already in flight for - stops a beacon every 2s piling up attempts. */
    private val connectingTo: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    /** Latest beacon per device id, for addresses and live "seen recently" state - aged out, and bounded. */
    private val beaconBook = BeaconBook()

    /** Names heard this session, by beacon or handshake - memory only, see [rememberProvenName]. */
    private val peerNames = PeerNames()

    /** The remote address of each peer's most recent connection, for the Devices tab. */
    private val connectionAddresses = ConcurrentHashMap<String, String>()

    /** The connection a pairing prompt is about, and the prompt - always changed together, under [pairingLock]. */
    private var pendingPairingConnection: PeerConnection? = null
    private val pairingLock = Any()

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

    /** Numbers the log lines (declared up here so it exists before anything can log); log() runs on network threads too. */
    private val logSequence = java.util.concurrent.atomic.AtomicLong()

    private val _pairingOpen = MutableStateFlow(false)
    val pairingOpen: StateFlow<Boolean> = _pairingOpen.asStateFlow()

    private val _pairingRequest = MutableStateFlow<PairingRequest?>(null)
    val pairingRequest: StateFlow<PairingRequest?> = _pairingRequest.asStateFlow()

    private val _hasPassphrase = MutableStateFlow(false)
    val hasPassphrase: StateFlow<Boolean> = _hasPassphrase.asStateFlow()

    /** True while a Set or Change is still deriving its key - Change and Clear wait for it. */
    private val _passphraseBusy = MutableStateFlow(false)
    val passphraseBusy: StateFlow<Boolean> = _passphraseBusy.asStateFlow()

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

    private val _serverFault = MutableStateFlow<String?>(null)

    /**
     * Why this device can't take connections - or can't start at all: the TCP
     * port is held by something else, the listener keeps failing, the
     * identity key can't be opened. A sentence for the user, or null while
     * all is well. Set while the problem lasts, and cleared when the engine has
     * recovered (it keeps retrying in the background), like the Windows
     * engine's `Faulted`. Nothing shows it yet.
     */
    val serverFault: StateFlow<String?> = _serverFault.asStateFlow()

    private val faultLock = Any()
    private val faults = LinkedHashMap<String, String>()

    /**
     * Written on an IO thread whenever the passcode is set, changed or
     * cleared, and read by the beacon loop on another - volatile so the very
     * next beacon carries the new proof (or none) instead of a stale one.
     */
    @Volatile
    private var cachedProof: String? = null
    private val passphraseStateLock = Any()

    /**
     * Bumped by every Set, Change and Clear, under [passphraseStateLock]. A
     * Set stores its key only if nothing bumped it while the key was being
     * derived - otherwise a Clear tapped mid-derivation would be silently
     * undone the moment the older Set finished.
     */
    private var passphraseGeneration = 0L
    private var derivationsInFlight = 0
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

    /** One capture at a time: the on-open one and a tap on the paste button can overlap, and would both import a copied file. */
    private val captureLock = Mutex()

    private val itemsLock = Any()
    private val devicesLock = Any()

    // ---- lifecycle --------------------------------------------------------

    @Synchronized
    fun start() {
        if (started) return
        started = true

        syncManager.onConnectionsChanged = { count ->
            _connectedCount.value = count
            refreshDevices()
        }
        syncManager.onLog = { message -> log(message) }
        syncManager.onEntryApplied = { entry -> onEntryReceived(entry) }
        syncManager.onHistoryChanged = { refreshItems() }
        syncManager.onFileStored = { refreshItems() }
        syncManager.onSessionProven = { conn -> rememberProvenName(conn) }
        syncManager.onConnectionClosed = { conn -> forgetUnprovenName(conn) }
        historyStore.onProblem = { message -> log(message) }
        passphraseKeyStore.onLog = { message -> log(message) }

        scope.launch { boot() }
    }

    /**
     * The start-up sequence. Each step stands alone: one that fails is logged
     * and the rest still run, so a Keystore hiccup in one place doesn't leave
     * the app listening for nobody, or never listening at all.
     */
    private suspend fun boot() {
        if (!openIdentity()) return
        // After the id - a capture waits for that (see readyOwnId), so
        // this mustn't hold it up - but before the TCP server starts and
        // before the first refreshItems, so a 0-byte file's blob is there
        // for it. A dial onForeground makes meanwhile is safe: the sweep
        // spares every file this process has touched.
        step("tidying stored files") { tidyFileStore() }
        step("reading settings") {
            loadTailscaleIp()
            _deviceNameOverride.value = deviceSettings.deviceNameOverride
            _defaultDeviceName.value = deviceSettings.systemDeviceName()
        }
        step("reading the passcode") { refreshPassphraseState() }
        step("loading the history") {
            refreshItems()
            refreshDevices()
        }

        startTcpServer()
        step("starting discovery") { restartDiscovery() }

        // The interval timer doesn't fire immediately, and this call has to
        // run AFTER ownDeviceId is set: every tie-breaker below compares
        // against it, and running with it still empty makes every peer's
        // key read as ">= ours" and get skipped - a false "let them dial
        // us" decision, not a real one.
        step("reconnecting") { reconnectOffLanPeers() }
        reconnectJob = scope.launch {
            while (isActive) {
                delay(RECONNECT_INTERVAL_MS)
                // Per pass: one throw must not end reconnecting for the session.
                step("reconnecting") { reconnectOffLanPeers() }
            }
        }
        housekeepingJob = scope.launch {
            while (isActive) {
                delay(HOUSEKEEPING_INTERVAL_MS)
                step("housekeeping") {
                    pruneBeacons()
                    // Always: a trusted device that went quiet stops being "pairing" and
                    // "here" without any event to say so. The state flow drops a list
                    // that came out equal, so this costs nothing when nothing changed.
                    refreshDevices()
                    syncManager.tidyTransfers()
                }
            }
        }
    }

    /**
     * Opens this device's identity key - and keeps trying, with growing
     * pauses, if the Keystore won't (it can fail transiently, e.g. while the
     * device is still unlocking). Nothing works without an id, so the
     * failure is shown as [serverFault] meanwhile. False only if cancelled.
     */
    private suspend fun openIdentity(): Boolean {
        var pause = IDENTITY_RETRY_MIN_MS
        while (currentCoroutineContext().isActive) {
            try {
                val id = withContext(Dispatchers.IO) {
                    identity.ensureKey()
                    identity.publicKeyBase64()
                }
                _ownDeviceId.value = id
                setFault(FAULT_IDENTITY, null)
                return true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                log("couldn't open this device's key: ${describeError(e)} - retrying")
                setFault(FAULT_IDENTITY, "This device's security key can't be opened (${describeError(e)}). Retrying.")
                delay(pause)
                pause = (pause * 2).coerceAtMost(IDENTITY_RETRY_MAX_MS)
            }
        }
        return false
    }

    /** [block], with whatever it throws logged instead of thrown - see [boot]. */
    private suspend fun step(what: String, block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            log("$what failed: ${describeError(e)}")
        }
    }

    private fun setFault(source: String, message: String?) {
        synchronized(faultLock) {
            if (message == null) faults.remove(source) else faults[source] = message
            _serverFault.value = faults.values.firstOrNull()
        }
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
        // The only automatic capture Android permits: the clipboard is
        // readable exactly while this app has focus. Silent when there is
        // nothing new - captureAndBroadcast's echo check already
        // suppresses whatever we last applied ourselves. First, and on its
        // own: it used to wait behind the reconnects below, each stored
        // peer that was away costing a 3 s connect timeout, so with a few
        // of them the capture ran seconds after the app came up - when the
        // user may already have left it, and the clipboard is unreadable.
        if (deviceSettings.autoCapture) captureAndBroadcast(quiet = true)
        scope.launch {
            // The phone may have been renamed in system settings while away.
            // With no override set, that new name is ours from the next beacon.
            step("reading the device name") { _defaultDeviceName.value = deviceSettings.systemDeviceName() }
            step("restarting discovery") { restartDiscovery() }
            step("reconnecting") { reconnectOffLanPeers() }
        }
    }

    /**
     * Deletes the stored files no item refers to any more - see
     * [HistoryStore.tidyBlobs]. Never stops the start: at worst they wait for
     * the next one.
     */
    private suspend fun tidyFileStore() = withContext(Dispatchers.IO) {
        try {
            val swept = historyStore.tidyBlobs()
            if (swept > 0) log("deleted $swept file(s) no item refers to")
        } catch (e: Exception) {
            log("couldn't tidy stored files: ${e.message}")
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

        // Held while discovery runs, and not a moment longer than it can:
        // without it the radio drops multicast packets to save power.
        acquireMulticastLock()
        if (startDiscovery(id)) return@withLock
        // A failed bind is the one error that must never be swallowed: it
        // means no peer is ever discovered for the rest of the session,
        // which presents as "sync just doesn't work" with nothing in the
        // log to explain it. Retry once, then report.
        log("discovery failed to start - retrying")
        delay(1000)
        if (!startDiscovery(id)) {
            _discoveryRunning.value = false
            releaseMulticastLock()
        }
    }

    private suspend fun startDiscovery(id: String): Boolean = try {
        discovery.start(
            deviceId = id,
            tcpPort = Protocol.TCP_PORT,
            proof = { cachedProof },
            ownAddress = { _tailscaleIp.value.takeIf { it.isNotEmpty() } },
            pairingOpen = { _pairingOpen.value },
            ownName = ::ownName,
        )
        _discoveryRunning.value = true
        true
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        log("discovery couldn't start: ${e.message}")
        false
    }

    private fun onBeacon(beacon: Discovery.Beacon) {
        if (beacon.deviceId == _ownDeviceId.value) return // our own broadcast, looped back
        val trusted = trustStore.isTrusted(beacon.deviceId)
        // Anyone on the network can make up device ids: the book is bounded,
        // and past that a stranger's beacon is simply not kept.
        val recorded = beaconBook.record(beacon, ::isProtected)
        if (recorded == BeaconBook.Recorded.Rejected) return
        // Memory only, trusted or not: a beacon is unauthenticated, so its
        // name must never be written to the trust store.
        peerNames.heardInBeacon(beacon.deviceId, beacon.name)
        // Only when something the list shows is new: this runs every 2 s per
        // peer, and a flood of forged beacons must not rebuild the list per packet.
        if (recorded == BeaconBook.Recorded.Changed) refreshDevices()

        // Nothing to launch for a beacon that asks nothing of us.
        val wantsTrust = beacon.proof != null && !trusted
        val wantsDial = (trusted && !syncManager.isConnected(beacon.deviceId)) ||
            (_pairingOpen.value && beacon.pairing)
        if (!wantsTrust && !wantsDial) return
        scope.launch {
            // Each on its own: a Keystore failure checking a passcode proof is no
            // reason not to connect to a device that is already trusted.
            step("checking a beacon's passcode proof") { maybeAutoTrustViaPassphrase(beacon) }
            step("connecting to a device") { maybeAutoConnect(beacon) }
            step("connecting to pair") { maybeConnectForPairing(beacon) }
        }
    }

    /** Trusted or connected: kept in the beacon book however quiet it goes. */
    private fun isProtected(deviceId: String): Boolean =
        trustStore.isTrusted(deviceId) || syncManager.isConnected(deviceId)

    /** Forgets the discovered-only devices that went quiet. True if the list changed. */
    private fun pruneBeacons(): Boolean {
        val gone = beaconBook.prune(::isProtected)
        gone.forEach(peerNames::forgetBeacon)
        return gone.isNotEmpty()
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
        log("auto-trusting ${shortIdOf(beacon.deviceId)} (shared passcode)")
        // No name - the proof vouches for the device id, not for whatever
        // label rode along with it. The connection that follows stores its
        // handshake's name once it proves its session (rememberProvenName).
        trustStore.trust(beacon.deviceId, beacon.address)
        refreshDevices()
    }

    /** The best name we have for a peer, from its trust record or from this session. */
    private fun knownNameOf(deviceId: String): String? =
        peerNames.display(deviceId, trustStore.all().firstOrNull { it.publicKey == deviceId }?.name)

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
     * Only the LARGER-public-key side dials, so two devices that hear each
     * other don't open two connections at once: this is true - don't dial,
     * wait to be dialled - for a peer whose key is larger than or equal to
     * ours.
     *
     * Kotlin's String.compareTo is ordinal over UTF-16 code units, matching
     * the HarmonyOS side's JS comparison and the Windows daemon's
     * string.CompareOrdinal (which dials when the OTHER key is smaller, that
     * is when its own is larger) exactly. Keep it ordinal: the daemon used to
     * use culture-sensitive String.CompareTo, which orders some key pairs the
     * other way around (ICU sorts 'k' before 'Q'), and against it either both
     * sides dialled or neither did.
     */
    private fun losesTieBreaker(peerDeviceId: String): Boolean =
        peerDeviceId >= _ownDeviceId.value

    // ---- TCP --------------------------------------------------------------

    private fun startTcpServer() {
        acceptJob?.cancel()
        acceptJob = scope.launch(Dispatchers.IO) { serveTcp() }
    }

    /**
     * Keeps a listener bound for as long as the engine runs. A port that is
     * taken, or a listener that dies, is not the end: it is shown as
     * [serverFault] and bound again after a growing pause - before, the one
     * failed bind was logged once and the app sat there not accepting a
     * connection, looking healthy.
     */
    private suspend fun serveTcp() {
        var pause = BIND_RETRY_MIN_MS
        while (currentCoroutineContext().isActive) {
            val server = try {
                bindServer()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                log("TCP server can't start: ${describeError(e)} - retrying in ${pause / 1000}s")
                setFault(
                    FAULT_LISTENER,
                    "Port ${Protocol.TCP_PORT} isn't available (${e.message ?: e.javaClass.simpleName}), " +
                        "so other devices can't connect to this one. Retrying.",
                )
                delay(pause)
                pause = (pause * 2).coerceAtMost(BIND_RETRY_MAX_MS)
                continue
            }
            serverSocket = server
            pause = BIND_RETRY_MIN_MS
            setFault(FAULT_LISTENER, null)
            acceptLoop(server)
            // Only here when the listener closed or keeps failing: bind afresh.
            runCatching { server.close() }
            serverSocket = null
            setFault(FAULT_LISTENER, "The listener stopped, so other devices can't connect to this one. Restarting.")
            delay(BIND_RETRY_MIN_MS)
        }
    }

    private fun bindServer(): ServerSocket {
        val server = ServerSocket()
        try {
            server.reuseAddress = true
            server.bind(InetSocketAddress(Protocol.TCP_PORT))
        } catch (e: Throwable) {
            runCatching { server.close() } // an unbound socket still holds a file descriptor
            throw e
        }
        return server
    }

    /** Accepts until the socket closes, or keeps failing - and never faster than errors can be waited out. */
    private suspend fun acceptLoop(server: ServerSocket) {
        var failures = 0
        while (currentCoroutineContext().isActive) {
            val socket = try {
                server.accept()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (server.isClosed) return
                failures++
                if (failures >= MAX_ACCEPT_FAILURES) {
                    log("TCP accept keeps failing (${describeError(e)}) - restarting the listener")
                    return
                }
                // E.g. out of file descriptors: a persistent error, not a
                // moment to spin on.
                delay((ACCEPT_ERROR_PAUSE_MS * failures).coerceAtMost(ACCEPT_ERROR_PAUSE_MAX_MS))
                continue
            }
            failures = 0
            admit(socket)
        }
    }

    private val dropLock = Any()
    private var droppedConnections = 0
    private var lastDropLogAt = 0L

    /**
     * A connection from nobody we know yet: it gets a thread, an EC key pair
     * and a Keystore signature before the handshake says who it is, so only
     * a few at a time, and not many from one address. The rest are closed
     * unread - an extra one is a peer that will redial, or a flood.
     */
    private fun admit(socket: Socket) {
        val source = socket.inetAddress?.hostAddress.orEmpty()
        if (!handshakeGate.tryEnter(source)) {
            closeQuietly(socket)
            noteTurnedAway()
            return
        }
        scope.launch(Dispatchers.IO) {
            try {
                acceptConnection(socket)
            } catch (e: CancellationException) {
                closeQuietly(socket)
                throw e
            } catch (e: Throwable) {
                // One connection's failure is that connection's.
                closeQuietly(socket)
                log("an incoming connection failed: ${describeError(e)}")
            } finally {
                handshakeGate.leave()
            }
        }
    }

    /** One line per half minute, not one per connection: a flood must not flood the log too. */
    private fun noteTurnedAway() {
        synchronized(dropLock) {
            droppedConnections++
            val now = System.currentTimeMillis()
            if (now - lastDropLogAt >= DROP_LOG_INTERVAL_MS) {
                log("turned away $droppedConnections connection(s): too many at once")
                droppedConnections = 0
                lastDropLogAt = now
            }
        }
    }

    private fun closeQuietly(socket: Socket) {
        try {
            socket.close()
        } catch (e: Exception) {
            // already closed - fine
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

    /**
     * Returns whether a connection was established - not whether pairing
     * succeeded. Runs to the end even if the caller is cancelled meanwhile
     * (its Activity recreated during pairing, say): the connect and the
     * handshake block in socket calls a cancellation can't interrupt, and a
     * connection finished after its caller was cancelled would be dropped
     * with its socket still open.
     */
    private suspend fun connectToAddress(address: String, port: Int): Boolean =
        withContext(Dispatchers.IO + NonCancellable) {
            val socket = Socket()
            try {
                // An explicit short timeout matters on targetSdk 37: when
                // ACCESS_LOCAL_NETWORK is denied, a LAN connect doesn't fail,
                // it HANGS. The default would park this coroutine for minutes.
                socket.connect(InetSocketAddress(address, port), CONNECT_TIMEOUT_MS)
            } catch (e: Throwable) {
                closeQuietly(socket)
                return@withContext false
            }
            val conn = try {
                PeerConnection.create(
                    socket = socket,
                    identity = identity,
                    trustStore = trustStore,
                    passphraseKeyStore = passphraseKeyStore,
                    pairingModeOpen = _pairingOpen.value,
                    ownName = ownName(),
                )
            } catch (e: Throwable) {
                closeQuietly(socket)
                null
            } ?: return@withContext false
            handleNewConnection(conn, address)
            true
        }

    /**
     * The single funnel for every freshly created connection, whichever of
     * the three paths made it (incoming TCP, beacon dial, manual address).
     * Whatever goes wrong inside ends that connection - closed, not leaked.
     */
    private fun handleNewConnection(conn: PeerConnection, address: String?) {
        try {
            setUpConnection(conn, address)
        } catch (e: Throwable) {
            conn.close("couldn't be set up")
            forgetUnprovenName(conn)
            log("couldn't set up a connection: ${describeError(e)}")
        }
    }

    private fun setUpConnection(conn: PeerConnection, address: String?) {
        // Shown right away, but stored only once proven - see rememberProvenName.
        peerNames.heardInHandshake(conn.peerDeviceId, conn.peerName)
        if (!conn.wasAlreadyTrusted) {
            // Checked and set together: two untrusted connections arriving at
            // once could both pass a bare check, and the second would
            // replace - and orphan, socket open - the first.
            val awaitingDecision = synchronized(pairingLock) {
                if (_pairingRequest.value != null) {
                    false
                } else {
                    pendingPairingConnection = conn
                    _pairingRequest.value = PairingRequest(
                        conn.peerDeviceId,
                        address,
                        // Handshake name first; a beacon's only for display. The
                        // prompt shows the id and address beside it either way.
                        peerNames.display(conn.peerDeviceId, null),
                    )
                    true
                }
            }
            if (!awaitingDecision) {
                // Already prompting for a different candidate. Don't juggle
                // two - whoever came second just doesn't pair this round.
                conn.close("another pairing request is open")
                forgetUnprovenName(conn)
            }
            return
        }

        // Trust first when this very handshake's passcode proof is what
        // established it: a link is only ever served while its peer is in the
        // trust store (see SyncManager), and registering first would leave a
        // moment in which it isn't. A failure to write it must not stop the
        // link being registered, though - that one would just be refused.
        if (conn.newlyTrustedViaPassphrase) {
            try {
                trustStore.trust(conn.peerDeviceId, address)
            } catch (e: Exception) {
                log("couldn't store the trust record: ${e.message}")
            }
        }
        // Registered before the log line and the rest below: those are
        // conveniences; starting the read loop is not. In the other order,
        // one throw leaves the link unregistered and unlistened while the
        // peer redials every two seconds forever. It also closes the loser
        // when a second connection to the same peer got here first.
        syncManager.registerConnection(conn)

        (conn.remoteAddress ?: address)?.let { connectionAddresses[conn.peerDeviceId] = it }
        if (conn.newlyTrustedViaPassphrase) {
            // The read loop is already running, so the session may have been
            // proven before this record existed to take the name.
            if (conn.isSessionProven) rememberProvenName(conn)
            log("auto-paired via passcode: ${shortIdOf(conn.peerDeviceId)}")
        } else {
            // Already trusted, but we may have just learned a real address -
            // back-fill it. This is what repairs a trust record written before
            // the accept path captured addresses at all, which would otherwise
            // be permanently stuck with nothing to dial off-LAN.
            if (address != null) trustStore.trust(conn.peerDeviceId, address)
            log("connected: ${shortIdOf(conn.peerDeviceId)}")
        }
        refreshDevices()
    }

    /**
     * Stores [conn]'s handshake name once its session is proven - its first
     * envelope decrypted - and never before. The handshake signature covers
     * only the ephemeral key, so a recorded handshake of a trusted device
     * replays with any DeviceName, but a replayer never gets this far - not
     * even by echoing our own lines (PeerConnection's EchoGuard). This
     * connection's own name, not PeerNames' latest, which may be from a
     * handshake that proved nothing. It's what picks up a trusted peer that
     * has been renamed since we last heard from it, and fills in the name a
     * new pairing was stored without. Never adds a device.
     */
    private fun rememberProvenName(conn: PeerLink) {
        if (trustStore.rememberName(conn.peerDeviceId, conn.peerName)) refreshDevices()
    }

    /**
     * The other half of [rememberProvenName]: a connection that ends - or is
     * turned away - without proving its session takes its handshake's name
     * off the screen with it. Otherwise a replayed handshake would leave its
     * name on a device that has none stored, ahead of anything its beacons say.
     */
    private fun forgetUnprovenName(conn: PeerLink) {
        if (conn.isSessionProven) return
        if (peerNames.forgetHandshake(conn.peerDeviceId, conn.peerName)) refreshDevices()
    }

    fun acceptPairing() {
        val (conn, request) = synchronized(pairingLock) {
            val pending = pendingPairingConnection ?: return // nothing waiting: nothing to accept
            val prompt = _pairingRequest.value
            pendingPairingConnection = null
            _pairingRequest.value = null
            pending to prompt
        }
        // No name yet, whatever the prompt showed: this connection's is
        // stored once its session is proven (rememberProvenName).
        trustStore.trust(conn.peerDeviceId, request?.address)
        conn.remoteAddress?.let { connectionAddresses[conn.peerDeviceId] = it }
        log("paired: ${shortIdOf(conn.peerDeviceId)}")
        syncManager.registerConnection(conn)
        refreshDevices()
        showToast("Paired.")
    }

    /** Safe to call with nothing pending - it then does nothing, as the pairing screen closing does. */
    fun rejectPairing() {
        val conn = synchronized(pairingLock) {
            val pending = pendingPairingConnection
            pendingPairingConnection = null
            _pairingRequest.value = null
            pending
        }
        if (conn != null) {
            conn.close("pairing declined")
            forgetUnprovenName(conn) // never listened, so never proven
        }
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
        beaconBook.get(deviceId)?.senderIp?.takeIf { it.isNotEmpty() }?.let(candidates::add)
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
     *
     * Safe against the caller going away mid-way (see [connectToAddress]).
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
                // The id beside the name: a code's name is self-claimed.
                val who = info.name?.let { "$it (${shortIdOf(info.publicKey)})" } ?: shortIdOf(info.publicKey)
                return "$who has no address in its code. " +
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

    /** False when nothing was stored: a blank passcode, or a Clear or newer Set overtook it. */
    suspend fun setPassphrase(passphrase: String): Boolean = withContext(Dispatchers.Default) {
        if (passphrase.isBlank()) return@withContext false
        val generation = synchronized(passphraseStateLock) {
            derivationsInFlight++
            _passphraseBusy.value = true
            ++passphraseGeneration
        }
        try {
            // 210,000 HMAC rounds - never on the main thread. Trimmed like
            // HarmonyOS and Windows do, so a stray space on one device can't
            // silently derive a different key.
            val key = passphraseKeyStore.deriveKey(passphrase.trim())
            // Saved and refreshed together even when the caller is cancelled
            // meanwhile - its activity recreated by a rotation mid-derivation.
            // Otherwise the key would be stored while the Me screen and the
            // beacons' proof still showed the old passcode, or none.
            withContext(NonCancellable) {
                val stored = synchronized(passphraseStateLock) {
                    (generation == passphraseGeneration).also { current ->
                        if (current) passphraseKeyStore.saveKey(key)
                    }
                }
                if (stored) refreshPassphraseState()
                stored
            }
        } finally {
            synchronized(passphraseStateLock) {
                derivationsInFlight--
                _passphraseBusy.value = derivationsInFlight > 0
            }
        }
    }

    fun clearPassphrase() {
        synchronized(passphraseStateLock) {
            passphraseGeneration++ // any Set still deriving is now stale
            passphraseKeyStore.clearPassphrase()
        }
        scope.launch { refreshPassphraseState() }
    }

    private suspend fun refreshPassphraseState() = withContext(Dispatchers.IO) {
        // One at a time, each reading the store afresh: otherwise the refresh
        // after a Set, still holding the key it read, could finish after the
        // Clear's and put the old proof back into the beacons.
        synchronized(passphraseStateLock) {
            val has = passphraseKeyStore.hasPassphrase()
            _hasPassphrase.value = has
            val id = _ownDeviceId.value
            cachedProof = if (has && id.isNotEmpty()) {
                passphraseKeyStore.key()?.let { passphraseKeyStore.computeProof(it, id) }
            } else {
                null
            }
        }
    }

    /**
     * The saved Tailscale address, if it is still a usable one: an IPv4
     * address. An earlier build took any text, and anything with a ':' in it
     * would shift every field after it in this device's beacon.
     */
    private fun loadTailscaleIp() {
        val stored = deviceSettings.tailscaleIp
        val valid = Ipv4.normalize(stored)
        if (stored.isNotEmpty() && valid == null) {
            log("the saved Tailscale address isn't an IPv4 address - not using it")
            deviceSettings.tailscaleIp = ""
        }
        _tailscaleIp.value = valid.orEmpty()
    }

    /**
     * Saves the address this device advertises for off-LAN reconnects. It goes
     * out in every beacon and in the pairing code, so only an IPv4 address is
     * accepted (IPv6 would need an encoding the other platforms don't have);
     * anything else is refused and the previous value kept. Blank clears it.
     */
    fun saveTailscaleIp(ip: String) {
        val trimmed = ip.trim()
        if (trimmed.isEmpty()) {
            deviceSettings.tailscaleIp = ""
            _tailscaleIp.value = ""
            showToast("Tailscale IP cleared.")
            return
        }
        val valid = Ipv4.normalize(trimmed)
        if (valid == null) {
            log("Tailscale address not saved: not an IPv4 address")
            showToast("That isn't an IPv4 address. Enter it like 100.64.0.1.")
            return
        }
        deviceSettings.tailscaleIp = valid
        _tailscaleIp.value = valid
        showToast("Tailscale IP saved.")
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
        val beacon = beaconBook.get(deviceId)
        // Nameless until a connection to it proves its session.
        trustStore.trust(deviceId, beacon?.senderIp)
        refreshDevices()
        scope.launch { beacon?.let { connectToAddress(it.senderIp, it.tcpPort) } }
    }

    fun untrustDevice(deviceId: String) {
        val label = displayNameOf(deviceId, knownNameOf(deviceId)) // before the record goes
        trustStore.untrust(deviceId)
        // And its link with it: a removed device must not keep receiving what
        // is copied here, asking for files, or showing as connected.
        syncManager.close(deviceId, "removed")
        connectionAddresses.remove(deviceId)
        refreshDevices()
        // Explicit confirmation matters: a just-untrusted device that is still
        // beaconing doesn't vanish from the list, it reappears as "discovered"
        // with a Trust button - so without this, Remove looks like it did
        // nothing at all.
        log("untrusted ${shortIdOf(deviceId)}")
        showToast("Removed $label")
    }

    // ---- clipboard --------------------------------------------------------

    /**
     * Reads the system clipboard and syncs it. Only works while the app is in
     * the foreground - that is an Android 10+ platform rule, not a choice
     * here. Never throws: a failure is logged (and toasted, if the user asked).
     */
    fun captureAndBroadcast(quiet: Boolean = false) {
        scope.launch {
            captureLock.withLock {
                try {
                    // On IO: a copied file is streamed into the FileStore right here.
                    when (val capture = withContext(Dispatchers.IO) { clipboard.capture() }) {
                        // `quiet` is for the automatic on-open capture: an unprompted
                        // "nothing to sync" every time the app opens is noise, but the
                        // same message after a deliberate button press is the answer.
                        null -> if (!quiet) showToast("Nothing on the clipboard to sync.")
                        is Capture.Text -> broadcastText(capture.text, quiet)
                        is Capture.Image -> broadcastImage(capture.pngBytes, quiet)
                        is Capture.Payload -> broadcastFile(capture, quiet)
                        is Capture.TooLarge -> if (!quiet) showToast("${capture.fileName} is over 1 GB, too big to sync.")
                        Capture.Ours -> alreadySynced(quiet)
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    // A Keystore that won't sign, a disk that won't write, an
                    // image too big for the heap: this capture's problem only.
                    log("couldn't sync the clipboard: ${describeError(e)}")
                    if (!quiet) showToast("Couldn't sync the clipboard.")
                }
            }
        }
    }

    /**
     * Syncs what another app shared into ClipLink, or a file picked on the
     * Synced tab, exactly like something copied here: each file becomes a
     * "file" entry whose bytes wait in the FileStore for peers to ask for,
     * text a "text" entry. Nothing goes on this phone's own clipboard, and an
     * image stays the file it was - receivers preview image files anyway -
     * rather than being re-encoded as an inline PNG.
     *
     * [text] only counts when there are no [uris]: next to files it is a
     * caption, not the thing being shared.
     *
     * Runs on the engine's scope rather than the caller's, so a rotation or a
     * Back press can't abandon a copy halfway through. The caller should
     * still stay alive until [onDone] (called on the main thread): the read
     * grant for a shared URI only lasts as long as it does, and although
     * every URI is opened up front (see [ShareIntake.copyAll]), a visible
     * activity is also what keeps the process running a long copy.
     */
    fun shareIn(text: String?, uris: List<Uri>, onDone: (ShareOutcome) -> Unit): Job = scope.launch {
        // Always answered: the share screen stays up, invisible, until it is.
        val outcome = try {
            share(text, uris)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            log("share failed: ${describeError(e)}")
            ShareOutcome(failed = true)
        }
        withContext(Dispatchers.Main) { onDone(outcome) }
    }

    private suspend fun share(text: String?, uris: List<Uri>): ShareOutcome {
        val taken = uris.take(ShareIntake.MAX_FILES)
        val copies = withContext(Dispatchers.IO) { shareIntake.copyAll(taken) }
        val stored = copies.filterIsInstance<ShareIntake.Copy.Stored>()
        val sharedText = text?.takeIf { uris.isEmpty() && it.isNotEmpty() }
        val outcome = ShareOutcome(
            files = stored.map { it.name },
            text = sharedText != null,
            unreadable = copies.count { it is ShareIntake.Copy.Unreadable },
            tooLarge = copies.filterIsInstance<ShareIntake.Copy.TooLarge>().map { it.name },
            skipped = uris.size - taken.size,
        )
        if (stored.isEmpty() && sharedText == null) return outcome

        // A cold start via the share sheet gets here while start() may still
        // be creating the identity key - see readyOwnId.
        val ownId = readyOwnId()
        if (ownId == null) {
            stored.forEach { historyStore.releaseBlobIfUnused(it.hash) }
            return ShareOutcome(failed = true)
        }
        val entries = mutableListOf<ClipboardEntry>()
        try {
            if (sharedText != null) entries += signDistinct(sharedText, ClipboardEntry.TYPE_TEXT, ownId, null)
            for (file in stored) {
                val payload = FilePayload(file.name, file.hash, file.size).toJson()
                entries += signDistinct(payload, ClipboardEntry.TYPE_FILE, ownId, entries.lastOrNull())
            }
        } catch (e: Exception) {
            // The keystore refused to sign: no entry will ever point at these
            // copies, so nothing else would ever delete them.
            stored.forEach { historyStore.releaseBlobIfUnused(it.hash) }
            throw e
        }
        // Deliberately not noted as lastKnownHash: that tracks the clipboard,
        // and a share never touches it.
        syncManager.broadcastEntries(entries)
        stored.forEach { syncManager.tryFulfillPendingEntry(it.hash) }
        refreshItems()
        log("shared ${entries.size} item(s) to ${syncManager.connectionCount} peer(s)")
        return outcome.copy(connected = syncManager.connectionCount)
    }

    /**
     * Signs, then signs again in the rare case the clock hasn't moved since
     * [previous]: two entries of one share must never share a timestamp.
     */
    private fun signDistinct(content: String, type: String, ownId: String, previous: ClipboardEntry?): ClipboardEntry {
        var entry = Signing.sign(identity, content, type, ownId)
        while (previous != null && entry.timestamp == previous.timestamp) {
            entry = Signing.sign(identity, content, type, ownId)
        }
        return entry
    }

    /**
     * This device's id, once start() has it - or null if it never comes. A
     * paste, the on-open capture or a share can all come first on a cold
     * start, and an entry signed with an empty id is shown as another
     * device's and dropped by every peer.
     */
    private suspend fun readyOwnId(): String? =
        withTimeoutOrNull(READY_TIMEOUT_MS) { _ownDeviceId.first { it.isNotEmpty() } }

    /** A capture [readyOwnId] gave up on - before its hash was noted, so trying again works. */
    private fun notReady(quiet: Boolean) {
        if (!quiet) showToast("ClipLink is still starting - try again in a moment.")
    }

    private suspend fun broadcastText(text: String, quiet: Boolean = false) {
        val hash = FileStore.hashOf(text.toByteArray(Charsets.UTF_8))
        if (hash == clipboard.lastKnownHash) return alreadySynced(quiet)
        val ownId = readyOwnId() ?: return notReady(quiet)
        // Signed BEFORE the hash is noted: a Keystore that refuses must leave
        // the clipboard unsynced, not marked as synced and never retried.
        val entry = Signing.sign(identity, text, ClipboardEntry.TYPE_TEXT, ownId)
        clipboard.noteLocalHash(hash)
        broadcast(entry)
        if (!quiet) showToast("Synced text.")
    }

    private suspend fun broadcastImage(pngBytes: ByteArray, quiet: Boolean = false) {
        val hash = FileStore.hashOf(pngBytes)
        if (hash == clipboard.lastKnownHash) return alreadySynced(quiet)
        val ownId = readyOwnId() ?: return notReady(quiet)
        // Images travel inline as base64 in the entry itself, matching the
        // other two platforms - they are NOT sent through the file-chunk path.
        val content = B64.encode(pngBytes)
        val entry = Signing.sign(identity, content, ClipboardEntry.TYPE_IMAGE, ownId)
        clipboard.noteLocalHash(hash)
        broadcast(entry)
        if (!quiet) showToast("Synced image.")
    }

    // A copy that goes no further here is left in the store for the next
    // start's sweep (FileStore.sweepUnreferenced) rather than deleted now: a
    // share of the same file may be about to record an entry for it.
    private suspend fun broadcastFile(file: Capture.Payload, quiet: Boolean = false) {
        val hash = file.hash
        if (hash == clipboard.lastKnownHash) return alreadySynced(quiet)
        val ownId = readyOwnId() ?: return notReady(quiet)
        // The bytes are in the store already (see ClipboardBridge.capture),
        // BEFORE the entry goes out: the receiver broadcasts a file_request
        // the instant it sees an entry it has no bytes for.
        val payload = FilePayload(file.fileName, hash, file.size).toJson()
        val entry = Signing.sign(identity, payload, ClipboardEntry.TYPE_FILE, ownId)
        clipboard.noteLocalHash(hash)
        broadcast(entry)
        syncManager.tryFulfillPendingEntry(hash)
        if (!quiet) showToast("Synced ${file.fileName}.")
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
        log("received ${entry.type} from ${shortIdOf(entry.deviceId)}")
        if (deviceSettings.autoApply) {
            if (clipboard.apply(entry)) showToast("Copied ${entry.type} from a paired device.")
        }
    }

    fun applyToClipboard(item: SyncedItem): Boolean = clipboard.apply(item.entry)

    /**
     * Deletes an item from this phone only, and for good - a peer's next
     * history_batch won't bring it back. The clipboard and the peers are left
     * exactly as they were.
     */
    fun deleteItem(item: SyncedItem) {
        // Off the caller's thread - the UI's - which a disk write doesn't belong on.
        scope.launch(Dispatchers.IO) {
            step("deleting an item") {
                historyStore.delete(item.entry)
                refreshItems()
            }
        }
    }

    /** [deleteItem] for everything - the items stay deleted the same way. */
    fun clearHistory() {
        scope.launch(Dispatchers.IO) {
            step("clearing the history") {
                historyStore.clear()
                refreshItems()
                showToast("History cleared.")
            }
        }
    }

    // ---- derived state ----------------------------------------------------

    /**
     * Rebuilds [items] from the history. Serialised: it is called from the
     * network threads, the UI's and the engine's own, and two rebuilds
     * overlapping could publish the older snapshot last.
     */
    private fun refreshItems() {
        synchronized(itemsLock) {
            val own = _ownDeviceId.value
            // .NET round-trip format sorts chronologically once canonicalised.
            val entries = historyStore.all().sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
            val keys = uniqueKeysFor(entries)
            _items.value = entries.mapIndexed { index, entry ->
                val file = if (entry.type == ClipboardEntry.TYPE_FILE) {
                    FilePayload.parse(entry.content)?.let { fileStore.path(it.fileHash) }?.takeIf { it.exists() }
                } else {
                    null
                }
                SyncedItem(
                    entry = entry,
                    isOwn = entry.deviceId == own,
                    fileAvailable = entry.type != ClipboardEntry.TYPE_FILE || file != null,
                    file = file,
                    uniqueKey = keys[index],
                )
            }
        }
    }

    /** Rebuilds [devices] - serialised like [refreshItems]. */
    fun refreshDevices() {
        synchronized(devicesLock) {
            val connected = syncManager.connectedDeviceIds()
            val trusted = trustStore.all()
            val ids = LinkedHashSet<String>()
            trusted.forEach { ids.add(it.publicKey) }
            beaconBook.ids().forEach(ids::add)

            _devices.value = ids.map { id ->
                val beacon = beaconBook.get(id)
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
                    // A trusted device's stored name wins; a beacon name only
                    // fills in while there is none.
                    name = peerNames.display(id, trustedEntry?.name),
                    trusted = trustedEntry != null,
                    connected = connected.contains(id),
                    addresses = addresses.toList(),
                    // A pairing screen that was open when its device was last
                    // heard, long ago, is not open now.
                    pairing = beacon?.pairing == true && beaconBook.isRecent(id),
                    lastSeenAtMs = beaconBook.lastSeenAt(id),
                )
            }.sortedWith(DeviceRow.STABLE_ORDER)
        }
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
        val line = LogLine(logSequence.incrementAndGet(), LocalTime.now().format(LOG_TIME_FORMAT), message)
        _log.update { existing -> (listOf(line) + existing).take(MAX_LOG_LINES) }
    }

    private companion object {
        const val TAG = "ClipLinkNet"
        const val MAX_LOG_LINES = 60
        const val RECONNECT_INTERVAL_MS = 30_000L
        const val HOUSEKEEPING_INTERVAL_MS = 5_000L
        const val CONNECT_TIMEOUT_MS = 3_000
        const val READY_TIMEOUT_MS = 15_000L

        const val IDENTITY_RETRY_MIN_MS = 2_000L
        const val IDENTITY_RETRY_MAX_MS = 30_000L
        const val BIND_RETRY_MIN_MS = 1_000L
        const val BIND_RETRY_MAX_MS = 30_000L
        const val ACCEPT_ERROR_PAUSE_MS = 250L
        const val ACCEPT_ERROR_PAUSE_MAX_MS = 2_000L
        const val MAX_ACCEPT_FAILURES = 20
        const val DROP_LOG_INTERVAL_MS = 30_000L

        const val FAULT_LISTENER = "listener"
        const val FAULT_IDENTITY = "identity"

        val LOG_TIME_FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")
    }
}
