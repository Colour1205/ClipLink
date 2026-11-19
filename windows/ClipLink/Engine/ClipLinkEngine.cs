using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading.Channels;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Engine;

// The whole P2P node - LAN discovery, peer connections, the clipboard
// watcher, history, trust and pairing - as one object the ClipLink app runs
// in-process. (It used to be the ClipboardDaemon console program, driven by
// a separate tray app over a named pipe; the typed methods in
// ClipLinkEngine.Api.cs replace that pipe's string commands, and the events
// below replace the tray's polling.)
//
// Lifecycle: new ClipLinkEngine(), subscribe to the events, Start(label,
// port). Start loads this device's stores from %APPDATA%\ClipboardDaemon
// (files suffixed with the label) and then starts everything, or - if it
// can't listen on the port - reports Faulted (see Retry). Stop() ends it.
//
// Threading: every public method is thread-safe and quick unless it's
// async (those do network or slow crypto work - await them, don't block on
// them from a UI thread). Events are raised one at a time, in order, on a
// background thread - never the caller's, never the UI thread, never while
// the engine holds a lock. A UI must marshal them (WinUI:
// DispatcherQueue.TryEnqueue) and should keep handlers short: a slow handler
// delays later events (not the networking). An exception thrown by a
// handler is logged and otherwise ignored.
public sealed partial class ClipLinkEngine : IDisposable
{
    public const string DefaultLabel = "default";
    public const int DefaultPort = 49000;

    // Something about GetHistory() changed: an entry was added (copied here
    // or received), deleted, cleared or trimmed, or a file's bytes arrived.
    // Bursts (a peer's history batch) are coalesced into one event.
    public event Action? HistoryChanged;

    // GetDevices() changed - a device connected or disconnected, was
    // trusted or removed, appeared on / dropped off the LAN, or changed its
    // name or addresses. Carries the new list (same as
    // GetDevices()). Only raised when the list actually differs.
    public event Action<IReadOnlyList<DeviceListing>>? DevicesChanged;

    // A new device wants to pair: show an Accept/Reject prompt and call
    // AcceptPairing/RejectPairing.
    public event Action<PendingPairing>? PairingRequested;

    // The pending request for this device id was accepted, rejected or
    // abandoned - close its prompt if it's still showing.
    public event Action<string, PairingDecision>? PairingResolved;

    // Status changed (see EngineStatus) - e.g. Faulted because another copy
    // is already listening on the port.
    public event Action<EngineStatus>? StatusChanged;

    // GetTransfers() changed in more than its numbers: a file started
    // arriving, was stored, failed, broke off, or was asked for again. Not
    // raised as its bytes come in: a UI showing progress polls GetTransfers
    // (a few times a second, only while one is Receiving) between these.
    public event Action? TransfersChanged;

    // Bundles the state chunked file transfers need besides the streams
    // being received (those are IncomingFiles'): any entry that arrived (and
    // was verified) before its bytes finished streaming in, waiting to be
    // applied once they do (see PendingApply), and how often each file has
    // been asked for again after a transfer of it failed (see RequestAgain).
    // By hash in either case: the phones send lowercase, this PC uppercase,
    // and a copy here has to find the entry a phone sent.
    private class FileTransferState
    {
        public ConcurrentDictionary<string, PendingApply> PendingEntries = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, int> Retries = new(StringComparer.OrdinalIgnoreCase);
        // Guards against streaming the same file to the same peer twice at
        // once: ClipboardChanged proactively streams a freshly-captured
        // file right after broadcasting its entry, but the receiving side
        // (HandleIncomingFileEntry) also unconditionally broadcasts a
        // file_request the moment it sees an entry it doesn't have bytes
        // for yet, regardless of whether the sender is already streaming.
        // Without this guard that redundant request starts a SECOND
        // concurrent stream over the same connection, and the two chunk
        // sequences interleave on the wire - the actual cause of "file
        // transfer failed hash verification" on the receiving end.
        public ConcurrentDictionary<string, byte> StreamingInFlight = new();
        // What GetTransfers says about a file that isn't arriving right now:
        // just stored, asked for again, or waiting for a device that has it
        // (see TransferPhase), and since when (Environment.TickCount64).
        // Dropped when a stream of it starts, or once it is stored.
        public ConcurrentDictionary<string, (TransferPhase Phase, long Since)> Notes = new(StringComparer.OrdinalIgnoreCase);
    }

