using System.Text.Json;
using ClipboardDaemon.Networking;

namespace ClipboardDaemon.Storage;

// The "history_head" message. Two forms, by the protocol the connection speaks
// (see HandshakeMessage.Protocol):
//
// Version 1: a tiny message a device sends right before its history_batch
// (which can be many MB, since pictures travel as Base64) when the batch has
// two or more entries. It carries the newest entry and the key of every entry
// in the batch, so the receiver can show its newest item and the size of the
// stack at once, while the batch is still on its way. The batch that follows
// is unchanged.
//
// Version 2 (SyncHead): sent on every connection, instead of a batch: the keys
// of the sender's history with their times, and its tombstones. The receiver
// asks for the entries it is missing (history_request) and deletes what the
// sender deleted. It has no entry in it: nothing big travels unless wanted.
// See the docs' "Sharing history".
public static class HistoryHead
{
    // How many keys a version 2 head lists (the history's cap), and how many
    // deleted keys (the most recent tombstones).
    public const int MaxKeys = 25;
    public const int MaxDeleted = 500;

    // The version 1 payload. Newest: the sender's most recent entry, signed
    // like any entry. Keys: Key() of every entry in the batch that follows,
    // newest first (so Keys[0] is Newest's).
    public sealed record Payload(ClipboardEntry Newest, List<string> Keys);

    // The version 2 payload: Keys: Key() of every entry in the sender's
    // history, newest first. Times: the same entries' times, in Unix
    // milliseconds in UTC, in the same order - null when a received head had
    // none, or not as many as Keys (never half-trusted). Deleted: its
    // tombstones, most recently deleted first.
    public sealed record SyncHead(List<string> Keys, List<long>? Times, List<string> Deleted);

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

    // The version 2 head for this history and these tombstones (the most
    // recently deleted first). Always made, even for an empty history.
    public static SyncHead ForSync(IReadOnlyList<ClipboardEntry> history, IEnumerable<string> deletedNewestFirst)
    {
        var newestFirst = history.OrderByDescending(entry => UnixMs(entry.Timestamp)).Take(MaxKeys).ToList();
        return new SyncHead(
            newestFirst.Select(entry => entry.Key()).ToList(),
            newestFirst.Select(entry => UnixMs(entry.Timestamp)).ToList(),
            deletedNewestFirst.Take(MaxDeleted).ToList());
    }

    // A time as the wire has it: Unix milliseconds in UTC. (A timestamp read from
    // JSON may be Unspecified, which counts as UTC, or Local.)
    public static long UnixMs(DateTime timestamp)
    {
        var utc = timestamp.Kind switch
        {
            DateTimeKind.Local => timestamp.ToUniversalTime(),
            _ => DateTime.SpecifyKind(timestamp, DateTimeKind.Utc),
        };
        return new DateTimeOffset(utc).ToUnixTimeMilliseconds();
    }

    // A received version 2 head, or null if the payload is not one. Lenient on
    // purpose: unknown keys are skipped, Deleted and Times may be missing (Times
    // then null), and what is not a usable key (not a string, empty, longer than
    // KeysMessage.MaxKeyLength) is left out - with its time (which is not even looked at). More than MaxKeys
    // usable keys: the first MaxKeys. More than MaxDeleted: the first MaxDeleted. A
    // "Newest" is ignored.
    public static SyncHead? ParseSync(string? payload)
    {
        if (string.IsNullOrEmpty(payload)) return null;
        try
        {
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;

            var keys = new List<string>();
            List<long>? times = null;
            if (root.TryGetProperty("Keys", out var keyList) && keyList.ValueKind == JsonValueKind.Array)
            {
                var rawKeys = keyList.EnumerateArray().ToList();
                var rawTimes = root.TryGetProperty("Times", out var timeList) && timeList.ValueKind == JsonValueKind.Array
                    ? timeList.EnumerateArray().ToList()
                    : null;
                // Times count only if there are as many as keys, and all numbers.
                bool timed = rawTimes != null && rawTimes.Count == rawKeys.Count;
                times = new List<long>();
                // (The first MaxKeys usable keys: one that is not a key does not use up a place.)
                for (int i = 0; i < rawKeys.Count && keys.Count < MaxKeys; i++)
                {
                    // The key first: a time that goes with a key that is left out is
                    // not looked at, so it cannot turn Times off for the whole head.
                    if (!IsKey(rawKeys[i])) continue;
                    long time = 0;
                    if (timed && !TryTime(rawTimes![i], out time)) timed = false;
                    keys.Add(rawKeys[i].GetString()!);
                    times.Add(time);
                }
                if (!timed) times = null;
            }

            var deleted = new List<string>();
            if (root.TryGetProperty("Deleted", out var deletedList) && deletedList.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in deletedList.EnumerateArray().Take(MaxDeleted))
                {
                    if (IsKey(item)) deleted.Add(item.GetString()!);
                }
            }
            return new SyncHead(keys, times, deleted);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool IsKey(JsonElement item) =>
        item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 and <= KeysMessage.MaxKeyLength };

    private static bool TryTime(JsonElement item, out long time)
    {
        time = 0;
        if (item.ValueKind != JsonValueKind.Number) return false;
        if (item.TryGetInt64(out time)) return true;
        // A time written as 1730000000123.0 is still a time.
        if (!item.TryGetDouble(out double value) || double.IsNaN(value) || Math.Abs(value) > 9e15) return false;
        time = (long)value;
        return true;
    }
}
