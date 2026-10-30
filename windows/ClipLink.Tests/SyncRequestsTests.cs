using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.Tests;

// What a version 2 head makes this PC ask for (missing, wanted), and the
// requests sent and not answered yet (the queue per connection, the pending
// keys, the timeout).
public class SyncRequestsTests
{
    private static readonly object None = new();

    private static readonly Func<string, bool> Nothing = _ => false;

    private static List<string> Keys(params int[] numbers) => numbers.Select(n => $"k{n}").ToList();

    // The head of a peer with these entries, newest first; entry n was made at time n.
    private static HistoryHead.SyncHead Head(params int[] newestFirst) =>
        new(Keys(newestFirst), newestFirst.Select(n => (long)n).ToList(), new List<string>());

    private static Func<string, bool> Set(params int[] numbers)
    {
        var keys = Keys(numbers).ToHashSet();
        return keys.Contains;
    }

    // ---- what is wanted ----

    [Fact]
    public void Keys_this_pc_has_are_not_wanted()
    {
        var wanted = SyncRequests.Wanted(Keys(5, 4, 3, 2, 1), null, Set(4, 2), Nothing, Nothing, Array.Empty<long>());

        Assert.Equal(Keys(5, 3, 1), wanted);
    }

    [Fact]
    public void Keys_deleted_here_are_not_wanted()
    {
        var wanted = SyncRequests.Wanted(Keys(5, 4, 3), null, Nothing, Set(5, 3), Nothing, Array.Empty<long>());

        Assert.Equal(Keys(4), wanted);
    }

    [Fact]
    public void Keys_already_asked_of_another_device_are_not_wanted()
    {
        var wanted = SyncRequests.Wanted(Keys(5, 4, 3), null, Nothing, Nothing, Set(4), Array.Empty<long>());

        Assert.Equal(Keys(5, 3), wanted);
    }

    [Fact]
    public void A_key_listed_twice_is_wanted_once()
    {
        var wanted = SyncRequests.Wanted(new List<string> { "a", "b", "a" }, null, Nothing, Nothing, Nothing, Array.Empty<long>());

        Assert.Equal(new[] { "a", "b" }, wanted);
    }

    [Fact]
    public void Without_times_every_missing_key_is_wanted_up_to_25()
    {
        var keys = Enumerable.Range(1, 30).Select(n => $"k{n}").ToList();

        var wanted = SyncRequests.Wanted(keys, null, Nothing, Nothing, Nothing, new long[] { 1000, 2000, 3000 });

        Assert.Equal(keys.Take(25), wanted);
    }

    [Fact]
    public void Times_that_do_not_match_the_keys_count_as_no_times()
    {
        var wanted = SyncRequests.Wanted(Keys(3, 2, 1), new long[] { 3, 2 }, Nothing, Nothing, Nothing, new long[] { 100, 200, 300 });

        Assert.Equal(Keys(3, 2, 1), wanted);
    }

    [Fact]
    public void Only_the_25_newest_of_what_this_pc_has_and_lacks_are_wanted()
    {
        // This PC has 20 entries at times 101..120. The peer has 10 at times 1..10 and
        // 10 at times 111..120+: of all of them only the 25 newest fit.
        var local = Enumerable.Range(101, 20).Select(t => (long)t).ToList();
        var keys = new List<string>();
        var times = new List<long>();
        for (int t = 130; t >= 121; t--) { keys.Add($"new{t}"); times.Add(t); } // 10 newer than all local ones
        for (int t = 10; t >= 1; t--) { keys.Add($"old{t}"); times.Add(t); }    // 10 older than all

        var wanted = SyncRequests.Wanted(keys, times, Nothing, Nothing, Nothing, local);

        // 10 new + 20 local = 30 > 25: of the 25 newest, 10 are new ones and 15 local; no old one fits.
        // The first missing key is wanted anyway, as the others of the new ones are.
        Assert.Equal(keys.Take(10), wanted);
    }

    [Fact]
    public void Missing_keys_older_than_a_full_history_are_not_downloaded()
    {
        var local = Enumerable.Range(100, 25).Select(t => (long)t).ToList();

        var wanted = SyncRequests.Wanted(Keys(5, 4, 3), new long[] { 5, 4, 3 }, Nothing, Nothing, Nothing, local);

        // Only the first (the convenience item) is wanted, though it would be trimmed by time.
        Assert.Equal(Keys(5), wanted);
    }

