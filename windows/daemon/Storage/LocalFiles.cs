namespace ClipboardDaemon.Storage;

// Why a path handed over to sync wasn't sent.
public enum FileSkipReason
{
    // Nothing there (or not even allowed to look).
    NotFound,
    // A folder: only files are synced.
    Folder,
    // Over LocalFiles.MaxFileBytes.
    TooLarge,
    // There, but it couldn't be read (locked by another app, no permission).
    Unreadable,
}

// A file on this PC going out to the other devices - copied in Explorer
// (ClipboardSync) or handed to "Share to ClipLink" (ClipLinkEngine.
// ShareFilesAsync): the same checks and the same payload either way. (Kept
// out of ClipboardSync, which is WinForms, so the engine can use it without
// the clipboard - the iOS interop harness swaps ClipboardSync for a fake.)
public static class LocalFiles
{
    // A ceiling against something absurd, not a memory constraint anymore
    // now that files stream.
    public const long MaxFileBytes = 1024L * 1024 * 1024; // 1GB

    // What goes out for the file at path - its name, size and SHA-256 - or
    // null, with why not (and for Unreadable, the error). The hash streams:
    // the file is never loaded whole.
    public static FilePayload? Describe(string path, out FileSkipReason skip, out string? error)
    {
        skip = FileSkipReason.NotFound;
        error = null;
        try
        {
            var fileInfo = new FileInfo(path);
            if (!fileInfo.Exists)
            {
                if (Directory.Exists(path)) skip = FileSkipReason.Folder;
                return null;
            }
            if (fileInfo.Length > MaxFileBytes)
            {
                skip = FileSkipReason.TooLarge;
                return null;
            }

            using var stream = File.OpenRead(path);
            // What's actually read: for a symbolic link, FileInfo.Length is
            // the link's own size (0), not its target's.
            long size = stream.Length;
            if (size > MaxFileBytes)
            {
                skip = FileSkipReason.TooLarge;
                return null;
            }
            string hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)); // streams internally — never loads the whole file for hashing
            return new FilePayload(fileInfo.Name, hash, size);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            // (ArgumentException / NotSupportedException: not a usable path at all.)
            skip = ex is IOException or UnauthorizedAccessException ? FileSkipReason.Unreadable : FileSkipReason.NotFound;
            error = ex.Message;
            return null;
        }
    }
}
