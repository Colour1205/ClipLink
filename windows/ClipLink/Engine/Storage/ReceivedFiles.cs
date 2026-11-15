using System.Security.Cryptography;
using System.Text.RegularExpressions;
using ClipboardDaemon.Engine;

namespace ClipboardDaemon.Storage;

// %APPDATA%\ClipboardDaemon\ReceivedFiles: where something another device
// sent is saved so it can go on the clipboard as a file too (Explorer only
// pastes files). A received file is the user's to keep. A received image is
// only ClipLink's copy of a synced-history item, so those - "ClipLink image
// <hash>.<ext>", exactly as SaveImage names them - are capped at MaxImages
// and deleted with the history. The app's own label keeps its images here,
// next to the received files; any other label (a test copy) keeps them in
// a folder of its own, receivedimages<label>, so one copy's cap or Clear
// never deletes another's images.
public static class ReceivedFiles
{
    private const string ImagePrefix = "ClipLink image ";
    private const int MaxImages = 50;

    // The names SaveImage writes: the hash, and " (n)" if a different file
    // already had that name. Nothing else counts as a received image - not
    // a received file that merely starts "ClipLink image " (say an image
    // opened from Synced, then copied as a file on another PC).
    private static readonly Regex ImageName = new(@"^ClipLink image [0-9A-F]{12}( \(\d+\))?\.[A-Za-z0-9]+$", RegexOptions.CultureInvariant);

    private static string FolderPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "ClipboardDaemon", "ReceivedFiles");

    // Where `label`'s received images go (see above).
    private static string ImagesPath(string label) => label == ClipLinkEngine.DefaultLabel
        ? FolderPath
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClipboardDaemon", $"receivedimages{label}");

    public static string Folder()
    {
        string dir = FolderPath;
        Directory.CreateDirectory(dir);
        return dir;
    }

    // Puts a file entry's bytes - source, its blob in the FileStore - in the
    // received files folder under the sender's name made safe (only as a
    // name: joined on as it came, a rooted or "..\" one put the file
    // anywhere), and returns where. A copy already there that holds exactly
    // these bytes is used as it is: applying the same file again (Copy in
    // Synced, a retry, the next reconnect) used to write another full copy -
    // "name (1).ext", "name (2).ext"... - every time. fromElsewhere: another
    // device's file, which gets the Mark of the Web as a download would, so
    // pasted and opened from Explorer it gets SmartScreen and Office's
    // Protected View (as a copy opened from Synced does). Throws IOException /
    // UnauthorizedAccessException if it can't be copied.
    public static string SaveFile(string source, string? fileName, string fileHash, bool fromElsewhere)
    {
        string dir = Folder();
        long length = new FileInfo(source).Length;
        var (path, exists) = FileNames.CopyPath(dir, FileNames.Safe(fileName, "file"), existing => HasHash(existing, fileHash, length));
        if (!exists)
        {
            File.Copy(source, path);
        }
        if (fromElsewhere)
        {
            MarkAsFromElsewhere(path);
        }
        return path;
    }

    // The Mark of the Web (zone 3, the internet). Best effort: some drives
    // can't hold it.
    private static void MarkAsFromElsewhere(string path)
    {
        try
        {
            File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            Console.WriteLine($"couldn't mark {Path.GetFileName(path)} as downloaded: {ex.Message}");
        }
    }

    // Whether path holds exactly the bytes with this SHA-256 (same size, same
    // hash) - read while an app may have it open, hence the sharing.
    private static bool HasHash(string path, string sha256Hex, long length)
    {
        try
        {
            if (new FileInfo(path).Length != length) return false;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return Convert.ToHexString(SHA256.HashData(stream)).Equals(sha256Hex, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // Saves an image `label` received as "ClipLink image <first 12 hex
    // digits of its SHA-256>.<ext>" and returns the path - the existing
    // file's if one already holds exactly these bytes, so applying the same
    // image again (a retry while the clipboard was busy, Copy in Synced)
    // writes nothing. Null if it couldn't be saved.
    public static string? SaveImage(byte[] bytes, string label)
    {
        string dir = ImagesPath(label);
        try
        {
            Directory.CreateDirectory(dir);
            string name = $"{ImagePrefix}{Convert.ToHexString(SHA256.HashData(bytes))[..12]}{ImageFiles.Extension(bytes)}";
            var (path, exists) = FileNames.CopyPath(dir, name, existing => HasBytes(existing, bytes));
            if (exists)
            {
                // In use again: the newest, as far as trimming goes.
                try { File.SetLastWriteTimeUtc(path, DateTime.UtcNow); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                return path;
            }
            File.WriteAllBytes(path, bytes);
            TrimImages(dir, keep: path);
            return path;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"couldn't save the received image in {dir}: {ex.Message}");
            return null;
        }
    }

    // "Clear synced history": every image `label` received goes too - but
    // keep, the one the clipboard refers to now (ClipboardSync.
    // ImageFileOnClipboard): a clear leaves the clipboard alone, and pasting
    // it into a folder needs the file. Trimmed like any other later. Best
    // effort - one an app still has open stays.
    public static void DeleteImages(string label, string? keep)
    {
        string dir = ImagesPath(label);
        try
        {
            if (!Directory.Exists(dir)) return;
            foreach (var file in Images(dir).ToList())
            {
                if (keep != null && string.Equals(file.FullName, Path.GetFullPath(keep), StringComparison.OrdinalIgnoreCase)) continue;
                TryDelete(file.FullName);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"couldn't delete the received images in {dir}: {ex.Message}");
        }
    }

    // Keeps the newest MaxImages received images in dir by last write -
    // always including the one just written - and deletes the rest. Nothing
    // else in the folder is touched.
    private static void TrimImages(string dir, string keep)
    {
        try
        {
            var older = Images(dir)
                .Where(file => !string.Equals(file.FullName, keep, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(file => file.LastWriteTimeUtc)
                .Skip(MaxImages - 1)
                .ToList();
            foreach (var file in older)
            {
                TryDelete(file.FullName);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"couldn't trim the received images in {dir}: {ex.Message}");
        }
    }

    private static IEnumerable<FileInfo> Images(string dir) =>
        new DirectoryInfo(dir).EnumerateFiles(ImagePrefix + "*")
            .Where(file => ImageName.IsMatch(file.Name));

    private static bool HasBytes(string path, byte[] bytes)
    {
        try
        {
            return new FileInfo(path).Length == bytes.Length && File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Open in an app - it goes next time.
        }
    }
}
