namespace ClipboardDaemon.Storage;

// The bookkeeping of a version 2 sync, as plain list and dictionary work (no
// network, no files) so it can be tested on its own: what is worth asking each
// connection for after its history_head, the requests sent and not answered
// yet (a queue per connection, answered in order), and which keys are being
// asked for where - so one key is not asked for from two devices. The
// connection is a plain object here, as in BatchGroups. Thread-safe: heads
// arrive on every connection's own thread.
public sealed class SyncRequests
{
    // A request is dropped if it has no answer after this long (ms).
    public const long TimeoutMs = 90_000;

    // One history_request that was sent. Convenience: it is for the
    // convenience item (the single newest entry this PC did not have), which
    // is the only one answered onto the clipboard. Expired: nobody answered in
    // time; it stays in the queue as a marker, so its late answer is still
    // known for what it is (and not taken for the answer to a later request),
    // but it is no longer waited for: its keys are not pending and it counts
    // as no open request (Open, the timeout, a stack's waiting).
    public sealed record Request(IReadOnlyList<string> Keys, bool Convenience, long SentAt)
    {
        public bool Expired { get; init; }
    }

    // What to send for a head: the requests, in order, and how many entries in
    // all they ask for (the size of the stack it will make).
    public sealed record Plan(IReadOnlyList<Request> Requests, int Wanted);

    private readonly object gate = new();
    private readonly Dictionary<object, List<Request>> queues = new();
    // Key -> the connection it was asked from.
    private readonly Dictionary<string, object> pending = new();
    // The last version 2 head of each connection, to ask again from if
    // another connection's requests are lost.
    private readonly Dictionary<object, HistoryHead.SyncHead> heads = new();

    // The keys of a head worth asking for, newest first. Skipped: the ones this
    // PC has (has), deleted (gone) or is already asking for (asked). The cap
    // is the history's: of everything this PC would hold - what it has (its
    // times, localTimes) and what is missing - the cap newest by time are
    // worth downloading, the rest would be trimmed at once. The first missing
    // key is always wanted though: it is the convenience item, which goes on the
    // clipboard and is kept by the trim, even when it is older than all of
    // those. Without times (a head that had none, or not as many as keys) every
    // missing key is wanted, up to the cap.
    public static List<string> Wanted(IReadOnlyList<string> keys, IReadOnlyList<long>? times, Func<string, bool> has,
        Func<string, bool> gone, Func<string, bool> asked, IReadOnlyList<long> localTimes, int cap = HistoryHead.MaxKeys)
    {
        bool timed = times != null && times.Count == keys.Count;
        var seen = new HashSet<string>();
        var missing = new List<(string Key, long Time)>();
        for (int i = 0; i < keys.Count; i++)
        {
            string key = keys[i];
            if (!seen.Add(key) || has(key) || gone(key) || asked(key)) continue;
            missing.Add((key, timed ? times![i] : 0));
        }
        if (!timed) return missing.Take(cap).Select(entry => entry.Key).ToList();

        // (OrderBy is stable: of equal times this PC's own entries come first.)
        var inside = localTimes.Select(time => (Index: -1, Time: time))
            .Concat(missing.Select((entry, index) => (Index: index, Time: entry.Time)))
            .OrderByDescending(candidate => candidate.Time)
            .Take(cap)
            .Where(candidate => candidate.Index >= 0)
            .Select(candidate => candidate.Index)
            .ToHashSet();
        if (missing.Count > 0) inside.Add(0);
        return missing.Where((_, index) => inside.Contains(index)).Take(cap).Select(entry => entry.Key).ToList();
    }

