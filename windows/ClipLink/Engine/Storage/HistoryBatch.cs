namespace ClipboardDaemon.Storage;

// What a peer's history_batch does to this PC's history, as plain list work
// (no files, no locks, no network) so it can be tested on its own. The engine
// and HistoryAccess call it; see the docs' "Sharing history".
public static class HistoryBatch
{
    // One batch that adds at least this many new entries is shown as one
    // stack on the Synced page; fewer is just normal cards. (Every platform
    // uses the same number.)
    public const int GroupMinItems = 2;

    // What merging a batch into a history did. Added: the entries that are new
    // and are still in history afterwards, in the order the batch listed them.
    // Evicted: everything the cap pushed out (old entries, or new ones that
    // were older than all the rest). Duplicates: already in history (or twice
    // in the batch). Deleted: the user deleted them here earlier.
    public sealed record MergeResult(
        IReadOnlyList<ClipboardEntry> Added,
        IReadOnlyList<ClipboardEntry> Evicted,
        int Duplicates,
        int Deleted)
    {
        // Set by BatchGroups.ApplyBatch. HeadApplied: this connection's
        // history_head already added the newest entry (and what a received
        // item does besides), so the batch must not do it again. GroupChanged:
        // the group that head made is final now, which changes what the UI
        // shows even if the batch added nothing.
        public bool HeadApplied { get; init; }
        public bool GroupChanged { get; init; }
    }

    // Adds every new, not deleted entry of incoming to history, then trims
    // once. Changes history in place. Nothing is notified or saved here: that
    // is one step for the whole batch, done by the caller.
    public static MergeResult Merge(List<ClipboardEntry> history, IEnumerable<ClipboardEntry> incoming,
        Func<ClipboardEntry, bool> isDeleted, int maxItems)
    {
        var added = new List<ClipboardEntry>();
        int duplicates = 0, deleted = 0;
        foreach (var entry in incoming)
        {
            if (history.Contains(entry))
            {
                duplicates++;
            }
            else if (isDeleted(entry))
            {
                deleted++;
            }
            else
            {
                history.Add(entry);
                added.Add(entry);
            }
        }
        var evicted = TrimOldest(history, maxItems);
        if (evicted.Count > 0)
        {
            // A new entry older than the whole history is added and trimmed
            // in the same step: it never was in history, so it is not "added".
            added.RemoveAll(evicted.Contains);
        }
        return new MergeResult(added, evicted, duplicates, deleted);
    }

    // Oldest-first eviction (by timestamp) down to maxItems. Returns what went.
    public static List<ClipboardEntry> TrimOldest(List<ClipboardEntry> history, int maxItems)
    {
        var evicted = new List<ClipboardEntry>();
        while (history.Count > maxItems)
        {
            var oldest = history.OrderBy(e => e.Timestamp).First();
            history.Remove(oldest);
            evicted.Add(oldest);
        }
        return evicted;
    }

    // What Apply did, in numbers and in entries. Rejected: a bad signature or
    // a maker this PC does not trust.
    public sealed record Outcome(IReadOnlyList<ClipboardEntry> Added, int Rejected, int Duplicates, int Deleted)
    {
        // As in MergeResult: the connection's history_head already took the newest entry.
        public bool HeadApplied { get; init; }
    }

    // A whole history_batch as one unit: each entry is checked (isAcceptable:
    // signature and trusted maker, isDeleted: the user deleted it here), all
    // the survivors are added in one step (add), and changed is called ONCE
    // if anything was added - never once per entry.
    public static Outcome Apply(IEnumerable<ClipboardEntry> entries, Func<ClipboardEntry, bool> isAcceptable,
        Func<ClipboardEntry, bool> isDeleted, Func<IReadOnlyList<ClipboardEntry>, MergeResult> add, Action changed)
    {
        var candidates = new List<ClipboardEntry>();
        int rejected = 0, deletedEarly = 0;
        foreach (var entry in entries)
        {
            if (entry == null || !isAcceptable(entry))
            {
                rejected++; // skip just this one, keep the rest of the batch
            }
            else if (isDeleted(entry))
            {
                deletedEarly++; // peers keep resending what was deleted here
            }
            else
            {
                candidates.Add(entry);
            }
        }
        var merged = add(candidates);
        if (merged.Added.Count > 0 || merged.GroupChanged)
        {
            changed();
        }
        return new Outcome(merged.Added, rejected, merged.Duplicates, merged.Deleted + deletedEarly) { HeadApplied = merged.HeadApplied };
    }
}
