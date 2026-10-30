// STEP 8:
// Persist clipboard history locally (start with a simple JSON file on disk;
// a real database like SQLite can come later once the shape is proven out).

namespace ClipboardDaemon.Storage;

public class HistoryAccess
{
    public const int MaxHistoryItems = 25;

    private List<ClipboardEntry> inMemoryHistory = new List<ClipboardEntry>();
    private string history_path;
    private readonly FileStore fileStore;
    private readonly DeletedEntries deletedEntries;
    // Written from every connection's read loop plus the clipboard watcher.
    // Unlocked, two peers' history batches arriving together made two
    // saveHistory calls collide on the file; the IOException escaped the
    // message handler and ended that peer's connection with nothing logged.
    // Serializing history for a batch while another thread trimmed it could
    // also throw mid-enumeration.
    private readonly object gate = new();
    // Which history_batch each entry came in, for a batch that added
    // HistoryBatch.GroupMinItems or more: the UI shows those together as one
    // stack (also early, from the batch's history_head). In memory only
    // (nothing about it is saved or sent), so after a restart the history is
    // plain cards.
    private readonly BatchGroups groups = new();

    public HistoryAccess(string label, FileStore fileStore, DeletedEntries deletedEntries)
    {
        this.fileStore = fileStore;
        this.deletedEntries = deletedEntries;
        // build clipboard entry from file
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        history_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"history{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        if (File.Exists(history_path))
        {
            try
            {
                string json = File.ReadAllText(history_path);
                inMemoryHistory = System.Text.Json.JsonSerializer.Deserialize<List<ClipboardEntry>>(json) ?? new List<ClipboardEntry>();
            }
            catch (System.Text.Json.JsonException ex)
            {
                Console.WriteLine($"Could not load history ({ex.Message}) — starting with empty history.");
                inMemoryHistory = new List<ClipboardEntry>();
            }
        }
        else
        {
            inMemoryHistory = new List<ClipboardEntry>();
        }
    }
    // A snapshot - safe to serialize or enumerate while other threads add.
    public List<ClipboardEntry> GetHistory()
    {
        lock (gate) { return inMemoryHistory.ToList(); }
    }
    // The same, with which batch each entry came in (Key() -> batch id) and
    // how many entries a batch's head still promises (batch id -> size, while
    // its batch is on its way), taken together so a stack never shows up
    // half-known.
    public (List<ClipboardEntry> Entries, Dictionary<string, string> BatchOf, Dictionary<string, int> Expected) GetHistoryWithBatches()
    {
        lock (gate)
        {
            var (batchOf, expected) = groups.Snapshot();
            return (inMemoryHistory.ToList(), batchOf, expected);
        }
    }
    /*
    merges history from peer into local history
    return True if operation succeeded, False otherwise
    */
    public Boolean addToHistory(ClipboardEntry entry)
    {
        lock (gate)
        {
            if (inMemoryHistory.Contains(entry))
            {
                return false; // duplicate entry
            }
            // The engine checks isEntryDeleted before applying an incoming entry;
            // checked again here, under the lock, so one can't slip back in
            // between that check and its deletion.
            if (deletedEntries.Contains(entry.Key()))
            {
                return false;
            }
            inMemoryHistory.Add(entry);
            TrimToLimit();
            groups.Forget(inMemoryHistory);
            saveHistory();
            return true;
        }
    }

    // A whole history_batch in one step: one change to the list, one trim, one
    // write to disk. What it returns is what the caller needs to notify once.
    // Two or more new entries make a batch group, or join the one this
    // connection's history_head made (see BatchGroups).
    public HistoryBatch.MergeResult AddBatch(IReadOnlyList<ClipboardEntry> entries, object conn)
    {
        lock (gate)
        {
            // Deleted is checked again here, under the lock, as in addToHistory.
            var merged = groups.ApplyBatch(conn, inMemoryHistory, entries, e => deletedEntries.Contains(e.Key()), MaxHistoryItems);
            if (merged.Added.Count == 0 && merged.Evicted.Count == 0)
            {
                return merged;
            }
            foreach (var evicted in merged.Evicted)
            {
                DeleteBlobIfUnused(evicted);
            }
            saveHistory();
            return merged;
        }
    }

    // A peer's history_head (already verified): its newest entry goes into
    // history at once, and may start a provisional batch group. One write to
    // disk, and the caller notifies once.
    public BatchGroups.HeadResult AddHead(object conn, HistoryHead.Payload head)
    {
        lock (gate)
        {
            var result = groups.HeadReceived(conn, inMemoryHistory, head, key => deletedEntries.Contains(key), MaxHistoryItems);
            if (result.Added != null || result.Evicted.Count > 0)
            {
                foreach (var evicted in result.Evicted)
                {
                    DeleteBlobIfUnused(evicted);
                }
                saveHistory();
            }
            return result;
        }
    }

