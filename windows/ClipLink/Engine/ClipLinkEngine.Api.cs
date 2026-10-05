using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Engine;

// What the app's UI calls - typed replacements for the named-pipe commands
// the tray used to send (each notes the old command). Everything here is
// thread-safe; the stores behind them need Start() to have been called
// (InvalidOperationException otherwise) but keep working when the engine
// is Faulted or Stopped. See ClipLinkEngine.cs for threading and events.
public sealed partial class ClipLinkEngine
{
    // ---- this device -------------------------------------------------

    // This device's id: its public key (Base64 SPKI). ("get_public_key")
    public string DeviceId
    {
        get { RequireStores(); return ownId; }
    }

    // The display name in effect: the user's override, else the computer's
    // name. ("get_device_name")
    public string DeviceName
    {
        get { RequireStores(); return deviceName.Current; }
    }

    // Sets the name other devices see. Blank (or null) clears the override,
    // back to the computer's name - and so does the computer's name itself,
    // so the name keeps following it. Returns the name now in effect. Used
    // from the next beacon and the next handshake - live connections keep
    // the name they opened with. ("set_device_name")
    public string SetDeviceName(string? name)
    {
        RequireStores();
        return deviceName.SetOverride(name);
    }

    // This PC's Tailscale address, if Tailscale is installed and up: as
    // looked up when the engine started (null until then, or if none), or
    // by the latest RefreshTailscaleAddressAsync / GetPairingPayloadAsync.
    public string? TailscaleAddress => ownTailscaleAddress;

    // Asks Tailscale again (runs its CLI - hence async).
    public Task<string?> RefreshTailscaleAddressAsync() => Task.Run(() =>
    {
        string? address = TailscaleHelper.GetOwnTailscaleIp();
        ownTailscaleAddress = address;
        return address;
    });

    // This device's pairing payload - JSON {"PublicKey", "Address", "Name"}
    // (see PairingInfo) - for the QR code and "Copy pairing info". Looks up
    // the Tailscale address afresh each time. ("get_pairing_info")
    public async Task<string> GetPairingPayloadAsync()
    {
        RequireStores();
        string? address = await RefreshTailscaleAddressAsync();
        return JsonSerializer.Serialize(new PairingInfo(ownId, address, deviceName.Current));
    }

    // ---- passcode ----------------------------------------------------

    // Whether a passcode is set. ("has_passphrase")
    public bool HasPasscode
    {
        get { RequireStores(); return passphraseKeyStore.HasPassphrase; }
    }

    // Sets or changes the passcode, any time. Blank (after trimming) is the
    // only thing refused: false, nothing changed. Beacons and new handshakes
    // use it from the next one; live connections are left as they are.
    // Deriving the key is deliberately slow, so this runs off the caller's
    // thread. Faults (IOException etc.) if it couldn't be saved - the old
    // passcode then stays in effect. ("set_passphrase")
    public Task<bool> SetPasscodeAsync(string passcode)
    {
        RequireStores();
        return Task.Run(() => passphraseKeyStore.SetPassphrase(passcode ?? ""));
    }

    // Back to no passcode: HasPasscode is false and beacons and new
    // handshakes carry no proof. Devices already trusted (by passcode or any
    // other way) stay trusted. Throws if the stored key couldn't be deleted.
    // ("clear_passphrase")
    public void ClearPasscode()
    {
        RequireStores();
        passphraseKeyStore.Clear();
    }

    // ---- devices -----------------------------------------------------

    // Every trusted device, then every untrusted one beaconing on the LAN,
    // in a stable display order - see DeviceListing. ("list_devices")
    public IReadOnlyList<DeviceListing> GetDevices()
    {
        RequireStores();
        return ListDevices();
    }

    // Ids of the devices connected right now. ("list_connections")
    public IReadOnlyList<string> GetConnections() => connectionsByDeviceId.Keys.ToList();

