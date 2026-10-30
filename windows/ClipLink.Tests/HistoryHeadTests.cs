using System.Text.Json;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using ClipLink;
using Xunit;

namespace ClipLink.Tests;

// The "history_head" message: the newest entry and the batch's size arrive
// first, so the Synced page shows the stack while the (big) history_batch is
// still on its way. BatchGroups is what HistoryAccess runs for it; these tests
// drive it the way the engine does, on a plain list.
public class HistoryHeadTests
{
    private static readonly DateTime Start = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    // Entry n is made n minutes after Start; its Key() is "sig-n".
    private static ClipboardEntry Entry(int n, string device = "PEER") =>
        new($"text {n}", "text", device, Start.AddMinutes(n), $"sig-{n}");

    private static List<ClipboardEntry> Entries(params int[] numbers) => numbers.Select(n => Entry(n)).ToList();

    private static string[] Keys(IEnumerable<ClipboardEntry> entries) => entries.Select(e => e.Key()).ToArray();

    // What the engine holds for one PC: its history, the deleted list, the
    // groups, and a few connections.
    private sealed class Rig
    {
        public const int Max = 25;
        public List<ClipboardEntry> History { get; } = new();
        public HashSet<string> Deleted { get; } = new();
        public BatchGroups Groups { get; } = new();
        public object Conn { get; } = new();

        public BatchGroups.HeadResult Head(HistoryHead.Payload head, object? conn = null) =>
            Groups.HeadReceived(conn ?? Conn, History, head, Deleted.Contains, Max);

        // The sender's head for a batch, as the peer would write it.
        public static HistoryHead.Payload HeadFor(List<ClipboardEntry> batch) => HistoryHead.ForBatch(batch)!;

        // A history_batch the way HandleHistoryBatch applies it.
        public (HistoryBatch.Outcome Outcome, int Changed) Batch(List<ClipboardEntry> batch, object? conn = null,
            Func<ClipboardEntry, bool>? acceptable = null)
        {
            int changed = 0;
            var outcome = HistoryBatch.Apply(batch, acceptable ?? (_ => true), e => Deleted.Contains(e.Key()),
                add: entries => Groups.ApplyBatch(conn ?? Conn, History, entries, e => Deleted.Contains(e.Key()), Max),
                changed: () => changed++);
            return (outcome, changed);
        }

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

        public string? BatchIdOf(string key) => Groups.Snapshot().BatchOf.GetValueOrDefault(key);
    }

    // ---- the sender ----

    [Fact]
    public void No_head_for_fewer_than_two_entries()
    {
        Assert.Null(HistoryHead.ForBatch(new List<ClipboardEntry>()));
        Assert.Null(HistoryHead.ForBatch(Entries(1)));
        Assert.NotNull(HistoryHead.ForBatch(Entries(1, 2)));
    }

    [Fact]
    public void The_head_matches_the_batch_newest_first()
    {
        // History is kept in the order entries were added, not by time.
        var batch = Entries(3, 1, 5, 2, 4);

        var head = HistoryHead.ForBatch(batch)!;

        Assert.Equal(new[] { "sig-5", "sig-4", "sig-3", "sig-2", "sig-1" }, head.Keys);
        Assert.Equal(Keys(batch).OrderBy(k => k), head.Keys.OrderBy(k => k));
        Assert.Equal(head.Keys[0], head.Newest.Key());
        Assert.Equal(Entry(5), head.Newest);
        Assert.False(string.IsNullOrEmpty(head.Newest.Signature));
    }

    [Fact]
    public void Of_equal_timestamps_the_one_listed_first_is_the_newest()
    {
        var a = new ClipboardEntry("a", "text", "PEER", Start, "sig-a");
        var b = new ClipboardEntry("b", "text", "PEER", Start, "sig-b");

        Assert.Equal("sig-a", HistoryHead.ForBatch(new List<ClipboardEntry> { a, b })!.Newest.Key());
    }

    // ---- on the wire ----

