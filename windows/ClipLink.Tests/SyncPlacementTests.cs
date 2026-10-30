using ClipboardDaemon.Storage;
using ClipLink;
using Xunit;

namespace ClipLink.Tests;

// Where things sit on the Synced page after a sync: what just arrived goes on
// top whatever its time (the newest new item of a sync in front of the rest of
// it, as one stack), an opened stack keeps its entries together right below its
// front card, and the trim spares the item put on the clipboard. BatchGroups is
// what HistoryAccess runs; these tests drive it the way the engine does, on a
// plain list.
public class SyncPlacementTests
{
    private static readonly DateTime Start = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    // Entry n is made n minutes after Start; its Key() is "sig-n".
    private static ClipboardEntry Entry(int n, string device = "PEER") =>
        new($"text {n}", "text", device, Start.AddMinutes(n), $"sig-{n}");

    private static List<ClipboardEntry> Entries(params int[] numbers) => numbers.Select(n => Entry(n)).ToList();

    private static string[] Sigs(params int[] numbers) => numbers.Select(n => $"sig-{n}").ToArray();

    private sealed class Rig
    {
        public const int Max = 25;
        public List<ClipboardEntry> History { get; } = new();
        public HashSet<string> Deleted { get; } = new();
        public BatchGroups Groups { get; } = new();
        public object Conn { get; } = new();

        // Entries already in history when the app started: no blocks.
        public Rig(params int[] restored)
        {
            History.AddRange(Entries(restored));
        }

        // An item copied here, or received live: what HistoryAccess.addToHistory does.
        public void Live(int n)
        {
            History.Add(Entry(n));
            Groups.Arrived(Entry(n).Key());
            HistoryBatch.TrimOldest(History, Max, Groups.ProtectedKey);
            Groups.Forget(History);
        }

        public void Sync(int size, object? conn = null) => Groups.BeginSync(conn ?? Conn, size);

        // One answer to a history_request, the way HandleSyncAnswer applies it.
        public HistoryBatch.MergeResult Answer(int[] numbers, bool convenience, bool last = false, object? conn = null, long? nowMs = null) =>
            Groups.ApplyAnswer(conn ?? Conn, History, Entries(numbers), e => Deleted.Contains(e.Key()), Max, convenience, last, nowMs);

        // The answer to a request that had expired, the way HandleLateAnswer applies it.
        public HistoryBatch.MergeResult Late(params int[] numbers) =>
            Groups.ApplyLate(History, Entries(numbers), e => Deleted.Contains(e.Key()), Max);

        public HistoryBatch.MergeResult Batch(int[] numbers, object? conn = null) =>
            Groups.ApplyBatch(conn ?? Conn, History, Entries(numbers), e => Deleted.Contains(e.Key()), Max);

        // A local or remote delete: what HistoryAccess.RemoveMany does.
        public void Remove(params int[] numbers)
        {
            foreach (int n in numbers)
            {
                Deleted.Add($"sig-{n}");
                History.RemoveAll(e => e.Key() == $"sig-{n}");
            }
            Groups.Forget(History);
        }

        public string[] Order() => Groups.Order(History).Select(e => e.Key()).ToArray();

        // The cards the Synced page makes of the history right now.
        public List<BatchGrouping.Row> Rows(ISet<string>? opened = null)
        {
            var (batchOf, expected) = Groups.Snapshot();
            var listing = Groups.Order(History).Select(e =>
            {
                string? batch = batchOf.GetValueOrDefault(e.Key());
                return new BatchGrouping.Entry(e.Key(), batch, batch != null && expected.TryGetValue(batch, out int size) ? size : null);
            }).ToList();
            return BatchGrouping.Build(listing, opened ?? new HashSet<string>());
        }

        // The keys of the cards, in order, when every stack in `opened` is open.
        public string[] Cards(ISet<string>? opened = null) => Rows(opened).Select(r => r.FrontKey).ToArray();

        public string? BatchIdOf(int n) => Groups.Snapshot().BatchOf.GetValueOrDefault($"sig-{n}");
    }

    // ---- the front item ----

