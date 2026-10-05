namespace ClipboardDaemon.Storage;

// One remembered deletion: the entry's Key() and when it was deleted (ms
// since the Unix epoch).
public record DeletedEntry(string Key, long DeletedAt);

// History entries the user deleted here ("tombstones"), so they stay
// deleted. Peers keep offering them - every connection's history_batch
// resends a peer's whole history - and without this each one would come
// straight back into history, and onto the clipboard. Local only: nothing
// about a deletion is ever sent to peers. Capped, dropping the oldest - a
// peer only resends what's still in its own (much smaller) history, so a
// long-ago deletion stops mattering.
public class DeletedEntries
{
    public const int MaxEntries = 2000;

    private readonly string deleted_path;
    private readonly List<DeletedEntry> entries = new List<DeletedEntry>(); // oldest first
    private readonly HashSet<string> keys = new HashSet<string>();
    // Checked from every connection's read loop, written from the app - same
    // reason as HistoryAccess's lock.
    private readonly object gate = new();

    public DeletedEntries(string? label = "")
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        deleted_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"deleted{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(deleted_path))
        {
            try
            {
                string json = File.ReadAllText(deleted_path);
                var loaded = System.Text.Json.JsonSerializer.Deserialize<List<DeletedEntry>>(json) ?? new List<DeletedEntry>();
                foreach (var entry in loaded.Where(e => !string.IsNullOrEmpty(e.Key)).OrderBy(e => e.DeletedAt))
                {
                    if (keys.Add(entry.Key)) entries.Add(entry);
                }
                TrimToLimit();
            }
            catch (System.Text.Json.JsonException ex)
            {
                // Deleted items may come back from peers, but that's better
                // than the daemon refusing to start.
                Console.WriteLine($"Could not load deleted history items ({ex.Message}) — starting with none.");
            }
        }
    }

    public bool Contains(string key)
    {
        lock (gate) { return keys.Contains(key); }
    }

    // Records these keys as deleted now. One already recorded keeps its
    // original time.
    public void Add(IEnumerable<string> newKeys)
    {
        lock (gate)
        {
            long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            bool changed = false;
            foreach (string key in newKeys)
            {
                if (keys.Add(key))
                {
                    entries.Add(new DeletedEntry(key, now));
                    changed = true;
                }
            }
            if (!changed) return;
            TrimToLimit();
            save();
        }
    }

    private void TrimToLimit()
    {
        int excess = entries.Count - MaxEntries;
        if (excess <= 0) return;
        foreach (var entry in entries.Take(excess)) keys.Remove(entry.Key);
        entries.RemoveRange(0, excess);
    }

    private void save()
    {
        try
        {
            File.WriteAllText(deleted_path, System.Text.Json.JsonSerializer.Serialize(entries));
        }
        catch (Exception ex)
        {
            // Still in effect for this run, just not remembered.
            Console.WriteLine($"Could not save deleted history items ({ex.Message}) — they may come back after a restart.");
        }
    }
}
