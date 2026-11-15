namespace ClipboardDaemon.Storage;

// Writing a whole store file so a crash, a power cut or a full disk midway
// never leaves it cut short: the new contents go to "<file>.tmp" first,
// flushed to disk, and only then take the file's place - the previous version
// kept as "<file>.bak". Reading falls back on that copy when the file itself
// can't be read. The file keeps its name and format, so older builds read it
// as before (they ignore the .tmp and .bak next to it).
public static class SafeFile
{
    public static void Write(string path, string text) => Write(path, stream =>
    {
        using var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false), leaveOpen: true);
        writer.Write(text);
    });

    // write puts the file's whole new contents in the stream it's given -
    // straight from a serializer, say, without the text as one big string.
    public static void Write(string path, Action<Stream> write)
    {
        string temp = path + ".tmp";
        using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None, 64 * 1024))
        {
            write(stream);
            stream.Flush(flushToDisk: true);
        }
        if (File.Exists(path))
        {
            try
            {
                File.Replace(temp, path, path + ".bak", ignoreMetadataErrors: true);
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PlatformNotSupportedException)
            {
                // A file system without Replace, or the backup is locked: the
                // new version still goes in, just without a backup this time.
            }
        }
        File.Move(temp, path, overwrite: true);
    }

    // The file's contents made into a T by parse (which throws JsonException
    // for text it can't use), else the backup's, else null. A file that
    // doesn't parse is kept beside it as "<file>.corrupt" before anything can
    // overwrite it; one that can't be opened (a virus scanner holding it as
    // the app starts) is tried again a few times first. throwIfUnreadable:
    // a file that still can't be opened throws IOException instead - for a
    // store whose loss is worse than not starting (the trust store: starting
    // empty, the next save would have written over every pairing).
    public static T? Read<T>(string path, Func<string, T> parse, string what, bool throwIfUnreadable = false) where T : class =>
        ReadStream(path, stream =>
        {
            using var reader = new StreamReader(stream, System.Text.Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
            return parse(reader.ReadToEnd());
        }, what, throwIfUnreadable);

    // Read, with parse reading the file's stream itself (a deserializer):
    // a big file is never one string as well.
    public static T? ReadStream<T>(string path, Func<Stream, T> parse, string what, bool throwIfUnreadable = false) where T : class
    {
        var (loaded, unreadable) = TryRead(path, parse, what, keepCorrupt: true);
        if (loaded != null) return loaded;
        // Locked, not broken: its backup is a version behind, and saving
        // that would lose the newest change for good.
        if (unreadable != null && throwIfUnreadable) throw new IOException($"Couldn't open {what}: {unreadable.Message}", unreadable);
        string backup = path + ".bak";
        if (!File.Exists(backup)) return null;
        var (restored, _) = TryRead(backup, parse, what, keepCorrupt: false);
        if (restored != null) Console.WriteLine($"Restored {what} from its backup.");
        return restored;
    }

    // The parsed file, or null with - when it couldn't be opened at all -
    // why not.
    private static (T? value, Exception? unreadable) TryRead<T>(string path, Func<Stream, T> parse, string what, bool keepCorrupt) where T : class
    {
        if (!File.Exists(path)) return (null, null);
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024);
                return (parse(stream), null);
            }
            catch (System.Text.Json.JsonException ex)
            {
                Console.WriteLine($"Could not read {what} ({ex.Message}).");
                if (keepCorrupt)
                {
                    try { File.Copy(path, path + ".corrupt", overwrite: true); }
                    catch (Exception copyEx) when (copyEx is IOException or UnauthorizedAccessException) { }
                }
                return (null, null);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                if (attempt < 3)
                {
                    Thread.Sleep(200);
                    continue;
                }
                Console.WriteLine($"Could not open {what} ({ex.Message}).");
                return (null, ex);
            }
        }
    }
}
