// Stands in for windows/ClipLink/Engine/Clipboard/ClipboardSync.cs (a WinForms
// clipboard watcher) in the engine tests: nothing is read from or written to
// the real clipboard. What the engine would put on the clipboard is recorded
// (Applied), and a copy on this PC can be simulated (Copy). Same public surface
// the engine uses.
namespace ClipboardDaemon.Clipboard;

using System.Collections.Concurrent;
using ClipboardDaemon.Storage;

public class ClipboardSync
{
    // The double of each engine, by its label.
    public static readonly ConcurrentDictionary<string, ClipboardSync> ByLabel = new();

    private readonly object gate = new();
    private readonly List<(string Content, string Type)> applied = new();

    public event Action<(string content, string type, string? sourceFilePath)>? ClipboardChanged;

    public ClipboardSync(FileStore fileStore, string label)
    {
        ByLabel[label] = this;
    }

    // What was put on the clipboard so far, in order.
    public List<(string Content, string Type)> Applied
    {
        get { lock (gate) { return applied.ToList(); } }
    }

    public void Watch() { }

    public void Stop() { }

    public void addToQueue(string content, string type = "text")
    {
        lock (gate) { applied.Add((content, type)); }
    }

    public string? ImageFileOnClipboard() => null;

    // The user copied this text on this PC.
    public void Copy(string text) => ClipboardChanged?.Invoke((text, "text", null));
}
