namespace ClipboardDaemon.Storage;

// Where each entry sits in what the Synced page shows, and which entries
// arrived together in one peer sync (a "batch group", shown as one stack).
// Plain list and dictionary work (no files, no locks - the caller holds
// HistoryAccess's lock) so it can be tested on its own. In memory only:
// nothing here is saved or sent, so after a restart the history is plain
// cards by time.
//
// Session blocks. The point of the app is convenience, not a timeline: what
// just arrived goes on top, whatever its time. A live item (copied here, or
// received) is a block of its own. A sync from a peer (a version 1 history_batch,
// or the answers to a version 2 history_request) is ONE block: the convenience
// item C (the newest item this PC did not have, the one put on the clipboard)
// first, then the rest of the sync, newest first. Blocks are ordered by when
// they arrived, newest on top, above every entry that is in no block. See
// Order. C is protected from the trim, once it goes to the clipboard, until a
// newer item goes there or a live item arrives.
//
// A batch group is the stack: a block of a sync that brought two or more
// entries. It is made either when the sync's entries are applied, or earlier:
// from a version 1 history_head, or from the answer to a version 2 sync's
// convenience request. Then C is added at once and the group starts with just
// that one, with the size the head or the sync promised (expected), and the
// rest later joins it (same group id).
public sealed class BatchGroups
{
    // Key() -> batch id, for entries in a group.
    private readonly Dictionary<string, string> batchOf = new();
    // Batch id -> how many entries a head or a sync promised, while the rest is
    // still on its way. Only for a group made before all of it arrived.
    private readonly Dictionary<string, int> expectedOf = new();

    // The version 1 head a connection sent, until its batch arrives or it
    // closes: the group it made (null when it made none: it promised one new
    // entry only), the block of its newest entry, and when it came (ms, see
    // ExpireHeads). The connection is a plain object here, to keep this free
    // of the network code.
    private sealed record Head(string? Batch, long Block, long At);
    private readonly Dictionary<object, Head> headOf = new();

    // A version 2 sync under way on a connection: asked for Size entries in all
    // (adding up as more is asked for), and not answered yet in full. Block: the
    // block its entries went in (0 until the first of them arrived), Batch: its
    // group, once it is one.
    private sealed class Sync
    {
        public int Size;
        public long Block;
        public string? Batch;
    }
    private readonly Dictionary<object, Sync> syncOf = new();

    // Key() -> the block it is in. Blocks and groups share one counter, so a
    // group's id is its block's number.
    private readonly Dictionary<string, long> blockOf = new();
    // Block -> Key() of its convenience item.
    private readonly Dictionary<long, string> frontOf = new();
    // Entries that came in a version 2 sync's later answers: shown, but not
    // announced (only the convenience item is).
    private readonly HashSet<string> quiet = new();
    private long lastId;

    // The last convenience item that went to the clipboard: its time (Unix ms)
    // and when that happened (Environment.TickCount64). Global to the engine,
    // not per connection: when two devices answer at once, each with its own
    // newest item, only one of them goes to the clipboard (see ApplyAnswer).
    private (long Time, long AppliedAt)? lastConvenience;

    // A convenience item is not put on the clipboard if one was put there less
    // than this long ago (ms) and the new one is not newer.
    public const long ConvenienceWindowMs = 90_000;

    // The convenience item the trim must not drop: the last one that went to the
    // clipboard. A live item, or a sync with a convenience item of its own that
    // goes to the clipboard, ends the protection (or moves it); a sync whose
    // convenience item was skipped (see ApplyAnswer) does not.
    public string? ProtectedKey { get; private set; }

    // What a head did. Added: its newest entry, when it was new and is in
    // history now. Evicted: what the cap pushed out for it. Changed: the
    // history or what the stacks show changed, so the UI must update.
    public sealed record HeadResult(ClipboardEntry? Added, IReadOnlyList<ClipboardEntry> Evicted, bool Changed);

    // A copy of the groups, for listing the history: Key() -> batch id, and
    // batch id -> the size still expected (provisional groups only).
    public (Dictionary<string, string> BatchOf, Dictionary<string, int> Expected) Snapshot() =>
        (new Dictionary<string, string>(batchOf), new Dictionary<string, int>(expectedOf));

    // The Key() of every entry that arrived quietly.
    public HashSet<string> QuietKeys() => new(quiet);

