using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.Tests;

// A peer's history_batch applied as one unit (HistoryBatch), and which cards
// the Synced page makes of what arrived (BatchGrouping).
public class HistoryBatchTests
{
    private static readonly DateTime Start = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    // Entry n is made n minutes after Start; its signature (and so its Key)
    // is "sig-n".
    private static ClipboardEntry Entry(int n, string device = "PEER") =>
        new($"text {n}", "text", device, Start.AddMinutes(n), $"sig-{n}");

    private static List<ClipboardEntry> Entries(params int[] numbers) => numbers.Select(n => Entry(n)).ToList();

    private static string[] Keys(IEnumerable<ClipboardEntry> entries) => entries.Select(e => e.Key()).ToArray();

    private static HistoryBatch.MergeResult MergeInto(List<ClipboardEntry> history, IEnumerable<ClipboardEntry> incoming,
        Func<ClipboardEntry, bool>? isDeleted = null, int max = 25) =>
        HistoryBatch.Merge(history, incoming, isDeleted ?? (_ => false), max);

    // ---- the merge ----

    [Fact]
    public void Merge_adds_every_new_entry_in_the_order_the_batch_listed_them()
    {
        var history = new List<ClipboardEntry>();

        var result = MergeInto(history, Entries(1, 2, 3));

        Assert.Equal(new[] { "sig-1", "sig-2", "sig-3" }, Keys(result.Added));
        Assert.Equal(3, history.Count);
        Assert.Empty(result.Evicted);
    }

    [Fact]
    public void Merge_splits_new_known_and_deleted()
    {
        var history = Entries(1, 2);

        var result = MergeInto(history, Entries(2, 3, 4, 5), isDeleted: e => e.Key() == "sig-4");

        Assert.Equal(new[] { "sig-3", "sig-5" }, Keys(result.Added));
        Assert.Equal(1, result.Duplicates);
        Assert.Equal(1, result.Deleted);
        Assert.Equal(4, history.Count);
    }

    [Fact]
    public void Merge_counts_an_entry_twice_in_the_batch_once()
    {
        var history = new List<ClipboardEntry>();

        var result = MergeInto(history, new[] { Entry(1), Entry(1), Entry(2) });

        Assert.Equal(new[] { "sig-1", "sig-2" }, Keys(result.Added));
        Assert.Equal(1, result.Duplicates);
    }

    [Fact]
    public void Merge_of_the_same_history_again_adds_nothing()
    {
        var history = new List<ClipboardEntry>();
        MergeInto(history, Entries(1, 2, 3));

        var again = MergeInto(history, Entries(1, 2, 3));

        Assert.Empty(again.Added);
        Assert.Equal(3, again.Duplicates);
        Assert.Equal(3, history.Count);
    }

    [Fact]
    public void Merge_trims_once_for_the_whole_batch_and_drops_the_oldest()
    {
        var history = Entries(Enumerable.Range(10, 25).ToArray()); // full: 10..34

        var result = MergeInto(history, Entries(40, 41, 42), max: 25);

        Assert.Equal(25, history.Count);
        Assert.Equal(new[] { "sig-40", "sig-41", "sig-42" }, Keys(result.Added));
        Assert.Equal(new[] { "sig-10", "sig-11", "sig-12" }, Keys(result.Evicted));
    }

    [Fact]
    public void Merge_does_not_call_a_new_entry_added_when_the_cap_pushes_it_straight_out()
    {
        var history = Entries(Enumerable.Range(10, 25).ToArray()); // full, 10..34

        // 1 and 2 are older than everything in history.
        var result = MergeInto(history, Entries(1, 2, 50), max: 25);

        Assert.Equal(new[] { "sig-50" }, Keys(result.Added));
        Assert.Contains(Keys(result.Evicted), key => key == "sig-1");
        Assert.DoesNotContain(history, e => e.Key() == "sig-1");
        Assert.Equal(25, history.Count);
    }

    // ---- Apply: one change, one notification ----

    private sealed class Spy
    {
        public int Changed;
        public int Adds;
        public List<ClipboardEntry> History { get; } = new();
        public HashSet<string> Deleted { get; } = new();

