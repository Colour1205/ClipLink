namespace ClipboardDaemon.Storage;

// Content-addressed local storage for synced files — keyed by the SHA256 hash
// of the file's bytes (hex string), so identical content is never stored
// twice, and evicting a history entry can reliably find (and delete) the
// exact blob it refers to, without any other bookkeeping.
public class FileStore
{
    private readonly string storeDir;
    private const string CopyingSuffix = ".copying";

    public FileStore(string label)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        storeDir = Path.Combine(app_data_dir, "ClipboardDaemon", $"filestore{label}");
        Directory.CreateDirectory(storeDir);
        // Left by a CopyIn that never finished.
        foreach (string stale in Directory.EnumerateFiles(storeDir, "*" + CopyingSuffix))
        {
            try { File.Delete(stale); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    // A hash always comes from another device - a file entry, a file_request
    // or a file_chunk - and every method here turns it into a path. Only a
    // real SHA-256 in hex (what every platform sends) is one: anything else,
    // "..\..\Documents\secret.docx" say, let a peer read, overwrite or delete
    // files outside this store. GetPath/GetTempPath throw for it; Exists is
    // false and Delete does nothing.
    public static bool IsValidHash(string? hash) => hash is { Length: 64 } && hash.All(char.IsAsciiHexDigit);

    public string GetPath(string hash) => Path.Combine(storeDir, Checked(hash));

    // Used while a file's chunks are still arriving — not yet verified/complete.
    public string GetTempPath(string hash) => Path.Combine(storeDir, $"{Checked(hash)}.partial");

    public bool Exists(string hash) => IsValidHash(hash) && File.Exists(GetPath(hash));

    // A file on this PC (copied or shared) cached as hash's blob - copied
    // beside it, then moved into place: a copy cut short (ClipLink quit, or
    // Windows shut down, halfway through a big file) mustn't leave a
    // truncated blob under the hash, which Exists would take for the file
    // and every device would then reject. Throws IOException /
    // UnauthorizedAccessException if it can't be done.
    public void CopyIn(string sourcePath, string hash)
    {
        string path = GetPath(hash);
        string copying = Path.Combine(storeDir, $"{hash}.{Guid.NewGuid():N}{CopyingSuffix}");
        try
        {
            File.Copy(sourcePath, copying);
            // File.Copy keeps a read-only source's attribute - and a
            // read-only blob can't be deleted (or replaced) later.
            File.SetAttributes(copying, FileAttributes.Normal);
            File.Move(copying, path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException && File.Exists(path))
        {
            // Cached meanwhile by another copy of the same file (and being
            // sent, so it can't be replaced) - same hash, same bytes.
        }
        finally
        {
            try { File.Delete(copying); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    public void Delete(string hash)
    {
        if (!IsValidHash(hash)) return;
        string path = GetPath(hash);
        if (File.Exists(path))
        {
            // (One cached by an older build from a read-only file is
            // read-only itself, which File.Delete refuses.)
            File.SetAttributes(path, FileAttributes.Normal);
            File.Delete(path);
        }
    }

    private static string Checked(string hash) =>
        IsValidHash(hash) ? hash : throw new ArgumentException("Not a file hash (64 hex digits).", nameof(hash));
}
