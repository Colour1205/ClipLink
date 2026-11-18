using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Engine;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.EngineTests;

// Flow control for file streams (see FileFlow): between two builds that both
// say "file-ack" in their handshake, the receiver acknowledges each chunk once
// it is done with it, and the sender keeps at most SendWindow.Size chunks
// unacknowledged. With a peer that didn't say it, nothing changes either way.
// Some of these run the real engine, so they share the log with the other
// engine tests and run one at a time with them.
[Collection("engine log")]
public class FlowControlTests
{
    private const int Chunk = 256 * 1024;

    public FlowControlTests()
    {
        LogTap.Start();
    }

    private static readonly string Hash = Convert.ToHexString(SHA256.HashData("flow"u8.ToArray()));

    // ---- the message ----

    [Fact]
    public void An_ack_is_a_small_envelope_that_reads_back_as_it_was_written()
    {
        var made = FileAckMessage.Envelope(Hash, 41);

        Assert.Equal("{\"Type\":\"file_ack\",\"Payload\":\"{\\\"FileHash\\\":\\\"" + Hash + "\\\",\\\"ChunkIndex\\\":41}\"}", Encoding.UTF8.GetString(made.Span));
        var envelope = JsonSerializer.Deserialize<Envelope>(made.Span)!;
        Assert.Equal(FileAckMessage.Type, envelope.Type);
        Assert.Equal(new FileAckMessage(Hash, 41), FileAckMessage.Parse(envelope.Payload));
        // As the phones would write it: other field order, lower case, a field it doesn't know.
        Assert.Equal(new FileAckMessage(Hash.ToLowerInvariant(), 0),
            FileAckMessage.Parse("{\"ChunkIndex\":0,\"Extra\":true,\"FileHash\":\"" + Hash.ToLowerInvariant() + "\"}"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{\"FileHash\":\"abc\",\"ChunkIndex\":1}")]
    [InlineData("{\"FileHash\":\"../../x\",\"ChunkIndex\":1}")]
    [InlineData("{\"FileHash\":\"HASH\",\"ChunkIndex\":-1}")]
    [InlineData("{\"FileHash\":\"HASH\",\"ChunkIndex\":\"3\"}")]
    [InlineData("{\"FileHash\":\"HASH\",\"ChunkIndex\":1.5}")]
    [InlineData("[1,2]")]
    public void An_ack_that_does_not_read_as_one_is_dropped_without_throwing(string payload)
    {
        Assert.Null(FileAckMessage.Parse(payload.Replace("HASH", Hash)));
    }

    // ---- the window ----

    private static async Task<bool> Blocks(Task wait, int ms = 150)
    {
        await Task.WhenAny(wait, Task.Delay(ms));
        return !wait.IsCompleted;
    }

    [Fact]
    public async Task A_window_stops_at_its_size_and_opens_as_acks_come()
    {
        var window = new SendWindow();
        for (int i = 0; i < SendWindow.Size; i++)
        {
            await window.WaitForRoomAsync(TimeSpan.FromSeconds(5)); // room: returns at once
            window.Sending();
        }
        Assert.Equal(8, SendWindow.Size);
        Assert.Equal(SendWindow.Size, window.Unacked);

        var wait = window.WaitForRoomAsync(TimeSpan.FromSeconds(5));
        Assert.True(await Blocks(wait));

        Assert.True(window.Ack(0));
        await wait.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(SendWindow.Size - 1, window.Unacked);

        // Acks are cumulative: one for chunk 5 is one for every chunk up to it.
        window.Sending();
        Assert.True(window.Ack(5));
        Assert.Equal(3, window.Unacked); // 9 sent, chunks 0 to 5 acknowledged
    }

    [Fact]
    public void An_ack_that_moves_nothing_changes_nothing()
    {
        var window = new SendWindow(4);
        window.Sending();
        window.Sending();
        window.Sending();

        Assert.False(window.Ack(3));  // never sent (a late ack from an earlier stream, say)
        Assert.False(window.Ack(99));
        Assert.Equal(3, window.Unacked);
        Assert.True(window.Ack(1));
        Assert.False(window.Ack(1));  // again
        Assert.False(window.Ack(0));  // older
        Assert.Equal(1, window.Unacked);
        Assert.True(window.Ack(2));
        Assert.Equal(0, window.Unacked);
    }

    [Fact]
    public async Task A_window_with_no_ack_for_its_timeout_gives_up_and_each_ack_starts_the_time_again()
    {
        var window = new SendWindow(2);
        window.Sending();
        window.Sending();

        var started = DateTime.UtcNow;
        await Assert.ThrowsAsync<TimeoutException>(() => window.WaitForRoomAsync(TimeSpan.FromMilliseconds(200)));
        Assert.True(DateTime.UtcNow - started >= TimeSpan.FromMilliseconds(180));

        // Still waiting after 300 ms of a 400 ms limit, an ack frees room in time.
        var wait = window.WaitForRoomAsync(TimeSpan.FromMilliseconds(400));
        await Task.Delay(300);
        Assert.False(wait.IsCompleted);
        Assert.True(window.Ack(0));
        await wait.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task A_window_waiting_on_a_connection_that_closes_stops_at_once()
    {
        var window = new SendWindow(1);
        window.Sending();
        using var closed = new CancellationTokenSource();

        var wait = window.WaitForRoomAsync(TimeSpan.FromSeconds(30), closed.Token);
        Assert.True(await Blocks(wait));
        closed.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => wait.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    // The thread that closes a connection may hold the engine's lock (Stop),
    // so a waiting stream must never go on - its error handling, tidying its
    // blob away - right there, inside Cancel.
    [Fact]
    public async Task A_window_whose_connection_closes_goes_on_off_the_thread_that_closed_it()
    {
        var window = new SendWindow(1);
        window.Sending();
        using var closed = new CancellationTokenSource();
        using var insideCancel = new ThreadLocal<bool>();

        async Task<bool> WaitThenLook()
        {
            try
            {
                await window.WaitForRoomAsync(TimeSpan.FromSeconds(30), closed.Token);
            }
            catch (OperationCanceledException)
            {
            }
            return insideCancel.Value;
        }

        // Off xUnit's synchronization context, which would post every
        // continuation and hide what this is about.
        var ranInside = Task.Run(WaitThenLook);
        Assert.True(await Blocks(ranInside));
        var closer = new Thread(() =>
        {
            insideCancel.Value = true;
            closed.Cancel();
            insideCancel.Value = false;
        });
        closer.Start();
        closer.Join();

        Assert.False(await ranInside.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void Acks_find_their_stream_by_connection_and_hash_and_a_restart_gets_a_fresh_window()
    {
        var windows = new SendWindows();
        var conn = new object();
        var other = new object();

        Assert.False(windows.Ack(conn, Hash, 0)); // nothing being sent

        var first = windows.Open(conn, Hash);
        first.Sending();
        first.Sending();
        Assert.False(windows.Ack(other, Hash, 0));                          // another connection's
        Assert.False(windows.Ack(conn, new string('0', 64), 0));            // another file
        Assert.True(windows.Ack(conn, Hash.ToLowerInvariant(), 0));         // any case
        Assert.Equal(1, first.Unacked);

        // Started over from chunk 0: a new window, and the old one's late acks don't count.
        var second = windows.Open(conn, Hash);
        Assert.Equal(0, second.Unacked);
        second.Sending();
        Assert.False(windows.Ack(conn, Hash, 1)); // chunk 1 of the old stream: not sent in this one
        Assert.Equal(1, second.Unacked);
        Assert.Equal(1, first.Unacked);

        // The old stream ending leaves the new one alone.
        windows.Close(conn, Hash, first);
        Assert.True(windows.Ack(conn, Hash, 0));
        Assert.Equal(0, second.Unacked);

        // Once it ends, its acks are ignored.
        windows.Close(conn, Hash, second);
        Assert.Equal(0, windows.Count);
        Assert.False(windows.Ack(conn, Hash, 0));
    }

    // ---- the engine ----

    private static async Task Registered(TestNode node, RawPeer peer) =>
        Assert.True(await Wait.Until(() => node.Engine!.GetConnections().Contains(peer.Id)));

    private static List<FileChunkMessage> Chunks(RawPeer peer) =>
        peer.Received("file_chunk").Select(envelope => JsonSerializer.Deserialize<FileChunkMessage>(envelope.Payload)!).ToList();

    private static List<int> AckedIndexes(RawPeer peer) =>
        peer.Received(FileAckMessage.Type).Select(envelope => FileAckMessage.Parse(envelope.Payload)!.ChunkIndex).ToList();

    // A file of chunks 256 KiB chunks and a few bytes more, shared by node.
    private static async Task<string> Share(TestNode node, int chunks, List<string> cleanup)
    {
        byte[] data = RandomNumberGenerator.GetBytes(chunks * Chunk - 100);
        string file = Path.Combine(Path.GetTempPath(), $"cliplink-flow-{Guid.NewGuid():N}.bin");
        await File.WriteAllBytesAsync(file, data);
        cleanup.Add(file);
        var shared = await node.Engine!.ShareFilesAsync(new[] { file });
        Assert.Single(shared.Shared);
        return Convert.ToHexString(SHA256.HashData(data));
    }

    private static void Delete(List<string> files)
    {
        foreach (string file in files) File.Delete(file);
    }

    [Fact]
    public async Task A_peer_that_acknowledges_gets_at_most_the_window_unacknowledged_and_the_rest_as_its_acks_come()
    {
        using var node = new TestNode("paced");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        Assert.Contains(HandshakeMessage.FileAckCap, peer.PeerCaps);
        var files = new List<string>();
        try
        {
            string hash = await Share(node, 20, files);

            Assert.True(await Wait.Until(() => Chunks(peer).Count >= SendWindow.Size));
            await Wait.Quiet(500);
            Assert.Equal(Enumerable.Range(0, 8), Chunks(peer).Select(chunk => chunk.ChunkIndex));
            Assert.True(LogTap.Contains("(paced by acks)"));

            await peer.SendAckAsync(hash, 3);
            Assert.True(await Wait.Until(() => Chunks(peer).Count >= 12));
            await Wait.Quiet(300);
            Assert.Equal(12, Chunks(peer).Count);

            // Acks that move nothing: for chunks not sent yet, and older ones.
            await peer.SendAckAsync(hash, 15);
            await peer.SendAckAsync(hash, 2);
            await Wait.Quiet(300);
            Assert.Equal(12, Chunks(peer).Count);

            await peer.SendAckAsync(hash, 11);
            Assert.True(await Wait.Until(() => Chunks(peer).Count >= 20));
            var chunks = Chunks(peer);
            Assert.Equal(Enumerable.Range(0, 20), chunks.Select(chunk => chunk.ChunkIndex));
            Assert.True(chunks[^1].IsLast);
            Assert.True(await Wait.Until(() => LogTap.Contains($"[file] finished sending {hash[..12]}... to")));
            // The same file_chunk messages as ever.
            Assert.All(chunks, chunk => Assert.Equal(hash, chunk.FileHash));
        }
        finally
        {
            Delete(files);
        }
    }

    [Fact]
    public async Task A_stream_with_no_acks_is_given_up_on_and_asked_for_again_it_starts_over_with_a_fresh_window()
    {
        using var node = new TestNode("stall");
        node.Start(fileAckTimeout: TimeSpan.FromSeconds(1));
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        var files = new List<string>();
        try
        {
            string hash = await Share(node, 12, files);

            Assert.True(await Wait.Until(() => LogTap.Contains($"[file] sending {hash[..12]}... to") && LogTap.Contains("no acknowledgement for 1 s")));
            Assert.Equal(Enumerable.Range(0, 8), Chunks(peer).Select(chunk => chunk.ChunkIndex));
            Assert.Contains(peer.Id, node.Engine!.GetConnections()); // the link stays up

            // Asked again: from chunk 0, with a window of its own.
            await peer.SendAsync("file_request", JsonSerializer.Serialize(new FileRequestMessage(hash)));
            Assert.True(await Wait.Until(() => Chunks(peer).Count >= 16));
            await Wait.Quiet(300);
            Assert.Equal(Enumerable.Range(0, 8).Concat(Enumerable.Range(0, 8)), Chunks(peer).Select(chunk => chunk.ChunkIndex));

            await peer.SendAckAsync(hash, 7);
            Assert.True(await Wait.Until(() => Chunks(peer).Count >= 20));
            Assert.Equal(Enumerable.Range(0, 12), Chunks(peer).Skip(8).Select(chunk => chunk.ChunkIndex));
            Assert.True(Chunks(peer)[^1].IsLast);
        }
        finally
        {
            Delete(files);
        }
    }

    // A file entry made by peer, and its bytes.
    private static ClipboardEntry FileEntry(RawPeer peer, byte[] data, out string hash)
    {
        hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        string content = JsonSerializer.Serialize(new FilePayload("in.bin", hash, data.Length));
        return SigningService.Sign(new ClipboardEntry(content, "file", peer.Id, DateTime.UtcNow), peer.Identity);
    }

    private static async Task SendFile(TestNode node, RawPeer peer, byte[] data, string hash, ClipboardEntry entry)
    {
        await peer.SendAsync("entry", JsonSerializer.Serialize(entry));
        await peer.WaitForAsync("file_request", 1);
        var pieces = data.Chunk(Chunk).ToList();
        for (int i = 0; i < pieces.Count; i++)
        {
            await peer.SendUtf8Async(Wire.Envelope("file_chunk", new FileChunkMessage(hash, i, i == pieces.Count - 1, Convert.ToBase64String(pieces[i]))));
        }
        Assert.True(await Wait.Until(() => node.Engine!.GetHistory().Single().IsAvailable));
    }

    [Fact]
    public async Task A_receiver_acknowledges_every_chunk_once_it_is_written_and_every_chunk_it_ignores()
    {
        using var node = new TestNode("acks");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        byte[] data = RandomNumberGenerator.GetBytes(3 * Chunk + 10);
        var entry = FileEntry(peer, data, out string hash);

        await SendFile(node, peer, data, hash, entry);

        Assert.True(await Wait.Until(() => AckedIndexes(peer).Count >= 4));
        Assert.Equal(new[] { 0, 1, 2, 3 }, AckedIndexes(peer));
        Assert.All(peer.Received(FileAckMessage.Type), envelope => Assert.Equal(hash, FileAckMessage.Parse(envelope.Payload)!.FileHash));

        // A chunk of a stream whose start it never saw is ignored - and acknowledged, so its sender goes on.
        string other = new string('c', 64);
        await peer.SendUtf8Async(Wire.Envelope("file_chunk", new FileChunkMessage(other, 5, false, Convert.ToBase64String(new byte[10]))));
        Assert.True(await Wait.Until(() => AckedIndexes(peer).Count >= 5));
        Assert.Equal(new FileAckMessage(other, 5), FileAckMessage.Parse(peer.Received(FileAckMessage.Type)[^1].Payload));
        // And a stray ack for nothing it sends is ignored.
        await peer.SendAckAsync(other, 3);
        await Wait.Quiet(200);
        Assert.Contains(peer.Id, node.Engine!.GetConnections());
        Assert.False(LogTap.Contains("error handling a message"));
        Assert.False(LogTap.Contains("unknown type"));
    }

    [Theory]
    [InlineData(true)]  // an older peer, to this build
    [InlineData(false)] // this build as an older one, to a peer that has it
    public async Task Without_the_capability_on_either_side_every_chunk_goes_out_unpaced_and_no_ack_is_sent(bool nodeHasIt)
    {
        using var node = new TestNode("old");
        node.Start(caps: nodeHasIt ? null : Array.Empty<string>());
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node, caps: nodeHasIt ? Array.Empty<string>() : null);
        await Registered(node, peer);
        Assert.Equal(nodeHasIt, peer.PeerCaps.Contains(HandshakeMessage.FileAckCap));
        var files = new List<string>();
        try
        {
            string hash = await Share(node, 12, files);

            // All of it, though nothing is acknowledged.
            Assert.True(await Wait.Until(() => Chunks(peer).Count >= 12));
            Assert.Equal(Enumerable.Range(0, 12), Chunks(peer).Select(chunk => chunk.ChunkIndex));
            Assert.False(LogTap.Contains("(paced by acks)"));

            // And a file coming the other way is stored with no file_ack sent back.
            byte[] data = RandomNumberGenerator.GetBytes(2 * Chunk + 3);
            var entry = FileEntry(peer, data, out string inHash);
            await peer.SendAsync("entry", JsonSerializer.Serialize(entry));
            await peer.WaitForAsync("file_request", 1);
            var pieces = data.Chunk(Chunk).ToList();
            for (int i = 0; i < pieces.Count; i++)
            {
                await peer.SendUtf8Async(Wire.Envelope("file_chunk", new FileChunkMessage(inHash, i, i == pieces.Count - 1, Convert.ToBase64String(pieces[i]))));
            }
            Assert.True(await Wait.Until(() => node.Engine!.GetHistory().Any(item => item.IsAvailable && string.Equals(item.FileHash, inHash, StringComparison.OrdinalIgnoreCase))));
            await Wait.Quiet(300);
            Assert.Empty(peer.Received(FileAckMessage.Type));
        }
        finally
        {
            Delete(files);
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Two_engines_send_a_big_file_paced_when_both_have_it_and_unpaced_when_one_does_not(bool both)
    {
        using var a = new TestNode("a");
        using var b = new TestNode("b");
        a.Start();
        b.Start(caps: both ? null : Array.Empty<string>());
        a.Trust(b.Id);
        b.Trust(a.Id);
        Assert.Equal(PairOutcome.Connected, await b.Engine!.PairByAddressAsync($"127.0.0.1:{a.Port}"));
        Assert.True(await Wait.Until(() => a.Engine!.GetConnections().Contains(b.Id) && b.Engine.GetConnections().Contains(a.Id)));
        var files = new List<string>();
        try
        {
            string hash = await Share(a, 24, files);

            Assert.True(await Wait.Until(() => b.Engine.GetHistory().Any(item => item.IsAvailable && string.Equals(item.FileHash, hash, StringComparison.OrdinalIgnoreCase)), 20000));
            Assert.True(await Wait.Until(() => LogTap.Contains($"[file] finished sending {hash[..12]}... to")));
            Assert.Equal(both, LogTap.Contains("(paced by acks)"));
            Assert.False(LogTap.Contains("no acknowledgement"));
            Assert.False(LogTap.Contains("unknown type"));
        }
        finally
        {
            Delete(files);
        }
    }
}