        public HistoryBatch.Outcome Run(IEnumerable<ClipboardEntry> batch, Func<ClipboardEntry, bool>? acceptable = null) =>
            HistoryBatch.Apply(batch, acceptable ?? (_ => true), e => Deleted.Contains(e.Key()),
                add: entries =>
                {
                    Adds++;
                    return HistoryBatch.Merge(History, entries, e => Deleted.Contains(e.Key()), 25);
                },
                changed: () => Changed++);
    }

    [Fact]
    public void Apply_adds_a_whole_batch_in_one_step_and_notifies_once()
    {
        var spy = new Spy();

        var outcome = spy.Run(Entries(1, 2, 3, 4, 5));

        Assert.Equal(5, outcome.Added.Count);
        Assert.Equal(1, spy.Adds);
        Assert.Equal(1, spy.Changed);
    }

    [Fact]
    public void Apply_does_not_notify_when_nothing_is_new()
    {
        var spy = new Spy();
        spy.Run(Entries(1, 2));
        spy.Changed = 0;

        var outcome = spy.Run(Entries(1, 2));

        Assert.Empty(outcome.Added);
        Assert.Equal(0, spy.Changed);
    }

    [Fact]
    public void Apply_skips_bad_signatures_and_deleted_entries_but_keeps_the_rest()
    {
        var spy = new Spy();
        spy.Deleted.Add("sig-3");

        var outcome = spy.Run(Entries(1, 2, 3, 4), acceptable: e => e.Key() != "sig-2");

        Assert.Equal(new[] { "sig-1", "sig-4" }, Keys(outcome.Added));
        Assert.Equal(1, outcome.Rejected);
        Assert.Equal(1, outcome.Deleted);
        Assert.Equal(1, spy.Changed);
    }

    [Fact]
    public void Apply_with_only_rejected_entries_changes_nothing()
    {
        var spy = new Spy();

        var outcome = spy.Run(Entries(1, 2), acceptable: _ => false);

        Assert.Empty(outcome.Added);
        Assert.Equal(2, outcome.Rejected);
        Assert.Equal(0, spy.Changed);
        Assert.Empty(spy.History);
    }

    // ---- which cards the page shows ----

    private static List<BatchGrouping.Entry> Listing(params (string Key, string? Batch)[] newestFirst) =>
        newestFirst.Select(e => new BatchGrouping.Entry(e.Key, e.Batch)).ToList();

    private static readonly ISet<string> NoneOpened = new HashSet<string>();

    [Fact]
    public void A_batch_of_two_or_more_is_one_stack_with_the_newest_in_front()
    {
        var rows = BatchGrouping.Build(Listing(("e5", "1"), ("e4", "1"), ("e3", "1")), NoneOpened);

        var row = Assert.Single(rows);
        Assert.Equal("e5", row.FrontKey);
        Assert.Equal(new[] { "e4", "e3" }, row.HiddenKeys);
        Assert.True(row.IsStack);
    }

    [Fact]
    public void The_threshold_is_two_new_entries()
    {
        Assert.Equal(2, HistoryBatch.GroupMinItems);

        var two = BatchGrouping.Build(Listing(("b", "1"), ("a", "1")), NoneOpened);
        Assert.Single(two);
        Assert.Single(two[0].HiddenKeys); // one layer behind

        var one = BatchGrouping.Build(Listing(("a", "1")), NoneOpened);
        Assert.False(Assert.Single(one).IsStack);
    }

    [Fact]
    public void A_stack_sits_where_its_newest_member_is_and_the_other_cards_keep_their_order()
    {
        // live (newest), then a batch of three, then an older card in the middle of it, then more.
        var rows = BatchGrouping.Build(Listing(
            ("live", null), ("b3", "7"), ("b2", "7"), ("mine", null), ("b1", "7"), ("old", null)), NoneOpened);

        Assert.Equal(new[] { "live", "b3", "mine", "old" }, rows.Select(r => r.FrontKey));
        Assert.Equal(new[] { "b2", "b1" }, rows[1].HiddenKeys);
        Assert.False(rows[0].IsStack);
        Assert.False(rows[2].IsStack);
    }

