using System.Text;
using System.Text.Json;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.EngineTests;

// The same content showing up twice, and connections that mustn't be taken
// over (design/sync-dedupe-spec.md), with the real engine: echoes of what was
// just copied here, one card per content, re-copies, live items history does
// not take, and a replayed handshake. Shares the log with SyncEngineTests, so
// these run one at a time with it.
[Collection("engine log")]
public class DedupeEngineTests
{
    public DedupeEngineTests()
    {
        LogTap.Start();
    }

    private static ClipboardSync Clipboard(TestNode node) => ClipboardSync.ByLabel[node.Label];

    // Until the node has registered the peer's connection (what it sends goes nowhere before that).
    private static async Task Registered(TestNode node, RawPeer peer) =>
        Assert.True(await Wait.Until(() => node.Engine!.GetConnections().Contains(peer.Id)));

    private static List<string> EntryTexts(RawPeer peer) =>
        peer.Received("entry").Select(e => JsonSerializer.Deserialize<ClipboardEntry>(e.Payload)!.Content).ToList();

    // ---- live entries: history first ----

    [Fact]
    public async Task A_live_entry_older_than_everything_a_full_history_keeps_is_neither_listed_nor_applied()
    {
        using var node = new TestNode("a");
        node.SeedHistory(Enumerable.Range(100, 25).Select(n => node.Make($"own {n}", n)).ToArray());
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var old = peer.Make("old", 5);

        await peer.SendAsync("entry", JsonSerializer.Serialize(old));
        await Wait.Until(() => LogTap.Contains("older than all history keeps"));
        await Wait.Quiet(200);

        Assert.Empty(node.Applied);
        Assert.False(node.Has(old));
        Assert.Equal(25, node.Texts.Count);
    }

    [Fact]
    public async Task A_live_entry_that_is_already_here_is_not_applied_again()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var entry = peer.Make("once", 5);

        await peer.SendAsync("entry", JsonSerializer.Serialize(entry));
        Assert.True(await Wait.Until(() => node.Applied.Count == 1));
        await peer.SendAsync("entry", JsonSerializer.Serialize(entry));
        await Wait.Quiet(300);

