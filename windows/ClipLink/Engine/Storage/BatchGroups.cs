namespace ClipboardDaemon.Storage;

// Which entries arrived together in one peer batch (a "batch group"), so the
// Synced page can show them as one stack. Plain list and dictionary work
// (no files, no locks - the caller holds HistoryAccess's lock) so it can be
// tested on its own. In memory only: nothing here is saved or sent.
//
// A group is made either when a history_batch is applied (two or more new
// entries), or earlier, from the batch's history_head: then the newest entry
// is added at once and the group starts with just that one, with the size the
// head promised (expected), and the batch later joins it (same group id).
public sealed class BatchGroups
{
    // Key() -> batch id, for entries in a group.
    private readonly Dictionary<string, string> batchOf = new();
    // Batch id -> how many entries a head promised, while its batch is still
    // on its way. Only for a group made by a head.
    private readonly Dictionary<string, int> expectedOf = new();
    // The head a connection sent, until its batch arrives or it closes: the
    // id of the group it made, or null when it made none (it promised one new
    // entry only). The connection is a plain object here, to keep this free
    // of the network code.
    private readonly Dictionary<object, string?> headOf = new();
    private long lastId;

    // What a head did. Added: its newest entry, when it was new and is in
    // history now. Evicted: what the cap pushed out for it. Changed: the
    // history or what the stacks show changed, so the UI must update.
    public sealed record HeadResult(ClipboardEntry? Added, IReadOnlyList<ClipboardEntry> Evicted, bool Changed);

    // A copy of the groups, for listing the history: Key() -> batch id, and
    // batch id -> the size still expected (provisional groups only).
    public (Dictionary<string, string> BatchOf, Dictionary<string, int> Expected) Snapshot() =>
        (new Dictionary<string, string>(batchOf), new Dictionary<string, int>(expectedOf));

    // A verified head arrived on conn. history is changed in place (the newest
    // entry added, the cap applied). A head still waiting on the same
    // connection is finished first (it is replaced). isDeletedKey: the user
    // deleted this entry here.
    public HeadResult HeadReceived(object conn, List<ClipboardEntry> history, HistoryHead.Payload head,
        Func<string, bool> isDeletedKey, int maxItems)
    {
        bool changed = FinishHead(conn, history);
        var newest = head.Newest;
        string newestKey = newest.Key();
        var known = new HashSet<string>(history.Select(entry => entry.Key()));
        if (known.Contains(newestKey) || isDeletedKey(newestKey))
        {
            // Nothing to show early: the batch is applied as it would be
            // without a head.
            return new HeadResult(null, Array.Empty<ClipboardEntry>(), changed);
        }

        // How many of the promised entries this PC would take. (The newest is
        // one of them even if the list left it out.) At most what history
        // holds, so a head cannot promise a stack of any size.
        var keys = new HashSet<string>(head.Keys.Where(key => key != null)) { newestKey };
        int expectedNew = Math.Min(maxItems, keys.Count(key => !known.Contains(key) && !isDeletedKey(key)));

        var merged = HistoryBatch.Merge(history, new[] { newest }, entry => isDeletedKey(entry.Key()), maxItems);
        if (merged.Added.Count == 0)
        {
            // Older than everything in a full history: added and trimmed at once.
            Forget(history);
            return new HeadResult(null, merged.Evicted, changed || merged.Evicted.Count > 0);
        }

        string? batch = null;
        if (expectedNew >= HistoryBatch.GroupMinItems)
        {
            batch = NewId();
            batchOf[newestKey] = batch;
            expectedOf[batch] = expectedNew;
        }
        headOf[conn] = batch;
        Forget(history);
        return new HeadResult(newest, merged.Evicted, true);
    }

    // conn's history_batch: every new, not deleted entry goes into history
    // (one step, the cap applied once, see HistoryBatch.Merge). The new ones
    // join the group conn's head made, or make a group of their own when there
    // are two or more and no head did. The head is done. The result says, in
    // HeadApplied, that the head had already added the newest entry (and done
    // its side effects, so the batch must not put its own newest on the
    // clipboard), and in GroupChanged, that a group the head made is final
    // now (its real size shows, even if the batch added nothing).
    public HistoryBatch.MergeResult ApplyBatch(object conn, List<ClipboardEntry> history, IEnumerable<ClipboardEntry> incoming,
        Func<ClipboardEntry, bool> isDeleted, int maxItems)
    {
        var merged = HistoryBatch.Merge(history, incoming, isDeleted, maxItems);
        bool headApplied = headOf.Remove(conn, out string? batch);
        bool finishedGroup = batch != null;
        if (batch != null) expectedOf.Remove(batch);
        else if (merged.Added.Count >= HistoryBatch.GroupMinItems) batch = NewId();
        if (batch != null)
        {
            foreach (var entry in merged.Added) batchOf[entry.Key()] = batch;
        }
        Forget(history);
        // Fewer than two left (the rest was rejected, deleted or trimmed):
        // normal cards.
        if (finishedGroup) Dissolve(batch!);
        return merged with { HeadApplied = headApplied, GroupChanged = finishedGroup };
    }

    // conn closed before its batch arrived (or a new head replaces its head):
    // the size is not expected any more, and a group with fewer than two
    // entries is plain cards. Returns whether a group made by a head changed.
    public bool FinishHead(object conn, IReadOnlyList<ClipboardEntry> history)
    {
        if (!headOf.Remove(conn, out string? batch) || batch == null) return false;
        expectedOf.Remove(batch);
        Forget(history);
        Dissolve(batch);
        return true;
    }

    // Groups only keep entries that are still in history.
    public void Forget(IReadOnlyList<ClipboardEntry> history)
    {
        if (batchOf.Count == 0) return;
        var present = new HashSet<string>(history.Select(entry => entry.Key()));
        foreach (string key in batchOf.Keys.Where(key => !present.Contains(key)).ToList())
        {
            batchOf.Remove(key);
        }
    }

    // History was cleared. (A connection's head stays: its batch is still
    // coming, and what it adds is checked against the deleted list.)
    public void Clear()
    {
        batchOf.Clear();
        expectedOf.Clear();
    }

    private string NewId() => (++lastId).ToString();

    // A group with fewer than HistoryBatch.GroupMinItems entries left is not
    // a group.
    private void Dissolve(string batch)
    {
        var members = batchOf.Where(pair => pair.Value == batch).Select(pair => pair.Key).ToList();
        if (members.Count >= HistoryBatch.GroupMinItems) return;
        foreach (string key in members) batchOf.Remove(key);
    }
}