    [Fact]
    public void The_front_item_goes_on_top_although_it_is_older_than_the_items_below()
    {
        var rig = new Rig(10, 11, 12);
        rig.Sync(1);

        var merged = rig.Answer(new[] { 5 }, convenience: true, last: true);

        Assert.Equal(Entries(5), merged.Added);
        Assert.Equal(Sigs(5, 12, 11, 10), rig.Order());
        Assert.Equal(Sigs(5, 12, 11, 10), rig.Cards());
        Assert.All(rig.Rows(), row => Assert.False(row.IsStack));
    }

    [Fact]
    public void Without_a_sync_the_history_is_the_timeline()
    {
        var rig = new Rig(3, 12, 10, 11);

        Assert.Equal(Sigs(12, 11, 10, 3), rig.Order());
    }

    [Fact]
    public void A_live_item_arriving_later_goes_above_the_block_even_when_its_time_is_older()
    {
        var rig = new Rig(20, 21);
        rig.Sync(1);
        rig.Answer(new[] { 7 }, convenience: true, last: true);

        rig.Live(2);

        Assert.Equal(Sigs(2, 7, 21, 20), rig.Order());
        rig.Live(30);
        Assert.Equal(Sigs(30, 2, 7, 21, 20), rig.Order());
    }

    [Fact]
    public void A_later_sync_goes_above_an_earlier_one()
    {
        var rig = new Rig(20);
        var other = new object();
        rig.Sync(1);
        rig.Answer(new[] { 9 }, convenience: true, last: true);
        rig.Sync(1, other);

        rig.Answer(new[] { 4 }, convenience: true, last: true, conn: other);

        Assert.Equal(Sigs(4, 9, 20), rig.Order());
    }

    [Fact]
    public void Two_items_of_the_same_time_keep_a_stable_order()
    {
        var rig = new Rig();
        rig.History.Add(new ClipboardEntry("a", "text", "PEER", Start, "sig-a"));
        rig.History.Add(new ClipboardEntry("b", "text", "PEER", Start, "sig-b"));

        Assert.Equal(new[] { "sig-a", "sig-b" }, rig.Groups.Order(rig.History).Select(e => e.Key()));
    }

    // ---- a stack ----

    [Fact]
    public void A_sync_of_several_items_is_one_stack_with_the_front_item_in_front_and_the_size_asked_for()
    {
        var rig = new Rig(20, 21);
        rig.Sync(3);

        rig.Answer(new[] { 7 }, convenience: true);

        // The newest new item is in, the stack already counts what was asked for.
        var rows = rig.Rows();
        Assert.Equal("sig-7", rows[0].FrontKey);
        Assert.True(rows[0].IsStack);
        Assert.Equal(2, rows[0].Pending);
        Assert.Equal(2, rows[0].Hidden);
        Assert.Equal(Sigs(7, 21, 20), rig.Cards());
    }

    [Fact]
    public void The_next_answer_joins_the_stack_and_the_size_is_what_arrived_when_the_last_is_in()
    {
        var rig = new Rig(20, 21);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);

