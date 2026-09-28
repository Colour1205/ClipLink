using System.Runtime.InteropServices;
using System.Text;

namespace ClipboardDaemon.Identity;

// This device's display name - what other devices show in their device
// lists and pairing prompts instead of a raw key. Carried in the LAN
// beacon's 6th field and the handshake's DeviceName (see docs/protocol.md).
// The user's override (the "set_device_name" IPC command) wins; with none
// set it's the computer's own name. Callers read Current fresh for every
// beacon and handshake, so a rename takes effect on the next one without a
// restart.
public class DeviceNameStore
{
    // Same cap every platform applies before a name goes on the wire.
    public const int MaxLength = 64;

    private readonly string override_path;
    private readonly string osDefault;
    private readonly object gate = new();
    private string? overrideName;

    public DeviceNameStore(string? label = "")
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        override_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"devicename{label}.txt");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        osDefault = Normalize(ReadComputerName()) ?? Environment.MachineName;

        if (File.Exists(override_path))
        {
            try
            {
                overrideName = Normalize(File.ReadAllText(override_path));
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Could not load device name ({ex.Message}) — using the computer name.");
            }
        }
    }

    public string Current
    {
        get { lock (gate) { return overrideName ?? osDefault; } }
    }

    // Blank (or null) clears the override, back to the computer name.
    // Returns the name now in effect.
    public string SetOverride(string? name)
    {
        lock (gate)
        {
            overrideName = Normalize(name);
            try
            {
                if (overrideName == null) File.Delete(override_path);
                else File.WriteAllText(override_path, overrideName);
            }
            catch (Exception ex)
            {
                // Still in effect for this run, just not remembered.
                Console.WriteLine($"Could not save device name ({ex.Message}) — it resets on restart.");
            }
            return overrideName ?? osDefault;
        }
    }

    // What every name goes through, ours before sending and a peer's on
    // receipt: trimmed, then capped at MaxLength Unicode scalars (never
    // splitting a surrogate pair). Blank means unknown - null.
    public static string? Normalize(string? name)
    {
        string trimmed = name?.Trim() ?? "";
        if (trimmed.Length == 0) return null;
        if (trimmed.Length <= MaxLength) return trimmed; // can't be over in scalars either

        var capped = new StringBuilder();
        int count = 0;
        foreach (Rune rune in trimmed.EnumerateRunes())
        {
            if (count++ == MaxLength) break;
            capped.Append(rune.ToString());
        }
        return capped.ToString();
    }

    // The case-preserved DNS host name ("Colours-Laptop"), rather than
    // Environment.MachineName's upper-cased, 15-character NetBIOS name.
    // Null (so the caller falls back to MachineName) off Windows or if the
    // call fails.
    private static string? ReadComputerName()
    {
        if (!OperatingSystem.IsWindows()) return null;
        try
        {
            uint size = 256;
            char[] buffer = new char[size];
            if (!GetComputerNameExW(ComputerNamePhysicalDnsHostname, buffer, ref size))
            {
                // Buffer too small: size is now what's needed, terminator included.
                if (Marshal.GetLastPInvokeError() != ErrorMoreData) return null;
                buffer = new char[size];
                if (!GetComputerNameExW(ComputerNamePhysicalDnsHostname, buffer, ref size)) return null;
            }
            // On success size is the length copied, terminator excluded.
            return new string(buffer, 0, (int)size);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private const int ComputerNamePhysicalDnsHostname = 5; // COMPUTER_NAME_FORMAT
    private const int ErrorMoreData = 234;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern bool GetComputerNameExW(int nameType, [Out] char[] buffer, ref uint size);
}
