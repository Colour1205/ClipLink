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
    // Where entries sit on the Synced page (the session blocks, newest on top)
    // and which sync each came in, for a sync that added
    // HistoryBatch.GroupMinItems or more: the UI shows those together as one
    // stack (also early, from the batch's history_head, or from the first
    // answer of a version 2 sync). In memory only (nothing about it is saved
    // or sent), so after a restart the history is plain cards by time.
    private readonly BatchGroups groups = new();
    // Each entry's print (ContentPrint.Key), by Key(): a picture's means
    // decoding and hashing megabytes, and the Synced page lists the history
    // on every change. Entries that left history are dropped from it.
    private readonly Dictionary<string, string?> printOf = new();
    // Entries the Synced page hid as twins of a card above them (see
    // GetHistoryWithBatches), so one that shows again later - its visible twin
    // was deleted or trimmed - isn't announced as if it had just arrived.
    private readonly HashSet<string> everHidden = new();
    // The history file is written off the lock, by one writer at a time (see
    // saveHistory): the newest snapshot waiting to be written, and whether a
    // writer is running. Under saveGate.
    private readonly object saveGate = new();
    private List<ClipboardEntry>? unsaved;
    private bool writing;
    private Task saving = Task.CompletedTask;

    public HistoryAccess(string label, FileStore fileStore, DeletedEntries deletedEntries)
    {
        this.fileStore = fileStore;
        this.deletedEntries = deletedEntries;
        // build clipboard entry from file
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        history_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"history{label}.json");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        // (Also from its backup when the file is corrupt - see SafeFile. One
        // that can't be opened stops the start, as it always did: started
        // empty, the next save would write over the whole history.)
        // Parsed from the file's stream: with pictures inline it can be tens
        // of MB, which as one string was as much again, twice over (UTF-16).
        inMemoryHistory = SafeFile.ReadStream(history_path,
            stream => System.Text.Json.JsonSerializer.Deserialize<List<ClipboardEntry>>(stream) ?? new List<ClipboardEntry>(),
            "history", throwIfUnreadable: true) ?? new List<ClipboardEntry>();
    }
    // A snapshot - safe to serialize or enumerate while other threads add.
    public List<ClipboardEntry> GetHistory()
    {
        lock (gate) { return inMemoryHistory.ToList(); }
    }
    // What the Synced page shows: the history in display order (see
    // BatchGroups.Order), with which batch each entry came in (Key() -> batch
    // id), how many entries a batch's head or sync still promises (batch id ->
    // size, while the rest is on its way) and which entries arrived quietly,
    // taken together so a stack never shows up half-known.
    public sealed record HistoryView(List<ClipboardEntry> Entries, Dictionary<string, string> BatchOf,
        Dictionary<string, int> Expected, HashSet<string> Quiet);

    //
    // One card per content: an entry whose content a card above it already has
    // is left out (ContentPrint.Fold) - the topmost, so what just arrived
    // wins - and so are its stack and quiet marks; a stack left with fewer
    // than two cards (and nothing more on its way) is plain cards. The history
    // itself keeps every twin.
    public HistoryView GetHistoryWithBatches()
    {
        lock (gate)
        {
            var (batchOf, expected) = groups.Snapshot();
            var quiet = groups.QuietKeys();
            var (visible, hidden) = ContentPrint.Fold(groups.Order(inMemoryHistory), PrintOf);
            if (hidden.Count > 0)
            {
                everHidden.UnionWith(hidden);
                ContentPrint.DropFolded(batchOf, expected, hidden);
                quiet.ExceptWith(hidden);
            }
            quiet.UnionWith(visible.Select(entry => entry.Key()).Where(everHidden.Contains));
            return new HistoryView(visible, batchOf, expected, quiet);
        }
    }

    // The keys of every entry with the same content as the entry with this
    // key - itself included - which is one card on the Synced page. Just the
    // key when it isn't in history, or its content has no print.
    public List<string> TwinKeys(string key)
    {
        lock (gate)
        {
            var entry = inMemoryHistory.FirstOrDefault(e => e.Key() == key);
            string? print = entry != null ? PrintOf(entry) : null;
            if (print == null) return new List<string> { key };
            return inMemoryHistory.Where(e => PrintOf(e) == print).Select(e => e.Key()).Distinct().ToList();
        }
    }

    // Whether one of the n newest entries (see ContentPrint.Newest) has one of
    // these prints: the content is what the devices already have on top.
    public bool NewestHas(IEnumerable<string> prints, int n) => prints.Any(NewestPrints(n).Contains);

    // The prints of the n newest entries.
    public HashSet<string> NewestPrints(int n)
    {
        lock (gate)
        {
            return ContentPrint.Newest(inMemoryHistory, n).Select(PrintOf).OfType<string>().ToHashSet();
        }
    }

    // An entry that arrived is not announced (it's listed all the same): what
    // ClipLink put on the clipboard last already is that content.
    public void MarkQuiet(string key)
    {
        lock (gate) { groups.MarkQuiet(key); }
    }

    // Under the lock.
    private string? PrintOf(ClipboardEntry entry)
    {
        string key = entry.Key();
        if (!printOf.TryGetValue(key, out string? print))
        {
            print = ContentPrint.Key(entry);
            printOf[key] = print;
        }
        return print;
    }

    // Under the lock, after entries left history.
    private void ForgetPrints()
    {
        if (printOf.Count <= inMemoryHistory.Count && everHidden.Count == 0) return;
        var present = inMemoryHistory.Select(e => e.Key()).ToHashSet();
        foreach (string key in printOf.Keys.Where(key => !present.Contains(key)).ToList()) printOf.Remove(key);
        everHidden.IntersectWith(present);
    }

    // The head this device sends a version 2 peer on connect: the keys and times
    // of its history, and its latest tombstones. Taken under the lock a delete
    // holds, so a key is never in both lists.
    public HistoryHead.SyncHead SyncHead()
    {
        lock (gate)
        {
            return HistoryHead.ForSync(inMemoryHistory, deletedEntries.Recent(HistoryHead.MaxDeleted));
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
            // Older than everything a full history keeps: the trim would drop
            // it at once (a live item ends the protection of the convenience
            // item, so nothing is spared for it), so it never is in history -
            // not listed, and not applied either (the engine adds first).
            if (HistoryBatch.TrimmedAtOnce(inMemoryHistory, entry, MaxHistoryItems))
            {
                return false;
            }
            inMemoryHistory.Add(entry);
            groups.Arrived(entry.Key());
            TrimToLimit();
            groups.Forget(inMemoryHistory);
            ForgetPrints();
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
            ForgetPrints();
            saveHistory();
            return merged;
        }
    }

    // The answer to one of a version 2 peer's history_requests as ONE unit, like
    // AddBatch: see BatchGroups.ApplyAnswer. last: no request of conn is open
    // any more.
    public HistoryBatch.MergeResult AddAnswer(IReadOnlyList<ClipboardEntry> entries, object conn, bool convenience, bool last)
    {
        lock (gate)
        {
            var merged = groups.ApplyAnswer(conn, inMemoryHistory, entries, e => deletedEntries.Contains(e.Key()), MaxHistoryItems, convenience, last);
            if (merged.Added.Count == 0 && merged.Evicted.Count == 0)
            {
                return merged;
            }
            foreach (var evicted in merged.Evicted)
            {
                DeleteBlobIfUnused(evicted);
            }
            ForgetPrints();
            saveHistory();
            return merged;
        }
    }

    // The late answer to a request that had expired, as ONE unit, quietly: see
    // BatchGroups.ApplyLate.
    public HistoryBatch.MergeResult AddLate(IReadOnlyList<ClipboardEntry> entries)
    {
        lock (gate)
        {
            var merged = groups.ApplyLate(inMemoryHistory, entries, e => deletedEntries.Contains(e.Key()), MaxHistoryItems);
            if (merged.Added.Count == 0 && merged.Evicted.Count == 0)
            {
                return merged;
            }
            foreach (var evicted in merged.Evicted)
            {
                DeleteBlobIfUnused(evicted);
            }
            ForgetPrints();
            saveHistory();
            return merged;
        }
    }

    // conn's version 2 sync now waits for size more entries (see
    // BatchGroups.BeginSync).
    public void BeginSync(object conn, int size)
    {
        lock (gate) { groups.BeginSync(conn, size); }
    }

    // conn's version 2 sync waits for nothing any more (a request timed out, or
    // conn closed). Returns whether the stacks changed.
    public bool EndSync(object conn)
    {
        lock (gate) { return groups.EndSync(conn, inMemoryHistory); }
    }

    // Finishes the version 1 heads whose batch is more than maxAgeMs overdue.
    // Returns whether the stacks changed.
    public bool ExpireHeads(long nowMs, long maxAgeMs)
    {
        lock (gate) { return groups.ExpireHeads(inMemoryHistory, nowMs, maxAgeMs); }
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
                ForgetPrints();
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

    public bool IsKeyDeleted(string key) => deletedEntries.Contains(key);

    // Deletes one entry, by its Key(), for good - local history only, never
    // the clipboard (the engine tells the peers). See RemoveMany.
    public List<ClipboardEntry> removeFromHistory(string key) => RemoveMany(new[] { key });

    // Deletes entries, by their Key(), for good. Recorded as deleted first, so a
    // peer re-sending one can't bring it back; recorded even if it's already
    // gone from here (trimmed since the caller listed it, or never here), for the
    // same reason. Returns the removed entries (normally one per key), or nothing
    // if none was in history. A stack that loses its front card has its next
    // entry in front (see BatchGroups.Order); one left with a single entry is a
    // single card.
    public List<ClipboardEntry> RemoveMany(IReadOnlyCollection<string> keys)
    {
        lock (gate)
        {
            deletedEntries.Add(keys);
            var gone = new HashSet<string>(keys);
            var removed = inMemoryHistory.Where(e => gone.Contains(e.Key())).ToList();
            if (removed.Count == 0)
            {
                return removed;
            }
            inMemoryHistory.RemoveAll(removed.Contains);
            foreach (var entry in removed)
            {
                DeleteBlobIfUnused(entry);
            }
            groups.Forget(inMemoryHistory);
            ForgetPrints();
            saveHistory();
            return removed;
        }
    }

    // Oldest-first eviction once we're over the cap. For a file entry, this
    // also deletes its backing blob from FileStore — otherwise disk usage
    // would grow forever even though the history record itself is capped.
    private void TrimToLimit()
    {
        foreach (var oldest in HistoryBatch.TrimOldest(inMemoryHistory, MaxHistoryItems, groups.ProtectedKey))
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

    // Written whole and swapped in (see SafeFile): a crash or a full disk
    // midway used to leave a cut-off file, and the next start an empty history.
    //
    // Only a snapshot of the list is taken here, under the lock; the file is
    // written by a background writer, serialized straight into it (Wire's
    // JSON, see Wire.Json - the same entries, as any build reads them). The
    // whole history, pictures and all, used to be made into one string and
    // written with the lock held - and the UI thread takes that lock to list
    // the history, so the window froze for as long as a write took. One
    // writer at a time, and it always writes the newest snapshot: an older
    // one waiting is skipped, never written over a newer one. Flush waits
    // for it.
    public Boolean saveHistory()
    {
        lock (gate)
        {
            var snapshot = inMemoryHistory.ToList();
            lock (saveGate)
            {
                unsaved = snapshot;
                if (!writing)
                {
                    writing = true;
                    saving = Task.Run(WriteUnsaved);
                }
            }
            return true;
        }
    }

    private void WriteUnsaved()
    {
        while (true)
        {
            List<ClipboardEntry>? snapshot;
            lock (saveGate)
            {
                snapshot = unsaved;
                unsaved = null;
                if (snapshot == null)
                {
                    writing = false;
                    return;
                }
            }
            try
            {
                SafeFile.Write(history_path, stream => System.Text.Json.JsonSerializer.Serialize(stream, snapshot, Networking.Wire.Json));
            }
            catch (Exception ex)
            {
                // The next change writes it all again.
                Console.WriteLine($"Could not save history ({ex.Message}).");
            }
        }
    }

    // Waits (up to timeout) until every change so far is on disk - the engine
    // stopping, before the process exits.
    public void Flush(TimeSpan? timeout = null)
    {
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(10));
        while (true)
        {
            Task running;
            lock (saveGate)
            {
                if (!writing) return;
                running = saving;
            }
            var left = deadline - DateTime.UtcNow;
            if (left <= TimeSpan.Zero || !running.Wait(left)) return;
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
            ForgetPrints();
            saveHistory();
            return removed;
        }
    }

    public Boolean isEntryInHistory(ClipboardEntry entry)
    {
        lock (gate) { return inMemoryHistory.Contains(entry); }
    }
}