        Assert.Equal(new[] { "once" }, node.Applied);
    }

    // ---- echoes and twins ----

    [Fact]
    public async Task An_echo_of_what_was_just_copied_here_is_one_card_not_applied_and_not_announced()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        Clipboard(node).Copy("hello");
        await peer.WaitForAsync("entry", 1);

        // The phone read it back as a copy of its own (with a Windows line ending even).
        await peer.SendAsync("entry", JsonSerializer.Serialize(peer.Make("hello\r\n", 5)));
        Assert.True(await Wait.Until(() => LogTap.Contains("is what the clipboard already holds")));
        await Wait.Quiet(200);

        Assert.Empty(node.Applied);
        var shown = node.Engine!.GetHistory();
        var card = Assert.Single(shown);
        Assert.Equal("hello\r\n", card.TextPreview); // the one that arrived last is on top
        Assert.True(card.Quiet);
    }

    [Fact]
    public async Task Deleting_a_card_deletes_every_entry_with_its_content_and_tells_the_peers()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        var (first, second) = (peer.Make("dup", 1), peer.Make("dup", 2));

        await peer.SendAsync("entry", JsonSerializer.Serialize(first));
        await peer.SendAsync("entry", JsonSerializer.Serialize(second));
        Assert.True(await Wait.Until(() => node.Has(second)));
        await Wait.Quiet(200);
        Assert.Equal(new[] { "dup" }, node.Applied); // the twin found it on the clipboard already
        var card = Assert.Single(node.Engine!.GetHistory());

        Assert.True(node.Engine.DeleteHistoryEntry(card.Key));

        var deletes = await peer.WaitForAsync("delete", 1);
        Assert.Equal(new[] { first.Key(), second.Key() }.OrderBy(k => k), RawPeer.KeysOf(deletes[0]).OrderBy(k => k));
        Assert.Empty(node.Engine.GetHistory());
        Assert.False(node.Has(first));
    }

    // ---- copies here ----

    [Fact]
    public async Task A_copy_of_what_the_newest_item_already_is_is_not_sent_again()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);

        node.Engine!.ShareText("shared");
        await peer.WaitForAsync("entry", 1);
        Clipboard(node).Copy("shared\n");
        node.Engine.ShareText("shared");
        await Wait.Quiet(300);

        Assert.Equal(new[] { "shared" }, EntryTexts(peer));
        Assert.Single(node.Texts);
    }

    [Fact]
    public async Task Copying_A_then_B_then_A_again_sends_A_again_and_lists_it_once_on_top()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);

        Clipboard(node).Copy("A");
        Clipboard(node).Copy("B");
        Clipboard(node).Copy("A");

        await peer.WaitForAsync("entry", 3);
        Assert.Equal(new[] { "A", "B", "A" }, EntryTexts(peer));
        Assert.True(await Wait.Until(() => node.Texts.Count == 2 && node.Texts[0] == "A"));
        Assert.Equal(new[] { "A", "B" }, node.Texts);
    }

    [Fact]
    public async Task The_same_file_twice_in_one_copied_selection_goes_out_once_and_not_again_while_it_is_the_newest()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        string file = Path.Combine(Path.GetTempPath(), $"cliplink-dedupe-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(file, "file body");
        try
        {
            var payload = LocalFiles.Describe(file, out _, out _)!;
            string json = JsonSerializer.Serialize(payload);

            Clipboard(node).CopyFiles(new[] { (json, file), (json, file) });
            await peer.WaitForAsync("entry", 1);
            Clipboard(node).CopyFiles(new[] { (json, file) });
            await Wait.Quiet(300);

            Assert.Single(peer.Received("entry"));
            Assert.Single(node.Engine!.GetHistory());
        }
        finally
        {
            File.Delete(file);
        }
    }

    // ---- connections ----

    [Fact]
    public async Task A_replayed_handshake_does_not_take_over_the_live_connection_but_a_real_new_one_does()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.SendHeadAsync(Array.Empty<ClipboardEntry>()); // proves the session
        Assert.True(await Wait.Until(() => node.Engine!.GetDevices().Any(d => d.PublicKey == peer.Id && d.Connected)));

        using var replay = new RawPeer(peer);
        await replay.ConnectSilentlyAsync(node);
        Assert.True(await Wait.Until(() => LogTap.Contains("the live connection stays")));
        Clipboard(node).Copy("still here");

        await peer.WaitForAsync("entry", 1);
        Assert.Equal(new[] { "still here" }, EntryTexts(peer));

        using var again = new RawPeer(peer);
        await again.ConnectAsync(node);
        await again.SendHeadAsync(Array.Empty<ClipboardEntry>());
        Assert.True(await Wait.Until(() => LogTap.With("[conn] connected:").Count >= 2));
        Clipboard(node).Copy("moved");

        await again.WaitForAsync("entry", 1);
        Assert.Equal(new[] { "moved" }, EntryTexts(again));
    }

    [Fact]
    public async Task A_handshake_line_is_read_up_to_its_limit_and_what_follows_it_is_kept()
    {
        var bytes = Encoding.UTF8.GetBytes("{\"a\":1}\r\nnext line\n");
        using (var reader = new StreamReader(new MemoryStream(bytes)))
        {
            Assert.Equal("{\"a\":1}", await PeerConnection.ReadHandshakeLineAsync(reader));
            Assert.Equal("next line", await reader.ReadLineAsync());
        }

        var endless = Encoding.UTF8.GetBytes(new string('x', PeerConnection.MaxHandshakeChars + 10) + "\n");
        using (var reader = new StreamReader(new MemoryStream(endless)))
        {
            Assert.Null(await PeerConnection.ReadHandshakeLineAsync(reader));
        }

        using (var reader = new StreamReader(new MemoryStream(Encoding.UTF8.GetBytes("no newline"))))
        {
            Assert.Null(await PeerConnection.ReadHandshakeLineAsync(reader));
        }
    }
}