    // Works out what to ask conn for from its head, and reserves it: the
    // requests are queued and their keys are pending. The convenience item
    // is asked for alone, first, so it arrives (and goes on the clipboard)
    // before the rest; then the rest in one request. allowConvenience false: no
    // request is for the convenience item, so nothing is put on the clipboard (when
    // asking again for what another connection lost, after the convenience
    // item was handled).
    public Plan Reserve(object conn, HistoryHead.SyncHead head, Func<string, bool> has, Func<string, bool> gone,
        IReadOnlyList<long> localTimes, long nowMs, bool allowConvenience = true)
    {
        lock (gate)
        {
            heads[conn] = head;
            var wanted = Wanted(head.Keys, head.Times, has, gone, pending.ContainsKey, localTimes);
            if (wanted.Count == 0) return new Plan(Array.Empty<Request>(), 0);
            var requests = new List<Request>();
            if (allowConvenience)
            {
                requests.Add(new Request(new[] { wanted[0] }, true, nowMs));
                if (wanted.Count > 1) requests.Add(new Request(wanted.Skip(1).ToList(), false, nowMs));
            }
            else
            {
                requests.Add(new Request(wanted, false, nowMs));
            }
            if (!queues.TryGetValue(conn, out var queue)) queues[conn] = queue = new List<Request>();
            queue.AddRange(requests);
            foreach (string key in wanted) pending[key] = conn;
            return new Plan(requests, wanted.Count);
        }
    }

    // The head conn sent last, if it is still connected.
    public HistoryHead.SyncHead? LastHead(object conn)
    {
        lock (gate) { return heads.GetValueOrDefault(conn); }
    }

    public bool IsPending(string key)
    {
        lock (gate) { return pending.ContainsKey(key); }
    }

    // How many of conn's requests wait for an answer (not the expired ones).
    public int Open(object conn)
    {
        lock (gate) { return queues.TryGetValue(conn, out var queue) ? queue.Count(request => !request.Expired) : 0; }
    }

    // A history_batch came from conn: it answers the oldest request in the queue,
    // which may be an expired one (check Expired: its answer is a late one). Null
    // if there is none - the batch is one nobody asked for. open: how many are
    // still open after this one (expired ones do not count). The request's keys
    // stay pending until Done, so there is no moment when they are neither
    // pending nor in history.
    public Request? Answered(object conn, out int open)
    {
        lock (gate)
        {
            open = 0;
            if (!queues.TryGetValue(conn, out var queue) || queue.Count == 0) return null;
            var request = queue[0];
            queue.RemoveAt(0);
            open = queue.Count(other => !other.Expired);
            if (queue.Count == 0) queues.Remove(conn);
            return request;
        }
    }

    // An answered request was dealt with: its keys are no longer pending. (An
    // expired one has none: they were freed when it expired, and may be pending
    // again for a newer request.)
    public void Done(object conn, Request request)
    {
        if (request.Expired) return;
        lock (gate) { Release(request, conn); }
    }

    // Every request that has waited maxAgeMs or more expires: its keys are no
    // longer pending, and it stays in the queue as a marker until its answer
    // comes or the connection closes. Returns the connections that lost some,
    // once each (see Open for what they still wait for).
    public List<object> Expire(long nowMs, long maxAgeMs)
    {
        lock (gate)
        {
            var affected = new List<object>();
            foreach (var (conn, queue) in queues.ToList())
            {
                bool lost = false;
                for (int i = 0; i < queue.Count; i++)
                {
                    var request = queue[i];
                    if (request.Expired || nowMs - request.SentAt < maxAgeMs) continue;
                    queue[i] = request with { Expired = true };
                    Release(request, conn);
                    lost = true;
                }
                if (lost) affected.Add(conn);
            }
            return affected;
        }
    }

    // conn is gone: its requests (and markers) are dropped, their keys are no
    // longer pending and its head is forgotten. Returns the requests that were
    // open (not the expired ones: nothing was owed for those any more).
    public List<Request> Close(object conn)
    {
        lock (gate)
        {
            heads.Remove(conn);
            if (!queues.Remove(conn, out var queue)) return new List<Request>();
            var open = queue.Where(request => !request.Expired).ToList();
            foreach (var request in open) Release(request, conn);
            return open;
        }
    }

    // (A key pending for a different connection stays so: a second request for
    // it, from a head that came while it was pending, was never made.)
    private void Release(Request request, object conn)
    {
        foreach (string key in request.Keys)
        {
            if (pending.TryGetValue(key, out var owner) && ReferenceEquals(owner, conn)) pending.Remove(key);
        }
    }
}