    // conn closed: a head still waiting for its batch is finished (the
    // expected size goes, a group of fewer than two is plain cards). Returns
    // whether the stacks changed.
    public bool EndHead(object conn)
    {
        lock (gate) { return groups.FinishHead(conn, inMemoryHistory); }
    }

    // Whether the user deleted this entry here (see DeletedEntries) - if so,
    // an incoming copy of it is ignored, not re-added or applied.
    public Boolean isEntryDeleted(ClipboardEntry entry)
    {
        return deletedEntries.Contains(entry.Key());
    }

    // Deletes one entry, by its Key(), for good - local history only, never
    // the clipboard or peers. Recorded as deleted first, so a peer re-sending
    // it can't bring it back; recorded even if it's already gone from here
    // (trimmed since the caller listed it), for the same reason. Returns the
    // removed entry (normally one), or nothing if it wasn't in history.
    public List<ClipboardEntry> removeFromHistory(string key)
    {
        lock (gate)
        {
            deletedEntries.Add(new[] { key });
            var removed = inMemoryHistory.Where(e => e.Key() == key).ToList();
            if (removed.Count == 0)
            {
                return removed;
            }
            inMemoryHistory.RemoveAll(e => e.Key() == key);
            foreach (var entry in removed)
            {
                DeleteBlobIfUnused(entry);
            }
            groups.Forget(inMemoryHistory);
            saveHistory();
            return removed;
        }
    }

    // Oldest-first eviction once we're over the cap. For a file entry, this
    // also deletes its backing blob from FileStore — otherwise disk usage
    // would grow forever even though the history record itself is capped.
    private void TrimToLimit()
    {
        foreach (var oldest in HistoryBatch.TrimOldest(inMemoryHistory, MaxHistoryItems))
        {
            DeleteBlobIfUnused(oldest);
        }
    }

    // Call after `removed` has left inMemoryHistory.
    private void DeleteBlobIfUnused(ClipboardEntry removed)
    {
        string? hash = FileHashOf(removed);
        if (hash != null)
        {
            DeleteFileIfUnused(hash);
        }
    }

    // FileStore is keyed by content hash, so one blob backs every entry for
    // the same file (copied twice, say) - it's only deleted once no entry
    // left in history uses it. Also used when a file's bytes finish arriving
    // after its entry was deleted. Under the lock, so an entry for the same
    // file can't be added between the check and the delete. Returns whether
    // it was deleted.
    public Boolean DeleteFileIfUnused(string hash)
    {
        lock (gate)
        {
            if (inMemoryHistory.Any(e => string.Equals(FileHashOf(e), hash, StringComparison.OrdinalIgnoreCase)))
            {
                return false;
            }
            try
            {
                fileStore.Delete(hash);
                return true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Open right now - being streamed to a peer (StreamFileToPeer
                // deletes it once it's done), or applied. Left behind rather
                // than failing the history change.
                Console.WriteLine($"Could not delete stored file {hash[..Math.Min(12, hash.Length)]}... ({ex.Message}) — leaving it.");
                return false;
            }
        }
    }

    // The FileStore hash a file entry's descriptor points at; null for any
    // other entry, or a malformed descriptor (nothing coherent to clean up).
    public static string? FileHashOf(ClipboardEntry entry)
    {
        if (entry.Type != "file")
        {
            return null;
        }
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<FilePayload>(entry.Content)?.FileHash;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    public Boolean saveHistory()
    {
        lock (gate)
        {
            string json = System.Text.Json.JsonSerializer.Serialize(inMemoryHistory);
            File.WriteAllText(history_path, json);
            return true;
        }
    }
    // "Clear synced history": every current entry is recorded as deleted
    // first (so peers' history batches don't just refill it), then history
    // and the file blobs it used are cleared. Returns what was removed.
    public List<ClipboardEntry> clearHistory()
    {
        lock (gate)
        {
            var removed = inMemoryHistory.ToList();
            deletedEntries.Add(removed.Select(e => e.Key()));
            inMemoryHistory.Clear();
            foreach (var entry in removed)
            {
                DeleteBlobIfUnused(entry);
            }
            groups.Clear();
            saveHistory();
            return removed;
        }
    }

    public Boolean isEntryInHistory(ClipboardEntry entry)
    {
        lock (gate) { return inMemoryHistory.Contains(entry); }
    }
}
