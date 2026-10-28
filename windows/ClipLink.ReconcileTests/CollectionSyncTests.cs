using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Xunit;

namespace ClipLink.ReconcileTests;

public class CollectionSyncTests
{
    // A card: the key is what it is, the text what it shows (Update changes it).
    private sealed class Card
    {
        public Card(string key, string text) { Key = key; Text = text; }
        public string Key { get; }
        public string Text { get; set; }
    }

    private static IReadOnlyList<(string Key, string Text)> Source(params string[] keys) =>
        keys.Select(key => (key, "new " + key)).ToList();

    private static ObservableCollection<Card> Cards(params string[] keys) =>
        new(keys.Select(key => new Card(key, "old " + key)));

    private static void Sync(ObservableCollection<Card> target, IReadOnlyList<(string Key, string Text)> source) =>
        CollectionSync.ByKey(target, source, card => card.Key, item => item.Key,
            item => new Card(item.Key, item.Text), (card, item) => card.Text = item.Text);

    private static string[] Keys(IEnumerable<Card> cards) => cards.Select(card => card.Key).ToArray();

    // What the Synced page's ItemsView (an ItemsRepeater) does with the
    // collection's notifications: Add and Remove are followed, Move is not
    // (it was seen leaving every card showing what it showed before).
    private sealed class Repeater
    {
        private readonly List<Card> shown;
        public List<NotifyCollectionChangedAction> Actions { get; } = new();

        public Repeater(ObservableCollection<Card> collection)
        {
            shown = collection.ToList();
            collection.CollectionChanged += (_, e) =>
            {
                Actions.Add(e.Action);
                switch (e.Action)
                {
                    case NotifyCollectionChangedAction.Add:
                        shown.Insert(e.NewStartingIndex, (Card)e.NewItems![0]!);
                        break;
                    case NotifyCollectionChangedAction.Remove:
                        shown.RemoveAt(e.OldStartingIndex);
                        break;
                    case NotifyCollectionChangedAction.Move:
                        break;
                    default:
                        throw new InvalidOperationException($"unexpected {e.Action}");
                }
            };
        }

        public string[] Shown => Keys(shown);
    }

    // Syncs and checks all that matters: the collection is the source, the
    // repeater shows the collection, and no Move was ever raised.
    private static Repeater SyncAndCheck(ObservableCollection<Card> target, params string[] keys)
    {
        var repeater = new Repeater(target);
        Sync(target, Source(keys));
        Assert.Equal(keys, Keys(target));
        Assert.Equal(keys, repeater.Shown);
        Assert.DoesNotContain(NotifyCollectionChangedAction.Move, repeater.Actions);
        return repeater;
    }

    [Fact]
    public void DeletingTheFirstCardOfThreeRemovesThatCard()
    {
        // The reported bug: [text, picture, pdf] showed [text, picture] after deleting the text.
        var cards = Cards("text", "picture", "pdf");
        var repeater = SyncAndCheck(cards, "picture", "pdf");
        Assert.Equal(new[] { NotifyCollectionChangedAction.Remove }, repeater.Actions);
    }

    [Fact]
    public void DeletingAMiddleCardRemovesThatCard()
    {
        var repeater = SyncAndCheck(Cards("a", "b", "c", "d"), "a", "c", "d");
        Assert.Equal(new[] { NotifyCollectionChangedAction.Remove }, repeater.Actions);
    }

    [Fact]
    public void DeletingTheLastCardRemovesThatCard()
    {
        var repeater = SyncAndCheck(Cards("a", "b", "c"), "a", "b");
        Assert.Equal(new[] { NotifyCollectionChangedAction.Remove }, repeater.Actions);
    }

    [Fact]
    public void DeletingSeveralCardsAtOnce()
    {
        SyncAndCheck(Cards("a", "b", "c", "d", "e"), "b", "d");
    }

    [Fact]
    public void DeletingEveryCardEmptiesTheList()
    {
        SyncAndCheck(Cards("a", "b", "c"));
    }

    [Fact]
    public void ANewCardGoesInAtTheTop()
    {
        var repeater = SyncAndCheck(Cards("a", "b"), "new", "a", "b");
        Assert.Equal(new[] { NotifyCollectionChangedAction.Add }, repeater.Actions);
    }

    [Fact]
    public void ACardArrivingInTheMiddleAndOneGoneAtTheSameTime()
    {
        SyncAndCheck(Cards("a", "b", "c"), "a", "x", "c");
    }

    [Fact]
    public void AListFromNothing()
    {
        SyncAndCheck(Cards(), "a", "b", "c");
    }

    [Fact]
    public void ACardThatReallyChangesPlaceIsFollowedWithoutAMove()
    {
        SyncAndCheck(Cards("a", "b", "c"), "c", "a", "b");
        SyncAndCheck(Cards("a", "b", "c"), "c", "b", "a");
    }

    [Fact]
    public void CardsAreKeptNotRecreated()
    {
        var cards = Cards("a", "b", "c");
        var b = cards[1];
        var c = cards[2];
        Sync(cards, Source("b", "c"));
        Assert.Same(b, cards[0]);
        Assert.Same(c, cards[1]);
        Sync(cards, Source("c", "b"));
        Assert.Same(c, cards[0]);
        Assert.Same(b, cards[1]);
    }

    [Fact]
    public void KeptCardsAreUpdatedAndNewOnesCreatedFromTheSource()
    {
        var cards = Cards("a", "b");
        var b = cards[1];
        Sync(cards, Source("x", "b"));
        Assert.Same(b, cards[1]);
        Assert.Equal("new b", b.Text);
        Assert.Equal("new x", cards[0].Text);
    }

    [Fact]
    public void NothingChangedRaisesNothing()
    {
        var cards = Cards("a", "b", "c");
        var repeater = new Repeater(cards);
        Sync(cards, Source("a", "b", "c"));
        Assert.Empty(repeater.Actions);
    }

    [Fact]
    public void SeveralDeletionsInARow()
    {
        // The Synced page after the user deletes cards one by one.
        var cards = Cards("a", "b", "c", "d", "e", "f");
        var repeater = new Repeater(cards);
        foreach (var keys in new[] { new[] { "b", "c", "d", "e", "f" }, new[] { "b", "d", "e", "f" }, new[] { "b", "d", "e" }, new[] { "d", "e" } })
        {
            Sync(cards, Source(keys));
            Assert.Equal(keys, Keys(cards));
            Assert.Equal(keys, repeater.Shown);
        }
        Assert.DoesNotContain(NotifyCollectionChangedAction.Move, repeater.Actions);
    }

    [Fact]
    public void AnyListToAnyOtherListEndsUpRight()
    {
        // Random walks over a small set of keys, in every kind of change at once.
        var random = new Random(20261028);
        var all = Enumerable.Range(0, 8).Select(i => "k" + i).ToArray();
        string[] Pick() => all.Where(_ => random.Next(2) == 0).OrderBy(_ => random.Next()).ToArray();

        var cards = Cards();
        var repeater = new Repeater(cards);
        for (int round = 0; round < 500; round++)
        {
            var keys = Pick();
            Sync(cards, Source(keys));
            Assert.Equal(keys, Keys(cards));
            Assert.Equal(keys, repeater.Shown);
        }
        Assert.DoesNotContain(NotifyCollectionChangedAction.Move, repeater.Actions);
    }
}