    // The history in the order the Synced page shows it: the session blocks,
    // the newest block first - each with its convenience item first and its
    // other entries after it, newest first - and then every other entry,
    // newest first. A stack that is opened keeps its place: its entries are
    // already together, right below its front card, above all the others.
    public List<ClipboardEntry> Order(IReadOnlyList<ClipboardEntry> history)
    {
        var blocks = new SortedDictionary<long, List<ClipboardEntry>>(Comparer<long>.Create((a, b) => b.CompareTo(a)));
        var others = new List<ClipboardEntry>();
        foreach (var entry in history)
        {
            if (blockOf.TryGetValue(entry.Key(), out long block))
            {
                if (!blocks.TryGetValue(block, out var members)) blocks[block] = members = new List<ClipboardEntry>();
                members.Add(entry);
            }
            else
            {
                others.Add(entry);
            }
        }
        var ordered = new List<ClipboardEntry>(history.Count);
        foreach (var (block, members) in blocks)
        {
            string? front = frontOf.GetValueOrDefault(block);
            // (OrderBy is stable: of equal timestamps, the one listed first is first.)
            ordered.AddRange(members.OrderBy(entry => entry.Key() == front ? 0 : 1).ThenByDescending(entry => entry.Timestamp));
        }
        ordered.AddRange(others.OrderByDescending(entry => entry.Timestamp));
        return ordered;
    }

    // A live item (copied here, or received as an "entry") was added to
    // history: a block of its own, on top. It ends the protection of an older
    // convenience item.
    public void Arrived(string key)
    {
        blockOf[key] = ++lastId;
        ProtectedKey = null;
    }

    // A verified version 1 head arrived on conn. history is changed in place
    // (the newest entry added, the cap applied). A head still waiting on the
    // same connection is finished first (it is replaced). isDeletedKey: the
    // user deleted this entry here. The newest entry is the convenience item,
    // so it is never the one the cap drops.
    public HeadResult HeadReceived(object conn, List<ClipboardEntry> history, HistoryHead.Payload head,
        Func<string, bool> isDeletedKey, int maxItems, long? nowMs = null)
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

        var merged = HistoryBatch.Merge(history, new[] { newest }, entry => isDeletedKey(entry.Key()), maxItems, keepNewestAdded: true);
        if (merged.Added.Count == 0)
        {
            Forget(history);
            return new HeadResult(null, merged.Evicted, changed || merged.Evicted.Count > 0);
        }