    [Fact]
    public void The_head_is_written_with_the_names_the_other_apps_read()
    {
        var head = HistoryHead.ForBatch(Entries(1, 2))!;

        var json = JsonSerializer.Serialize(new Envelope("history_head", JsonSerializer.Serialize(head)));

        using var envelope = JsonDocument.Parse(json);
        Assert.Equal("history_head", envelope.RootElement.GetProperty("Type").GetString());
        // The payload is a JSON string, like the other envelope types.
        using var payload = JsonDocument.Parse(envelope.RootElement.GetProperty("Payload").GetString()!);
        Assert.Equal(new[] { "Newest", "Keys" }, payload.RootElement.EnumerateObject().Select(p => p.Name));
        var newest = payload.RootElement.GetProperty("Newest");
        Assert.Equal(new[] { "Content", "Type", "DeviceId", "Timestamp", "Signature" }, newest.EnumerateObject().Select(p => p.Name));
        Assert.Equal("sig-2", newest.GetProperty("Signature").GetString());
        Assert.Equal(new[] { "sig-2", "sig-1" }, payload.RootElement.GetProperty("Keys").EnumerateArray().Select(k => k.GetString()));
    }

    [Fact]
    public void What_the_sender_writes_the_receiver_reads()
    {
        var batch = Entries(1, 2, 3);
        var line = JsonSerializer.Serialize(new Envelope("history_head", JsonSerializer.Serialize(HistoryHead.ForBatch(batch))));

        var envelope = JsonSerializer.Deserialize<Envelope>(line)!;
        var head = JsonSerializer.Deserialize<HistoryHead.Payload>(envelope.Payload);

        Assert.Equal("history_head", envelope.Type);
        Assert.True(HistoryHead.Accept(head, _ => true));
        Assert.Equal(Entry(3), head!.Newest);
        Assert.Equal(new[] { "sig-3", "sig-2", "sig-1" }, head.Keys);
    }

    [Fact]
    public void A_head_from_another_app_is_read_by_field_name()
    {
        // As an Android, iOS or HarmonyOS peer writes it (timestamp with 7 digits).
        const string payload = "{\"Newest\":{\"Content\":\"hi\",\"Type\":\"text\",\"DeviceId\":\"PEER\",\"Timestamp\":\"2026-10-01T12:03:00.0000000Z\",\"Signature\":\"sig-3\"},\"Keys\":[\"sig-3\",\"sig-2\"]}";

        var head = JsonSerializer.Deserialize<HistoryHead.Payload>(payload);

        Assert.Equal("sig-3", head!.Newest.Key());
        Assert.Equal(new[] { "sig-3", "sig-2" }, head.Keys);
        Assert.Equal(new DateTime(2026, 10, 1, 12, 3, 0, DateTimeKind.Utc), head.Newest.Timestamp.ToUniversalTime());
    }

    // ---- receiving a head ----

