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
    // Read, but it changed before it was stored here to send - a file still
    // being written (a download, a recording), or saved again meanwhile.
    Changed,
    // Read, but it couldn't be stored here to send (the disk is full, say).
    NotStored,
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

            using var stream = OpenRead(path);
            // What's actually read: for a symbolic link, FileInfo.Length is
            // the link's own size (0), not its target's.
            if (stream.Length > MaxFileBytes)
            {
                skip = FileSkipReason.TooLarge;
                return null;
            }
            string hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)); // streams internally — never loads the whole file for hashing
            // Exactly what was hashed: a file being written can grow (or
            // shrink) while it's read.
            long size = stream.Position;
            if (size > MaxFileBytes)
            {
                skip = FileSkipReason.TooLarge;
                return null;
            }
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

    // Caches the file at path - which Describe gave hash - as hash's blob in
    // store, to be sent from there: only if it still holds exactly the bytes
    // that were hashed (see FileStore.CopyIn). False, with why not (and for
    // Unreadable and NotStored, the error), if it wasn't cached.
    public static bool CopyInto(FileStore store, string path, string hash, out FileSkipReason skip, out string? error)
    {
        skip = FileSkipReason.Unreadable;
        error = null;
        FileStream source;
        try
        {
            source = OpenRead(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            error = ex.Message;
            return false;
        }
        using (source)
        {
            try
            {
                if (store.CopyIn(source, hash)) return true;
                skip = FileSkipReason.Changed;
                return false;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                skip = FileSkipReason.NotStored;
                // The likely one, without the path of ClipLink's own copy
                // that the system's message ends with.
                error = IsDiskFull(ex) ? "There's not enough space on the disk." : ex.Message;
                return false;
            }
        }
    }

    // ERROR_DISK_FULL or ERROR_HANDLE_DISK_FULL (as an HRESULT, FACILITY_WIN32).
    private static bool IsDiskFull(Exception ex) =>
        ((ex.HResult >> 16) & 0x1FFF) == 7 && (ex.HResult & 0xFFFF) is 112 or 39;

    // Opens a file on this PC to read with the sharing File.Copy (and so
    // Explorer) uses: a document an app has open for writing - Word's .docx,
    // Excel's .xlsx - can be read, and so shared or copied, as Explorer can
    // copy it. (File.OpenRead shares reading only, and failed for those:
    // "being used by another process".) So the file may be written while
    // it's read - which CopyInto checks for.
    private static FileStream OpenRead(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024, FileOptions.SequentialScan);
}
