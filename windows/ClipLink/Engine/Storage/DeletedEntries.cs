namespace ClipboardDaemon.Storage;

// One remembered deletion: the entry's Key() and when it was deleted (ms
// since the Unix epoch).
public record DeletedEntry(string Key, long DeletedAt);

// History entries the user deleted ("tombstones"), here or on another paired
// device, so they stay deleted. Peers keep offering them - a version 1 peer's
// history_batch resends its whole history - and without this each one would
// come straight back into history, and onto the clipboard. The most recent
// ones are sent to version 2 peers in every history_head (see Recent), which
// is how a device that was offline when something was deleted hears of it.
// Capped, dropping the oldest - a peer only resends what's still in its own
// (much smaller) history, so a long-ago deletion stops mattering.
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
        // From its backup when the file is corrupt (see SafeFile). With
        // neither, deleted items may come back from peers, but that's better
        // than the daemon refusing to start. One that can't be opened (held by
        // a virus scanner as Windows signs in) stops the start, as it always
        // did: started empty, the next save would write over every tombstone.
        var loaded = SafeFile.Read(deleted_path,
            json => System.Text.Json.JsonSerializer.Deserialize<List<DeletedEntry>>(json) ?? new List<DeletedEntry>(),
            "deleted history items", throwIfUnreadable: true);
        if (loaded != null)
        {
            foreach (var entry in loaded.Where(e => e != null && !string.IsNullOrEmpty(e.Key)).OrderBy(e => e.DeletedAt))
            {
                if (keys.Add(entry.Key)) entries.Add(entry);
            }
            TrimToLimit();
        }
    }

    public bool Contains(string key)
    {
        lock (gate) { return keys.Contains(key); }
    }

    // The keys deleted most recently, the latest first (at most count).
    public List<string> Recent(int count)
    {
        lock (gate) { return entries.AsEnumerable().Reverse().Take(count).Select(entry => entry.Key).ToList(); }
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
            // Swapped in whole: cut off midway, every tombstone was lost and
            // deleted items came back from the peers.
            SafeFile.Write(deleted_path, System.Text.Json.JsonSerializer.Serialize(entries));
        }
        catch (Exception ex)
        {
            // Still in effect for this run, just not remembered.
            Console.WriteLine($"Could not save deleted history items ({ex.Message}) — they may come back after a restart.");
        }
    }
}
