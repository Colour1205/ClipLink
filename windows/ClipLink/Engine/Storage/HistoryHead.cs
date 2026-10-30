namespace ClipboardDaemon.Storage;

// The "history_head" message: a tiny message a device sends right before its
// history_batch (which can be many MB, since pictures travel as Base64) when
// the batch has two or more entries. It carries the newest entry and the key
// of every entry in the batch, so the receiver can show its newest item and
// the size of the stack at once, while the batch is still on its way. See the
// docs' "Sharing history". The batch that follows is unchanged.
public static class HistoryHead
{
    // The message's payload. Newest: the sender's most recent entry, signed
    // like any entry. Keys: Key() of every entry in the batch that follows,
    // newest first (so Keys[0] is Newest's).
    public sealed record Payload(ClipboardEntry Newest, List<string> Keys);

    // Whether a received head is worth acting on: it is whole, and its newest
    // entry passes isAcceptable (a valid signature from a trusted device, as
    // for a live entry). A head that fails is ignored completely: the batch
    // then works as it does without one.
    public static bool Accept(Payload? head, Func<ClipboardEntry, bool> isAcceptable) =>
        head?.Newest != null && head.Keys != null && isAcceptable(head.Newest);

    // The head for a batch of these entries, or null when the batch has fewer
    // than HistoryBatch.GroupMinItems entries (then no head is sent).
    public static Payload? ForBatch(IReadOnlyList<ClipboardEntry> batch)
    {
        if (batch.Count < HistoryBatch.GroupMinItems) return null;
        // (OrderBy is stable: of equal timestamps, the one listed first is first.)
        var newestFirst = batch.OrderByDescending(entry => entry.Timestamp).ToList();
        return new Payload(newestFirst[0], newestFirst.Select(entry => entry.Key()).ToList());
    }
}