    [Fact]
    public void A_head_with_two_or_more_new_keys_adds_the_newest_and_shows_the_stack_at_once()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3, 4, 5);

        var result = rig.Head(Rig.HeadFor(peerHistory));

        Assert.Equal(Entry(5), result.Added);
        Assert.True(result.Changed);
        Assert.Equal(new[] { "sig-5" }, Keys(rig.History));
        var row = Assert.Single(rig.Rows());
        Assert.Equal("sig-5", row.FrontKey);
        Assert.Empty(row.HiddenKeys);
        Assert.Equal(4, row.Pending);
        Assert.Equal(4, row.Hidden); // the badge says +4 (and the layers follow from it)
        Assert.True(row.IsStack);
    }

    [Fact]
    public void A_head_with_one_new_key_is_a_normal_card()
    {
        var rig = new Rig();
        rig.Batch(Entries(1, 2, 3)); // the peer's older entries are already here

        var result = rig.Head(Rig.HeadFor(Entries(1, 2, 3, 4)));

        Assert.Equal(Entry(4), result.Added);
        var rows = rig.Rows();
        Assert.Equal("sig-4", rows[0].FrontKey);
        Assert.False(rows[0].IsStack);
        Assert.Null(rig.BatchIdOf("sig-4"));
        Assert.Empty(rig.Groups.Snapshot().Expected);
    }

    [Fact]
    public void A_head_with_no_new_key_changes_nothing()
    {
        var rig = new Rig();
        rig.Batch(Entries(1, 2, 3));
        var before = rig.Rows();

        var result = rig.Head(Rig.HeadFor(Entries(1, 2, 3)));

        Assert.Null(result.Added);
        Assert.False(result.Changed);
        Assert.Equal(3, rig.History.Count);
        Assert.Equal(before.Count, rig.Rows().Count);
    }

    [Fact]
    public void A_head_whose_newest_is_known_makes_no_early_stack_and_the_batch_works_as_before()
    {
        var rig = new Rig();
        rig.Batch(Entries(5)); // the newest is already here
        var peerHistory = Entries(1, 2, 3, 5);

        var result = rig.Head(Rig.HeadFor(peerHistory));
        Assert.Null(result.Added);
        Assert.False(result.Changed);
        Assert.Empty(rig.Groups.Snapshot().Expected);

        var (outcome, changed) = rig.Batch(peerHistory);
        Assert.Equal(3, outcome.Added.Count);
        Assert.False(outcome.HeadApplied);
        Assert.Equal(1, changed);
        Assert.Contains(rig.Rows(), row => row.IsStack && row.Hidden == 2);
    }

    [Fact]
    public void A_head_for_an_entry_deleted_here_is_ignored()
    {
        var rig = new Rig();
        rig.Deleted.Add("sig-3");

        var result = rig.Head(Rig.HeadFor(Entries(1, 2, 3)));

        Assert.Null(result.Added);
        Assert.Empty(rig.History);
    }

    [Fact]
    public void Only_keys_that_are_new_and_not_deleted_count()
    {
        var rig = new Rig();
        rig.Batch(Entries(1, 2));
        rig.Deleted.Add("sig-4");
        // Peer has 1 to 6: here 1 and 2 are known and 4 was deleted, so 3, 5 and 6 are new.

        rig.Head(Rig.HeadFor(Entries(1, 2, 3, 4, 5, 6)));

        var stack = Assert.Single(rig.Rows(), row => row.FrontKey == "sig-6");
        Assert.True(stack.IsStack);
        Assert.Equal(2, stack.Hidden);
    }

    [Fact]
    public void A_head_cannot_promise_a_stack_bigger_than_the_history()
    {
        var rig = new Rig();
        var keys = Enumerable.Range(1, 500).Select(n => $"sig-{n}").Reverse().ToList();
        var head = new HistoryHead.Payload(Entry(500), keys);

        rig.Head(head);

        Assert.Equal(Rig.Max - 1, Assert.Single(rig.Rows()).Hidden);
    }

    [Fact]
    public void A_head_in_a_full_history_evicts_the_oldest()
    {
        var rig = new Rig();
        rig.Batch(Entries(Enumerable.Range(10, 25).ToArray())); // full

        var result = rig.Head(Rig.HeadFor(Entries(40, 41, 42)));

        Assert.Equal(new[] { "sig-10" }, Keys(result.Evicted));
        Assert.Equal(25, rig.History.Count);
    }

    // ---- a head that does not check out ----

    [Fact]
    public void A_head_with_a_bad_signature_or_an_untrusted_maker_is_ignored()
    {
        var head = Rig.HeadFor(Entries(1, 2, 3));

        Assert.False(HistoryHead.Accept(head, _ => false)); // bad signature / not trusted
        Assert.False(HistoryHead.Accept(null, _ => true));
        Assert.False(HistoryHead.Accept(new HistoryHead.Payload(null!, new List<string>()), _ => true));
        Assert.False(HistoryHead.Accept(new HistoryHead.Payload(Entry(1), null!), _ => true));
        Assert.True(HistoryHead.Accept(head, e => e.DeviceId == "PEER"));
    }

    [Fact]
    public void After_an_ignored_head_the_batch_works_as_before()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3);
        Assert.False(HistoryHead.Accept(Rig.HeadFor(peerHistory), _ => false)); // so the engine never calls Head()

        var (outcome, changed) = rig.Batch(peerHistory);

        Assert.Equal(3, outcome.Added.Count);
        Assert.False(outcome.HeadApplied);
        Assert.Equal(1, changed);
        var row = Assert.Single(rig.Rows());
        Assert.Equal(0, row.Pending);
        Assert.Equal(2, row.HiddenKeys.Count);
    }

    // ---- the batch that follows a head ----

    [Fact]
    public void Head_then_batch_is_one_group_and_the_badge_does_not_change()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3, 4, 5);

        rig.Head(Rig.HeadFor(peerHistory));
        string? idAtHead = rig.BatchIdOf("sig-5");
        var early = Assert.Single(rig.Rows());

        var (outcome, changed) = rig.Batch(peerHistory);

        Assert.NotNull(idAtHead);
        Assert.Equal(new[] { "sig-4", "sig-3", "sig-2", "sig-1" }, Keys(outcome.Added).OrderByDescending(k => k)); // the newest was known
        Assert.True(outcome.HeadApplied);
        Assert.Equal(1, changed);
        var late = Assert.Single(rig.Rows());
        Assert.Equal(idAtHead, late.BatchId);                       // the same group, so the same card
        foreach (var e in peerHistory) Assert.Equal(idAtHead, rig.BatchIdOf(e.Key()));
        Assert.Equal("sig-5", late.FrontKey);
        Assert.Equal(early.Hidden, late.Hidden);                    // badge: still +4
        Assert.Equal(0, late.Pending);                              // now the real members
        Assert.Equal(4, late.HiddenKeys.Count);
        Assert.Empty(rig.Groups.Snapshot().Expected);
    }

    [Fact]
    public void The_batch_after_a_head_does_not_apply_its_own_newest_again()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3);

        var head = rig.Head(Rig.HeadFor(peerHistory));
        var (outcome, _) = rig.Batch(peerHistory);

        // The head returned the newest once (the engine applies it then); the
        // batch says a head was applied and its Added does not hold the newest.
        Assert.Equal(Entry(3), head.Added);
        Assert.True(outcome.HeadApplied);
        Assert.DoesNotContain(outcome.Added, e => e.Key() == "sig-3");
    }

    [Fact]
    public void A_group_the_batch_shrinks_to_one_dissolves_and_the_ui_is_told()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3, 4);
        rig.Head(Rig.HeadFor(peerHistory));
        Assert.True(Assert.Single(rig.Rows()).IsStack);

        // None of the others is accepted.
        var (outcome, changed) = rig.Batch(peerHistory, acceptable: e => e.Key() == "sig-4");

        Assert.Empty(outcome.Added);
        Assert.Equal(1, changed); // told even though nothing was added
        var row = Assert.Single(rig.Rows());
        Assert.False(row.IsStack);
        Assert.Null(rig.BatchIdOf("sig-4"));
    }

    [Fact]
    public void A_batch_that_brings_fewer_than_promised_but_two_or_more_keeps_a_stack_of_the_real_size()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3, 4, 5);
        rig.Head(Rig.HeadFor(peerHistory)); // promises +4

        rig.Batch(peerHistory, acceptable: e => e.Key() is "sig-5" or "sig-4");

        var row = Assert.Single(rig.Rows(), r => r.IsStack);
        Assert.Equal(1, row.Hidden);
        Assert.Equal(0, row.Pending);
    }

    [Fact]
    public void Without_a_head_the_group_is_made_at_batch_time_as_before()
    {
        var rig = new Rig();

        var (outcome, changed) = rig.Batch(Entries(1, 2, 3));

        Assert.False(outcome.HeadApplied);
        Assert.Equal(1, changed);
        var row = Assert.Single(rig.Rows());
        Assert.Equal(2, row.Hidden);
        Assert.Equal(0, row.Pending);
        Assert.Empty(rig.Groups.Snapshot().Expected);
    }

    [Fact]
    public void A_batch_of_one_new_entry_without_a_head_is_a_normal_card()
    {
        var rig = new Rig();

        rig.Batch(Entries(1));

        Assert.False(Assert.Single(rig.Rows()).IsStack);
    }

    // ---- the connection closes, a second head, the user opens the stack ----

    [Fact]
    public void A_connection_that_closes_before_its_batch_leaves_plain_cards()
    {
        var rig = new Rig();
        rig.Head(Rig.HeadFor(Entries(1, 2, 3)));
        Assert.True(Assert.Single(rig.Rows()).IsStack);

        bool changed = rig.Groups.FinishHead(rig.Conn, rig.History);

        Assert.True(changed);
        var row = Assert.Single(rig.Rows());
        Assert.False(row.IsStack);
        Assert.Empty(rig.Groups.Snapshot().Expected);
        Assert.Empty(rig.Groups.Snapshot().BatchOf);
    }

    [Fact]
    public void Closing_a_connection_that_sent_no_head_changes_nothing()
    {
        var rig = new Rig();
        rig.Batch(Entries(1, 2, 3));

        Assert.False(rig.Groups.FinishHead(rig.Conn, rig.History));
        Assert.True(Assert.Single(rig.Rows()).IsStack);
    }

    [Fact]
    public void A_batch_that_arrives_after_the_stack_was_dissolved_is_a_group_of_its_own()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3);
        rig.Head(Rig.HeadFor(peerHistory));
        rig.Groups.FinishHead(rig.Conn, rig.History); // closed, and the peer came back

        var (outcome, _) = rig.Batch(peerHistory, new object());

        Assert.False(outcome.HeadApplied);
        Assert.Equal(2, outcome.Added.Count);
        // The early card stays a plain card, now below the two others, which came
        // later and are a stack of their own.
        var rows = rig.Rows();
        Assert.Equal("sig-2", rows[0].FrontKey);
        Assert.True(rows[0].IsStack);
        Assert.Equal("sig-3", rows[1].FrontKey);
        Assert.False(rows[1].IsStack);
    }

    [Fact]
    public void A_second_head_on_the_same_connection_replaces_the_first()
    {
        var rig = new Rig();
        rig.Head(Rig.HeadFor(Entries(1, 2, 3)));
        string? first = rig.BatchIdOf("sig-3");

        var result = rig.Head(Rig.HeadFor(Entries(11, 12, 13, 14)));

        Assert.True(result.Changed);
        string? second = rig.BatchIdOf("sig-14");
        Assert.NotNull(second);
        Assert.NotEqual(first, second);
        Assert.Null(rig.BatchIdOf("sig-3")); // the first one is a plain card now
        var rows = rig.Rows();
        Assert.Equal(2, rows.Count);
        Assert.Equal("sig-14", rows[0].FrontKey);
        Assert.Equal(3, rows[0].Hidden);
        Assert.False(rows[1].IsStack);
        Assert.Single(rig.Groups.Snapshot().Expected);
    }

    [Fact]
    public void Heads_on_two_connections_are_two_provisional_stacks_and_each_batch_joins_its_own()
    {
        var rig = new Rig();
        var other = new object();
        var mine = Entries(1, 2, 3);
        var theirs = Entries(11, 12, 13);
        rig.Head(Rig.HeadFor(mine));
        rig.Head(Rig.HeadFor(theirs), other);

        rig.Batch(theirs, other);
        rig.Batch(mine);

        var rows = rig.Rows();
        Assert.Equal(2, rows.Count);
        Assert.All(rows, row => Assert.Equal(2, row.HiddenKeys.Count));
        Assert.NotEqual(rows[0].BatchId, rows[1].BatchId);
    }

    [Fact]
    public void A_stack_the_user_opened_before_the_batch_stays_plain_cards_when_it_arrives()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3, 4);
        rig.Head(Rig.HeadFor(peerHistory));
        string batch = rig.BatchIdOf("sig-4")!;
        var opened = new HashSet<string> { batch };

        Assert.False(Assert.Single(rig.Rows(opened)).IsStack); // opened: it dissolves

        rig.Batch(peerHistory);

        var rows = rig.Rows(opened);
        Assert.Equal(new[] { "sig-4", "sig-3", "sig-2", "sig-1" }, rows.Select(r => r.FrontKey));
        Assert.All(rows, row => Assert.False(row.IsStack));
    }

    [Fact]
    public void The_user_deleting_the_early_card_before_the_batch_leaves_the_batch_to_work()
    {
        var rig = new Rig();
        var peerHistory = Entries(1, 2, 3);
        rig.Head(Rig.HeadFor(peerHistory));
        rig.Deleted.Add("sig-3");
        rig.History.RemoveAll(e => e.Key() == "sig-3");
        rig.Groups.Forget(rig.History);

        var (outcome, _) = rig.Batch(peerHistory);

        Assert.Equal(new[] { "sig-1", "sig-2" }, Keys(outcome.Added).Order()); // 3 stays deleted
        Assert.True(Assert.Single(rig.Rows()).IsStack);
    }

    // ---- how the page counts a provisional stack ----

    [Fact]
    public void While_provisional_the_stack_counts_the_larger_of_members_and_expected()
    {
        var listing = new List<BatchGrouping.Entry> { new("b", "1", 5), new("a", "1", 5) };
        var row = Assert.Single(BatchGrouping.Build(listing, new HashSet<string>()));
        Assert.Equal(4, row.Hidden); // 5 expected, 2 here: +4
        Assert.Equal(new[] { "a" }, row.HiddenKeys);
        Assert.Equal(3, row.Pending);

        var more = new List<BatchGrouping.Entry> { new("c", "1", 2), new("b", "1", 2), new("a", "1", 2) };
        var big = Assert.Single(BatchGrouping.Build(more, new HashSet<string>()));
        Assert.Equal(2, big.Hidden); // more here than expected: the members
        Assert.Equal(0, big.Pending);
    }

    [Fact]
    public void One_member_with_one_expected_is_a_normal_card_and_one_with_two_is_a_stack()
    {
        var single = BatchGrouping.Build(new List<BatchGrouping.Entry> { new("a", "1", 1) }, new HashSet<string>());
        Assert.False(Assert.Single(single).IsStack);

        var pair = BatchGrouping.Build(new List<BatchGrouping.Entry> { new("a", "1", 2) }, new HashSet<string>());
        Assert.True(Assert.Single(pair).IsStack);
        Assert.Equal(1, pair[0].Hidden);
    }
}
