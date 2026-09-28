namespace ClipboardDaemon.Storage;

// Content-addressed local storage for synced files — keyed by the SHA256 hash
// of the file's bytes (hex string), so identical content is never stored
// twice, and evicting a history entry can reliably find (and delete) the
// exact blob it refers to, without any other bookkeeping.
public class FileStore
{
    private readonly string storeDir;

    public FileStore(string label)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        storeDir = Path.Combine(app_data_dir, "ClipboardDaemon", $"filestore{label}");
        Directory.CreateDirectory(storeDir);
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

    public void Delete(string hash)
    {
        if (!IsValidHash(hash)) return;
        string path = GetPath(hash);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    private static string Checked(string hash) =>
        IsValidHash(hash) ? hash : throw new ArgumentException("Not a file hash (64 hex digits).", nameof(hash));
}