        long block = NewBlock(newestKey);
        string? batch = null;
        if (expectedNew >= HistoryBatch.GroupMinItems)
        {
            batch = block.ToString();
            batchOf[newestKey] = batch;
            expectedOf[batch] = expectedNew;
        }
        headOf[conn] = new Head(batch, block, nowMs ?? Environment.TickCount64);
        Forget(history);
        return new HeadResult(newest, merged.Evicted, true);
    }

    // conn's history_batch (version 1, or one nobody asked for): every new, not
    // deleted entry goes into history (one step, the cap applied once, see
    // HistoryBatch.Merge). They are one block: the newest of them is the
    // convenience item, which is kept by the trim even if it is older than
    // all the rest; or, when conn's head already took the newest entry, they
    // join the block that made. With two or more entries in it they are a group
    // - the one the head made, or one of their own. The head is done. The
    // result says, in HeadApplied, that the head had already added the newest
    // entry (and done its side effects, so the batch must not put its own
    // newest on the clipboard), and in GroupChanged, that a group the head
    // made is final now (its real size shows, even if the batch added nothing).
    public HistoryBatch.MergeResult ApplyBatch(object conn, List<ClipboardEntry> history, IEnumerable<ClipboardEntry> incoming,
        Func<ClipboardEntry, bool> isDeleted, int maxItems)
    {
        bool headApplied = headOf.Remove(conn, out Head? head);
        var merged = HistoryBatch.Merge(history, incoming, isDeleted, maxItems, keep: ProtectedKey, keepNewestAdded: !headApplied);
        long block = head?.Block ?? 0;
        string? batch = head?.Batch;
        bool finishedGroup = batch != null;
        if (batch != null) expectedOf.Remove(batch);
        if (head == null && HistoryBatch.Newest(merged.Added) is { } newest) block = NewBlock(newest.Key());
        if (block != 0)
        {
            foreach (var entry in merged.Added) blockOf[entry.Key()] = block;
            if (batch == null && MembersOf(block) >= HistoryBatch.GroupMinItems) batch = block.ToString();
            if (batch != null) Join(block, batch);
        }
        Forget(history);
        // Fewer than two left (the rest was rejected, deleted or trimmed):
        // normal cards.
        if (finishedGroup) Dissolve(batch!);
        return merged with { HeadApplied = headApplied, GroupChanged = finishedGroup };
    }

    // conn closed before its batch arrived (or a new head replaces its head),
    // or the batch is overdue: the size is not expected any more, and a group
    // with fewer than two entries is plain cards. Returns whether a group made
    // by a head changed.
    public bool FinishHead(object conn, IReadOnlyList<ClipboardEntry> history)
    {
        if (!headOf.Remove(conn, out Head? head) || head.Batch == null) return false;
        expectedOf.Remove(head.Batch);
        Forget(history);
        Dissolve(head.Batch);
        return true;
    }

    // A head whose batch has not come in maxAgeMs is finished like one whose
    // connection closed (FinishHead). Returns whether a group changed.
    public bool ExpireHeads(IReadOnlyList<ClipboardEntry> history, long nowMs, long maxAgeMs)
    {
        bool changed = false;
        foreach (var conn in headOf.Where(pair => nowMs - pair.Value.At >= maxAgeMs).Select(pair => pair.Key).ToList())
        {
            changed |= FinishHead(conn, history);
        }
        return changed;
    }

    // conn's sync (version 2) now waits for size more entries: the requests
    // for them were sent. If its group already shows, so does the new size.
    public void BeginSync(object conn, int size)
    {
        if (!syncOf.TryGetValue(conn, out var sync)) syncOf[conn] = sync = new Sync();
        sync.Size += size;
        if (sync.Batch != null && sync.Size >= HistoryBatch.GroupMinItems) expectedOf[sync.Batch] = sync.Size;
    }

    // The answer to one of conn's history_requests: every new, not deleted
    // entry goes into history in one step, like a batch. They join the block
    // of conn's sync, which the first of them starts. convenience: the
    // answer to the request for the convenience item - its newest new entry is
    // that item (the front of the block, protected from the trim); the entries of
    // the other answers are quiet. last: no request of conn is open any more, so
    // nothing more is expected: the group is what really arrived (a group of fewer
    // than two entries is plain cards). The group shows as soon as the sync
    // is for two or more entries, with that size, even if only the convenience
    // item is here yet.
    //
    // When two devices answer at once, each answer has its own convenience
    // item, but the clipboard changes once: if a convenience item went to the
    // clipboard less than ConvenienceWindowMs ago (lastConvenience) and this one is
    // not newer by its time, this one does not (the result's Applied is null),
    // and is quiet (no notification). It is still added, and still the front of
    // its stack, but it is not protected from the trim: only the item that went
    // to the clipboard is, and it keeps that protection (also in the trim of this
    // very call) until a newer item goes to the clipboard. nowMs: the clock (Environment.TickCount64 if null).
    public HistoryBatch.MergeResult ApplyAnswer(object conn, List<ClipboardEntry> history, IEnumerable<ClipboardEntry> incoming,
        Func<ClipboardEntry, bool> isDeleted, int maxItems, bool convenience, bool last, long? nowMs = null)
    {
        bool tracked = syncOf.TryGetValue(conn, out var sync);
        sync ??= new Sync();
        bool taken = false;
        var merged = HistoryBatch.Merge(history, incoming, isDeleted, maxItems, keep: ProtectedKey, keepNewestAdded: convenience,
            keepIf: item => taken = TakeConvenience(item, nowMs ?? Environment.TickCount64));
        ClipboardEntry? applied = null;
        if (merged.Added.Count > 0)
        {
            if (sync.Block == 0) sync.Block = NewBlock(null);
            if (convenience && HistoryBatch.Newest(merged.Added) is { } front)
            {
                frontOf[sync.Block] = front.Key();
                if (taken)
                {
                    ProtectedKey = front.Key();
                    applied = front;
                }
            }
            foreach (var entry in merged.Added)
            {
                blockOf[entry.Key()] = sync.Block;
                if (!convenience || !taken) quiet.Add(entry.Key());
            }
            if (sync.Batch == null && (sync.Size >= HistoryBatch.GroupMinItems || MembersOf(sync.Block) >= HistoryBatch.GroupMinItems))
            {
                sync.Batch = sync.Block.ToString();
            }
            if (sync.Batch != null)
            {
                Join(sync.Block, sync.Batch);
                if (!last && sync.Size >= HistoryBatch.GroupMinItems) expectedOf[sync.Batch] = sync.Size;
            }
        }
        if (last) syncOf.Remove(conn);
        else if (!tracked) syncOf[conn] = sync;

        bool finishedGroup = last && sync.Batch != null;
        if (finishedGroup) expectedOf.Remove(sync.Batch!);
        Forget(history);
        if (finishedGroup) Dissolve(sync.Batch!);
        return merged with { GroupChanged = finishedGroup, Applied = applied };
    }

    // The answer to a request that had expired (its marker was still in the
    // queue, see SyncRequests.Expire): the new, not deleted entries are added
    // like any answer's, in one step, but quietly - they join no block and no
    // group, are not announced, and nothing is protected from the trim. They sit
    // in the timeline by their time.
    public HistoryBatch.MergeResult ApplyLate(List<ClipboardEntry> history, IEnumerable<ClipboardEntry> incoming,
        Func<ClipboardEntry, bool> isDeleted, int maxItems)
    {
        var merged = HistoryBatch.Merge(history, incoming, isDeleted, maxItems, keep: ProtectedKey);
        foreach (var entry in merged.Added) quiet.Add(entry.Key());
        Forget(history);
        return merged;
    }

    // conn's sync is not waiting for anything any more - a request timed out,
    // or conn closed: the size is not expected, and a group of fewer than two
    // entries is plain cards. Returns whether a group changed.
    public bool EndSync(object conn, IReadOnlyList<ClipboardEntry> history)
    {
        if (!syncOf.Remove(conn, out var sync) || sync.Batch == null) return false;
        expectedOf.Remove(sync.Batch);
        Forget(history);
        Dissolve(sync.Batch);
        return true;
    }

    // Everything here only keeps entries that are still in history.
    public void Forget(IReadOnlyList<ClipboardEntry> history)
    {
        if (blockOf.Count == 0 && batchOf.Count == 0) return;
        var present = new HashSet<string>(history.Select(entry => entry.Key()));
        foreach (string key in batchOf.Keys.Where(key => !present.Contains(key)).ToList())
        {
            batchOf.Remove(key);
        }
        foreach (string key in blockOf.Keys.Where(key => !present.Contains(key)).ToList())
        {
            blockOf.Remove(key);
        }
        foreach (var pair in frontOf.Where(pair => !present.Contains(pair.Value)).ToList())
        {
            frontOf.Remove(pair.Key);
        }
        quiet.RemoveWhere(key => !present.Contains(key));
        if (ProtectedKey != null && !present.Contains(ProtectedKey)) ProtectedKey = null;
    }

    // History was cleared. (A connection's head or sync stays: the rest of it is
    // still coming, and what it adds is checked against the deleted list.)
    public void Clear()
    {
        batchOf.Clear();
        expectedOf.Clear();
        blockOf.Clear();
        frontOf.Clear();
        quiet.Clear();
        ProtectedKey = null;
    }

    // Whether a convenience item goes to the clipboard, and if it does, it is
    // remembered as the last one (see ApplyAnswer).
    private bool TakeConvenience(ClipboardEntry item, long nowMs)
    {
        long time = HistoryHead.UnixMs(item.Timestamp);
        if (lastConvenience is { } last && nowMs - last.AppliedAt < ConvenienceWindowMs && time <= last.Time) return false;
        lastConvenience = (time, nowMs);
        return true;
    }

    // A block for a sync (front: its convenience item, now in history and
    // protected), or for the entries of one that has none yet.
    private long NewBlock(string? front)
    {
        long block = ++lastId;
        if (front != null)
        {
            blockOf[front] = block;
            frontOf[block] = front;
        }
        // A block with a convenience item protects that one instead of the one
        // before. A block without one (a sync whose convenience item did not go
        // to the clipboard) leaves the protection as it is: the item that did go
        // there keeps it until a newer one goes there, or a live item arrives.
        if (front != null) ProtectedKey = front;
        return block;
    }

    private int MembersOf(long block) => blockOf.Count(pair => pair.Value == block);

    private void Join(long block, string batch)
    {
        foreach (string key in blockOf.Where(pair => pair.Value == block).Select(pair => pair.Key).ToList())
        {
            batchOf[key] = batch;
        }
    }

    // A group with fewer than HistoryBatch.GroupMinItems entries left is not
    // a group.
    private void Dissolve(string batch)
    {
        var members = batchOf.Where(pair => pair.Value == batch).Select(pair => pair.Key).ToList();
        if (members.Count >= HistoryBatch.GroupMinItems) return;
        foreach (string key in members) batchOf.Remove(key);
    }
}
