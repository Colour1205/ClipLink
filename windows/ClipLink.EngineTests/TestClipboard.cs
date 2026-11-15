// Stands in for windows/ClipLink/Engine/Clipboard/ClipboardSync.cs (a WinForms
// clipboard watcher) in the engine tests: nothing is read from or written to
// the real clipboard. What the engine would put on the clipboard is recorded
// (Applied), and a copy on this PC can be simulated (Copy, CopyFiles). Same
// public surface the engine uses, and the same LastWrite bookkeeping: a write
// records what it wrote, a copy of exactly that is not sent again.
namespace ClipboardDaemon.Clipboard;

using System.Collections.Concurrent;
using ClipboardDaemon.Storage;

public class ClipboardSync
{
    // The double of each engine, by its label.
    public static readonly ConcurrentDictionary<string, ClipboardSync> ByLabel = new();

    private readonly object gate = new();
    private readonly List<(string Content, string Type)> applied = new();
    private readonly LastWrite lastWrite = new();
    private uint sequence = 1;

    public event Action<(string content, string type, string? sourceFilePath)>? ClipboardChanged;
    public event Action<IReadOnlyList<(string content, string path)>>? FilesCopied;

    public ClipboardSync(FileStore fileStore, string label)
    {
        ByLabel[label] = this;
    }

    // What was put on the clipboard so far, in order.
    public List<(string Content, string Type)> Applied
    {
        get { lock (gate) { return applied.ToList(); } }
    }

    public uint Sequence
    {
        get { lock (gate) { return sequence; } }
    }

    public bool Holds(string? print) => lastWrite.Holds(print);

    public void Watch() { }

    public void Stop() { }

    public void addToQueue(string content, string type = "text", bool fromElsewhere = false)
    {
        lock (gate)
        {
            applied.Add((content, type));
            sequence++;
            lastWrite.Wrote(new[] { ContentPrint.Of(content, type) }, sequence);
        }
    }

    public string? ImageFileOnClipboard() => null;

    // The user copied this text on this PC. Not sent if it is what ClipLink
    // last wrote or saw, as the real watcher does.
    public void Copy(string text)
    {
        string print = ContentPrint.Text(text);
        bool already;
        lock (gate)
        {
            sequence++;
            already = lastWrite.Holds(print);
            lastWrite.Classified(new[] { print });
        }
        if (!already) ClipboardChanged?.Invoke((text, "text", null));
    }

    // The user copied these files on this PC (each one's FilePayload JSON and path).
    public void CopyFiles(IReadOnlyList<(string content, string path)> files)
    {
        lock (gate) { sequence++; }
        FilesCopied?.Invoke(files);
    }

    // Something else was written to the clipboard (another app, the user).
    public void Touch()
    {
        lock (gate) { sequence++; }
    }
}
