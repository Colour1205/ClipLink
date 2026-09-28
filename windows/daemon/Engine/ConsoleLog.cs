using System.Text;

namespace ClipboardDaemon.Engine;

// The engine logs with Console.WriteLine, which goes nowhere in a windowed
// app. RedirectToFile sends Console output (and errors) to a log file
// instead, each line timestamped, rolled over to "<name>.1.log" once it
// passes maxBytes so it can't grow without bound. Call once at startup.
public static class ConsoleLog
{
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipLink", "logs", "cliplink.log");

    // Returns the log file's path, or null if it couldn't be opened (Console
    // output is then left as it was).
    public static string? RedirectToFile(string? path = null, long maxBytes = 5 * 1024 * 1024)
    {
        path ??= DefaultPath;
        try
        {
            var writer = new RollingLogWriter(path, maxBytes);
            Console.SetOut(writer);
            Console.SetError(writer);
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private sealed class RollingLogWriter : TextWriter
    {
        private readonly string path;
        private readonly long maxBytes;
        private readonly object gate = new();
        private readonly StringBuilder line = new();
        private FileStream stream;

        public RollingLogWriter(string path, long maxBytes)
        {
            this.path = path;
            this.maxBytes = maxBytes;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            stream = Open();
        }

        public override Encoding Encoding => Encoding.UTF8;

        // Shared, so the log can be read (or tailed) while the app runs.
        private FileStream Open() => new(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);

        public override void Write(char value)
        {
            lock (gate)
            {
                if (value == '\n') Flush(line);
                else if (value != '\r') line.Append(value);
            }
        }

        public override void Write(string? value)
        {
            if (value == null) return;
            lock (gate)
            {
                foreach (char c in value) Write(c);
            }
        }

        public override void WriteLine(string? value)
        {
            lock (gate)
            {
                Write(value);
                Write('\n');
            }
        }

        private void Flush(StringBuilder pending)
        {
            byte[] bytes = Encoding.UTF8.GetBytes($"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {pending}{Environment.NewLine}");
            pending.Clear();
            try
            {
                if (stream.Length + bytes.Length > maxBytes && stream.Length > 0)
                {
                    stream.Dispose();
                    File.Move(path, Path.ChangeExtension(path, ".1.log"), overwrite: true);
                    stream = Open();
                }
                stream.Write(bytes);
                stream.Flush();
            }
            catch (Exception)
            {
                // A log line isn't worth failing whatever was being logged.
                // (If the roll-over failed half way, the next line reopens.)
                try { if (!stream.CanWrite) stream = Open(); } catch (Exception) { }
            }
        }
    }
}
