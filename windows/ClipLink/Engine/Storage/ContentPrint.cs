using System.Security.Cryptography;
using System.Text;

namespace ClipboardDaemon.Storage;

// What a piece of content is, independent of who copied it and when: a kind
// prefix and lowercase SHA-256 hex ("t:" text, "i:" picture bytes, "f:" a
// file's hash). Every app makes the same prints (see design/sync-dedupe-spec.md),
// so they're how a copy is recognised as one this PC already has - an echo
// of what ClipLink just wrote (LastWrite), the newest item again, or a twin
// on the Synced page (Fold). Only ever compared: nothing that is sent, stored
// or put on the clipboard changes, and nothing on the wire carries a print.
public static class ContentPrint
{
    // The text as compared: CRLF and lone CR become LF, then one trailing LF
    // goes. A Windows app turning "a\nb" into "a\r\nb", or a copied line
    // gaining its newline, is still the same text. Nothing else (no trimming,
    // no Unicode or case folding).
    public static string Norm(string text)
    {
        string lf = text.Replace("\r\n", "\n").Replace('\r', '\n');
        return lf.EndsWith('\n') ? lf[..^1] : lf;
    }

    public static string Text(string text) => "t:" + Hex(Encoding.UTF8.GetBytes(Norm(text)));

    // A picture's print is of its bytes exactly as received or read.
    public static string Image(byte[] bytes) => "i:" + Hex(bytes);

    // A file's is the hash its payload carries, in either case: Windows and
    // iOS send uppercase, Android and HarmonyOS lowercase.
    public static string File(string fileHash) => "f:" + fileHash.ToLowerInvariant();

    // The print of content of this entry type; null when there is none (an
    // image that isn't base64, a file payload that doesn't parse or whose hash
    // isn't SHA-256, any other type). Null never matches anything.
    public static string? Of(string? content, string? type)
    {
        if (content == null) return null;
        switch (type)
        {
            case "text":
                return Text(content);
            case "image":
                try { return Image(Convert.FromBase64String(content)); }
                catch (FormatException) { return null; }
            case "file":
                try
                {
                    var payload = System.Text.Json.JsonSerializer.Deserialize<FilePayload>(content);
                    return FileStore.IsValidHash(payload?.FileHash) ? File(payload!.FileHash) : null;
                }
                catch (System.Text.Json.JsonException) { return null; }
            default:
                return null;
        }
    }

    public static string? Key(ClipboardEntry entry) => Of(entry.Content, entry.Type);

    // The cards of the Synced page, top to bottom, with every entry whose
    // content an entry above it already has taken out: one card per content,
    // the topmost wins (a live item is on top; after a restart the list is by
    // time, so the newest wins). key gives an entry's print (null: never a
    // twin). Display only - the history keeps every twin (see the spec's 2.6,
    // why this can't make a sync loop). Hidden: the Key()s taken out.
    public static (List<ClipboardEntry> Visible, HashSet<string> Hidden) Fold(IReadOnlyList<ClipboardEntry> ordered, Func<ClipboardEntry, string?> key)
    {
        var seen = new HashSet<string>();
        var visible = new List<ClipboardEntry>(ordered.Count);
        var hidden = new HashSet<string>();
        foreach (var entry in ordered)
        {
            string? print = key(entry);
            if (print != null && !seen.Add(print))
            {
                hidden.Add(entry.Key());
                continue;
            }
            visible.Add(entry);
        }
        return (visible, hidden);
    }

    // What Fold hid leaves the stacks (batchOf: Key() -> batch id): a stack
    // that lost cards and is left with fewer than two - and isn't waiting for
    // more (expected: batch id -> size promised) - is plain cards. Its front
    // gone, the next card shown leads it, as when a front card is deleted.
    public static void DropFolded(Dictionary<string, string> batchOf, IReadOnlyDictionary<string, int> expected, IReadOnlySet<string> hidden)
    {
        var shrunk = new HashSet<string>();
        foreach (string key in hidden)
        {
            if (batchOf.Remove(key, out string? batch)) shrunk.Add(batch);
        }
        foreach (string batch in shrunk)
        {
            if (expected.ContainsKey(batch)) continue;
            var members = batchOf.Where(pair => pair.Value == batch).Select(pair => pair.Key).ToList();
            if (members.Count >= HistoryBatch.GroupMinItems) continue;
            foreach (string key in members) batchOf.Remove(key);
        }
    }

    // The n entries with the latest times - every one tied with the n-th as
    // well - as the trim compares them.
    public static List<ClipboardEntry> Newest(IReadOnlyList<ClipboardEntry> history, int n)
    {
        if (n <= 0 || history.Count == 0) return new List<ClipboardEntry>();
        var byTime = history.OrderByDescending(entry => entry.Timestamp).ToList();
        if (byTime.Count <= n) return byTime;
        DateTime boundary = byTime[n - 1].Timestamp;
        return byTime.TakeWhile(entry => entry.Timestamp >= boundary).ToList();
    }

    private static string Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
}