        var merged = rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        Assert.True(merged.GroupChanged);
        var rows = rig.Rows();
        Assert.Equal("sig-7", rows[0].FrontKey);
        Assert.Equal(Sigs(6, 5), rows[0].HiddenKeys);
        Assert.Equal(0, rows[0].Pending);
        Assert.Empty(rig.Groups.Snapshot().Expected);
        Assert.Equal(rig.BatchIdOf(7), rig.BatchIdOf(5));
    }

    [Fact]
    public void A_stack_that_gets_less_than_asked_has_the_size_that_arrived()
    {
        var rig = new Rig(20);
        rig.Sync(4);
        rig.Answer(new[] { 7 }, convenience: true);

        rig.Answer(new[] { 6 }, convenience: false, last: true); // the other two were gone at the sender

        var row = rig.Rows()[0];
        Assert.True(row.IsStack);
        Assert.Equal(Sigs(6), row.HiddenKeys);
        Assert.Equal(0, row.Pending);
    }

    [Fact]
    public void A_stack_that_ends_with_only_the_front_item_is_a_single_card()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);

        var merged = rig.Answer(Array.Empty<int>(), convenience: false, last: true);

        Assert.True(merged.GroupChanged); // the page must show the real size
        Assert.False(rig.Rows()[0].IsStack);
        Assert.Equal(Sigs(7, 20), rig.Cards());
        Assert.Null(rig.BatchIdOf(7));
    }

    [Fact]
    public void One_item_asked_for_is_a_card_not_a_stack()
    {
        var rig = new Rig(20);
        rig.Sync(1);

        rig.Answer(new[] { 7 }, convenience: true, last: true);

        Assert.False(rig.Rows()[0].IsStack);
        Assert.Null(rig.BatchIdOf(7));
    }

    [Fact]
    public void Opening_the_stack_keeps_its_items_together_right_below_the_front_above_every_other_item()
    {
        var rig = new Rig(20, 21, 22);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);
        rig.Answer(new[] { 6, 5 }, convenience: false, last: true);
        string batch = rig.BatchIdOf(7)!;

        Assert.Equal(Sigs(7, 22, 21, 20), rig.Cards());
        // Opened: the other two come out below the front, not back where their times put them.
        Assert.Equal(Sigs(7, 6, 5, 22, 21, 20), rig.Cards(new HashSet<string> { batch }));
    }

    [Fact]
    public void An_opened_stack_stays_below_a_newer_live_item_and_above_the_rest()
    {
        var rig = new Rig(20, 21);
        rig.Sync(3);
        rig.Answer(new[] { 7, 6, 5 }, convenience: true, last: true);
        rig.Live(25);

        string batch = rig.BatchIdOf(7)!;

        Assert.Equal(Sigs(25, 7, 6, 5, 21, 20), rig.Cards(new HashSet<string> { batch }));
    }

    [Fact]
    public void The_others_in_a_stack_are_newest_first_whatever_order_they_arrived_in()
    {
        var rig = new Rig();
        rig.Sync(4);
        rig.Answer(new[] { 9 }, convenience: true);

        rig.Answer(new[] { 5, 8, 6 }, convenience: false, last: true);

        Assert.Equal(Sigs(9, 8, 6, 5), rig.Order());
        Assert.Equal(Sigs(8, 6, 5), rig.Rows()[0].HiddenKeys);
    }

    [Fact]
    public void A_front_item_older_than_the_others_in_its_stack_is_still_in_front()
    {
        var rig = new Rig();
        rig.Sync(3);

        // (An answer can bring more than was asked for.)
        rig.Answer(new[] { 5 }, convenience: true);
        rig.Answer(new[] { 8, 6 }, convenience: false, last: true);

        Assert.Equal(Sigs(5, 8, 6), rig.Order());
    }

    [Fact]
    public void When_the_front_item_is_not_there_the_stack_has_no_front_item_and_the_newest_leads()
    {
        var rig = new Rig(20);
        rig.Sync(3);

        rig.Answer(Array.Empty<int>(), convenience: true); // gone at the sender
        rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        var rows = rig.Rows();
        Assert.Equal("sig-6", rows[0].FrontKey);
        Assert.Equal(Sigs(5), rows[0].HiddenKeys);
        Assert.Null(rig.Groups.ProtectedKey);
    }

    [Fact]
    public void An_opened_stack_is_not_waiting_for_more()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);
        string batch = rig.BatchIdOf(7)!;

        // Opened while the rest is on its way: no pending card, only what is here.
        Assert.Equal(Sigs(7, 20), rig.Cards(new HashSet<string> { batch }));
        Assert.Equal(0, rig.Rows(new HashSet<string> { batch }).Sum(row => row.Pending));
    }

    // ---- the trim ----

    [Fact]
    public void The_trim_spares_the_front_item_and_drops_the_oldest_other_item()
    {
        var rig = new Rig(Enumerable.Range(100, 25).ToArray());
        rig.Sync(1);

        var merged = rig.Answer(new[] { 5 }, convenience: true, last: true);

        Assert.Equal(Entries(5), merged.Added);
        Assert.Equal(25, rig.History.Count);
        Assert.Contains("sig-5", rig.History.Select(e => e.Key()));
        Assert.DoesNotContain("sig-100", rig.History.Select(e => e.Key()));
        Assert.Equal(new[] { Entry(100) }, merged.Evicted);
        Assert.Equal("sig-5", rig.Order()[0]);
        Assert.Equal("sig-5", rig.Groups.ProtectedKey);
    }

    [Fact]
    public void The_front_item_is_trimmed_by_the_normal_rule_once_a_newer_block_arrives()
    {
        var rig = new Rig(Enumerable.Range(100, 25).ToArray());
        rig.Sync(1);
        rig.Answer(new[] { 5 }, convenience: true, last: true);

        rig.Live(300);

        Assert.Equal(25, rig.History.Count);
        Assert.DoesNotContain("sig-5", rig.History.Select(e => e.Key()));
        Assert.Contains("sig-101", rig.History.Select(e => e.Key()));
        Assert.Contains("sig-300", rig.History.Select(e => e.Key()));
        Assert.Null(rig.Groups.ProtectedKey);
    }

    [Fact]
    public void Only_the_front_item_is_protected_not_the_other_items_of_the_stack()
    {
        var rig = new Rig(Enumerable.Range(100, 25).ToArray());
        rig.Sync(3);
        rig.Answer(new[] { 5 }, convenience: true);

        var merged = rig.Answer(new[] { 4, 3 }, convenience: false, last: true);

        // The two others are older than everything: added and trimmed at once.
        Assert.Empty(merged.Added);
        Assert.Equal(25, rig.History.Count);
        Assert.Contains("sig-5", rig.History.Select(e => e.Key()));
        Assert.DoesNotContain("sig-4", rig.History.Select(e => e.Key()));
        Assert.False(rig.Rows()[0].IsStack);
    }

    [Fact]
    public void The_total_stays_25_through_a_sync_that_brings_many_items()
    {
        var rig = new Rig(Enumerable.Range(100, 20).ToArray());
        rig.Sync(10);
        rig.Answer(new[] { 130 }, convenience: true);

        rig.Answer(Enumerable.Range(121, 9).Reverse().ToArray(), convenience: false, last: true);

        Assert.Equal(25, rig.History.Count);
        Assert.Equal("sig-130", rig.Order()[0]);
    }

    [Fact]
    public void A_version_1_head_with_a_newest_older_than_a_full_history_keeps_it_and_drops_the_oldest_other()
    {
        var rig = new Rig(Enumerable.Range(100, 25).ToArray());
        var head = HistoryHead.ForBatch(Entries(5, 4))!;

        var result = rig.Groups.HeadReceived(rig.Conn, rig.History, head, rig.Deleted.Contains, Rig.Max);

        Assert.Equal(Entry(5), result.Added);
        Assert.Equal(25, rig.History.Count);
        Assert.Equal("sig-5", rig.Order()[0]);
        Assert.Equal(new[] { Entry(100) }, result.Evicted);
    }

    // ---- version 1 ----

    [Fact]
    public void A_version_1_batch_puts_its_newest_new_item_in_front_even_when_older_than_the_own_newest()
    {
        var rig = new Rig(20, 21);

        var merged = rig.Batch(new[] { 1, 3, 2 });

        Assert.Equal(Entry(3), HistoryBatch.Newest(merged.Added));
        Assert.Equal(Sigs(3, 2, 1, 21, 20), rig.Order());
        var rows = rig.Rows();
        Assert.Equal("sig-3", rows[0].FrontKey);
        Assert.True(rows[0].IsStack);
        Assert.Equal(Sigs(2, 1), rows[0].HiddenKeys);
        Assert.Equal("sig-3", rig.Groups.ProtectedKey);
    }

    [Fact]
    public void A_version_1_batch_of_one_new_item_is_a_card_on_top()
    {
        var rig = new Rig(20, 21);

        rig.Batch(new[] { 20, 3 });

        Assert.Equal(Sigs(3, 21, 20), rig.Cards());
        Assert.False(rig.Rows()[0].IsStack);
    }

    [Fact]
    public void A_version_1_batch_in_a_full_history_keeps_its_newest_even_if_older_than_all()
    {
        var rig = new Rig(Enumerable.Range(100, 25).ToArray());

        var merged = rig.Batch(new[] { 5, 4 });

        Assert.Equal(Entries(5), merged.Added); // (the older one is trimmed at once)
        Assert.Equal(25, rig.History.Count);
        Assert.Equal("sig-5", rig.Order()[0]);
    }

    [Fact]
    public void A_version_1_head_then_batch_places_the_batch_in_the_block_the_head_made()
    {
        var rig = new Rig(20, 21);
        var peer = Entries(5, 4, 3);
        rig.Groups.HeadReceived(rig.Conn, rig.History, HistoryHead.ForBatch(peer)!, rig.Deleted.Contains, Rig.Max);

        var merged = rig.Batch(new[] { 3, 4, 5 });

        Assert.True(merged.HeadApplied);
        Assert.Equal(Sigs(5, 4, 3, 21, 20), rig.Order());
        Assert.Equal(Sigs(4, 3), rig.Rows()[0].HiddenKeys);
    }

    [Fact]
    public void A_version_1_head_that_never_gets_its_batch_stops_waiting_after_90_seconds()
    {
        var rig = new Rig();
        rig.Groups.HeadReceived(rig.Conn, rig.History, HistoryHead.ForBatch(Entries(5, 4, 3))!, rig.Deleted.Contains, Rig.Max, nowMs: 1000);
        Assert.Equal(2, rig.Rows()[0].Pending);

        Assert.False(rig.Groups.ExpireHeads(rig.History, 1000 + 89_999, 90_000));
        Assert.Equal(2, rig.Rows()[0].Pending);
        Assert.True(rig.Groups.ExpireHeads(rig.History, 1000 + 90_000, 90_000));

        var row = Assert.Single(rig.Rows());
        Assert.False(row.IsStack);
        Assert.Equal(0, row.Pending);
        Assert.False(rig.Groups.ExpireHeads(rig.History, 1000 + 200_000, 90_000)); // nothing left to expire
    }

    // ---- waiting ends ----

    [Fact]
    public void When_a_request_times_out_or_the_connection_closes_the_stack_stops_waiting()
    {
        var rig = new Rig(20);
        rig.Sync(4);
        rig.Answer(new[] { 7 }, convenience: true);
        Assert.Equal(3, rig.Rows()[0].Pending);

        Assert.True(rig.Groups.EndSync(rig.Conn, rig.History));

        var row = rig.Rows()[0];
        Assert.False(row.IsStack); // only the front item arrived
        Assert.Equal(0, row.Pending);
        Assert.False(rig.Groups.EndSync(rig.Conn, rig.History)); // nothing left to end
    }

    [Fact]
    public void A_stack_with_two_or_more_items_stays_a_stack_of_what_arrived_when_waiting_ends()
    {
        var rig = new Rig(20);
        rig.Sync(4);
        rig.Answer(new[] { 7 }, convenience: true);
        rig.Answer(new[] { 6 }, convenience: false);

        rig.Groups.EndSync(rig.Conn, rig.History);

        var row = rig.Rows()[0];
        Assert.True(row.IsStack);
        Assert.Equal(Sigs(6), row.HiddenKeys);
        Assert.Equal(0, row.Pending);
    }

    [Fact]
    public void Two_connections_make_two_separate_stacks()
    {
        var rig = new Rig();
        var other = new object();
        rig.Sync(2);
        rig.Sync(2, other);

        rig.Answer(new[] { 9 }, convenience: true);
        rig.Answer(new[] { 8 }, convenience: true, conn: other);
        rig.Answer(new[] { 7 }, convenience: false, last: true);
        rig.Answer(new[] { 6 }, convenience: false, last: true, conn: other);

        var rows = rig.Rows();
        Assert.Equal(2, rows.Count);
        Assert.Equal("sig-8", rows[0].FrontKey); // the later block first
        Assert.Equal(Sigs(6), rows[0].HiddenKeys);
        Assert.Equal("sig-9", rows[1].FrontKey);
        Assert.Equal(Sigs(7), rows[1].HiddenKeys);
    }

    // ---- quiet ----

    [Fact]
    public void Only_the_front_item_is_announced()
    {
        var rig = new Rig();
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);
        rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        Assert.Equal(new HashSet<string>(Sigs(6, 5)), rig.Groups.QuietKeys());
    }

    [Fact]
    public void Live_items_and_batches_are_announced_as_before()
    {
        var rig = new Rig();
        rig.Live(1);
        rig.Batch(new[] { 4, 3 });

        Assert.Empty(rig.Groups.QuietKeys());
    }

    // ---- deleting ----

    [Fact]
    public void Deleting_the_front_card_puts_the_next_item_in_front()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);
        rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        rig.Remove(7);

        var rows = rig.Rows();
        Assert.Equal("sig-6", rows[0].FrontKey);
        Assert.Equal(Sigs(5), rows[0].HiddenKeys);
        Assert.Equal("sig-20", rows[1].FrontKey);
        Assert.Null(rig.Groups.ProtectedKey); // the item that was protected is gone
    }

    [Fact]
    public void A_stack_left_with_one_item_is_a_single_card()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);
        rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        rig.Remove(6, 5);

        var rows = rig.Rows();
        Assert.Equal(Sigs(7, 20), rig.Cards());
        Assert.All(rows, row => Assert.False(row.IsStack));
    }

    [Fact]
    public void Deleting_a_member_takes_it_out_of_the_stack()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);
        rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        rig.Remove(6);

        var row = rig.Rows()[0];
        Assert.Equal("sig-7", row.FrontKey);
        Assert.Equal(Sigs(5), row.HiddenKeys);
    }

    [Fact]
    public void Deleting_while_the_rest_is_still_coming_leaves_the_rest_to_arrive()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);

        rig.Remove(7);
        var merged = rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        Assert.Equal(2, merged.Added.Count);
        Assert.Equal("sig-6", rig.Rows()[0].FrontKey);
        Assert.Equal(Sigs(5), rig.Rows()[0].HiddenKeys);
    }

    [Fact]
    public void An_item_deleted_here_is_not_added_again_by_an_answer()
    {
        var rig = new Rig(20);
        rig.Deleted.Add("sig-6");
        rig.Sync(3);
        rig.Answer(new[] { 7 }, convenience: true);

        var merged = rig.Answer(new[] { 6, 5 }, convenience: false, last: true);

        Assert.Equal(Entries(5), merged.Added);
        Assert.Equal(1, merged.Deleted);
        Assert.DoesNotContain("sig-6", rig.Order());
    }

    // ---- one clipboard change when two devices answer at once ----

    [Fact]
    public void A_convenience_item_that_is_not_newer_than_one_put_on_the_clipboard_a_moment_ago_is_not_put_there()
    {
        var rig = new Rig(20);
        var other = new object();
        rig.Sync(1);
        rig.Sync(1, other);

        var first = rig.Answer(new[] { 9 }, convenience: true, last: true, nowMs: 1_000);
        var second = rig.Answer(new[] { 4 }, convenience: true, last: true, conn: other, nowMs: 2_000);

        Assert.Equal(Entry(9), first.Applied);
        Assert.Null(second.Applied);
        // It is added, and leads its own block like any front item; but it is not announced.
        Assert.Equal(Entries(4), second.Added);
        Assert.Equal(Sigs(4, 9, 20), rig.Order());
        Assert.Contains("sig-4", rig.Groups.QuietKeys());
        Assert.DoesNotContain("sig-9", rig.Groups.QuietKeys());
    }

    [Fact]
    public void A_convenience_item_with_the_same_time_is_not_newer_either()
    {
        var rig = new Rig(20);
        var other = new object();
        rig.Sync(1);
        rig.Sync(1, other);
        rig.Answer(new[] { 9 }, convenience: true, last: true, nowMs: 1_000);
        var sameTime = new ClipboardEntry("text 9b", "text", "PEER", Start.AddMinutes(9), "sig-9b");

        var again = rig.Groups.ApplyAnswer(other, rig.History, new[] { sameTime }, _ => false, Rig.Max, convenience: true, last: true, nowMs: 2_000);

        Assert.Equal(new[] { sameTime }, again.Added);
        Assert.Null(again.Applied);
    }

    [Fact]
    public void A_newer_convenience_item_is_put_on_the_clipboard_even_a_moment_after_another()
    {
        var rig = new Rig(20);
        var other = new object();
        rig.Sync(1);
        rig.Sync(1, other);
        rig.Answer(new[] { 4 }, convenience: true, last: true, nowMs: 1_000);

        var second = rig.Answer(new[] { 9 }, convenience: true, last: true, conn: other, nowMs: 2_000);

        Assert.Equal(Entry(9), second.Applied);
        Assert.Equal("sig-9", rig.Groups.ProtectedKey);
        Assert.DoesNotContain("sig-9", rig.Groups.QuietKeys());
    }

    [Fact]
    public void After_90_seconds_an_older_convenience_item_is_put_on_the_clipboard_again()
    {
        var rig = new Rig(20);
        var other = new object();
        var third = new object();
        rig.Sync(1);
        rig.Sync(1, other);
        rig.Sync(1, third);
        rig.Answer(new[] { 9 }, convenience: true, last: true, nowMs: 1_000);

        var justBefore = rig.Answer(new[] { 5 }, convenience: true, last: true, conn: other, nowMs: 1_000 + BatchGroups.ConvenienceWindowMs - 1);
        var justAfter = rig.Answer(new[] { 4 }, convenience: true, last: true, conn: third, nowMs: 1_000 + BatchGroups.ConvenienceWindowMs);

        Assert.Null(justBefore.Applied);
        Assert.Equal(Entry(4), justAfter.Applied);
    }

    [Fact]
    public void A_skipped_convenience_item_still_leads_its_stack()
    {
        var rig = new Rig(20);
        var other = new object();
        rig.Sync(1);
        rig.Sync(2, other);
        rig.Answer(new[] { 9 }, convenience: true, last: true, nowMs: 1_000);

        var front = rig.Answer(new[] { 4 }, convenience: true, conn: other, nowMs: 2_000);
        rig.Answer(new[] { 3 }, convenience: false, last: true, conn: other, nowMs: 2_000);

        Assert.Null(front.Applied);
        Assert.Equal(Sigs(4, 3, 9, 20), rig.Order());
        var stack = Assert.Single(rig.Rows(), row => row.IsStack);
        Assert.Equal("sig-4", stack.FrontKey);
        Assert.Equal(1, stack.Hidden);
    }

    [Fact]
    public void A_skipped_convenience_item_is_not_protected_from_the_trim()
    {
        var rig = new Rig(Enumerable.Range(11, 25).ToArray()); // a full history
        var other = new object();
        rig.Sync(1);
        rig.Sync(1, other);
        var first = rig.Answer(new[] { 36 }, convenience: true, last: true, nowMs: 1_000);
        Assert.Equal(Entry(36), first.Applied);
        Assert.Equal(25, rig.History.Count);

        // Older than the one on the clipboard, and older than the whole history: skipped, and trimmed at once
        // (it is the oldest; if it were protected, sig-12 would go instead).
        var second = rig.Answer(new[] { 8 }, convenience: true, last: true, conn: other, nowMs: 2_000);

        Assert.Null(second.Applied);
        Assert.Equal(Entries(8), second.Evicted);
        Assert.Empty(second.Added);
        Assert.Equal(25, rig.History.Count);
        Assert.Contains("sig-12", rig.Order());
        Assert.Contains("sig-36", rig.Order());
    }

    [Fact]
    public void A_skipped_convenience_item_that_starts_a_block_leaves_the_protection_of_the_one_on_the_clipboard()
    {
        // 23 items, so the skipped one fits next to the 24 that are there after the first answer.
        var rig = new Rig(Enumerable.Range(11, 23).ToArray());
        var other = new object();
        rig.Sync(1);
        rig.Sync(1, other);
        var first = rig.Answer(new[] { 5 }, convenience: true, last: true, nowMs: 1_000); // the oldest of all, on the clipboard
        Assert.Equal(Entry(5), first.Applied);
        Assert.Equal("sig-5", rig.Groups.ProtectedKey);

        // Not newer than sig-5, so skipped: it is added and leads its own block, which does not end the protection.
        var skipped = new ClipboardEntry("text 5b", "text", "PEER", Start.AddMinutes(5), "sig-5b");
        var second = rig.Groups.ApplyAnswer(other, rig.History, new[] { skipped }, _ => false, Rig.Max, convenience: true, last: true, nowMs: 2_000);

        Assert.Null(second.Applied);
        Assert.Equal(new[] { skipped }, second.Added);
        Assert.Equal(25, rig.History.Count);
        Assert.Equal("sig-5b", rig.Order()[0]);
        Assert.Equal("sig-5", rig.Groups.ProtectedKey);

        // A later trim still spares it, although it is the oldest and listed first among equal times.
        var late = rig.Late(50);
        Assert.Equal(Entries(50), late.Added);
        Assert.Equal(new[] { skipped }, late.Evicted);
        Assert.Contains("sig-5", rig.Order());
        Assert.Equal("sig-5", rig.Groups.ProtectedKey);
    }

    [Fact]
    public void The_protection_kept_over_a_skipped_item_ends_when_a_newer_item_is_put_on_the_clipboard_or_a_live_one_arrives()
    {
        var rig = new Rig(Enumerable.Range(11, 10).ToArray());
        var (other, third) = (new object(), new object());
        rig.Sync(1);
        rig.Sync(1, other);
        rig.Sync(1, third);
        rig.Answer(new[] { 9 }, convenience: true, last: true, nowMs: 1_000);
        rig.Answer(new[] { 4 }, convenience: true, last: true, conn: other, nowMs: 2_000); // skipped
        Assert.Equal("sig-9", rig.Groups.ProtectedKey);

        var newer = rig.Answer(new[] { 40 }, convenience: true, last: true, conn: third, nowMs: 3_000);
        Assert.Equal(Entry(40), newer.Applied);
        Assert.Equal("sig-40", rig.Groups.ProtectedKey);

        rig.Live(41);
        Assert.Null(rig.Groups.ProtectedKey);
    }

    [Fact]
    public void A_skipped_item_in_a_full_history_does_not_cost_the_protected_one_its_place()
    {
        var rig = new Rig(Enumerable.Range(11, 24).ToArray());
        var other = new object();
        rig.Sync(1);
        rig.Sync(1, other);
        rig.Answer(new[] { 5 }, convenience: true, last: true, nowMs: 1_000); // 25 items, the oldest is sig-5
        var tie = new ClipboardEntry("text 5b", "text", "PEER", Start.AddMinutes(5), "sig-5b");

        // Equal times: without the protection the trim would take sig-5 (listed first), not the new one.
        var second = rig.Groups.ApplyAnswer(other, rig.History, new[] { tie }, _ => false, Rig.Max, convenience: true, last: true, nowMs: 2_000);

        Assert.Null(second.Applied);
        Assert.Equal(new[] { tie }, second.Evicted);
        Assert.Contains("sig-5", rig.Order());
        Assert.Equal("sig-5", rig.Groups.ProtectedKey);
    }

    // ---- the late answer to an expired request ----

    [Fact]
    public void A_late_answer_is_added_quietly_in_no_block_and_no_stack()
    {
        var rig = new Rig(20, 21);

        var merged = rig.Late(5, 25, 3);

        Assert.Equal(3, merged.Added.Count);
        Assert.Null(merged.Applied);
        Assert.Equal(Sigs(25, 21, 20, 5, 3), rig.Order()); // the timeline, nothing on top
        Assert.All(rig.Rows(), row => Assert.False(row.IsStack));
        Assert.True(rig.Groups.QuietKeys().SetEquals(Sigs(3, 5, 25)));
        Assert.Empty(rig.Groups.Snapshot().BatchOf);
    }

    [Fact]
    public void A_late_answer_skips_what_is_known_or_deleted_and_the_trim_keeps_the_clipboard_item()
    {
        var rig = new Rig(Enumerable.Range(11, 25).ToArray()); // a full history
        rig.Sync(1);
        rig.Answer(new[] { 5 }, convenience: true, last: true, nowMs: 1_000); // on the clipboard, older than all
        Assert.Equal(25, rig.History.Count);
        rig.Deleted.Add("sig-40");

        var merged = rig.Late(50, 40, 30); // 50 is new, 40 is deleted here, 30 is known

        Assert.Equal(Entries(50), merged.Added);
        Assert.Equal(1, merged.Deleted);
        Assert.Equal(1, merged.Duplicates);
        Assert.Equal(25, rig.History.Count);
        Assert.Contains("sig-5", rig.Order());
        Assert.Equal(Entries(12), merged.Evicted);
    }

    [Fact]
    public void Clearing_the_history_clears_the_blocks()
    {
        var rig = new Rig(20);
        rig.Sync(3);
        rig.Answer(new[] { 7, 6, 5 }, convenience: true, last: true);

        rig.History.Clear();
        rig.Groups.Clear();

        Assert.Empty(rig.Order());
        Assert.Null(rig.Groups.ProtectedKey);
        Assert.Empty(rig.Groups.Snapshot().BatchOf);
    }
}
