using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using ClipboardDaemon.Engine;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;
using Xunit.Abstractions;

namespace ClipLink.EngineTests;

// The version 2 sync with the real engine: against a peer played by the test
// (every message by hand, so what the engine sends and how it answers can be
// read), and between two engines. Each engine has its own files (see
// TestData). The log (LogTap) is shared, so these run one at a time.
public class SyncEngineTests
{
    private readonly ITestOutputHelper output;

    public SyncEngineTests(ITestOutputHelper output)
    {
        this.output = output;
        LogTap.Start();
    }

    private static List<string> Keys(params ClipboardEntry[] entries) => entries.Select(entry => entry.Key()).ToList();

    // Until the engine has dealt with this many version 2 heads (its log says so).
    private static async Task HeadsReceived(int count) =>
        Assert.True(await Wait.Until(() => LogTap.With("[sync] history head from").Count >= count));

    // ---- on connect ----

    [Fact]
    public async Task The_handshake_says_protocol_2()
    {
        using var node = new TestNode("hs");
        node.Start();

        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, node.Port);
        using var reader = new StreamReader(client.GetStream());
        string? line = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));

        output.WriteLine("handshake: " + line!.Replace(node.Id, "<key>").Replace(JsonDocument.Parse(line).RootElement.GetProperty("EphemeralPublicKey").GetString()!, "<ephemeral>").Replace(JsonDocument.Parse(line).RootElement.GetProperty("Signature").GetString()!, "<signature>"));
        using var document = JsonDocument.Parse(line!);
        Assert.Equal(2, document.RootElement.GetProperty("Protocol").GetInt32());
        Assert.Equal(node.Id, document.RootElement.GetProperty("IdentityPublicKey").GetString());
    }

    [Fact]
    public async Task A_version_2_peer_gets_a_head_and_no_history_batch()
    {
        using var node = new TestNode("a");
        var (a1, a2, a3) = (node.Make("one", 1), node.Make("two", 2), node.Make("three", 3));
        node.SeedHistory(a1, a3, a2);
        node.SeedDeleted("old-1", "old-2");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);

        await peer.ConnectAsync(node);
        var heads = await peer.WaitForAsync("history_head", 1);
        await Wait.Quiet();

        Assert.Equal(2, peer.PeerProtocol);
        Assert.Empty(peer.Received("history_batch"));
        Assert.Empty(peer.Received("history_request"));
        var head = Assert.Single(heads);
        output.WriteLine("history_head: " + head.Payload);
        var parsed = HistoryHead.ParseSync(head.Payload)!;
        Assert.Equal(Keys(a3, a2, a1), parsed.Keys);
        Assert.Equal(3, parsed.Times!.Count);
        Assert.Equal(new[] { "old-2", "old-1" }, parsed.Deleted);
        using var json = JsonDocument.Parse(head.Payload);
        Assert.Equal(new[] { "Keys", "Times", "Deleted" }, json.RootElement.EnumerateObject().Select(p => p.Name));
    }

    [Fact]
    public async Task A_version_2_peer_with_an_empty_history_still_gets_a_head()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);

        await peer.ConnectAsync(node);

        var head = Assert.Single(await peer.WaitForAsync("history_head", 1));
        Assert.Equal("{\"Keys\":[],\"Times\":[],\"Deleted\":[]}", head.Payload);
    }

    [Fact]
    public async Task A_version_1_peer_gets_the_head_and_the_whole_batch_and_never_a_request_or_delete()
    {
        using var node = new TestNode("a");
        var (a1, a2, a3) = (node.Make("one", 1), node.Make("two", 2), node.Make("three", 3));
        node.SeedHistory(a1, a2, a3);
        node.Start();
        using var peer = new RawPeer("old");
        node.Trust(peer.Id);

        await peer.ConnectAsync(node, protocol: 1);
        var batches = await peer.WaitForAsync("history_batch", 1);

        // The same as before protocol 2: a head with the newest entry and the keys, then the whole history.
        var head = Assert.Single(peer.Received("history_head"));
        using (var json = JsonDocument.Parse(head.Payload))
        {
            Assert.Equal(new[] { "Newest", "Keys" }, json.RootElement.EnumerateObject().Select(p => p.Name));
        }
        var batch = JsonSerializer.Deserialize<List<ClipboardEntry>>(Assert.Single(batches).Payload)!;
        Assert.Equal(3, batch.Count);

        // It deletes on this PC, and the old peer is not told.
        Assert.True(node.Engine!.DeleteHistoryEntry(a2.Key()));
        node.Engine.ClearHistory();
        await Wait.Quiet();
        Assert.Empty(peer.Received("delete"));
        Assert.Empty(peer.Received("history_request"));
    }

    [Fact]
    public async Task A_version_1_peers_head_and_batch_apply_the_newest_new_item_to_the_clipboard_even_if_older_than_the_own_newest()
    {
        using var node = new TestNode("a");
        node.SeedHistory(node.Make("own newest", 100));
        node.Start();
        using var peer = new RawPeer("old");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node, protocol: 1);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        var all = new List<ClipboardEntry> { r1, r2, r3 };

        // As a version 1 build sends them.
        await peer.SendAsync("history_head", JsonSerializer.Serialize(HistoryHead.ForBatch(all)));
        await peer.SendAsync("history_batch", JsonSerializer.Serialize(all));

        Assert.True(await Wait.Until(() => node.Texts.Count == 4));
        Assert.Equal(new[] { "r3" }, node.Applied);
        Assert.Equal(new[] { "r3", "r2", "r1", "own newest" }, node.Texts);
    }

    // ---- asking ----

    [Fact]
    public async Task The_newest_missing_item_is_asked_for_alone_first_and_is_the_only_one_put_on_the_clipboard()
    {
        using var node = new TestNode("a");
        node.SeedHistory(node.Make("own newest", 100));
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));

        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        var requests = await peer.WaitForAsync("history_request", 2);

        // Two requests back to back: the newest alone, then the rest.
        output.WriteLine("history_request 1: " + requests[0].Payload);
        output.WriteLine("history_request 2: " + requests[1].Payload);
        Assert.Equal(Keys(r3), RawPeer.KeysOf(requests[0]));
        Assert.Equal(Keys(r2, r1), RawPeer.KeysOf(requests[1]));
        Assert.Equal("{\"Keys\":[" + string.Join(",", Keys(r3).Select(k => JsonSerializer.Serialize(k))) + "]}", requests[0].Payload);

        // The answer to the first: r3 on the clipboard, a stack that counts all three at once.
        await peer.SendBatchAsync(r3);
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));
        Assert.True(await Wait.Until(() => node.Texts.Contains("r3")));
        var shown = node.Engine!.GetHistory();
        Assert.Equal(new[] { "r3", "own newest" }, shown.Select(i => i.TextPreview));
        Assert.NotNull(shown[0].BatchId);
        Assert.Equal(3, shown[0].BatchExpected);
        Assert.False(shown[0].Quiet);

        // The answer to the second: no clipboard, no announcement, one stack of three.
        await peer.SendBatchAsync(r2, r1);
        Assert.True(await Wait.Until(() => node.Texts.Count == 4));
        Assert.Equal(new[] { "r3" }, node.Applied);
        shown = node.Engine.GetHistory();
        Assert.Equal(new[] { "r3", "r2", "r1", "own newest" }, shown.Select(i => i.TextPreview));
        Assert.Single(shown.Take(3).Select(i => i.BatchId).Distinct());
        Assert.NotNull(shown[0].BatchId);
        Assert.Null(shown[0].BatchExpected);
        Assert.Null(shown[3].BatchId);
        Assert.Equal(new[] { false, true, true, false }, shown.Select(i => i.Quiet));
        Assert.True(LogTap.Contains("answer from"));
    }

    [Fact]
    public async Task Items_already_here_or_deleted_here_are_not_asked_for()
    {
        using var node = new TestNode("a");
        using var peer = new RawPeer("p");
        var own = node.Make("own", 1);
        var (r0, r2, r3) = (peer.Make("r0", 0), peer.Make("r2", 2), peer.Make("r3", 3));
        node.SeedHistory(own);
        node.SeedDeleted(r2.Key());
        node.Start();
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendHeadAsync(new[] { r0, own, r2, r3 });
        var requests = await peer.WaitForAsync("history_request", 2);
        await Wait.Quiet();

        Assert.Equal(2, peer.Received("history_request").Count);
        Assert.Equal(Keys(r3), RawPeer.KeysOf(requests[0]));
        Assert.Equal(Keys(r0), RawPeer.KeysOf(requests[1]));
    }

    [Fact]
    public async Task A_head_with_nothing_missing_asks_for_nothing()
    {
        using var node = new TestNode("a");
        var own = node.Make("own", 1);
        node.SeedHistory(own);
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendHeadAsync(new[] { own });
        await Wait.Quiet();

        Assert.Empty(peer.Received("history_request"));
    }

    [Fact]
    public async Task Only_the_25_newest_are_worth_asking_for_but_the_first_is_always_asked_for()
    {
        using var node = new TestNode("a");
        node.SeedHistory(Enumerable.Range(100, 25).Select(n => node.Make($"own {n}", n)).ToArray());
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var older = new[] { peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3) };

        await peer.SendHeadAsync(older);
        var requests = await peer.WaitForAsync("history_request", 1);
        await Wait.Quiet();

        // Everything is older than the full history, so only the newest (the one for the clipboard) is wanted.
        Assert.Single(peer.Received("history_request"));
        Assert.Equal(Keys(older[2]), RawPeer.KeysOf(requests[0]));
        await peer.SendBatchAsync(older[2]);
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));
        Assert.Equal(new[] { "r3" }, node.Applied);
        // Kept though it is the oldest of all: the oldest other item went, and the total is still 25.
        Assert.Equal(25, node.Texts.Count);
        Assert.Equal("r3", node.Texts[0]);
        Assert.DoesNotContain("own 100", node.Texts);
    }

    [Fact]
    public async Task A_batch_nobody_asked_for_on_a_version_2_connection_applies_like_a_version_1_batch()
    {
        using var node = new TestNode("a");
        node.SeedHistory(node.Make("own newest", 100));
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.WaitForAsync("history_head", 1);

        await peer.SendBatchAsync(peer.Make("r1", 1), peer.Make("r3", 3), peer.Make("r2", 2));

        Assert.True(await Wait.Until(() => node.Texts.Count == 4));
        Assert.Equal(new[] { "r3" }, node.Applied);
        Assert.Equal(new[] { "r3", "r2", "r1", "own newest" }, node.Texts);
    }

    [Fact]
    public async Task A_second_answer_that_comes_first_is_still_taken_in_order()
    {
        // Answers are matched to requests by their order: the first answer is the convenience one.
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);

        await peer.SendBatchAsync(r3);
        await peer.SendBatchAsync(r2, r1);

        Assert.True(await Wait.Until(() => node.Texts.Count == 3));
        Assert.Equal(new[] { "r3" }, node.Applied);
        Assert.Equal(new[] { "r3", "r2", "r1" }, node.Texts);
    }

    [Fact]
    public async Task An_empty_answer_to_the_convenience_request_applies_nothing_and_the_rest_still_arrives_quietly()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);

        await peer.SendBatchAsync(); // r3 is gone at the sender
        await peer.SendBatchAsync(r2, r1);

        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        Assert.Empty(node.Applied);
        Assert.All(node.Engine!.GetHistory(), item => Assert.True(item.Quiet));
    }

    [Fact]
    public async Task What_a_peer_signed_wrongly_or_is_not_trusted_is_not_taken_from_an_answer()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        using var stranger = new RawPeer("stranger");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var good = peer.Make("good", 2);
        var forged = peer.Make("forged", 3) with { Content = "changed after signing" };
        var untrusted = stranger.Make("stranger's", 4);
        await peer.SendHeadAsync(new[] { good, forged, untrusted });
        await peer.WaitForAsync("history_request", 2);

        await peer.SendBatchAsync(untrusted);   // the convenience request: nothing acceptable
        await peer.SendBatchAsync(forged, good);

        Assert.True(await Wait.Until(() => node.Texts.Count == 1));
        Assert.Equal(new[] { "good" }, node.Texts);
        Assert.Empty(node.Applied);
    }

    // ---- being asked ----

    [Fact]
    public async Task A_request_is_answered_with_one_batch_newest_first_and_unknown_keys_are_skipped()
    {
        using var node = new TestNode("a");
        var (a1, a2, a3) = (node.Make("one", 1), node.Make("two", 2), node.Make("three", 3));
        node.SeedHistory(a1, a3, a2);
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(new List<string> { a1.Key(), "not-a-key", a3.Key() })));
        var batches = await peer.WaitForAsync("history_batch", 1);

        var batch = JsonSerializer.Deserialize<List<ClipboardEntry>>(Assert.Single(batches).Payload)!;
        Assert.Equal(Keys(a3, a1), Keys(batch.ToArray()));
        Assert.Empty(peer.Received("history_request"));
    }

    [Fact]
    public async Task A_request_for_nothing_it_has_is_answered_with_an_empty_batch()
    {
        using var node = new TestNode("a");
        node.SeedHistory(node.Make("one", 1));
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(new List<string> { "nope" })));

        var batches = await peer.WaitForAsync("history_batch", 1);
        Assert.Equal("[]", Assert.Single(batches).Payload);
    }

    [Fact]
    public async Task Requests_are_answered_in_the_order_they_came_with_a_big_answer_never_overtaking_a_small_one()
    {
        using var node = new TestNode("a");
        var big = node.Make(new string('x', 4_000_000), 1);
        var small = node.Make("small", 2);
        node.SeedHistory(big, small);
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(Keys(big))));
        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(Keys(small))));
        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(new List<string> { "nope" })));
        var batches = await peer.WaitForAsync("history_batch", 3);

        Assert.Equal(3, batches.Count);
        Assert.Equal(Keys(big), Keys(JsonSerializer.Deserialize<List<ClipboardEntry>>(batches[0].Payload)!.ToArray()));
        Assert.Equal(Keys(small), Keys(JsonSerializer.Deserialize<List<ClipboardEntry>>(batches[1].Payload)!.ToArray()));
        Assert.Equal("[]", batches[2].Payload);
    }

    [Fact]
    public async Task Only_the_first_100_keys_of_a_request_count()
    {
        using var node = new TestNode("a");
        var a1 = node.Make("one", 1);
        var a2 = node.Make("two", 2);
        node.SeedHistory(a1, a2);
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var keys = Enumerable.Range(0, 150).Select(i => $"nope-{i}").ToList();
        keys[0] = a1.Key();
        keys[120] = a2.Key(); // past the first 100

        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(keys)));

        var batch = JsonSerializer.Deserialize<List<ClipboardEntry>>(Assert.Single(await peer.WaitForAsync("history_batch", 1)).Payload)!;
        Assert.Equal(Keys(a1), Keys(batch.ToArray()));
    }

    [Fact]
    public async Task A_request_from_a_version_1_peer_is_not_answered()
    {
        using var node = new TestNode("a");
        var a1 = node.Make("one", 1);
        node.SeedHistory(a1);
        node.Start();
        using var peer = new RawPeer("old");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node, protocol: 1);
        await peer.WaitForAsync("history_batch", 1);

        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(Keys(a1))));
        await Wait.Quiet();

        Assert.Single(peer.Received("history_batch")); // only the one sent on connect
        Assert.True(LogTap.Contains("ignored a history request"));
    }

    // ---- deleting ----

    [Fact]
    public async Task A_delete_message_removes_the_items_and_never_touches_the_clipboard_and_they_do_not_come_back()
    {
        using var node = new TestNode("a");
        using var peer = new RawPeer("p");
        var (a1, a2, a3) = (node.Make("one", 1), node.Make("two", 2), node.Make("three", 3));
        var theirs = peer.Make("theirs", 4);
        node.SeedHistory(a1, a2, a3);
        node.Start();
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendAsync("delete", JsonSerializer.Serialize(new KeysMessage(new List<string> { a2.Key(), theirs.Key() })));

        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        Assert.Equal(new[] { "three", "one" }, node.Texts);
        Assert.Empty(node.Applied);

        // Offered again, in a batch nobody asked for and live: refused.
        await peer.SendBatchAsync(theirs);
        await peer.SendAsync("entry", JsonSerializer.Serialize(theirs));
        await Wait.Quiet();
        Assert.Equal(new[] { "three", "one" }, node.Texts);
        Assert.Empty(node.Applied);

        // Asked for in a head: not asked for.
        await peer.SendHeadAsync(new[] { theirs });
        await Wait.Quiet();
        Assert.Empty(peer.Received("history_request"));
    }

    [Fact]
    public async Task The_deleted_list_of_a_head_removes_the_items_and_is_passed_on_in_this_pcs_own_head()
    {
        using var node = new TestNode("a");
        using var peer = new RawPeer("p");
        var (a1, a2, a3) = (node.Make("one", 1), node.Make("two", 2), node.Make("three", 3));
        node.SeedHistory(a1, a2, a3);
        node.Start();
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendHeadAsync(new List<ClipboardEntry>(), a2.Key(), a3.Key());

        Assert.True(await Wait.Until(() => node.Texts.Count == 1));
        Assert.Equal(new[] { "one" }, node.Texts);
        Assert.Empty(node.Applied);
        // A device that connects later hears of it from this PC's head.
        using var later = new RawPeer("later");
        node.Trust(later.Id);
        await later.ConnectAsync(node);
        var head = HistoryHead.ParseSync(Assert.Single(await later.WaitForAsync("history_head", 1)).Payload)!;
        Assert.Equal(Keys(a1), head.Keys);
        Assert.Equal(new[] { a3.Key(), a2.Key() }, head.Deleted);
    }

    [Fact]
    public async Task A_delete_is_not_sent_on_to_the_other_devices()
    {
        using var node = new TestNode("a");
        using var peer = new RawPeer("p");
        using var other = new RawPeer("other");
        var a1 = node.Make("one", 1);
        node.SeedHistory(a1);
        node.Start();
        node.Trust(peer.Id);
        node.Trust(other.Id);
        await peer.ConnectAsync(node);
        await other.ConnectAsync(node);

        await peer.SendAsync("delete", JsonSerializer.Serialize(new KeysMessage(Keys(a1))));
        Assert.True(await Wait.Until(() => node.Texts.Count == 0));
        await Wait.Quiet();

        Assert.Empty(other.Received("delete"));
        Assert.Empty(peer.Received("delete"));
    }

    [Fact]
    public async Task A_local_delete_is_sent_to_version_2_peers_only_for_one_item_and_for_clearing_all()
    {
        using var node = new TestNode("a");
        var (a1, a2, a3) = (node.Make("one", 1), node.Make("two", 2), node.Make("three", 3));
        node.SeedHistory(a1, a2, a3);
        node.Start();
        using var v2 = new RawPeer("v2");
        using var v1 = new RawPeer("v1");
        node.Trust(v2.Id);
        node.Trust(v1.Id);
        await v2.ConnectAsync(node);
        await v1.ConnectAsync(node, protocol: 1);
        await v2.WaitForAsync("history_head", 1);
        await v1.WaitForAsync("history_batch", 1);

        Assert.True(node.Engine!.DeleteHistoryEntry(a2.Key()));
        var first = (await v2.WaitForAsync("delete", 1))[0];
        output.WriteLine("delete: " + first.Payload);
        Assert.Equal("{\"Keys\":[" + JsonSerializer.Serialize(a2.Key()) + "]}", first.Payload);

        node.Engine.ClearHistory();
        var second = (await v2.WaitForAsync("delete", 2))[1];
        Assert.Equal(Keys(a1, a3).OrderBy(k => k), RawPeer.KeysOf(second).OrderBy(k => k));
        await Wait.Quiet();
        Assert.Equal(2, v2.Received("delete").Count);
        Assert.Empty(v1.Received("delete"));
        Assert.Empty(v1.Received("history_request"));
        Assert.Empty(node.Texts);
    }

    [Fact]
    public async Task Clearing_a_big_history_is_sent_in_messages_of_at_most_100_keys()
    {
        using var node = new TestNode("a");
        // (The history keeps 25, so a clear is at most 25 keys: one message.)
        node.SeedHistory(Enumerable.Range(1, 25).Select(n => node.Make($"n{n}", n)).ToArray());
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.WaitForAsync("history_head", 1);

        node.Engine!.ClearHistory();

        var deletes = await peer.WaitForAsync("delete", 1);
        Assert.Equal(25, RawPeer.KeysOf(deletes[0]).Count);
    }

    [Fact]
    public async Task A_delete_of_a_stack_card_promotes_the_next_and_dissolving_follows()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);
        await peer.SendBatchAsync(r3);
        await peer.SendBatchAsync(r2, r1);
        Assert.True(await Wait.Until(() => node.Texts.Count == 3 && node.Engine!.GetHistory()[0].BatchExpected == null));

        // The peer deletes the front card.
        await peer.SendAsync("delete", JsonSerializer.Serialize(new KeysMessage(Keys(r3))));
        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        var shown = node.Engine!.GetHistory();
        Assert.Equal(new[] { "r2", "r1" }, shown.Select(i => i.TextPreview));
        Assert.Equal(shown[0].BatchId, shown[1].BatchId);
        Assert.NotNull(shown[0].BatchId);

        // Then one of the two: the other is a single card (the page shows it so; a group of one is not a stack).
        await peer.SendAsync("delete", JsonSerializer.Serialize(new KeysMessage(Keys(r1))));
        Assert.True(await Wait.Until(() => node.Texts.Count == 1));
        Assert.Equal(new[] { "r2" }, node.Texts);
        Assert.Empty(node.Applied.Skip(1)); // (only r3, from the sync)
    }

    // ---- live items, and other connections ----

    [Fact]
    public async Task A_live_item_goes_on_the_clipboard_and_on_top_whatever_its_time()
    {
        using var node = new TestNode("a");
        node.SeedHistory(node.Make("own newest", 100));
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);

        await peer.SendAsync("entry", JsonSerializer.Serialize(peer.Make("live", 5)));

        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        Assert.Equal(new[] { "live", "own newest" }, node.Texts);
        Assert.Equal(new[] { "live" }, node.Applied);
    }

    [Fact]
    public async Task When_the_connection_asked_closes_the_items_are_asked_of_another_device()
    {
        using var node = new TestNode("a");
        node.Start();
        using var first = new RawPeer("first");
        using var second = new RawPeer("second");
        node.Trust(first.Id);
        node.Trust(second.Id);
        await first.ConnectAsync(node);
        await second.ConnectAsync(node);
        var (r1, r2, r3) = (first.Make("r1", 1), first.Make("r2", 2), first.Make("r3", 3));
        var theirs = new[] { r1, r2, r3 };

        await first.SendHeadAsync(theirs);
        await first.WaitForAsync("history_request", 2);
        await second.SendHeadAsync(theirs);   // the same items: already asked for elsewhere
        await HeadsReceived(2);
        Assert.Empty(second.Received("history_request"));

        first.Close(); // never answered

        var requests = await second.WaitForAsync("history_request", 2);
        Assert.Equal(Keys(r3), RawPeer.KeysOf(requests[0]));
        Assert.Equal(Keys(r2, r1), RawPeer.KeysOf(requests[1]));
        await second.SendBatchAsync(r3);
        await second.SendBatchAsync(r2, r1);
        Assert.True(await Wait.Until(() => node.Texts.Count == 3));
        Assert.Equal(new[] { "r3" }, node.Applied);
    }

    [Fact]
    public async Task When_the_connection_closes_after_the_front_item_the_rest_is_asked_of_another_device_without_touching_the_clipboard_again()
    {
        using var node = new TestNode("a");
        node.Start();
        using var first = new RawPeer("first");
        using var second = new RawPeer("second");
        node.Trust(first.Id);
        node.Trust(second.Id);
        await first.ConnectAsync(node);
        await second.ConnectAsync(node);
        var (r1, r2, r3) = (first.Make("r1", 1), first.Make("r2", 2), first.Make("r3", 3));
        var theirs = new[] { r1, r2, r3 };
        await first.SendHeadAsync(theirs);
        await first.WaitForAsync("history_request", 2);
        await second.SendHeadAsync(theirs);
        await HeadsReceived(2);
        await first.SendBatchAsync(r3); // answered; the second request never is
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));

        first.Close();

        var requests = await second.WaitForAsync("history_request", 1);
        await Wait.Quiet();
        Assert.Single(second.Received("history_request"));
        Assert.Equal(Keys(r2, r1), RawPeer.KeysOf(requests[0]));
        await second.SendBatchAsync(r2, r1);
        Assert.True(await Wait.Until(() => node.Texts.Count == 3));
        Assert.Equal(new[] { "r3" }, node.Applied);
    }

    [Fact]
    public async Task A_connection_that_closes_before_the_rest_arrives_ends_the_stacks_waiting()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);
        await peer.SendBatchAsync(r3);
        Assert.True(await Wait.Until(() => node.Engine!.GetHistory() is [{ BatchExpected: 3 }]));

        peer.Close();

        Assert.True(await Wait.Until(() => node.Engine!.GetHistory() is [{ BatchExpected: null, BatchId: null }]));
    }

    // ---- a late answer, two answers at once, an unreadable answer ----

    [Fact]
    public async Task A_late_answer_to_an_expired_request_is_stored_quietly_and_never_touches_the_clipboard()
    {
        using var node = new TestNode("a");
        node.SeedHistory(node.Make("own newest", 100));
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);

        // Nobody answers for 90 seconds: both requests expire (they stay queued as markers).
        node.Engine!.ExpireSyncRequests(Environment.TickCount64 + 100_000);
        await peer.SendBatchAsync(r3);

        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        await Wait.Quiet(200);
        Assert.Empty(node.Applied);
        var shown = node.Engine.GetHistory();
        Assert.Equal(new[] { "own newest", "r3" }, shown.Select(i => i.TextPreview)); // the timeline: nothing goes on top
        Assert.True(shown[1].Quiet);
        Assert.Null(shown[1].BatchId);
        Assert.Null(shown[1].BatchExpected);

        // The second marker takes the second answer, again quietly.
        await peer.SendBatchAsync(r2, r1);
        Assert.True(await Wait.Until(() => node.Texts.Count == 4));
        Assert.Empty(node.Applied);
        shown = node.Engine.GetHistory();
        Assert.Equal(new[] { "own newest", "r3", "r2", "r1" }, shown.Select(i => i.TextPreview));
        Assert.All(shown.Skip(1), item => { Assert.True(item.Quiet); Assert.Null(item.BatchId); });
        Assert.True(LogTap.Contains("late answer from"));

        // The markers are gone: a batch nobody asked for is a version 1 batch again.
        await peer.SendBatchAsync(peer.Make("r4", 4));
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));
        Assert.Equal(new[] { "r4" }, node.Applied);
    }

    [Fact]
    public async Task An_expired_request_does_not_take_the_answer_of_a_newer_one()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2) = (peer.Make("r1", 1), peer.Make("r2", 2));
        await peer.SendHeadAsync(new[] { r1 });
        await peer.WaitForAsync("history_request", 1);
        node.Engine!.ExpireSyncRequests(Environment.TickCount64 + 100_000);
        await peer.SendHeadAsync(new[] { r1, r2 });   // the next connect would do this: asked again
        await peer.WaitForAsync("history_request", 3);

        await peer.SendBatchAsync(r1);                // the late answer of the first request
        Assert.True(await Wait.Until(() => node.Texts.Count == 1));
        await Wait.Quiet(200);
        Assert.Empty(node.Applied);

        await peer.SendBatchAsync(r2);                // the answer of the convenience request of the second head
        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        Assert.Equal(new[] { "r2" }, node.Applied);
    }

    [Fact]
    public async Task Two_peers_answering_at_once_put_one_item_on_the_clipboard_and_the_older_one_is_quiet()
    {
        using var node = new TestNode("a");
        node.Start();
        using var first = new RawPeer("first");
        using var second = new RawPeer("second");
        node.Trust(first.Id);
        node.Trust(second.Id);
        await first.ConnectAsync(node);
        await second.ConnectAsync(node);
        var newer = first.Make("newer", 5);
        var older = second.Make("older", 2);
        await first.SendHeadAsync(new[] { newer });
        await second.SendHeadAsync(new[] { older });
        await first.WaitForAsync("history_request", 1);
        await second.WaitForAsync("history_request", 1);

        await first.SendBatchAsync(newer);
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));
        await second.SendBatchAsync(older);

        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        await Wait.Quiet(200);
        Assert.Equal(new[] { "newer" }, node.Applied);
        var shown = node.Engine!.GetHistory();
        Assert.Equal(new[] { "older", "newer" }, shown.Select(i => i.TextPreview)); // the later block on top
        Assert.Equal(new[] { true, false }, shown.Select(i => i.Quiet));
        Assert.True(LogTap.Contains("not put on the clipboard"));
    }

    [Fact]
    public async Task Two_peers_answering_at_once_the_newer_one_last_puts_both_on_the_clipboard()
    {
        using var node = new TestNode("a");
        node.Start();
        using var first = new RawPeer("first");
        using var second = new RawPeer("second");
        node.Trust(first.Id);
        node.Trust(second.Id);
        await first.ConnectAsync(node);
        await second.ConnectAsync(node);
        var older = first.Make("older", 2);
        var newer = second.Make("newer", 5);
        await first.SendHeadAsync(new[] { older });
        await second.SendHeadAsync(new[] { newer });
        await first.WaitForAsync("history_request", 1);
        await second.WaitForAsync("history_request", 1);

        await first.SendBatchAsync(older);
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));
        await second.SendBatchAsync(newer);

        // (The newer one is "newest": it goes on the clipboard after the older, as the rule says.)
        Assert.True(await Wait.Until(() => node.Applied.Count == 2));
        Assert.Equal(new[] { "older", "newer" }, node.Applied);
        Assert.All(node.Engine!.GetHistory(), item => Assert.False(item.Quiet));
    }

    [Fact]
    public async Task A_history_batch_that_cannot_be_read_still_answers_the_oldest_request()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);

        await peer.SendAsync("history_batch", "this is not a batch");   // the answer to the request for r3: an empty one
        await peer.SendBatchAsync(r2, r1);                              // the answer to the second request

        // The second answer is the second one: nothing on the clipboard, no announcement.
        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        await Wait.Quiet(200);
        Assert.Empty(node.Applied);
        Assert.Equal(new[] { "r2", "r1" }, node.Texts);
    }

    [Fact]
    public async Task A_history_batch_without_a_payload_still_answers_the_oldest_request()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (r1, r2, r3) = (peer.Make("r1", 1), peer.Make("r2", 2), peer.Make("r3", 3));
        await peer.SendHeadAsync(new[] { r1, r2, r3 });
        await peer.WaitForAsync("history_request", 2);

        await peer.SendAsync("history_batch", null!);   // no Payload at all: the answer to the request for r3, an empty one
        await peer.SendBatchAsync(r2, r1);              // the answer to the second request

        // The second answer is the second one: nothing on the clipboard, no announcement.
        Assert.True(await Wait.Until(() => node.Texts.Count == 2));
        await Wait.Quiet(200);
        Assert.Empty(node.Applied);
        Assert.Equal(new[] { "r2", "r1" }, node.Texts);
    }

    // ---- two engines ----

    [Fact]
    public async Task Two_version_2_engines_exchange_only_what_the_other_is_missing_and_deleted_items_do_not_return()
    {
        using var a = new TestNode("a");
        using var b = new TestNode("b");
        var (a1, a2, a3) = (a.Make("a one", 1), a.Make("a two", 2), a.Make("a three", 3));
        var b1 = b.Make("b one", 5);
        a.SeedHistory(a1, a2, a3);
        b.SeedHistory(a1, b1); // b has a1 already
        a.Start();
        b.Start();
        a.Trust(b.Id);
        b.Trust(a.Id);

        var outcome = await b.Engine!.PairByAddressAsync($"127.0.0.1:{a.Port}");

        Assert.Equal(PairOutcome.Connected, outcome);
        Assert.True(await Wait.Until(() => a.Texts.Count == 4 && b.Texts.Count == 4));
        Assert.Equal(new[] { "a three", "a two", "b one", "a one" }, b.Texts);   // the sync on top
        Assert.Equal(new[] { "b one", "a three", "a two", "a one" }, a.Texts);
        Assert.Equal(new[] { "a three" }, b.Applied);
        Assert.Equal(new[] { "b one" }, a.Applied);
        // Only the missing items were asked for and sent: nothing was sent that the other had.
        var answers = LogTap.With("[sync] answer from");
        Assert.Equal(3, answers.Count); // two to b (the newest alone, then the other), one to a
        Assert.All(answers, line => Assert.Contains("0 known", line));
        Assert.Contains(LogTap.With("[sync] asking"), line => line.Contains("for 2 missing item(s) in 2 request(s)"));
        Assert.Contains(LogTap.With("[sync] asking"), line => line.Contains("for 1 missing item(s) in 1 request(s)"));
        Assert.False(LogTap.Contains("history batch:")); // no whole-history batch

        // A delete while connected reaches the other, without touching its clipboard.
        Assert.True(a.Engine!.DeleteHistoryEntry(a3.Key()));
        Assert.True(await Wait.Until(() => !b.Has(a3)));
        Assert.Equal(new[] { "a three" }, b.Applied);

        // A delete while the other is off reaches it in the next head.
        b.Engine.Dispose();
        Assert.True(await Wait.Until(() => !a.Engine.GetConnections().Any()));
        Assert.True(a.Engine.DeleteHistoryEntry(a2.Key()));
        b.Start();
        b.Trust(a.Id);
        Assert.True(b.Has(a2)); // it still has it, not knowing
        Assert.Equal(PairOutcome.Connected, await b.Engine.PairByAddressAsync($"127.0.0.1:{a.Port}"));
        Assert.True(await Wait.Until(() => !b.Has(a2)));
        Assert.False(a.Has(a2));
        await Wait.Quiet();
        Assert.False(b.Has(a2));
        Assert.False(b.Has(a3));
        Assert.Equal(new[] { "b one", "a one" }, b.Texts);
    }

    [Fact]
    public async Task A_version_2_engine_and_an_older_one_still_sync_the_old_way()
    {
        using var a = new TestNode("a");
        using var old = new TestNode("old");
        var (a1, a2) = (a.Make("a one", 1), a.Make("a two", 2));
        var o1 = old.Make("old one", 5);
        a.SeedHistory(a1, a2);
        old.SeedHistory(o1, old.Make("old two", 6));
        a.Start();
        old.Start(protocol: 1);
        a.Trust(old.Id);
        old.Trust(a.Id);

        Assert.Equal(PairOutcome.Connected, await old.Engine!.PairByAddressAsync($"127.0.0.1:{a.Port}"));

        Assert.True(await Wait.Until(() => a.Texts.Count == 4 && old.Texts.Count == 4));
        Assert.False(LogTap.Contains("[sync] asking"));
        Assert.False(LogTap.Contains("[sync] ignored"));
        Assert.Equal(new[] { "old two" }, a.Applied); // the newest new item of the batch
        Assert.Equal(new[] { "a two" }, old.Applied);
        // A delete on the newer one is not sent to the older one, which keeps its copy; it does not come back to the newer one.
        Assert.True(a.Engine!.DeleteHistoryEntry(a1.Key()));
        await Wait.Quiet();
        Assert.True(old.Has(a1));
        Assert.False(a.Has(a1));
        Assert.False(LogTap.Contains("[sync] ignored a delete"));
    }
}