    // The latest beacon heard from another device, trusted or not. Memory
    // only: it's what GetDevices shows for a device's LAN address, and the
    // only place a beacon's name is ever kept. Beacons are unauthenticated
    // (anyone on the LAN can send one under any device id), so that name is
    // never written to the trust store - only a pairing payload's is, or a
    // handshake's once its connection proves itself (RememberProvenName) -
    // and it's shown for an untrusted device, or a trusted one with no
    // stored name yet (nor a live connection's). Name keeps the last known
    // one when a later beacon carries none.
    private record SeenPeer(string? Name, string LanAddress, string? AdvertisedAddress, DateTime LastSeenUtc);

    // Set once by Start, before anything can use them.
    private string label = DefaultLabel;
    private int port = DefaultPort;
    private EngineOptions options = new();
    private string ownId = "";
    private DeviceIdentity identity = null!;
    private FileStore fileStore = null!;
    private IncomingFiles incomingFiles = null!;
    // The files being sent to peers that acknowledge chunks, so their acks
    // find them (see FileFlow and StreamFileToPeer).
    private readonly SendWindows sendWindows = new();
    private HistoryAccess historyAccess = null!;
    private TrustStore trustStore = null!;
    private BlockStore blockStore = null!;
    private PassphraseKeyStore passphraseKeyStore = null!;
    private DeviceNameStore deviceName = null!;
    private ClipboardSync clipboardSync = null!;
    private int automaticClipboardSyncGeneration;
    private volatile bool storesLoaded;

    private readonly FileTransferState fileTransferState = new();
    // What version 2 connections have been asked for and not answered, and
    // which keys are being asked where - see SyncRequests. askGate: one
    // connection's asks at a time, so the queue's order is the order they are
    // written in (AskForMissing).
    private readonly SyncRequests syncRequests = new();
    private readonly object askGate = new();
    private readonly PairingState pairingState = new();
    private readonly ConcurrentDictionary<string, PeerConnection> connectionsByDeviceId = new();
    // In-flight dial reservations, keyed by the peer's device id. Unlike
    // connectionsByDeviceId (only populated once a handshake fully
    // completes), this covers the gap WHILE a dial is happening -
    // without it, nothing stopped the beacon handler and the off-LAN
    // reconnect loop from both dialing the same peer at once (or the
    // beacon handler dialing it again on the next beacon before the
    // previous attempt's handshake finished - easily provoked over a
    // higher-latency link like Tailscale, where a handshake round trip can
    // outlast the ~2s beacon interval). TryAdd/TryRemove are atomic, so
    // this is safe even though it's read from two different async flows.
    // See RegisterConnection's orphan-closing fix for what a resulting
    // duplicate connection actually causes.
    private readonly ConcurrentDictionary<string, byte> connectingTo = new();
    // Latest beacon per other device - see SeenPeer.
    private readonly ConcurrentDictionary<string, SeenPeer> seenPeers = new();
    // Devices whose pairing requests are held back for a while - see RequestQuiet.
    private readonly RequestQuiet requestQuiet = new();
    // Trusted devices that should have dialled this one and have not - see DialFallback.
    private readonly DialFallback dialFallback = new();
    // One GetFileToOpen at a time picks and writes a copy, so two opens of
    // the same entry at once don't both write the same new file.
    private readonly object openCopiesGate = new();

    // Computed once, when discovery starts - Tailscale IPs are stable, and
    // shelling out to the CLI on every 2-second beacon would be wasteful.
    // If Tailscale gets installed while the engine is already running, the
    // beacon picks it up after a restart (the pairing payload looks again
    // every time - see GetPairingPayloadAsync).
    private volatile string? ownTailscaleAddress;

    private readonly object stateGate = new();
    private EngineStatus status = new(EngineState.NotStarted, null);
    private readonly CancellationTokenSource stopping = new();
    private TcpListener? tcpListener;

