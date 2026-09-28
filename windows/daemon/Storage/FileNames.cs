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
    // there), none of the invisible characters that disguise a name (see
    // IsUnsafeChar: "gpj.exe" after a right-to-left override shows as
    // "exe.jpg"), no characters Windows refuses, not a reserved device name,
    // not absurdly long. Blank after all that: fallback.
    public static string Safe(string? name, string fallback)
    {
        string safe = (name ?? "").Replace('\\', '/');
        safe = safe[(safe.LastIndexOf('/') + 1)..];
        var invalid = Path.GetInvalidFileNameChars();
        safe = new string(safe.Where(c => !IsUnsafeChar(c)).Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.', ' ');
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

    // Never kept in a name another device chose - a file name here, a
    // device name in DeviceLabel: control characters (C0 and C1), and the
    // invisible ones that reorder or hide text - the Arabic letter mark
    // (U+061C), zero-width space, non-joiner and joiner (U+200B-U+200D),
    // the left-to-right and right-to-left marks (U+200E, U+200F), bidi
    // embeddings and overrides (U+202A-U+202E), bidi isolates
    // (U+2066-U+2069) and the zero-width no-break space / BOM (U+FEFF).
    public static bool IsUnsafeChar(char c) =>
        char.IsControl(c)
        || c is '\u061C' or (>= '\u200B' and <= '\u200F') or (>= '\u202A' and <= '\u202E') or (>= '\u2066' and <= '\u2069') or '\uFEFF';

    // Where a copy of something goes as fileName in dir without ever
    // replacing a different file: the first of "name.ext", "name (1).ext",
    // "name (2).ext"... that either doesn't exist yet (Exists false - write
    // it there) or already holds exactly this content, as isSame decides
    // (Exists true - use it as it is).
    public static (string Path, bool Exists) CopyPath(string dir, string fileName, Func<string, bool> isSame)
    {
        string nameOnly = Path.GetFileNameWithoutExtension(fileName);
        string extension = Path.GetExtension(fileName);
        for (int counter = 0; ; counter++)
        {
            string candidate = Path.Combine(dir, counter == 0 ? fileName : $"{nameOnly} ({counter}){extension}");
            if (!File.Exists(candidate)) return (candidate, false);
            if (isSame(candidate)) return (candidate, true);
        }
    }
}
