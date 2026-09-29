using System.Diagnostics;

namespace ClipLink;

// Files handed over to share, gathered into one batch. File Explorer's
// "Share to ClipLink" starts one ClipLink per selected file (up to 100, all
// at once), each forwarding just its own path - they're shared together,
// with one "Shared 12 files", once none has arrived for Quiet, or MaxWait
// after the first of them (so a long trickle still gets going). A path
// already waiting isn't added twice. flush runs on a thread-pool thread.
internal sealed class ShareBatcher : IDisposable
{
    public static readonly TimeSpan DefaultQuiet = TimeSpan.FromMilliseconds(400);
    public static readonly TimeSpan DefaultMaxWait = TimeSpan.FromSeconds(3);

    private readonly object gate = new();
    private readonly Action<IReadOnlyList<string>> flush;
    private readonly TimeSpan quiet;
    private readonly TimeSpan maxWait;
    private readonly Timer timer;
    private readonly List<string> pending = new();
    private readonly HashSet<string> pendingSet = new(StringComparer.OrdinalIgnoreCase);
    private long firstAt;

    public ShareBatcher(Action<IReadOnlyList<string>> flush, TimeSpan? quiet = null, TimeSpan? maxWait = null)
    {
        this.flush = flush;
        this.quiet = quiet ?? DefaultQuiet;
        this.maxWait = maxWait ?? DefaultMaxWait;
        timer = new Timer(_ => Flush());
    }

    public void Add(IEnumerable<string> paths)
    {
        lock (gate)
        {
            bool wasEmpty = pending.Count == 0;
            foreach (string path in paths)
            {
                if (!string.IsNullOrWhiteSpace(path) && pendingSet.Add(path)) pending.Add(path);
            }
            if (pending.Count == 0) return;
            if (wasEmpty) firstAt = Stopwatch.GetTimestamp();
            // Quiet from now, but never past MaxWait from the first.
            TimeSpan left = maxWait - Stopwatch.GetElapsedTime(firstAt);
            timer.Change(TimeSpan.FromTicks(Math.Clamp(left.Ticks, 0, quiet.Ticks)), Timeout.InfiniteTimeSpan);
        }
    }

    private void Flush()
    {
        string[] batch;
        lock (gate)
        {
            // (A timer that went off while the last flush took the lot
            // finds nothing.)
            if (pending.Count == 0) return;
            batch = pending.ToArray();
            pending.Clear();
            pendingSet.Clear();
        }
        flush(batch);
    }

    public void Dispose() => timer.Dispose();
}