    [Fact]
    public void The_first_missing_key_is_always_wanted_even_when_it_is_older_than_the_whole_history()
    {
        var local = Enumerable.Range(100, 25).Select(t => (long)t).ToList();

        var wanted = SyncRequests.Wanted(Keys(7), new long[] { 7 }, Nothing, Nothing, Nothing, local);

        Assert.Equal(Keys(7), wanted);
    }

    [Fact]
    public void Missing_keys_that_fit_the_history_are_all_wanted_in_order()
    {
        var local = Enumerable.Range(100, 10).Select(t => (long)t).ToList(); // room for 15 more

        var wanted = SyncRequests.Wanted(Keys(5, 4, 3, 2, 1), new long[] { 5, 4, 3, 2, 1 }, Nothing, Nothing, Nothing, local);

        Assert.Equal(Keys(5, 4, 3, 2, 1), wanted);
    }

    [Fact]
    public void The_convenience_item_is_the_first_missing_key_not_the_first_key()
    {
        // The first KEY is known here: the first MISSING one (k4) is the convenience item.
        var wanted = SyncRequests.Wanted(Keys(5, 4, 3), new long[] { 5, 4, 3 }, Set(5), Nothing, Nothing, Enumerable.Range(100, 25).Select(t => (long)t).ToList());

        Assert.Equal(Keys(4), wanted);
    }

    [Fact]
    public void Nothing_missing_is_nothing_wanted()
    {
        Assert.Empty(SyncRequests.Wanted(Keys(2, 1), new long[] { 2, 1 }, Set(1, 2), Nothing, Nothing, Array.Empty<long>()));
        Assert.Empty(SyncRequests.Wanted(new List<string>(), null, Nothing, Nothing, Nothing, Array.Empty<long>()));
    }

    // ---- the requests ----

    [Fact]
    public void The_newest_missing_is_asked_alone_first_then_the_rest_in_one_request()
    {
        var requests = new SyncRequests();

        var plan = requests.Reserve(None, Head(5, 4, 3, 2, 1), Set(2), Nothing, Array.Empty<long>(), nowMs: 1000);

        Assert.Equal(4, plan.Wanted);
        Assert.Equal(2, plan.Requests.Count);
        Assert.Equal(Keys(5), plan.Requests[0].Keys);
        Assert.True(plan.Requests[0].Convenience);
        Assert.Equal(Keys(4, 3, 1), plan.Requests[1].Keys);
        Assert.False(plan.Requests[1].Convenience);
        Assert.All(plan.Requests, request => Assert.Equal(1000, request.SentAt));
        Assert.Equal(2, requests.Open(None));
        Assert.True(requests.IsPending("k5"));
        Assert.True(requests.IsPending("k1"));
        Assert.False(requests.IsPending("k2"));
    }

    [Fact]
    public void One_missing_item_is_one_request()
    {
        var requests = new SyncRequests();

        var plan = requests.Reserve(None, Head(2, 1), Set(1), Nothing, Array.Empty<long>(), nowMs: 0);

        Assert.Equal(1, plan.Wanted);
        var request = Assert.Single(plan.Requests);
        Assert.Equal(Keys(2), request.Keys);
        Assert.True(request.Convenience);
    }

