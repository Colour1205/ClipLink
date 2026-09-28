namespace ClipboardDaemon.Storage;

public static class FileNames
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    // A name another device chose, made safe to create here: no folders
    // (only the last path segment counts - a received "..\..\x" or
    // "C:\Users\...\Startup\x.exe" must land in the folder it's put in, not
    // there), no characters Windows refuses, not a reserved device name, not
    // absurdly long. Blank after all that: fallback.
    public static string Safe(string? name, string fallback)
    {
        string safe = (name ?? "").Replace('\\', '/');
        safe = safe[(safe.LastIndexOf('/') + 1)..];
        var invalid = Path.GetInvalidFileNameChars();
        safe = new string(safe.Select(c => invalid.Contains(c) || char.IsControl(c) ? '_' : c).ToArray()).Trim().TrimEnd('.', ' ');
        if (safe.Length == 0) return fallback;
        if (Reserved.Contains(Path.GetFileNameWithoutExtension(safe))) safe = "_" + safe;
        if (safe.Length > 120)
        {
            string extension = Path.GetExtension(safe);
            if (extension.Length > 20) extension = "";
            int keep = 120 - extension.Length;
            if (char.IsHighSurrogate(safe[keep - 1])) keep--; // never half a character
            safe = safe[..keep].TrimEnd('.', ' ') + extension;
        }
        return safe;
    }
}