    // The trust store as stored - {PublicKey, Address, Name} per trusted
    // device. ("list_trusted")
    public IReadOnlyList<TrustedDevice> GetTrustedDevices()
    {
        RequireStores();
        return trustStore.GetAllTrustedDevices().ToList();
    }

    // Trusts a device seen on the LAN (a discovered row's Trust), with the
    // address its latest beacon carried (its advertised off-LAN one, else
    // the LAN address it came from). Not its beacon's name: beacons are
    // unauthenticated, so that name is only shown (see SeenPeer) until the
    // first connection with the device that proves its session stores the
    // name from its handshake (RememberProvenName). One-sided: it
    // connects once that device trusts this PC too (paired or same passcode
    // there). False for a blank id or this device's own (however it's spelt
    // - see DeviceIdentity.IsSameKey); true, changing nothing, if it's
    // already trusted.
    public bool TrustDevice(string deviceId)
    {
        RequireStores();
        if (string.IsNullOrWhiteSpace(deviceId) || DeviceIdentity.IsSameKey(deviceId, ownId)) return false;
        if (trustStore.IsTrusted(deviceId)) return true;
        seenPeers.TryGetValue(deviceId, out var seen);
        trustStore.Trust(deviceId, seen?.AdvertisedAddress ?? seen?.LanAddress);
        NotifyDevicesChanged();
        return true;
    }

    // Trusts a device from its pairing payload (PairingInfo JSON) or a bare
    // device id, one-sided, exactly as the old command did - kept for tools
    // and tests; the app pairs with PairByAddressAsync / TrustDevice.
    // False for a blank payload, or this device's own (however its id is
    // spelt - see DeviceIdentity.IsSameKey). ("trust_device")
    public bool TrustPairingPayload(string payload)
    {
        RequireStores();
        if (string.IsNullOrWhiteSpace(payload)) return false;
        // accept either the {PublicKey, Address} pairing payload, or a
        // bare key (e.g. the old CLI --trust flow)
        PairingInfo? pairingInfo = null;
        try
        {
            pairingInfo = JsonSerializer.Deserialize<PairingInfo>(payload);
        }
        catch (JsonException) { /* not JSON — fall through to bare-key handling below */ }

        if (pairingInfo != null && !string.IsNullOrWhiteSpace(pairingInfo.PublicKey))
        {
            if (DeviceIdentity.IsSameKey(pairingInfo.PublicKey, ownId)) return false;
            trustStore.Trust(pairingInfo.PublicKey, pairingInfo.Address, pairingInfo.Name);
        }
        else
        {
            if (DeviceIdentity.IsSameKey(payload, ownId)) return false;
            trustStore.Trust(payload);
        }
        NotifyDevicesChanged();
        return true;
    }

    // Removes a device's trust and closes its connection, if any. One that's
    // still beaconing then shows up again as discovered. ("untrust_device")
    public void UntrustDevice(string deviceId)
    {
        RequireStores();
        trustStore.Untrust(deviceId);
        if (connectionsByDeviceId.TryRemove(deviceId, out var conn))
        {
            conn.Close();
        }
        NotifyDevicesChanged();
    }

    // ---- pairing -----------------------------------------------------

    // Pairing mode - mirrors the mobile apps' Pairing screens (HarmonyOS's
    // Index.ets pairingOpen): turn it on while the pairing UI is showing
    // and off when it goes. Only while it's on does a handshake from an
    // untrusted device complete at all (as a PairingRequested prompt - see
    // PeerConnection.CreateAsync), and this PC's beacon says it's open, so
    // a device whose own pairing screen is open dials it. ("set_pairing_mode")
    public bool PairingMode => pairingState.ModeOpen;

    public void SetPairingMode(bool open)
    {
        pairingState.ModeOpen = open;
        if (!open)
        {
            // Closing the pairing UI abandons any request it was showing.
            // Left pending, it blocked every later attempt (TrySetPending
            // refuses while one is held), and the held socket is never
            // read, so its peer dying went unnoticed.
            var abandoned = pairingState.TakePending();
            if (abandoned != null)
            {
                abandoned.Value.conn.Close();
                RaisePairingResolved(abandoned.Value.conn.PeerDeviceId, PairingDecision.Abandoned);
            }
        }
    }