    [Fact]
    public void Asking_again_without_the_convenience_item_is_one_plain_request()
    {
        var requests = new SyncRequests();

        var plan = requests.Reserve(None, Head(3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0, allowConvenience: false);

        var request = Assert.Single(plan.Requests);
        Assert.Equal(Keys(3, 2, 1), request.Keys);
        Assert.False(request.Convenience);
    }

    [Fact]
    public void A_head_with_nothing_missing_asks_for_nothing()
    {
        var requests = new SyncRequests();

        var plan = requests.Reserve(None, Head(2, 1), Set(1, 2), Nothing, Array.Empty<long>(), nowMs: 0);

        Assert.Empty(plan.Requests);
        Assert.Equal(0, requests.Open(None));
    }

    [Fact]
    public void A_key_pending_on_one_connection_is_not_asked_on_another()
    {
        var requests = new SyncRequests();
        var first = new object();
        var second = new object();
        requests.Reserve(first, Head(3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);

        var plan = requests.Reserve(second, Head(4, 3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);

        Assert.Equal(1, plan.Wanted);
        Assert.Equal(Keys(4), Assert.Single(plan.Requests).Keys);
    }

    [Fact]
    public void Requests_are_answered_in_the_order_they_were_sent()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(4, 3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);

        var first = requests.Answered(None, out int openAfterFirst);
        Assert.NotNull(first);
        Assert.True(first!.Convenience);
        Assert.Equal(Keys(4), first.Keys);
        Assert.Equal(1, openAfterFirst);
        // (Pending until the answer has been dealt with, so the key is never neither pending nor here.)
        Assert.True(requests.IsPending("k4"));
        requests.Done(None, first);
        Assert.False(requests.IsPending("k4"));
        Assert.True(requests.IsPending("k3"));

        var second = requests.Answered(None, out int openAfterSecond);
        Assert.NotNull(second);
        Assert.False(second!.Convenience);
        Assert.Equal(Keys(3, 2, 1), second.Keys);
        Assert.Equal(0, openAfterSecond);
        requests.Done(None, second);
        Assert.False(requests.IsPending("k3"));
    }

    [Fact]
    public void A_batch_nobody_asked_for_answers_nothing()
    {
        var requests = new SyncRequests();

        Assert.Null(requests.Answered(None, out int open));
        Assert.Equal(0, open);

        requests.Reserve(None, Head(2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Answered(None, out _);
        requests.Answered(None, out _);
        Assert.Null(requests.Answered(None, out _)); // more answers than requests
    }

    [Fact]
    public void An_answer_on_one_connection_does_not_take_a_request_of_another()
    {
        var requests = new SyncRequests();
        var other = new object();
        requests.Reserve(None, Head(2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);

        Assert.Null(requests.Answered(other, out _));
        Assert.Equal(2, requests.Open(None));
    }

    [Fact]
    public void A_request_that_waited_90_seconds_is_dropped_with_its_keys()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 10_000);

        Assert.Empty(requests.Expire(10_000 + SyncRequests.TimeoutMs - 1, SyncRequests.TimeoutMs));
        Assert.Equal(2, requests.Open(None));

        var affected = requests.Expire(10_000 + SyncRequests.TimeoutMs, SyncRequests.TimeoutMs);

        Assert.Equal(new[] { None }, affected);
        Assert.Equal(0, requests.Open(None));
        Assert.False(requests.IsPending("k3"));
        Assert.False(requests.IsPending("k1"));
        // (Its late answer is still known for what it is: see the markers below.)
        Assert.True(requests.Answered(None, out _)!.Expired);
    }

    // ---- expired requests stay as markers ----

    [Fact]
    public void An_expired_request_stays_in_the_queue_as_a_marker_that_its_late_answer_pops()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Expire(SyncRequests.TimeoutMs, SyncRequests.TimeoutMs);

        var first = requests.Answered(None, out int openAfterFirst);
        Assert.NotNull(first);
        Assert.True(first!.Expired);
        Assert.True(first.Convenience);
        Assert.Equal(Keys(3), first.Keys);
        Assert.Equal(0, openAfterFirst); // the other marker is not an open request

        var second = requests.Answered(None, out _);
        Assert.True(second!.Expired);
        Assert.Equal(Keys(2, 1), second.Keys);
        Assert.Null(requests.Answered(None, out _)); // now nothing is left: a batch is unexpected
    }

    [Fact]
    public void Markers_are_not_open_requests_and_do_not_expire_again()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Reserve(None, Head(4, 3), Nothing, Nothing, Array.Empty<long>(), nowMs: 60_000);
        requests.Expire(95_000, SyncRequests.TimeoutMs);

        Assert.Equal(2, requests.Open(None)); // two markers, two requests still waiting
        Assert.Empty(requests.Expire(96_000, SyncRequests.TimeoutMs)); // the markers do not count again

        // The late answer comes first (it is the oldest); what is open after it is the live pair only.
        Assert.True(requests.Answered(None, out int open)!.Expired);
        Assert.Equal(2, open);
        Assert.True(requests.Answered(None, out open)!.Expired);
        Assert.Equal(2, open);
        Assert.False(requests.Answered(None, out open)!.Expired);
        Assert.Equal(1, open);
    }

    [Fact]
    public void A_late_answer_does_not_free_keys_that_are_pending_again_for_a_newer_request()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(2), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Expire(SyncRequests.TimeoutMs, SyncRequests.TimeoutMs);
        Assert.False(requests.IsPending("k2"));
        requests.Reserve(None, Head(2), Nothing, Nothing, Array.Empty<long>(), nowMs: SyncRequests.TimeoutMs); // asked again
        Assert.True(requests.IsPending("k2"));

        var late = requests.Answered(None, out _)!;
        requests.Done(None, late);

        Assert.True(late.Expired);
        Assert.True(requests.IsPending("k2"));
    }

