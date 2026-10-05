using System.Security.Cryptography;

namespace ClipboardDaemon.Storage;

// Content-addressed local storage for synced files — keyed by the SHA256 hash
// of the file's bytes (hex string), so identical content is never stored
// twice, and evicting a history entry can reliably find (and delete) the
// exact blob it refers to, without any other bookkeeping.
public class FileStore
{
    private readonly string storeDir;
    private const string CopyingSuffix = ".copying";
    private const string PartialSuffix = ".partial";
    private const int CopyBufferSize = 1024 * 1024;

    // The SHA-256 of no bytes at all: every 0-byte file's hash.
    private const string EmptyFileHash = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";

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
    public string GetTempPath(string hash) => Path.Combine(storeDir, $"{Checked(hash)}{PartialSuffix}");

    public bool Exists(string hash) => IsValidHash(hash) && File.Exists(GetPath(hash));

    // Whether hash is the SHA-256 of no bytes (in either case).
    public static bool IsEmptyFileHash(string hash) => string.Equals(hash, EmptyFileHash, StringComparison.OrdinalIgnoreCase);

    // Whether a file entry's payload is a 0-byte file: size 0, and the
    // SHA-256 of no bytes as its hash.
    public static bool IsEmptyFile(FilePayload payload) => payload.FileSize == 0 && IsEmptyFileHash(payload.FileHash);

    // A 0-byte file's blob (IsEmptyFile), made here rather than received:
    // there are no bytes to send, and older builds send no chunk at all for
    // one, so asking a peer for it never ends. Nothing if it's here already.
    // Throws IOException / UnauthorizedAccessException if it can't be made.
    public void CreateEmpty(FilePayload payload)
    {
        if (!IsEmptyFile(payload)) throw new ArgumentException("Not a 0-byte file.", nameof(payload));
        string path = GetPath(payload.FileHash);
        try
        {
            using (new FileStream(path, FileMode.CreateNew, FileAccess.Write)) { }
        }
        catch (IOException) when (File.Exists(path))
        {
            // Made or received meanwhile - the same no bytes.
        }
    }

    // The hash of every blob stored here, as its file is named.
    public List<string> StoredHashes() =>
        Directory.EnumerateFiles(storeDir).Select(file => Path.GetFileName(file)).Where(IsValidHash).ToList();

    // Deletes every partly received file (GetTempPath) whose transfer
    // isReceiving says isn't running - left by one cut short (the peer went
    // away, or ClipLink quit, before its last chunk), which nothing ever
    // finishes or deletes. Best effort. Returns how many went.
    public int DeletePartials(Func<string, bool> isReceiving)
    {
        int deleted = 0;
        foreach (string partial in Directory.EnumerateFiles(storeDir, "*" + PartialSuffix).ToList())
        {
            string hash = Path.GetFileNameWithoutExtension(partial);
            if (!IsValidHash(hash) || isReceiving(hash)) continue;
            try
            {
                File.Delete(partial);
                deleted++;
            }
            catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        return deleted;
    }

    // A file on this PC (copied or shared), read from source (see
    // LocalFiles.CopyInto), cached as hash's blob - copied beside it, then
    // moved into place: a copy cut short (ClipLink quit, or Windows shut
    // down, halfway through a big file) mustn't leave a truncated blob under
    // the hash, which Exists would take for the file and every device would
    // then reject. Hashed as it's copied, and only stored if that's hash: the
    // file can be written while it's read (a file still being written, or
    // saved again after it was hashed), and other bytes under hash would be
    // rejected by every device - and kept here, for good, for every later
    // copy of the file (Exists). False then, with nothing stored. Throws
    // IOException / UnauthorizedAccessException if it can't be done.
    public bool CopyIn(Stream source, string hash)
    {
        string path = GetPath(hash);
        string copying = Path.Combine(storeDir, $"{hash}.{Guid.NewGuid():N}{CopyingSuffix}");
        try
        {
            using (var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                using (var target = new FileStream(copying, FileMode.CreateNew, FileAccess.Write))
                {
                    byte[] buffer = new byte[CopyBufferSize];
                    int read;
                    while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        hasher.AppendData(buffer, 0, read);
                        target.Write(buffer, 0, read);
                    }
                }
                if (!string.Equals(Convert.ToHexString(hasher.GetHashAndReset()), hash, StringComparison.OrdinalIgnoreCase)) return false;
            }
            File.Move(copying, path, overwrite: true);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException && File.Exists(path))
        {
            // Cached meanwhile by another copy of the same file (and being
            // sent, so it can't be replaced) - same hash, same bytes.
            return true;
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