    // The pairing request waiting for Accept/Reject, or null. The same thing
    // PairingRequested delivered. ("get_pending_pairing_info")
    public PendingPairing? GetPendingPairing()
    {
        var pending = pairingState.PendingPeer;
        if (pending == null)
        {
            return null;
        }
        string pendingId = pending.Value.peerId;
        // Handshake name first; an older peer's may only be in its beacon.
        string? pendingName = pending.Value.name ?? (seenPeers.TryGetValue(pendingId, out var seen) ? seen.Name : null);
        return new PendingPairing(pendingId, pendingName, pending.Value.address);
    }

    // Accepts the pending request: trusts the device (with its address, not
    // yet a name - its handshake's is stored once this connection proves its
    // session, see RememberProvenName; a beacon's never is) and starts
    // syncing over the connection it's waiting on - once the other device
    // accepts too. False if nothing is pending. Both happen
    // just after this returns, off the caller's thread - DevicesChanged
    // reports them. ("accept_pairing")
    public bool AcceptPairing()
    {
        var taken = pairingState.TakePending();
        if (taken == null)
        {
            return false;
        }
        string takenId = taken.Value.conn.PeerDeviceId;
        if (stopping.IsCancellationRequested)
        {
            taken.Value.conn.Close();
            RaisePairingResolved(takenId, PairingDecision.Abandoned);
            return false;
        }
        // Not on the caller's thread, which is the app's UI thread:
        // RegisterConnection starts the connection's read loop, whose awaits
        // would resume on that thread's SynchronizationContext for the
        // connection's whole life (every message from this device - history
        // batches, file chunks and their hashing - handled on the UI thread),
        // and it serializes and encrypts the whole history for the first batch.
        var (conn, address) = taken.Value;
        _ = Task.Run(() =>
        {
            try
            {
                trustStore.Trust(takenId, address);
                RegisterConnection(conn);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[pair] couldn't finish pairing with {DeviceLabel.ShortId(takenId)}: {ex.GetType().Name}: {ex.Message}");
                conn.Close();
            }
        });
        RaisePairingResolved(takenId, PairingDecision.Accepted);
        return true;
    }

    // Rejects the pending request and closes its connection. False if
    // nothing was pending. ("reject_pairing")
    public bool RejectPairing()
    {
        var taken = pairingState.TakePending();
        if (taken == null)
        {
            return false;
        }
        taken.Value.conn.Close();
        RaisePairingResolved(taken.Value.conn.PeerDeviceId, PairingDecision.Rejected);
        return true;
    }

    // Pairs with - or reconnects to - the device at an address: Windows has
    // no camera to scan a QR with, so this is the primary way to pair from
    // here. Takes what a user would paste: an IP address or host name,
    // optionally with ":port" ("[v6]:port" for IPv6), or another device's
    // whole pairing payload (only its Address is used - the peer's real
    // identity comes from the signature-verified handshake, not from
    // anything typed here). A new device ends up Pending (PairingRequested
    // fires - Accept on both devices) unless it has the same passcode; see
    // PairOutcome. Can take ~20 s when nothing answers at the address.
    // Never throws. ("pair_by_address", which only started it)
    public async Task<PairOutcome> PairByAddressAsync(string addressOrPayload)
    {
        if (!IsRunning)
        {
            return PairOutcome.NotRunning;
        }
        if (!TryParseAddress(addressOrPayload, out string host, out int targetPort))
        {
            return PairOutcome.InvalidAddress;
        }
        return await Task.Run(() => PairByAddress(host, targetPort));
    }

    // host:port with one colon, or [IPv6]:port.
    private static readonly Regex AddressWithPort = new(@"^\[(?<host>[^\]]+)\]:(?<port>\d{1,5})$|^(?<host>[^:\[\]]+):(?<port>\d{1,5})$");

