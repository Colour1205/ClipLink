namespace ClipboardDaemon.Identity;

// A device this PC refuses to hear from, with the name it had when it was
// blocked (what the Devices list shows for it - it may never beacon again).
public record BlockedDevice(string PublicKey, string? Name = null);

// The devices this PC has blocked. A blocked device never gets a pairing
// prompt, is never dialled, is never trusted by a shared passcode, and its
// handshake is refused before anything else about it is decided - so it can't
// be a source of spam, however often it asks.
//
// Blocking is blocking a KEY. Someone who generates a new identity is a new
// device and isn't stopped by this; what it does stop is the usual case, one
// phone or PC that keeps asking. Mirrors the mobile ports' block stores: a list
// of ids with the name each had when it was blocked, not encrypted at rest
// (same as the trust store beside it).
public class BlockStore
{
    private readonly List<BlockedDevice> blocked = new();
    private readonly string path;
    // Read from every connection path (TCP accept, beacon handler, reconnect
    // loop) and written by the app, each on its own thread.
    private readonly object gate = new();

    public BlockStore(string? label = "")
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        path = Path.Combine(app_data_dir, "ClipboardDaemon", $"blocked{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (!File.Exists(path)) return;
        try
        {
            var devices = System.Text.Json.JsonSerializer.Deserialize<List<BlockedDevice>>(File.ReadAllText(path));
            if (devices != null) blocked.AddRange(devices.Where(d => !string.IsNullOrWhiteSpace(d.PublicKey)));
        }
        catch (System.Text.Json.JsonException ex)
        {
            // Regenerate rather than crash, the policy every store here follows.
            Console.WriteLine($"Could not load the block list ({ex.Message}) - starting with nobody blocked.");
        }
    }

    // Whether two device ids are one key, however each is spelt: equal text,
    // or Base64 that decodes to the same bytes (Convert tolerates whitespace,
    // so one key can be written several ways and still verify as itself).
    // Compared as text alone, that would be a way round the block. Bytes, not
    // DeviceIdentity.IsSameKey: this runs for every beacon, and that parses keys.
    private static bool SameId(string first, string second)
    {
        if (string.Equals(first, second, StringComparison.Ordinal)) return true;
        try
        {
            return Convert.FromBase64String(first).AsSpan().SequenceEqual(Convert.FromBase64String(second));
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public bool IsBlocked(string key)
    {
        lock (gate) { return blocked.Any(d => SameId(d.PublicKey, key)); }
    }

    // A snapshot, for the Devices list.
    public IReadOnlyList<BlockedDevice> GetAll()
    {
        lock (gate) { return blocked.ToList(); }
    }

    // Adds the device, or - if it's already blocked - keeps its name unless a
    // better one is given.
    public void Block(string publicKey, string? name = null)
    {
        string? known = DeviceNameStore.Normalize(name);
        lock (gate)
        {
            int index = blocked.FindIndex(d => SameId(d.PublicKey, publicKey));
            if (index < 0) blocked.Add(new BlockedDevice(publicKey, known));
            else blocked[index] = blocked[index] with { Name = known ?? blocked[index].Name };
            Save();
        }
    }

    public void Unblock(string publicKey)
    {
        lock (gate)
        {
            blocked.RemoveAll(d => SameId(d.PublicKey, publicKey));
            Save();
        }
    }

    private void Save()
    {
        File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(blocked));
    }
}
