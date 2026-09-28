using System.IO;
using System.Text.Json;

namespace ClipLink;

// The app's own few preferences (the engine's data stays in
// %APPDATA%\ClipboardDaemon): %LOCALAPPDATA%\ClipLink\settings.json, or
// settings-<label>.json for a test copy. A missing or unreadable file is
// just "first run".
internal sealed class AppSettings
{
    // The sign-in entry has been set up once (on by default on first run);
    // from then on it's whatever the user chose.
    public bool SignInStartupConfigured { get; set; }

    // The "set a passcode" suggestion on the Synced page was closed.
    public bool PasscodeTipDismissed { get; set; }

    // The Synced page shows its cards as a grid rather than a list.
    public bool SyncedGridView { get; set; }

    private string path = "";

    public static AppSettings Load(AppOptions options)
    {
        string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipLink");
        string path = Path.Combine(folder, options.IsDefaultLabel ? "settings.json" : $"settings-{options.Label}.json");
        AppSettings? settings = null;
        try
        {
            if (File.Exists(path)) settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path));
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            Console.WriteLine($"[settings] couldn't read {path} ({ex.Message}) - using defaults");
        }
        settings ??= new AppSettings();
        settings.path = path;
        return settings;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"[settings] couldn't save {path}: {ex.Message}");
        }
    }
}