    private bool TryParseAddress(string? input, out string host, out int targetPort)
    {
        host = "";
        targetPort = port;
        string text = input?.Trim() ?? "";
        if (text.StartsWith('{'))
        {
            try
            {
                text = JsonSerializer.Deserialize<PairingInfo>(text)?.Address?.Trim() ?? "";
            }
            catch (JsonException) { return false; }
        }
        if (text.Length == 0)
        {
            return false;
        }
        var match = AddressWithPort.Match(text);
        if (match.Success)
        {
            host = match.Groups["host"].Value;
            if (!int.TryParse(match.Groups["port"].Value, out targetPort) || targetPort is < 1 or > 65535)
            {
                return false;
            }
        }
        else
        {
            host = text; // a bare address - IPv6 ones have colons of their own
        }
        return Uri.CheckHostName(host) != UriHostNameType.Unknown;
    }

    // ---- synced history ----------------------------------------------

    // The synced history, newest first - see HistoryItem. ("get_history",
    // slimmed down: fetch contents by Key with the methods below)
    public IReadOnlyList<HistoryItem> GetHistory()
    {
        RequireStores();
        var trustedNames = trustStore.GetAllTrustedDevices().ToDictionary(device => device.PublicKey, device => device.Name);
        string ownName = deviceName.Current;
        return historyAccess.GetHistory()
            .OrderByDescending(entry => entry.Timestamp)
            .Select(entry => ToHistoryItem(entry, trustedNames, ownName))
            .ToList();
    }

    // A text entry's full text; null if key isn't a text entry in history.
    public string? GetText(string key)
    {
        var entry = FindEntry(key);
        return entry?.Type == "text" ? entry.Content : null;
    }

    // An image entry's bytes - PNG, or JPEG/others from phones (decode by
    // content, not by assuming PNG); null if key isn't an image in history.
    // They never change for a key, so cache what you make of them.
    public byte[]? GetImageBytes(string key)
    {
        var entry = FindEntry(key);
        return entry?.Type == "image" ? DecodeImage(entry) : null;
    }

    // A local copy of a file or image entry to open with its default app
    // (e.g. ShellExecute), named as its sender named it - made safe as a
    // file name - in the entry's own folder under %TEMP%\ClipLink (see
    // OpenFolderFor). Null if key isn't a file or image in history, or a
    // file's bytes aren't here (IsAvailable false). A copy made earlier is
    // handed out again only while it's still exactly the entry's bytes: one
    // the user has since edited is never overwritten - a fresh copy goes
    // next to it ("name (1).ext"), and isn't deleted with the others (see
    // OpenCopiesRoot). Whatever writes to a copy afterwards (the app's Mark
    // of the Web) must put its last-write time back, or it passes for an
    // edited one and is never cleaned up. Copying (and checking an earlier
    // copy) reads the whole file, so for a big one call it off the UI
    // thread. Throws IOException if the copy fails.
    public string? GetFileToOpen(string key)
    {
        var entry = FindEntry(key);
        if (entry == null) return null;
        if (entry.Type == "file")
        {
            var payload = FilePayloadOf(entry);
            if (payload == null || !IsStored(payload)) return null;
            string source = fileStore.GetPath(payload.FileHash);
            long length = new FileInfo(source).Length;
            lock (openCopiesGate)
            {
                var (path, exists) = FileNames.CopyPath(CreateOpenFolderFor(entry), FileNames.Safe(payload.FileName, "file"),
                    copy => IsUnchangedCopy(copy, payload.FileHash, length));
                if (!exists)
                {
                    File.Copy(source, path);
                }
                return path;
            }
        }
        if (entry.Type == "image" && DecodeImage(entry) is byte[] bytes)
        {
            string hash = Convert.ToHexString(SHA256.HashData(bytes));
            lock (openCopiesGate)
            {
                var (path, exists) = FileNames.CopyPath(CreateOpenFolderFor(entry), $"ClipLink image {ToUtc(entry.Timestamp).ToLocalTime():yyyy-MM-dd HHmmss}{ImageFiles.Extension(bytes)}",
                    copy => IsUnchangedCopy(copy, hash, bytes.Length));
                if (!exists)
                {
                    File.WriteAllBytes(path, bytes);
                }
                return path;
            }
        }
        return null;
    }