    [Fact]
    public void Two_batches_are_two_stacks()
    {
        var rows = BatchGrouping.Build(Listing(("a2", "1"), ("b2", "2"), ("a1", "1"), ("b1", "2")), NoneOpened);

        Assert.Equal(new[] { "a2", "b2" }, rows.Select(r => r.FrontKey));
        Assert.All(rows, row => Assert.Single(row.HiddenKeys));
        Assert.Equal(new[] { "a1" }, rows[0].HiddenKeys);
        Assert.Equal(new[] { "b1" }, rows[1].HiddenKeys);
    }

    [Fact]
    public void Deleting_the_front_makes_the_next_newest_the_front()
    {
        var before = BatchGrouping.Build(Listing(("c", "1"), ("b", "1"), ("a", "1")), NoneOpened);
        Assert.Equal("c", before[0].FrontKey);

        var after = BatchGrouping.Build(Listing(("b", "1"), ("a", "1")), NoneOpened);

        Assert.Equal("b", after[0].FrontKey);
        Assert.Equal(new[] { "a" }, after[0].HiddenKeys);
    }

    [Fact]
    public void With_one_member_left_the_stack_is_a_normal_card()
    {
        var rows = BatchGrouping.Build(Listing(("a", "1")), NoneOpened);

        Assert.False(Assert.Single(rows).IsStack);
        Assert.Equal("a", rows[0].FrontKey);
    }

    [Fact]
    public void A_stack_with_every_member_deleted_is_gone()
    {
        Assert.Empty(BatchGrouping.Build(Listing(), NoneOpened));
    }

    [Fact]
    public void Trimming_members_away_shrinks_the_stack()
    {
        // Five arrived together; the cap pushed the two oldest out of history.
        var rows = BatchGrouping.Build(Listing(("e5", "1"), ("e4", "1"), ("e3", "1")), NoneOpened);

        Assert.Equal(2, Assert.Single(rows).HiddenKeys.Count);
    }

    [Fact]
    public void An_opened_stack_is_ordinary_cards_and_does_not_fold_again()
    {
        var items = Listing(("c", "1"), ("b", "1"), ("a", "1"));
        var opened = new HashSet<string> { "1" };

        var rows = BatchGrouping.Build(items, opened);

        Assert.Equal(new[] { "c", "b", "a" }, rows.Select(r => r.FrontKey));
        Assert.All(rows, row => Assert.False(row.IsStack));
    }

    [Fact]
    public void An_opened_batch_that_has_left_history_is_forgotten()
    {
        var opened = new HashSet<string> { "1", "2" };

        BatchGrouping.ForgetExpandedGone(opened, Listing(("a", "2"), ("b", null)));

        Assert.Equal(new[] { "2" }, opened);
    }

    // ---- the whole path: engine batches and the page ----

    [Fact]
    public void A_batch_is_shown_as_one_stack_and_the_same_batch_again_changes_nothing()
    {
        var spy = new Spy();
        spy.Run(Entries(1, 2, 3, 4));
        // What HistoryAccess does with a batch of two or more: they share a batch id.
        var ids = spy.History.ToDictionary(e => e.Key(), _ => "1");

        var rows = BatchGrouping.Build(
            spy.History.OrderByDescending(e => e.Timestamp).Select(e => new BatchGrouping.Entry(e.Key(), ids[e.Key()])).ToList(),
            NoneOpened);
        Assert.Equal("sig-4", Assert.Single(rows).FrontKey);

        spy.Changed = 0;
        var again = spy.Run(Entries(1, 2, 3, 4));
        Assert.Empty(again.Added);
        Assert.Equal(0, spy.Changed);
    }

    [Fact]
    public void A_live_entry_after_a_batch_is_a_normal_card_on_top()
    {
        var rows = BatchGrouping.Build(Listing(("live", null), ("b2", "1"), ("b1", "1")), NoneOpened);

        Assert.Equal(new[] { "live", "b2" }, rows.Select(r => r.FrontKey));
        Assert.False(rows[0].IsStack);
        Assert.True(rows[1].IsStack);
    }
}