    // Events go through this queue to one consumer, so they reach the UI in
    // the order they happened, off the networking threads.
    private readonly Channel<Action> events = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });

    // What was copied on this PC is published from here, one copy at a time
    // in the order they were made - not on the clipboard watcher's thread,
    // which raises them: signing a picture, caching a file in FileStore (up
    // to 1 GB, from a USB stick or a share) and adding it to history held
    // that thread, so no peer's item could reach the clipboard meanwhile
    // and nothing copied next was seen.
    private readonly Channel<Action> localCopies = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });

    // Bursts of changes (a whole history batch, a beacon from every device)
    // become one event each this long after the first.
    private static readonly TimeSpan CoalesceDelay = TimeSpan.FromMilliseconds(100);
    private int historyChangePending;
    private int devicesChangePending;
    private readonly object devicesSignatureGate = new();
    private string? lastDevicesSignature;

    public ClipLinkEngine()
    {
        _ = Task.Run(DeliverEvents);
        _ = Task.Run(PublishLocalCopies);
    }

    public EngineStatus Status
    {
        get { lock (stateGate) { return status; } }
    }

    public string Label => label;
    public int Port => port;

    // An odd generation means paused. A toggle invalidates work already
    // queued by the watcher, even if sync resumes before that work runs.
    private int? ActiveClipboardSyncGeneration
    {
        get
        {
            int generation = Volatile.Read(ref automaticClipboardSyncGeneration);
            return (generation & 1) == 0 ? generation : null;
        }
    }

    public bool AutomaticClipboardSyncEnabled => ActiveClipboardSyncGeneration.HasValue;

    public void SetAutomaticClipboardSyncEnabled(bool enabled)
    {
        lock (stateGate)
        {
            if (AutomaticClipboardSyncEnabled == enabled) return;
            if (enabled && storesLoaded && options.WatchClipboard) clipboardSync.SkipCurrentClipboard();
            Interlocked.Increment(ref automaticClipboardSyncGeneration);
        }
    }

    // Loads this device's stores for `label` (the app uses "default" - the
    // data folder's existing files) and starts listening for peers on TCP
    // `port`, LAN discovery, the clipboard watcher and the off-LAN reconnect
    // loop. Returns false - Status Faulted, StatusChanged raised - if it
    // can't listen on the port (another ClipLink, or the old ClipboardDaemon,
    // already running): nothing then runs until Retry() succeeds, but the
    // stores can be used. Does some disk I/O and returns quickly; callable
    // once per engine.
    public bool Start(string label = DefaultLabel, int port = DefaultPort, EngineOptions? options = null)
    {
        lock (stateGate)
        {
            if (status.State != EngineState.NotStarted)
            {
                throw new InvalidOperationException($"The engine was already started (it's {status.State}).");
            }
            this.label = label;
            this.port = port;
            this.options = options ?? new EngineOptions();

            identity = new DeviceIdentity(label);
            fileStore = new FileStore(label);
            incomingFiles = new IncomingFiles(fileStore, FileSizeOf);
            incomingFiles.Completed += OnTransferCompleted;
            incomingFiles.ChunkDone += OnChunkDone;
            historyAccess = new HistoryAccess(label, fileStore, new DeletedEntries(label));
            trustStore = new TrustStore(label);
            blockStore = new BlockStore(label);
            passphraseKeyStore = new PassphraseKeyStore(label);
            deviceName = new DeviceNameStore(label);
            clipboardSync = new ClipboardSync(fileStore, label, () => ActiveClipboardSyncGeneration);
            clipboardSync.ClipboardChanged += (content, generation) =>
                localCopies.Writer.TryWrite(() => OnLocalClipboardChanged(content, generation));
            clipboardSync.FilesCopied += (files, generation) =>
                localCopies.Writer.TryWrite(() => OnLocalFilesCopied(files, generation));
            ownId = identity.GetPublicKey();
            storesLoaded = true;
            Console.WriteLine($"Device ID (public key): {ownId}");
            Console.WriteLine($"Device fingerprint: {DeviceLabel.Fingerprint(ownId)}");
            Console.WriteLine($"Device name: {deviceName.Current}");
            if (trustStore.IsTrusted(ownId))
            {
                // Trusted by an older build (its own beacon, looped back) -
                // nothing trusts this device itself now.
                try
                {
                    trustStore.Untrust(ownId);
                    Console.WriteLine("[engine] this device was in its own trust store - removed");
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    Console.WriteLine($"[engine] couldn't remove this device from its own trust store: {ex.Message}");
                }
            }
            // Copies opened from Synced last time (see GetFileToOpen) - all
            // but the ones the user has edited.
            DeleteOpenCopies(OpenCopiesRoot());

            return TryRun();
        }
    }

    // After a Start that couldn't listen (Faulted): tries the same port
    // again - e.g. once the other program holding it has quit. True once
    // Running.
    public bool Retry()
    {
        lock (stateGate)
        {
            if (status.State != EngineState.Faulted)
            {
                return status.State == EngineState.Running;
            }
            return TryRun();
        }
    }

    // Stops everything: closes every peer connection (peers see this device
    // go at once), stops listening, discovery and the clipboard watcher, and
    // abandons a pending pairing request. Idempotent. The stores stay
    // readable, but nothing runs again - start a new engine for that.
    public void Stop()
    {
        lock (stateGate)
        {
            if (status.State == EngineState.Stopped) return;
            bool wasStarted = status.State != EngineState.NotStarted;
            stopping.Cancel();
            try { tcpListener?.Stop(); } catch (Exception) { }
            if (wasStarted)
            {
                var abandoned = pairingState.TakePending();
                if (abandoned != null)
                {
                    abandoned.Value.conn.Close();
                    RaisePairingResolved(abandoned.Value.conn.PeerDeviceId, PairingDecision.Abandoned);
                }
                clipboardSync.Stop();
                foreach (var conn in connectionsByDeviceId.Values)
                {
                    conn.Close();
                }
            }
            localCopies.Writer.TryComplete();
            // History is written in the background (see HistoryAccess.saveHistory):
            // the last change has to be on disk before the process exits.
            if (storesLoaded) historyAccess.Flush();
            SetStatus(new EngineStatus(EngineState.Stopped, null));
            // Whatever is queued (Stopped included) is still delivered;
            // nothing after it is.
            events.Writer.TryComplete();
        }
        Console.WriteLine("[engine] stopped");
    }

    public void Dispose() => Stop();

    private bool IsRunning
    {
        get { lock (stateGate) { return status.State == EngineState.Running; } }
    }

    // Under stateGate.
    private bool TryRun()
    {
        /* receiving connections */
        // Started first: a failure to bind (the port already taken - e.g.
        // a second copy on the same port) used to throw inside an unobserved
        // task, leaving a daemon that looked fine but could never be
        // dialled; later it stopped the whole process with a clear reason.
        // Now nothing else starts either (a second copy of this device
        // watching the same clipboard would echo everything), and the UI is
        // told why.
        var listener = new TcpListener(options.LoopbackOnly ? IPAddress.Loopback : IPAddress.Any, port);
        try
        {
            listener.Start();
        }
        catch (SocketException ex)
        {
            Console.WriteLine($"[listen] FATAL: can't listen on TCP port {port} ({ex.SocketErrorCode}: {ex.Message}). Is another ClipLink or ClipboardDaemon already running?");
            SetStatus(new EngineStatus(EngineState.Faulted,
                $"Can't listen for other devices on port {port} ({ex.SocketErrorCode}). Is another copy of ClipLink (or the old ClipboardDaemon) already running?"));
            return false;
        }
        tcpListener = listener;
        SetStatus(new EngineStatus(EngineState.Running, null));

        // Only now that this copy has the port - a copy already running for
        // the same label (which Faulted this one) could be mid-transfer in
        // the same FileStore - and before anything below starts a transfer.
        TidyFileStore();

        CancellationToken token = stopping.Token;
        StartClipboardWatcher();
        _ = Task.Run(() => AcceptLoop(listener, token));
        _ = Task.Run(() => RunDiscovery(token));
        _ = Task.Run(() => OffLanReconnectLoop(token));
        _ = Task.Run(() => DevicesRefreshLoop(token));
        return true;
    }

    // Under stateGate.
    private void SetStatus(EngineStatus next)
    {
        if (next == status) return;
        status = next;
        Raise(StatusChanged, next, nameof(StatusChanged));
    }

    // A Running engine with a problem worth showing (or cleared: null).
    private void SetRunningError(string? error)
    {
        lock (stateGate)
        {
            if (status.State == EngineState.Running) SetStatus(status with { Error = error });
        }
    }

    // clipboard watcher
    private void StartClipboardWatcher()
    {
        if (!options.WatchClipboard) return;

        // Its own thread with its own message loop (see ClipboardSync.Watch) -
        // independent of whatever UI thread the app runs.
        Thread thisThread = new Thread(() =>
        {
            clipboardSync.Watch();
        });

        thisThread.SetApartmentState(ApartmentState.STA);
        thisThread.IsBackground = true;
        thisThread.Name = "ClipLink clipboard watcher";
        thisThread.Start();
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(token);
            }
            catch (Exception) when (token.IsCancellationRequested)
            {
                break; // Stop()
            }
            catch (Exception ex) when (ex is SocketException or IOException)
            {
                Console.WriteLine($"[listen] accept failed, still listening: {ex.Message}");
                await Task.Delay(200); // a persistent error can't spin
                continue;
            }
            // Each connection is handled off the accept loop. Awaiting the
            // handshake here meant any exception in it (a peer resetting
            // mid-handshake throws IOException, which CreateAsync doesn't
            // catch) escaped this fire-and-forget task and silently ended
            // the loop - the listener was then gone for the rest of the
            // daemon's life. Nothing could dial in any more: on the LAN
            // that went unnoticed because this side dials out on beacons,
            // but over Tailscale (no beacons) every pairing and reconnect
            // failed. It also meant one slow handshake blocked every other
            // incoming connection until it finished.
            _ = Task.Run(() => AcceptConnection(client));
        }
    }

    private async Task RunDiscovery(CancellationToken token)
    {
        ownTailscaleAddress = TailscaleHelper.GetOwnTailscaleIp();
        if (options.LoopbackOnly) return;

        Discovery discovery = new Discovery();
        discovery.PORT = options.DiscoveryPort;
        discovery.PeerDiscovered += OnPeerDiscovered;
        try
        {
            await discovery.Start(ownId, port, () =>
                passphraseKeyStore.GetKey() is byte[] passphraseKey
                    ? PassphraseAuth.ComputeProof(passphraseKey, ownId)
                    : null,
                ownTailscaleAddress,
                () => deviceName.Current,
                token);
        }
        catch (Exception ex) when (!token.IsCancellationRequested)
        {
            // Used to end the daemon. Everything else still works - trusted
            // peers with an address, pairing by address, peers dialling in.
            Console.WriteLine($"[discovery] FAILED, LAN discovery is off: {ex.GetType().Name}: {ex.Message}");
            SetRunningError($"Can't look for devices on the local network (UDP port {options.DiscoveryPort}: {ex.Message}). Devices can still connect by address.");
        }
        catch (Exception) { /* stopping */ }
    }

    // This handler is async void: an exception escaping it doesn't just
    // end the handler, it crashes the whole app - hence the catch-all.
    private async void OnPeerDiscovered(string other_device_id, IPAddress sender, int other_port, string? proof, string? peerAddress, string? otherName)
    {
        try
        {
            if (stopping.IsCancellationRequested) return;

            // Nothing here is for this PC's own id: UDP broadcasts loop back
            // to the sender on localhost, so without this a device would list
            // itself, and "auto-trust" itself below. Compared as keys, not
            // text: a beacon can spell this PC's id some other way (see
            // DeviceIdentity.IsSameKey), and it's still this PC.
            if (DeviceIdentity.IsSameKey(other_device_id, ownId)) return;

            // Remember every other device's latest beacon - its name and LAN
            // address for the Devices list, whether or not it's trusted. In
            // memory only: nothing a beacon says about a name is ever saved
            // (see SeenPeer).
            RememberBeacon(other_device_id,
                new SeenPeer(otherName, sender.ToString(), peerAddress, DateTime.UtcNow));

            // A blocked device is listed (so it can be unblocked) and that is
            // all: no passcode auto-trust, no dial, no pairing.
            bool blocked = blockStore.IsBlocked(other_device_id);
            if (blocked)
            {
                NotifyDevicesChanged();
                return;
            }

            // auto-trust: if this device wasn't already trusted, but it proved
            // knowledge of the same passphrase we have configured, trust it now —
            // an alternative to manual QR/key pairing for "these are all my own devices".
            if (!trustStore.IsTrusted(other_device_id) && proof != null && passphraseKeyStore.GetKey() is byte[] passphraseKey
                && PassphraseAuth.VerifyProof(passphraseKey, other_device_id, proof))
            {
                Console.WriteLine($"Auto-trusting {other_device_id} — proved knowledge of shared passphrase");
                // Not the beacon's name: the connection that follows stores
                // its handshake's name once it proves its session.
                trustStore.Trust(other_device_id, peerAddress);
            }

            bool isTrusted = trustStore.IsTrusted(other_device_id);
            NotifyDevicesChanged(); // an event only if the list really changed

            // connect only if the other device is in the trust store, and when its key
            // sorts first or it is due the dial fallback: see DialDecision
            if (connectionsByDeviceId.ContainsKey(other_device_id)) dialFallback.Connected(other_device_id);
            if (DialDecision.ShouldDial(blocked, connectionsByDeviceId.ContainsKey(other_device_id), isTrusted,
                    other_device_id, ownId,
                    () => dialFallback.Due(other_device_id),
                    () => connectingTo.TryAdd(other_device_id, 0)))
            {
                Console.WriteLine($"Discovered peer {other_device_id} at {other_port}");
                try
                {
                    await ConnectToPeer(other_device_id, sender.ToString(), other_port);
                }
                catch (Exception)
                {
                    // peer wasn't actually reachable — ignore, we'll hear its next beacon
                }
                finally
                {
                    connectingTo.TryRemove(other_device_id, out _);
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[discovery] error handling beacon from {sender}: {ex.GetType().Name}: {ex.Message}");
        }
    }

    // off-LAN reconnect loop: for trusted peers we have a cached address for
    // (e.g. Tailscale, learned at pairing time) but aren't currently connected
    // to — LAN discovery can't find these, so we have to proactively retry
    private async Task OffLanReconnectLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            // Any exception here used to end this loop for good, silently -
            // after which trusted peers were never redialled off-LAN.
            try
            {
                var attempts = trustStore.GetTrustedDevicesWithAddress()
                    .Where(device => !connectionsByDeviceId.ContainsKey(device.PublicKey)
                        && string.CompareOrdinal(device.PublicKey, ownId) < 0
                        && connectingTo.TryAdd(device.PublicKey, 0))
                    .Select(async device =>
                    {
                        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                        try
                        {
                            await ConnectToPeer(device.PublicKey, device.Address!, port, cts.Token);
                        }
                        catch (Exception)
                        {
                            // not reachable via this address right now — retry next cycle
                        }
                        finally
                        {
                            connectingTo.TryRemove(device.PublicKey, out _);
                        }
                    });

                // run every attempt concurrently, so one offline peer's 5s timeout
                // doesn't delay checking the others
                await Task.WhenAll(attempts);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[conn] off-LAN reconnect pass failed, retrying next cycle: {ex.GetType().Name}: {ex.Message}");
            }
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(30), token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    // Untrusted devices drop off the list by time alone (no beacon for
    // DiscoveredListingWindow), with nothing else happening to notice it. The
    // same beat finds the sync requests that nobody answered.
    private async Task DevicesRefreshLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            NotifyDevicesChanged();
            try
            {
                ExpireSyncRequests();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[sync] couldn't drop overdue requests: {ex.GetType().Name}: {ex.Message}");
            }
        }
    }

    // clipboard watcher: something was copied on this PC (that ClipLink didn't
    // write or see already). Not sent when it is what the newest item already
    // has - the devices have it on top (from a share, say, or a clipboard
    // shared by Windows or the phone itself) - but an older item copied again
    // is: that's how the user gets it back onto the other devices (the
    // Synced page then shows it once, on top - see HistoryAccess.GetHistoryWithBatches).
    private void OnLocalClipboardChanged((string content, string type, string? sourceFilePath, string? name) content, int generation)
    {
        if (generation != ActiveClipboardSyncGeneration) return;
        Console.WriteLine($"[clip] detected local {content.type} change ({content.content.Length} chars/bytes-base64) - {connectionsByDeviceId.Count} peer(s) connected");
        if (ContentPrint.Of(content.content, content.type) is string print && historyAccess.NewestHas(new[] { print }, 1))
        {
            Console.WriteLine($"[clip] that {content.type} is the newest item already - not sent again");
            return;
        }
        PublishLocal(content.content, content.type, content.sourceFilePath, "copied",
            content.type == "image" ? content.name : null, generation);
    }

    // Files copied in Explorer (see ClipboardSync.FilesCopied): each goes out
    // as if copied alone, except those the newest items already have - as
    // many newest as files were copied, from before any of them went out.
    private void OnLocalFilesCopied(IReadOnlyList<(string content, string path)> files, int generation)
    {
        if (generation != ActiveClipboardSyncGeneration) return;
        Console.WriteLine($"[clip] detected {files.Count} local file(s) copied - {connectionsByDeviceId.Count} peer(s) connected");
        foreach (var file in SkipNewest(files, file => ContentPrint.Of(file.content, "file")))
        {
            PublishLocal(file.content, "file", file.path, "copied", automaticGeneration: generation);
        }
    }

    // The items of one share or copy that aren't what the newest items (as
    // many as there are items, taken from history before any goes out)
    // already have: those aren't signed again - the devices have them on
    // top - and count as shared. Two with the same content go out once.
    private List<T> SkipNewest<T>(IReadOnlyList<T> items, Func<T, string?> printOf)
    {
        var prints = items.Select(printOf).ToList();
        var known = historyAccess.NewestPrints(items.Count);
        var seen = new HashSet<string>();
        var fresh = new List<T>();
        for (int i = 0; i < items.Count; i++)
        {
            string? print = prints[i];
            if (print != null && (known.Contains(print) || !seen.Add(print))) continue;
            fresh.Add(items[i]);
        }
        if (fresh.Count < items.Count) Console.WriteLine($"[clip] {items.Count - fresh.Count} of {items.Count} item(s) are the newest already, or the same as another - not sent again");
        return fresh;
    }

    // Something new from this PC - copied here, or shared with "Share to
    // ClipLink" (ShareFilesAsync; how says which, for the log): signed, sent
    // to every connected device and added to history. For a file, content
    // is its FilePayload and sourceFilePath where its bytes are: they're
    // cached in the FileStore first and streamed to those devices (the
    // others ask for them when they connect and get the entry in the history
    // batch). A file that can't be cached - it changed since it was hashed,
    // or can't be stored - isn't sent at all: its entry would have nothing
    // behind it, on every device, for good. name: a picture's original name
    // (see ImageName), carried as the entry's unsigned Name; only for an
    // image.
    private void PublishLocal(string content, string type, string? sourceFilePath, string how, string? name = null,
        int? automaticGeneration = null)
    {
        FilePayload? payload = null;
        if (type == "file" && sourceFilePath != null)
        {
            try { payload = JsonSerializer.Deserialize<FilePayload>(content); }
            catch (JsonException) { }
        }
        if (payload != null)
        {
            Console.WriteLine($"[file] {how}: {payload.FileName} ({payload.FileSize} bytes, {payload.FileHash[..12]}...) - {connectionsByDeviceId.Count} peer(s) connected");
            if (!fileStore.Exists(payload.FileHash)
                && !LocalFiles.CopyInto(fileStore, sourceFilePath!, payload.FileHash, out var skip, out string? error))
            {
                Console.WriteLine($"[file] couldn't store {payload.FileName} to send it ({skip}{(error != null ? ": " + error : "")}) - not sent");
                return;
            }
        }

        if (automaticGeneration.HasValue && automaticGeneration != ActiveClipboardSyncGeneration) return;

        var entry = new ClipboardEntry(content, type, ownId, DateTime.UtcNow, Name: type == "image" ? ImageName.Clean(name) : null);
        var signedEntry = SigningService.Sign(entry, identity);
        // Made once, as UTF-8, for every peer (see Wire.Envelope).
        var envelope = Wire.Envelope("entry", signedEntry);
        foreach (var conn in connectionsByDeviceId.Values)
        {
            string peerShort = DeviceLabel.ShortId(conn.PeerDeviceId);
            _ = conn.Send(envelope).ContinueWith(t =>
            {
                if (t.IsFaulted)
                {
                    Console.WriteLine($"[clip] failed sending {type} entry to {peerShort}: {t.Exception?.GetBaseException().Message}");
                }
            }, TaskContinuationOptions.OnlyOnFaulted);
        }
        if (historyAccess.addToHistory(signedEntry))
        {
            NotifyHistoryChanged();
        }

        if (payload != null && fileStore.Exists(payload.FileHash))
        {
            foreach (var conn in connectionsByDeviceId.Values)
            {
                _ = StreamFileToPeer(conn, fileStore.GetPath(payload.FileHash), payload.FileHash);
            }
            // this exact content might already be something we were
            // waiting on from a peer (e.g. this device independently
            // captured the same file another connected device just
            // applied) — fulfill that now rather than leaving it stuck
            // (in either case: see FileTransferState)
            TryFulfillPendingEntry(payload.FileHash);
        }
    }

    // See localCopies. One copy failing doesn't stop the ones after it.
    private async Task PublishLocalCopies()
    {
        await foreach (var publish in localCopies.Reader.ReadAllAsync())
        {
            if (stopping.IsCancellationRequested) continue; // what's left is dropped
            try
            {
                publish();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[clip] couldn't send what was copied: {ex.GetType().Name}: {ex.Message}");
            }
        }
    }

    // ---- events -------------------------------------------------------

    private async Task DeliverEvents()
    {
        await foreach (var deliver in events.Reader.ReadAllAsync())
        {
            deliver();
        }
    }

    private void Raise(Action? handler, string name) =>
        Enqueue(handler, name, h => ((Action)h)());

    private void Raise<T>(Action<T>? handler, T arg, string name) =>
        Enqueue(handler, name, h => ((Action<T>)h)(arg));

    private void RaisePairingResolved(string deviceId, PairingDecision decision) =>
        Enqueue(PairingResolved, nameof(PairingResolved), h => ((Action<string, PairingDecision>)h)(deviceId, decision));

    // Each subscriber on its own, so one that throws doesn't starve the rest.
    private void Enqueue(Delegate? handler, string name, Action<Delegate> invoke)
    {
        if (handler == null) return;
        events.Writer.TryWrite(() =>
        {
            foreach (var subscriber in handler.GetInvocationList())
            {
                try
                {
                    invoke(subscriber);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[engine] {name} handler failed: {ex.GetType().Name}: {ex.Message}");
                }
            }
        });
    }

    private void NotifyHistoryChanged()
    {
        if (Interlocked.Exchange(ref historyChangePending, 1) == 1) return; // one already on its way
        _ = Task.Run(async () =>
        {
            await Task.Delay(CoalesceDelay);
            Volatile.Write(ref historyChangePending, 0);
            Raise(HistoryChanged, nameof(HistoryChanged));
        });
    }

    private void NotifyDevicesChanged()
    {
        if (!storesLoaded || Interlocked.Exchange(ref devicesChangePending, 1) == 1) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(CoalesceDelay);
            Volatile.Write(ref devicesChangePending, 0);
            try
            {
                // Listed and queued under the lock: a second notification
                // can be running alongside this one, and one that listed
                // earlier mustn't queue its (older) list after a newer one.
                lock (devicesSignatureGate)
                {
                    var devices = ListDevices();
                    string signature = string.Join("\n", devices.Select(d =>
                        $"{d.PublicKey}|{d.Name}|{d.Trusted}|{d.Connected}|{string.Join(",", d.Addresses)}"));
                    if (signature == lastDevicesSignature) return;
                    lastDevicesSignature = signature;
                    Raise(DevicesChanged, devices, nameof(DevicesChanged));
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[engine] couldn't list devices: {ex.GetType().Name}: {ex.Message}");
            }
        });
    }
}