    // Puts a history entry back on this PC's clipboard - through the
    // clipboard watcher's queue like every clipboard write, so it isn't
    // echoed back out as a new copy. An image or file is also saved under
    // ReceivedFiles, as receiving one is. False if key isn't in history, or
    // it's a file whose bytes aren't here.
    public bool CopyToClipboard(string key)
    {
        var entry = FindEntry(key);
        if (entry == null) return false;
        switch (entry.Type)
        {
            case "text":
            case "image":
                break;
            case "file":
                if (FilePayloadOf(entry) is not FilePayload payload || !IsStored(payload)) return false;
                break;
            default:
                return false;
        }
        clipboardSync.addToQueue(entry.Content, entry.Type);
        return true;
    }

    // Puts text the app itself shows (a device ID, the pairing info) on this
    // PC's clipboard - through the same queue, so it's written on the
    // watcher's thread and isn't sent to the other devices as a new copy.
    // Like CopyToClipboard, only applied while the engine is Running.
    public void CopyTextToClipboard(string text)
    {
        RequireStores();
        if (!string.IsNullOrEmpty(text)) clipboardSync.addToQueue(text, "text");
    }

    // Deletes one entry (a GetHistory Key) for good - local only: peers keep
    // their copy, and the clipboard is left alone. Remembered as deleted
    // either way, so a peer's next history batch can't restore it. Its
    // copies opened from here (GetFileToOpen) go too, unless the user has
    // edited them. False if it wasn't in history. ("delete_history_entry")
    public bool DeleteHistoryEntry(string key)
    {
        RequireStores();
        if (string.IsNullOrEmpty(key)) return false;
        var removed = historyAccess.removeFromHistory(key);
        ForgetPendingApplies(removed);
        foreach (var entry in removed)
        {
            DeleteOpenCopies(OpenFolderFor(entry));
        }
        if (removed.Count == 0) return false;
        NotifyHistoryChanged();
        return true;
    }

    // "Clear synced history" - every current entry is remembered as deleted,
    // so it stays cleared when peers reconnect. Every copy opened from here
    // (GetFileToOpen) but the ones the user has edited, and every image this
    // label received and saved for the clipboard (see ReceivedFiles) but the
    // one on the clipboard now, goes too - best effort: one an app still has
    // open stays. The clipboard is left alone. ("clear_history")
    public void ClearHistory()
    {
        RequireStores();
        var removed = historyAccess.clearHistory();
        ForgetPendingApplies(removed);
        DeleteOpenCopies(OpenCopiesRoot());
        ReceivedFiles.DeleteImages(label, keep: clipboardSync.ImageFileOnClipboard());
        NotifyHistoryChanged();
    }

    // ---- share ------------------------------------------------------

    // One share at a time, in the order they came.
    private readonly SemaphoreSlim shareGate = new(1, 1);

