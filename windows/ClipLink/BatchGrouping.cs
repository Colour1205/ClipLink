using ClipboardDaemon.Storage;

namespace ClipLink;

// Which cards the Synced page shows when entries that arrived together in one
// history batch are folded into a stack. Plain C# on purpose (no WinUI), so
// ClipLink.Tests can link this file in and run it. Nothing here is stored: the
// rows are worked out again from the history (newest first) every time, so
// deleting, trimming, clearing and expanding all follow from the same rule.
internal static class BatchGrouping
{
    // An entry as grouping sees it: BatchId and Expected are HistoryItem's
    // BatchId and BatchExpected.
    internal sealed record Entry(string Key, string? BatchId, int? Expected = null);

    // One card on the page. HiddenKeys: the other members of a stack, newest
    // first, folded away behind the front card. Empty for a normal card.
    // Pending: more members a history_head promised that have not arrived yet
    // (their batch is on its way), so the stack already has its real size.
    internal sealed record Row(string FrontKey, string? BatchId, IReadOnlyList<string> HiddenKeys, int Pending = 0)
    {
        // How many more items the front card stands for.
        public int Hidden => HiddenKeys.Count + Pending;
        public bool IsStack => Hidden > 0;
    }

    // newestFirst is the history as the engine lists it. expanded: batch ids
    // the user has opened - they stay normal cards, never fold again. A stack
    // sits where its newest member would be; its other members get no row. A
    // batch with fewer than HistoryBatch.GroupMinItems members left in
    // history (the rest deleted or trimmed away) is just a normal card. While
    // a batch's head has promised more than has arrived (Expected), the stack
    // counts max(members, expected) and shows that size already.
    public static List<Row> Build(IReadOnlyList<Entry> newestFirst, ISet<string> expanded)
    {
        var members = new Dictionary<string, List<string>>();
        var expected = new Dictionary<string, int>();
        foreach (var entry in newestFirst)
        {
            if (entry.BatchId is not { } batch || expanded.Contains(batch)) continue;
            if (!members.TryGetValue(batch, out var list)) members[batch] = list = new List<string>();
            list.Add(entry.Key);
            if (entry.Expected is { } size) expected[batch] = Math.Max(size, expected.GetValueOrDefault(batch));
        }

        var rows = new List<Row>(newestFirst.Count);
        var placed = new HashSet<string>();
        foreach (var entry in newestFirst)
        {
            if (entry.BatchId is { } batch && members.TryGetValue(batch, out var list))
            {
                int total = Math.Max(list.Count, expected.GetValueOrDefault(batch));
                if (total >= HistoryBatch.GroupMinItems)
                {
                    if (placed.Add(batch)) rows.Add(new Row(entry.Key, batch, list.Skip(1).ToList(), total - list.Count));
                    continue;
                }
            }
            rows.Add(new Row(entry.Key, null, Array.Empty<string>()));
        }
        return rows;
    }

    // Opened batches that are no longer in history needn't be remembered.
    public static void ForgetExpandedGone(ISet<string> expanded, IReadOnlyList<Entry> newestFirst)
    {
        if (expanded.Count == 0) return;
        var present = new HashSet<string>(newestFirst.Where(e => e.BatchId != null).Select(e => e.BatchId!));
        expanded.IntersectWith(present);
    }
}

// The words the stack adds to the Synced page. (The Windows app has no
// language files: its text is in the XAML and the code, in English.)
internal static class StackText
{
    // The badge: how many more items the front card is hiding.
    public static string Badge(int hidden) => $"+{hidden}";

    // The handle's accessible name.
    public static string ExpandName(int hidden) => hidden == 1 ? "Expand 1 more item" : $"Expand {hidden} more items";

    // Its accessible hint.
    public const string ExpandHint = "Swipe down or press Enter to show them";
}
