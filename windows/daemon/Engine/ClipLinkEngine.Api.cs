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
    // back to the computer's name. Returns the name now in effect. Used from
    // the next beacon and the next handshake - live connections keep the
    // name they opened with. ("set_device_name")
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
    // name and address its latest beacon carried (its advertised off-LAN
    // one, else the LAN address it came from). One-sided: it connects once
    // that device trusts this PC too (paired or same passcode there). False
    // for a blank id or this device's own; true, changing nothing, if it's
    // already trusted.
    public bool TrustDevice(string deviceId)
    {
        RequireStores();
        if (string.IsNullOrWhiteSpace(deviceId) || deviceId == ownId) return false;
        if (trustStore.IsTrusted(deviceId)) return true;
        seenPeers.TryGetValue(deviceId, out var seen);
        trustStore.Trust(deviceId, seen?.AdvertisedAddress ?? seen?.LanAddress, seen?.Name);
        NotifyDevicesChanged();
        return true;
    }

    // Trusts a device from its pairing payload (PairingInfo JSON) or a bare
    // device id, one-sided, exactly as the old command did - kept for tools
    // and tests; the app pairs with PairByAddressAsync / TrustDevice.
    // False for a blank payload. ("trust_device")
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
            trustStore.Trust(pairingInfo.PublicKey, pairingInfo.Address, pairingInfo.Name);
        }
        else
        {
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

    // Accepts the pending request: trusts the device (with its name and
    // address) and starts syncing over the connection it's waiting on - once
    // the other device accepts too. False if nothing is pending. Both happen
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
                trustStore.Trust(takenId, address, NameOfCandidate(conn));
                RegisterConnection(conn);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[pair] couldn't finish pairing with {takenId[..Math.Min(12, takenId.Length)]}...: {ex.GetType().Name}: {ex.Message}");
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
    // file name - in a folder of its own under %TEMP%\ClipLink. Null if key
    // isn't a file or image in history, or a file's bytes aren't here
    // (IsAvailable false). The first call copies the file, so for a big one
    // call it off the UI thread. Throws IOException if the copy fails.
    public string? GetFileToOpen(string key)
    {
        var entry = FindEntry(key);
        if (entry == null) return null;
        if (entry.Type == "file")
        {
            var payload = FilePayloadOf(entry);
            if (payload == null || !IsStored(payload)) return null;
            string source = fileStore.GetPath(payload.FileHash);
            string path = Path.Combine(OpenFolderFor(entry), FileNames.Safe(payload.FileName, "file"));
            // Kept between opens - only (re)copied if missing or different.
            if (!File.Exists(path) || new FileInfo(path).Length != new FileInfo(source).Length)
            {
                File.Copy(source, path, overwrite: true);
            }
            return path;
        }
        if (entry.Type == "image" && DecodeImage(entry) is byte[] bytes)
        {
            string path = Path.Combine(OpenFolderFor(entry), $"ClipLink image {ToUtc(entry.Timestamp).ToLocalTime():yyyy-MM-dd HHmmss}{ImageFiles.Extension(bytes)}");
            if (!File.Exists(path))
            {
                File.WriteAllBytes(path, bytes);
            }
            return path;
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
    // either way, so a peer's next history batch can't restore it. False if
    // it wasn't in history. ("delete_history_entry")
    public bool DeleteHistoryEntry(string key)
    {
        RequireStores();
        if (string.IsNullOrEmpty(key)) return false;
        var removed = historyAccess.removeFromHistory(key);
        ForgetPendingApplies(removed);
        if (removed.Count == 0) return false;
        NotifyHistoryChanged();
        return true;
    }

    // "Clear synced history" - every current entry is remembered as deleted,
    // so it stays cleared when peers reconnect. ("clear_history")
    public void ClearHistory()
    {
        RequireStores();
        var removed = historyAccess.clearHistory();
        ForgetPendingApplies(removed);
        NotifyHistoryChanged();
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

    // One folder per entry (named by a hash of its key), so two entries with
    // the same file name never overwrite each other's copy.
    private string OpenFolderFor(ClipboardEntry entry)
    {
        string entryHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(entry.Key())))[..16];
        string dir = Path.Combine(Path.GetTempPath(), "ClipLink", FileNames.Safe(label, DefaultLabel), entryHash);
        Directory.CreateDirectory(dir);
        return dir;
    }

}