    // "Share to ClipLink" (File Explorer's menu, Send To): each file goes
    // out exactly as if it had been copied here - a "file" entry in history,
    // its bytes in the FileStore, sent to every connected device and to the
    // others when they next connect - but this PC's clipboard is never
    // touched, and an image file stays a file. Folders, missing files, files
    // over LocalFiles.MaxFileBytes, files that can't be read, files that
    // change while they're read and files that can't be stored here are
    // skipped (see ShareResult and FileSkipReason); a path given twice is
    // shared once. Hashing and caching a big file takes a while, so this
    // runs off the caller's thread. Works while Faulted too: the entries
    // wait in history for the next connection.
    public async Task<ShareResult> ShareFilesAsync(IEnumerable<string> paths)
    {
        RequireStores();
        var unique = paths.Where(path => !string.IsNullOrWhiteSpace(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        await shareGate.WaitAsync();
        try
        {
            return await Task.Run(() =>
            {
                var shared = new List<string>();
                var skipped = new List<SkippedShare>();
                foreach (string path in unique)
                {
                    var payload = LocalFiles.Describe(path, out var skip, out string? error);
                    if (payload == null)
                    {
                        Console.WriteLine($"[share] skipped ({skip}{(error != null ? ": " + error : "")}): {path}");
                        skipped.Add(new SkippedShare(path, skip, error));
                        continue;
                    }
                    // Its bytes first: one that can't be cached here (disk
                    // full, say) could never reach the other devices -
                    // better reported than an entry with nothing behind it.
                    // PublishLocal finds them there.
                    if (!fileStore.Exists(payload.FileHash)
                        && !LocalFiles.CopyInto(fileStore, path, payload.FileHash, out skip, out error))
                    {
                        Console.WriteLine($"[share] couldn't store it to send ({skip}{(error != null ? ": " + error : "")}): {path}");
                        skipped.Add(new SkippedShare(path, skip, error));
                        continue;
                    }
                    try
                    {
                        PublishLocal(JsonSerializer.Serialize(payload), "file", path, "shared");
                        shared.Add(path);
                    }
                    catch (Exception ex)
                    {
                        // Read and stored, but its entry couldn't be (saving
                        // history failed - disk full, say).
                        Console.WriteLine($"[share] couldn't share {path}: {ex.GetType().Name}: {ex.Message}");
                        skipped.Add(new SkippedShare(path, FileSkipReason.NotStored, ex.Message));
                    }
                }
                Console.WriteLine($"[share] shared {shared.Count} file(s), skipped {skipped.Count}");
                return new ShareResult(shared, skipped);
            });
        }
        finally
        {
            shareGate.Release();
        }
    }

    // ---- helpers -----------------------------------------------------

    private void RequireStores()
    {
        if (!storesLoaded) throw new InvalidOperationException("Start the engine first.");
    }

    private ClipboardEntry? FindEntry(string key)
    {
        RequireStores();
        if (string.IsNullOrEmpty(key)) return null;
        return historyAccess.GetHistory().FirstOrDefault(entry => entry.Key() == key);
    }

    private HistoryItem ToHistoryItem(ClipboardEntry entry, Dictionary<string, string?> trustedNames, string ownName)
    {
        bool own = entry.DeviceId == ownId;
        string? name = own ? ownName
            : trustedNames.TryGetValue(entry.DeviceId, out var trustedName) && trustedName != null ? trustedName
            : seenPeers.TryGetValue(entry.DeviceId, out var seen) ? seen.Name : null;
        string content = entry.Content ?? "";
        var item = new HistoryItem(entry.Key(), entry.Type, entry.DeviceId, name, own, ToUtc(entry.Timestamp),
            TextPreview: null, TextLength: 0, FileName: null, SizeBytes: null, IsAvailable: true);
        switch (entry.Type)
        {
            case "text":
                return item with { TextPreview = Preview(content), TextLength = content.Length };
            case "image":
                return item with { SizeBytes = Base64DecodedLength(content) };
            case "file":
                var payload = FilePayloadOf(entry);
                return item with { FileName = payload?.FileName, SizeBytes = payload?.FileSize, IsAvailable = payload != null && IsStored(payload) };
            default:
                return item with { IsAvailable = false };
        }
    }

    // Received timestamps can come back from JSON as Unspecified or Local.
    private static DateTime ToUtc(DateTime timestamp) => timestamp.Kind switch
    {
        DateTimeKind.Utc => timestamp,
        DateTimeKind.Local => timestamp.ToUniversalTime(),
        _ => DateTime.SpecifyKind(timestamp, DateTimeKind.Utc),
    };

    private static string Preview(string text)
    {
        if (text.Length <= HistoryItem.PreviewLength) return text;
        int length = HistoryItem.PreviewLength;
        if (char.IsHighSurrogate(text[length - 1])) length--; // never half a character
        return text[..length];
    }

    private static long Base64DecodedLength(string base64)
    {
        long length = base64.Length / 4 * 3;
        if (base64.EndsWith("==")) length -= 2;
        else if (base64.EndsWith('=')) length -= 1;
        return Math.Max(0, length);
    }

    private static byte[]? DecodeImage(ClipboardEntry entry)
    {
        try
        {
            return Convert.FromBase64String(entry.Content ?? "");
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static FilePayload? FilePayloadOf(ClipboardEntry entry)
    {
        if (entry.Type != "file") return null;
        try
        {
            return JsonSerializer.Deserialize<FilePayload>(entry.Content ?? "");
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // FileHash comes from another device - FileStore only takes a real
    // SHA-256 hex hash (see FileStore.IsValidHash).
    private bool IsStored(FilePayload payload) => fileStore.Exists(payload.FileHash);

    // Copies opened from Synced live under %TEMP%\ClipLink\<label>: one
    // folder per entry (named by a hash of its key), so two entries with the
    // same file name never overwrite each other's copy. An entry's folder is
    // deleted with the entry, and all of them on Clear synced history and
    // when the engine starts - except any copy the user has edited (see
    // IsEditedCopy), which is theirs to keep.
    private string OpenCopiesRoot() => Path.Combine(Path.GetTempPath(), "ClipLink", FileNames.Safe(label, DefaultLabel));

    private string OpenFolderFor(ClipboardEntry entry)
    {
        string entryHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(entry.Key())))[..16];
        return Path.Combine(OpenCopiesRoot(), entryHash);
    }

    private string CreateOpenFolderFor(ClipboardEntry entry)
    {
        string dir = OpenFolderFor(entry);
        Directory.CreateDirectory(dir);
        return dir;
    }

    // Whether an earlier copy is still exactly the entry's bytes (same size,
    // same SHA-256) - false if the user has edited it, or it can't be read.
    // Read while an app may still have it open, hence the sharing.
    private static bool IsUnchangedCopy(string copy, string sha256Hex, long length)
    {
        try
        {
            if (new FileInfo(copy).Length != length) return false;
            using var stream = new FileStream(copy, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return Convert.ToHexString(SHA256.HashData(stream)).Equals(sha256Hex, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // Whether the user has saved changes to a copy since GetFileToOpen made
    // it. File.Copy keeps the stored file's (earlier) last-write time and
    // WriteAllBytes sets it as the file is created, so a copy ClipLink wrote
    // was last written no later than it was created; saving it in an app
    // makes that later. An app that saves by replacing the file counts too:
    // NTFS carries the old file's creation time over to the new one. (So
    // whatever marks a copy - the app's Mark of the Web - keeps its
    // last-write time: see GetFileToOpen.)
    private static bool IsEditedCopy(string file)
    {
        var info = new FileInfo(file);
        return info.LastWriteTimeUtc > info.CreationTimeUtc.AddSeconds(2);
    }

    // Deletes a folder of opened copies (OpenCopiesRoot, or one entry's) and
    // everything in it but the copies the user has edited (IsEditedCopy) -
    // those, and the folders holding them, stay. Best effort: a copy an app
    // still has open (locked) stays, and goes next time.
    private static void DeleteOpenCopies(string dir)
    {
        try
        {
            if (!Directory.Exists(dir)) return;
            foreach (string file in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).ToList())
            {
                try
                {
                    if (!IsEditedCopy(file)) File.Delete(file);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
            // Then every folder that's now empty, innermost first.
            foreach (string folder in Directory.EnumerateDirectories(dir, "*", SearchOption.AllDirectories).Append(dir).OrderByDescending(path => path.Length).ToList())
            {
                try { Directory.Delete(folder); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"[engine] couldn't delete opened copies in {dir}: {ex.Message}");
        }
    }
}
