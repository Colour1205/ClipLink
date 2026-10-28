using System.Collections.ObjectModel;

namespace ClipLink;

// Keeps an ObservableCollection that a page shows in step with the engine's
// latest list. Plain C# on purpose (no WinUI), so ClipLink.ReconcileTests can
// link this file in and run it.
internal static class CollectionSync
{
    // Makes target match source, in source's order, reusing the items it
    // already has by key - so a card keeps its thumbnail, a row its focus,
    // and the list its scroll position.
    //
    // Only Add and Remove notifications are raised, never Move: the Synced
    // page's ItemsView (an ItemsRepeater) ignores a Move - its cards go on
    // showing what they showed, and the Remove after it then takes the wrong
    // card away (delete the first of three and the last one vanishes instead).
    public static void ByKey<TItem, TSource>(ObservableCollection<TItem> target, IReadOnlyList<TSource> source,
        Func<TItem, string> keyOfItem, Func<TSource, string> keyOfSource, Func<TSource, TItem> create, Action<TItem, TSource> update)
    {
        // What's gone first, so that a deletion is just a Remove and the
        // items after it stay where they are.
        var wanted = new HashSet<string>(source.Select(keyOfSource));
        for (int i = target.Count - 1; i >= 0; i--)
        {
            if (!wanted.Contains(keyOfItem(target[i]))) target.RemoveAt(i);
        }

        var existing = new Dictionary<string, TItem>();
        foreach (var item in target) existing.TryAdd(keyOfItem(item), item);
        for (int i = 0; i < source.Count; i++)
        {
            if (existing.TryGetValue(keyOfSource(source[i]), out var item))
            {
                update(item, source[i]);
                int at = target.IndexOf(item);
                if (at != i)
                {
                    // An item that really changed place (not a Move, see above).
                    target.RemoveAt(at);
                    target.Insert(i, item);
                }
            }
            else
            {
                target.Insert(i, create(source[i]));
            }
        }
        while (target.Count > source.Count) target.RemoveAt(target.Count - 1);
    }
}
