using System.Text;

namespace ClipboardDaemon.Storage;

public static class FileNames
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    private const int MaxLength = 120;
    private const int MaxExtensionLength = 20;

    // The phones' file systems (ext4, f2fs, HarmonyOS's) and APFS cap a name
    // at 255 bytes of UTF-8, not 255 characters - 120 Chinese characters are
    // 360 bytes - so a name kept here is cut to fit there too, as Android's
    // FileNames.kt cuts it. Under 255, so a " (1)" can still be added.
    private const int MaxUtf8Bytes = 240;

    // A name another device chose, made safe to create here: no folders
    // (only the last path segment counts - a received "..\..\x" or
    // "C:\Users\...\Startup\x.exe" must land in the folder it's put in, not
    // there), none of the invisible characters that disguise a name (see
    // IsUnsafeChar: "gpj.exe" after a right-to-left override shows as
    // "exe.jpg"), no characters Windows refuses, not a reserved device name,
    // not absurdly long (at most 120 characters and 240 UTF-8 bytes, keeping
    // the extension, never cutting a character in half). Blank after all
    // that: fallback.
    public static string Safe(string? name, string fallback)
    {
        string safe = (name ?? "").Replace('\\', '/');
        safe = safe[(safe.LastIndexOf('/') + 1)..];
        var invalid = Path.GetInvalidFileNameChars();
        safe = new string(safe.Where(c => !IsUnsafeChar(c)).Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.', ' ');
        if (safe.Length == 0) return fallback;
        if (Reserved.Contains(Path.GetFileNameWithoutExtension(safe))) safe = "_" + safe;
        if (safe.Length > MaxLength || Encoding.UTF8.GetByteCount(safe) > MaxUtf8Bytes)
        {
            string extension = Path.GetExtension(safe);
            if (extension.Length > MaxExtensionLength) extension = "";
            string stem = Prefix(safe, MaxLength - extension.Length, MaxUtf8Bytes - Encoding.UTF8.GetByteCount(extension));
            safe = stem.TrimEnd('.', ' ') + extension;
            // A stem of nothing but dots and spaces trims away entirely - and
            // with no extension left either, "" would name the folder itself.
            if (safe.Length == 0) return fallback;
            // Or all that's left is a reserved name ("CON" of "CON.....txt").
            if (Reserved.Contains(Path.GetFileNameWithoutExtension(safe))) safe = "_" + safe;
        }
        return safe;
    }

    // The longest start of s within maxChars UTF-16 units and maxBytes of
    // UTF-8 - never half a character. (A lone surrogate counts as the 3
    // bytes of the U+FFFD it's encoded as, as Encoding.UTF8 counts it.)
    private static string Prefix(string s, int maxChars, int maxBytes)
    {
        int end = 0;
        int bytes = 0;
        while (end < s.Length)
        {
            Rune.DecodeFromUtf16(s.AsSpan(end), out Rune rune, out int consumed);
            bytes += rune.Utf8SequenceLength;
            if (end + consumed > maxChars || bytes > maxBytes) break;
            end += consumed;
        }
        return s[..end];
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
