namespace ClipboardDaemon.Storage;

// What this PC's clipboard holds because of ClipLink, as far as it knows: the
// prints (see ContentPrint) of the last thing ClipLink wrote there, or of the
// last copy it looked at, and the clipboard's sequence number right after
// ClipLink's last write. Kept until it is replaced - no timer: it stays right
// for as long as nothing else replaces it, and a stale one can only ever hold
// back content equal to what it names. In memory only: the watcher starts
// from the clipboard's current sequence number, so nothing already on the
// clipboard is captured at start. Thread-safe: the clipboard watcher writes
// it, the connections' threads ask it (see the spec's 1.5).
public sealed class LastWrite
{
    private readonly object gate = new();
    private HashSet<string> prints = new();
    private uint? count;
    private long generation;

    // ClipLink wrote the clipboard - only once the write succeeded (on a
    // failure the record stays as it was). count: the sequence number after it.
    public void Wrote(IEnumerable<string?> written, uint sequence)
    {
        lock (gate)
        {
            prints = written.OfType<string>().ToHashSet();
            count = sequence;
            generation++;
        }
    }

    // A copy was looked at - sent, or found to be one ClipLink already has:
    // that is what the clipboard holds now. The count stays.
    public void Classified(IEnumerable<string> captured)
    {
        lock (gate)
        {
            prints = captured.ToHashSet();
            generation++;
        }
    }

    // As Classified, unless the record changed since generation (ClipLink wrote
    // the clipboard, or looked at a newer copy, while this copy was being
    // read): then it already says something newer. Returns whether it was set.
    public bool ClassifiedIfUnchanged(IEnumerable<string> captured, long since)
    {
        lock (gate)
        {
            if (generation != since) return false;
            prints = captured.ToHashSet();
            generation++;
            return true;
        }
    }

    public bool Holds(string? print)
    {
        if (print == null) return false;
        lock (gate) { return prints.Contains(print); }
    }

    // Whether the clipboard still holds ClipLink's own last write, without
    // reading it: its sequence number is the one right after that write.
    public bool IsOwnWrite(uint sequence)
    {
        lock (gate) { return count == sequence; }
    }

    public HashSet<string> Prints
    {
        get { lock (gate) { return new HashSet<string>(prints); } }
    }

    // Changes every time the record does (see ClassifiedIfUnchanged).
    public long Generation
    {
        get { lock (gate) { return generation; } }
    }

    // Whether a copy is new or one this device already has (the spec's 1.3):
    // ownWrite - the clipboard still holds ClipLink's own write (checked
    // before reading); captured - the prints of what was read (null: not read
    // yet, or the read failed: ALREADY then, as nothing can be sent); every -
    // a file selection, which matches the record only when every file does;
    // inHistory - some history entry has this print; inNewest - the newest
    // entry has it. manual: a Paste button the user pressed (the Windows
    // watcher is always automatic). An automatic capture of something ClipLink
    // wrote or saw is never sent again, even after the item was deleted; a
    // manual one is, once the item is no longer in history.
    public static bool IsAlready(bool manual, bool ownWrite, IReadOnlyCollection<string> lastPrints,
        IReadOnlyCollection<string>? captured, Func<string, bool> inHistory, Func<string, bool> inNewest, bool every = false)
    {
        if (ownWrite && (!manual || lastPrints.Any(inHistory))) return true;
        if (captured == null || captured.Count == 0) return true;
        bool matches = every ? captured.All(lastPrints.Contains) : captured.Any(lastPrints.Contains);
        if (matches && (!manual || captured.Any(inHistory))) return true;
        return captured.Any(inNewest);
    }
}
