namespace ClipboardDaemon.Storage;

// A received file entry that goes on the clipboard once its bytes are here:
// when that was decided (ArmedAt, Environment.TickCount64 ms) and the
// clipboard's sequence number then. Bytes that take long, or come after
// something else went on the clipboard, mustn't overwrite what is newer.
public sealed record PendingApply(ClipboardEntry Entry, long ArmedAt, uint Sequence)
{
    // Bytes arriving later than this (ms) are only stored.
    public const long MaxWaitMs = 10 * 60 * 1000;

    // Whether, with the bytes here now, the entry still goes on the clipboard:
    // nothing was written to the clipboard since (copied here, or another
    // item applied), and it hasn't waited longer than MaxWaitMs. (That it is
    // still in history and not deleted is the caller's to check.)
    public bool IsDue(long nowMs, uint sequence) => sequence == Sequence && nowMs - ArmedAt <= MaxWaitMs;
}