    [Fact]
    public void A_connection_that_closes_drops_its_markers_and_owes_nothing_for_them()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Reserve(None, Head(4, 3), Nothing, Nothing, Array.Empty<long>(), nowMs: 60_000);
        requests.Expire(95_000, SyncRequests.TimeoutMs);

        var dropped = requests.Close(None);

        Assert.Equal(2, dropped.Count);
        Assert.All(dropped, request => Assert.False(request.Expired));
        Assert.Null(requests.Answered(None, out _));
        Assert.False(requests.IsPending("k4"));
    }

    // ---- the cap of what is wanted ----

    [Fact]
    public void Times_that_are_not_in_order_never_make_more_than_25_wanted()
    {
        // The first key is the oldest of 30 (always wanted); the other 29 are newer, newest first.
        var keys = Enumerable.Range(1, 30).Select(n => $"k{n}").ToList();
        var times = new List<long> { 1 };
        times.AddRange(Enumerable.Range(1, 29).Select(i => 1000L - i));

        var wanted = SyncRequests.Wanted(keys, times, Nothing, Nothing, Nothing, Array.Empty<long>());

        Assert.Equal(25, wanted.Count);
        Assert.Equal("k1", wanted[0]);
        Assert.Equal(keys.Skip(1).Take(24), wanted.Skip(1)); // the first key, then the newest 24 of the rest
    }

    [Fact]
    public void Times_in_no_order_with_this_pcs_own_items_still_make_at_most_25_wanted()
    {
        var keys = Enumerable.Range(1, 30).Select(n => $"k{n}").ToList();
        var times = Enumerable.Range(1, 30).Select(i => (long)((i * 7) % 30 + 1)).ToList(); // a shuffle
        var local = Enumerable.Range(1, 10).Select(i => (long)(i * 3)).ToList();

        var wanted = SyncRequests.Wanted(keys, times, Nothing, Nothing, Nothing, local);

        Assert.True(wanted.Count <= 25);
        Assert.Equal("k1", wanted[0]);
    }

    [Fact]
    public void Only_the_requests_that_are_overdue_are_dropped()
    {
        var requests = new SyncRequests();
        requests.Reserve(None, Head(2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Reserve(None, Head(4, 3), Nothing, Nothing, Array.Empty<long>(), nowMs: 60_000);

        var affected = requests.Expire(95_000, SyncRequests.TimeoutMs);

        Assert.Equal(new[] { None }, affected);
        Assert.Equal(2, requests.Open(None)); // the second pair is still waiting
        Assert.False(requests.IsPending("k2"));
        Assert.True(requests.IsPending("k4"));
    }

    [Fact]
    public void A_connection_that_closes_drops_its_requests_and_frees_its_keys()
    {
        var requests = new SyncRequests();
        var first = new object();
        var second = new object();
        requests.Reserve(first, Head(3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        requests.Reserve(second, Head(4, 3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0); // asks only k4

        var dropped = requests.Close(first);

        Assert.Equal(2, dropped.Count);
        Assert.True(dropped[0].Convenience);
        Assert.Equal(0, requests.Open(first));
        Assert.Null(requests.LastHead(first));
        Assert.False(requests.IsPending("k3"));
        Assert.True(requests.IsPending("k4")); // the other connection's stay
        Assert.Equal(1, requests.Open(second));
    }

    [Fact]
    public void What_a_closed_connection_was_asked_for_is_asked_of_another_from_its_last_head()
    {
        var requests = new SyncRequests();
        var first = new object();
        var second = new object();
        var secondHead = Head(3, 2, 1);
        requests.Reserve(first, Head(3, 2, 1), Nothing, Nothing, Array.Empty<long>(), nowMs: 0);
        // The second device has the same items: they are pending on the first connection, so not asked here.
        Assert.Empty(requests.Reserve(second, secondHead, Nothing, Nothing, Array.Empty<long>(), nowMs: 0).Requests);
        Assert.Equal(secondHead, requests.LastHead(second));

        requests.Close(first);
        var plan = requests.Reserve(second, requests.LastHead(second)!, Nothing, Nothing, Array.Empty<long>(), nowMs: 5);

        Assert.Equal(3, plan.Wanted);
        Assert.Equal(Keys(3), plan.Requests[0].Keys);
    }

    [Fact]
    public void Closing_a_connection_with_nothing_open_changes_nothing()
    {
        var requests = new SyncRequests();

        Assert.Empty(requests.Close(None));
    }
}
