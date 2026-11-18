using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Engine;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.EngineTests;

// Big files after the receive path stopped going through strings: lines read as
// bytes, file chunks read from their bytes and written off the read loop, and
// the progress the Synced page shows - with the same bytes on the wire as
// before, both ways. Some of these run the real engine, so they share the log
// with the other engine tests and run one at a time with them.
[Collection("engine log")]
public class TransferTests
{
    private const int Chunk = 256 * 1024;

    public TransferTests()
    {
        LogTap.Start();
    }

    private static async Task Registered(TestNode node, RawPeer peer) =>
        Assert.True(await Wait.Until(() => node.Engine!.GetConnections().Contains(peer.Id)));

    // ---- reading lines ----

    // Hands out at most step bytes per read, the way a socket may.
    private sealed class Trickle(byte[] bytes, int step) : Stream
    {
        private int at;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => bytes.Length;
        public override long Position { get => at; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count)
        {
            int n = Math.Min(Math.Min(step, count), bytes.Length - at);
            Array.Copy(bytes, at, buffer, offset, n);
            at += n;
            return n;
        }
    }

    private static async Task<List<string>> LinesOf(byte[] bytes, int step, int initialSize)
    {
        using var reader = new LineReader(new Trickle(bytes, step), initialSize);
        var lines = new List<string>();
        while (await reader.ReadLineAsync() is { } line) lines.Add(Encoding.UTF8.GetString(line.Span));
        return lines;
    }

    // What the read loop's StreamReader used to make of the same bytes.
    private static List<string> StreamReaderLinesOf(byte[] bytes)
    {
        using var reader = new StreamReader(new MemoryStream(bytes));
        var lines = new List<string>();
        while (reader.ReadLine() is { } line) lines.Add(line);
        return lines;
    }

    [Theory]
    [InlineData("one\ntwo\n")]
    [InlineData("one\r\ntwo\r\n")]
    [InlineData("one\rtwo\r")]
    [InlineData("a\r\r\nb\n\nc")]
    [InlineData("\r\n\r\n")]
    [InlineData("\n")]
    [InlineData("\r")]
    [InlineData("")]
    [InlineData("no ending")]
    [InlineData("x\r\n")]
    [InlineData("mixed\nends\r\nhere\rand\r\n\rlast")]
    [InlineData("QUJDRA==\r\nX19waW5nX18=\r\n")]
    public async Task Lines_end_where_the_stream_reader_ended_them_however_the_bytes_arrive(string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        var expected = StreamReaderLinesOf(bytes);
        foreach (int step in new[] { 1, 2, 3, 7, 4096 })
        {
            foreach (int initialSize in new[] { 16, 64 * 1024 })
            {
                Assert.Equal(expected, await LinesOf(bytes, step, initialSize));
            }
        }
    }

    [Fact]
    public async Task A_line_split_over_many_reads_comes_whole()
    {
        string line = string.Concat(Enumerable.Range(0, 5000).Select(i => (char)('A' + i % 26)));
        byte[] bytes = Encoding.ASCII.GetBytes(line + "\r\n" + line + "\n");
        Assert.Equal(new[] { line, line }, await LinesOf(bytes, step: 13, initialSize: 16));
    }

    [Fact]
    public async Task A_very_long_line_comes_whole_and_the_lines_after_it_too()
    {
        // Longer than the buffers that are pooled (ByteBuffers.MaxPooled).
        byte[] longLine = new byte[6 * 1024 * 1024 + 3];
        Array.Fill(longLine, (byte)'Q');
        byte[] bytes = longLine.Concat("\r\nshort\nlast"u8.ToArray()).ToArray();
        using var reader = new LineReader(new Trickle(bytes, 64 * 1024));

        var first = (await reader.ReadLineAsync())!.Value;
        Assert.Equal(longLine.Length, first.Length);
        Assert.True(first.Span.IndexOfAnyExcept((byte)'Q') < 0);
        Assert.Equal("short", Encoding.ASCII.GetString((await reader.ReadLineAsync())!.Value.Span));
        Assert.Equal("last", Encoding.ASCII.GetString((await reader.ReadLineAsync())!.Value.Span));
        Assert.Null(await reader.ReadLineAsync());
    }

    [Fact]
    public async Task The_handshake_line_drops_carriage_returns_and_a_byte_order_mark_and_leaves_the_rest()
    {
        byte[] bytes = new byte[] { 0xEF, 0xBB, 0xBF }
            .Concat(Encoding.UTF8.GetBytes("{\"DeviceName\":\"中文 PC\"}\r\nline two\r\nline three\n"))
            .ToArray();
        using var reader = new LineReader(new Trickle(bytes, 5), initialSize: 16);

        Assert.Equal("{\"DeviceName\":\"中文 PC\"}", await PeerConnection.ReadHandshakeLineAsync(reader));
        Assert.Equal("line two", Encoding.UTF8.GetString((await reader.ReadLineAsync())!.Value.Span));
        Assert.Equal("line three", Encoding.UTF8.GetString((await reader.ReadLineAsync())!.Value.Span));
    }

    [Fact]
    public async Task A_heartbeat_proves_the_session_and_is_never_handled_as_a_message()
    {
        using var node = new TestNode("ping");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);

        await peer.SendUtf8Async("__ping__"u8.ToArray());

        Assert.True(await Wait.Until(() => node.Engine!.GetDevices().Any(device => device.PublicKey == peer.Id && device.Connected)));
        await Wait.Quiet(300);
        Assert.False(LogTap.Contains("error handling a message"));
        Assert.False(LogTap.Contains("Received invalid message"));
        Assert.Contains(peer.Id, node.Engine!.GetConnections());
    }

    // ---- file chunks read from their bytes ----

    private static readonly string Hash = Convert.ToHexString(SHA256.HashData("x"u8.ToArray()));

    // A file_chunk message as each kind of sender writes it: with only the
    // escapes JSON needs (Windows, HarmonyOS), with "\/" for every "/"
    // (Android's org.json), or with the serializer's default escapes ("+"
    // as "+", '"' as """).
    private static byte[] ChunkMessage(string style, string hash, int index, bool isLast, byte[] bytes)
    {
        var chunk = new FileChunkMessage(hash, index, isLast, Convert.ToBase64String(bytes));
        switch (style)
        {
            case "relaxed":
                return Wire.Envelope("file_chunk", chunk).ToArray();
            case "android":
                string payload = JsonSerializer.Serialize(chunk, Wire.Json).Replace("/", "\\/");
                return Wire.Envelope("file_chunk", payload).ToArray();
            default:
                return Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new Envelope("file_chunk", JsonSerializer.Serialize(chunk))));
        }
    }

    [Theory]
    [InlineData("relaxed")]
    [InlineData("android")]
    [InlineData("default")]
    public void A_file_chunk_is_read_from_its_bytes_as_the_old_way_read_it(string style)
    {
        byte[] data = RandomNumberGenerator.GetBytes(3000);
        byte[] message = ChunkMessage(style, Hash, 7, true, data);

        using var chunk = FileChunk.TryRead(message);

        Assert.NotNull(chunk);
        var old = JsonSerializer.Deserialize<FileChunkMessage>(JsonSerializer.Deserialize<Envelope>(message)!.Payload)!;
        Assert.Equal(old.FileHash, chunk!.FileHash);
        Assert.Equal(old.ChunkIndex, chunk.ChunkIndex);
        Assert.Equal(old.IsLast, chunk.IsLast);
        Assert.True(chunk.HasData);
        Assert.True(chunk.TryDecode(out var decoded));
        Assert.Equal(Convert.FromBase64String(old.DataBase64), decoded.Span.ToArray());
        decoded.Release();
    }

    [Fact]
    public void An_empty_chunk_is_no_bytes()
    {
        using var chunk = FileChunk.TryRead(ChunkMessage("relaxed", Hash, 0, true, Array.Empty<byte>()))!;
        Assert.True(chunk.HasData);
        Assert.True(chunk.TryDecode(out var decoded));
        Assert.Equal(0, decoded.Length);
    }

    [Fact]
    public void Fields_are_matched_as_the_serializer_matches_them()
    {
        // Payload before Type, fields it doesn't know, a field named twice
        // (the last one counts), and no DataBase64 at all.
        string payload = "{\"Extra\":[1,{\"a\":2}],\"FileHash\":\"first\",\"ChunkIndex\":4,\"filehash\":\"other case\",\"FileHash\":\"second\",\"IsLast\":true}";
        byte[] message = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { Payload = payload, Type = "file_chunk" }));

        using var chunk = FileChunk.TryRead(message)!;

        var old = JsonSerializer.Deserialize<FileChunkMessage>(payload)!;
        Assert.Equal(old.FileHash, chunk.FileHash);
        Assert.Equal("second", chunk.FileHash);
        Assert.Equal(4, chunk.ChunkIndex);
        Assert.True(chunk.IsLast);
        Assert.Null(old.DataBase64);
        Assert.False(chunk.HasData);
    }

    [Theory]
    [InlineData("{\"Type\":\"entry\",\"Payload\":\"{}\"}")]
    [InlineData("{\"Type\":\"file_chunk\",\"Payload\":{}}")]
    [InlineData("{\"Type\":\"file_chunk\",\"Payload\":\"{}\"} and more")]
    [InlineData("{\"Type\":\"file_chunk\",\"Payload\":\"{\\\"ChunkIndex\\\":\\\"1\\\"}\"}")]
    [InlineData("{\"Type\":\"file_chunk\",\"Payload\":\"{\\\"ChunkIndex\\\":1.5}\"}")]
    [InlineData("{\"Type\":\"file_chunk\",\"Payload\":\"{\\\"IsLast\\\":null}\"}")]
    [InlineData("{\"Type\":\"file_chunk\",\"Payload\":\"not json\"}")]
    [InlineData("{\"Type\":null,\"Payload\":\"{}\"}")]
    [InlineData("__ping__")]
    [InlineData("")]
    public void Anything_else_is_left_to_the_old_way(string message)
    {
        Assert.Null(FileChunk.TryRead(Encoding.UTF8.GetBytes(message)));
    }

    // ---- what goes out ----

    [Fact]
    public void A_file_chunk_message_is_the_same_bytes_as_ever()
    {
        string hash = new string('A', 32) + new string('f', 32);
        var made = Wire.Envelope("file_chunk", new FileChunkMessage(hash, 3, true, "+/8="));
        Assert.Equal("{\"Type\":\"file_chunk\",\"Payload\":\"{\\\"FileHash\\\":\\\"" + hash
            + "\\\",\\\"ChunkIndex\\\":3,\\\"IsLast\\\":true,\\\"DataBase64\\\":\\\"+/8=\\\"}\"}", Encoding.UTF8.GetString(made.Span));
    }

    // Relays one connection to the node, keeping every byte the node sends.
    private sealed class Tap : IDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly MemoryStream fromNode = new();

        public Tap(int nodePort)
        {
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            _ = Run(nodePort);
        }

        public int Port { get; }

        private async Task Run(int nodePort)
        {
            using var inbound = await listener.AcceptTcpClientAsync();
            using var outbound = new TcpClient();
            await outbound.ConnectAsync(IPAddress.Loopback, nodePort);
            await Task.WhenAny(Pump(inbound.GetStream(), outbound.GetStream(), null), Pump(outbound.GetStream(), inbound.GetStream(), fromNode));
        }

        private static async Task Pump(Stream from, Stream to, MemoryStream? keep)
        {
            byte[] buffer = new byte[64 * 1024];
            try
            {
                int read;
                while ((read = await from.ReadAsync(buffer)) > 0)
                {
                    if (keep != null) lock (keep) keep.Write(buffer, 0, read);
                    await to.WriteAsync(buffer.AsMemory(0, read));
                }
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException or SocketException)
            {
            }
        }

        public byte[] FromNode()
        {
            lock (fromNode) return fromNode.ToArray();
        }

        public void Dispose() => listener.Stop();
    }

    [Fact]
    public async Task A_file_goes_out_as_it_always_did_in_256_KiB_chunks_in_order_one_crlf_line_each()
    {
        using var node = new TestNode("send");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        using var tap = new Tap(node.Port);
        await peer.ConnectAsync(node, port: tap.Port);
        await Registered(node, peer);
        byte[] data = RandomNumberGenerator.GetBytes(2 * Chunk + 1000);
        string hash = Convert.ToHexString(SHA256.HashData(data));
        string file = Path.Combine(Path.GetTempPath(), $"cliplink-send-{Guid.NewGuid():N}.bin");
        await File.WriteAllBytesAsync(file, data);
        try
        {
            var shared = await node.Engine!.ShareFilesAsync(new[] { file });
            Assert.Single(shared.Shared);
            await peer.WaitForAsync("file_chunk", 3);

            var expected = data.Chunk(Chunk)
                .Select((bytes, index) => Wire.Envelope("file_chunk", new FileChunkMessage(hash, index, index == 2, Convert.ToBase64String(bytes))).ToArray())
                .ToList();
            var sent = peer.Texts.Where(text => text.StartsWith("{\"Type\":\"file_chunk\"")).ToList();
            Assert.Equal(expected.Select(bytes => Encoding.UTF8.GetString(bytes)), sent);

            // On the wire: lines ended by "\r\n", each the Base64 of nonce,
            // tag and the encrypted message - the chunks in order, one each.
            Assert.True(await Wait.Until(() => tap.FromNode() is { Length: > 0 } bytes && bytes[^1] == (byte)'\n'));
            byte[] wire = tap.FromNode();
            for (int i = 0; i < wire.Length; i++)
            {
                if (wire[i] == (byte)'\n') Assert.Equal((byte)'\r', wire[i - 1]);
            }
            var lines = Encoding.ASCII.GetString(wire).Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
            var lengths = lines.Skip(1).Select(line => Convert.FromBase64String(line).Length).ToList();
            var chunkLines = lengths.Select((length, at) => (length, at)).Where(line => expected.Any(bytes => 12 + 16 + bytes.Length == line.length)).ToList();
            Assert.Equal(expected.Select(bytes => 12 + 16 + bytes.Length), chunkLines.Select(line => line.length));
        }
        finally
        {
            File.Delete(file);
        }
    }

    // ---- what comes in ----

    private static ClipboardEntry FileEntry(RawPeer peer, string name, byte[] data, out string hash)
    {
        // The phones write hashes in lower case.
        hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        string content = JsonSerializer.Serialize(new FilePayload(name, hash, data.Length));
        return SigningService.Sign(new ClipboardEntry(content, "file", peer.Id, DateTime.UtcNow), peer.Identity);
    }

    [Theory]
    [InlineData("relaxed")]
    [InlineData("android")]
    [InlineData("default")]
    public async Task A_file_from_a_peer_arrives_with_progress_and_is_stored(string style)
    {
        using var node = new TestNode("recv");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        byte[] data = RandomNumberGenerator.GetBytes(3 * Chunk + 5000);
        var entry = FileEntry(peer, "big.bin", data, out string hash);
        var pieces = data.Chunk(Chunk).ToList();

        await peer.SendAsync("entry", JsonSerializer.Serialize(entry));
        await peer.WaitForAsync("file_request", 1);
        for (int i = 0; i < 2; i++) await peer.SendUtf8Async(ChunkMessage(style, hash, i, false, pieces[i]));

        Assert.True(await Wait.Until(() => node.Engine!.GetTransfers().Any(t => t.Phase == TransferPhase.Receiving && t.Received == 2 * Chunk)));
        var receiving = node.Engine!.GetTransfers().Single();
        Assert.Equal(hash, receiving.FileHash, ignoreCase: true);
        Assert.Equal(data.Length, receiving.Total);
        var item = node.Engine.GetHistory().Single();
        Assert.Equal(hash, item.FileHash, ignoreCase: true);
        Assert.False(item.IsAvailable);

        for (int i = 2; i < pieces.Count; i++) await peer.SendUtf8Async(ChunkMessage(style, hash, i, i == pieces.Count - 1, pieces[i]));

        Assert.True(await Wait.Until(() => node.Engine.GetHistory().Single().IsAvailable));
        Assert.Contains(node.Engine.GetTransfers(), t => t.Phase == TransferPhase.Done && string.Equals(t.FileHash, hash, StringComparison.OrdinalIgnoreCase));
        var store = new FileStore(node.Label);
        Assert.Equal(data, File.ReadAllBytes(store.GetPath(hash)));
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(store.GetPath(hash))!, "*.partial"));
        Assert.True(LogTap.Contains($"[file] received {hash[..12]}... - verified, saved"));
    }

    [Fact]
    public async Task A_file_whose_bytes_are_wrong_is_asked_for_again_and_shown_as_retrying()
    {
        using var node = new TestNode("bad");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await Registered(node, peer);
        byte[] data = RandomNumberGenerator.GetBytes(Chunk + 10);
        var entry = FileEntry(peer, "bad.bin", data, out string hash);

        await peer.SendAsync("entry", JsonSerializer.Serialize(entry));
        await peer.WaitForAsync("file_request", 1);
        byte[] wrong = data.ToArray();
        wrong[5] ^= 1;
        var pieces = wrong.Chunk(Chunk).ToList();
        await peer.SendUtf8Async(ChunkMessage("relaxed", hash, 0, false, pieces[0]));
        await peer.SendUtf8Async(ChunkMessage("relaxed", hash, 1, true, pieces[1]));

        await peer.WaitForAsync("file_request", 2);
        Assert.True(await Wait.Until(() => node.Engine!.GetTransfers().Any(t => t.Phase == TransferPhase.Retrying)));
        Assert.False(node.Engine!.GetHistory().Single().IsAvailable);
        Assert.True(LogTap.Contains("file transfer failed hash verification"));
    }

    // ---- IncomingFiles, queued ----

    private static List<string> Partials(FileStore store, string hash) =>
        Directory.EnumerateFiles(Path.GetDirectoryName(store.GetPath(hash))!, "*.partial").ToList();

    [Fact]
    public async Task Queued_chunks_are_written_by_the_files_writer_and_its_end_is_told_once()
    {
        string label = TestData.NewLabel("queued");
        try
        {
            var store = new FileStore(label);
            var incoming = new IncomingFiles(store);
            var ends = new List<IncomingFiles.Result>();
            var ended = new TaskCompletionSource();
            incoming.Completed += (_, _, result) =>
            {
                lock (ends) ends.Add(result);
                ended.TrySetResult();
            };
            byte[] data = RandomNumberGenerator.GetBytes(5 * Chunk + 77);
            string hash = Convert.ToHexString(SHA256.HashData(data));
            var owner = new object();
            var pieces = data.Chunk(Chunk).ToList();

            for (int i = 0; i < pieces.Count; i++)
            {
                var result = await incoming.ReceiveAsync(owner, hash, i, i == pieces.Count - 1, ChunkData.Of(pieces[i]));
                Assert.Equal(IncomingFiles.Outcome.Written, result.Outcome);
            }
            await ended.Task.WaitAsync(TimeSpan.FromSeconds(10));
            await Wait.Quiet(100);

            Assert.Equal(new[] { IncomingFiles.Outcome.Stored }, ends.Select(end => end.Outcome));
            Assert.Equal(data, File.ReadAllBytes(store.GetPath(hash)));
            Assert.Empty(incoming.Snapshot());
            Assert.False(incoming.IsReceiving(hash));
            Assert.Empty(Partials(store, hash));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public async Task Progress_is_what_was_written_of_the_size_its_entry_gave_and_starts_over_with_its_stream()
    {
        string label = TestData.NewLabel("progress");
        try
        {
            var store = new FileStore(label);
            byte[] data = RandomNumberGenerator.GetBytes(4 * Chunk);
            string hash = Convert.ToHexString(SHA256.HashData(data));
            var incoming = new IncomingFiles(store, asked => asked == hash ? data.Length : null);
            var owner = new object();
            var other = new object();

            await incoming.ReceiveAsync(owner, hash, 0, false, ChunkData.Of(data[..Chunk]));
            await incoming.ReceiveAsync(owner, hash, 1, false, ChunkData.Of(data[Chunk..(2 * Chunk)]));
            Assert.True(await Wait.Until(() => incoming.Snapshot().Single().Received == 2 * Chunk));
            var progress = incoming.Snapshot().Single();
            Assert.Equal(hash, progress.FileHash);
            Assert.Equal(data.Length, progress.Total);
            Assert.False(progress.Finishing);

            // Another sender's chunks are ignored, and known to be before they're decoded.
            Assert.True(incoming.WouldIgnore(other, hash, 0));
            Assert.True(incoming.WouldIgnore(other, hash, 2));
            Assert.False(incoming.WouldIgnore(owner, hash, 2));
            Assert.Equal(IncomingFiles.Outcome.Ignored, (await incoming.ReceiveAsync(other, hash, 0, false, ChunkData.Of(data[..10]))).Outcome);

            // Chunk 0 again: its sender started over, and so does the count.
            await incoming.ReceiveAsync(owner, hash, 0, false, ChunkData.Of(data[..10]));
            Assert.True(await Wait.Until(() => incoming.Snapshot().Single().Received == 10));

            // A gap fails it, and its file goes.
            Assert.Equal(IncomingFiles.Outcome.Failed, (await incoming.ReceiveAsync(owner, hash, 5, false, ChunkData.Of(data[..10]))).Outcome);
            Assert.Empty(incoming.Snapshot());
            Assert.True(await Wait.Until(() => Partials(store, hash).Count == 0));

            // A link that goes away abandons what it was sending.
            await incoming.ReceiveAsync(owner, hash, 0, false, ChunkData.Of(data[..Chunk]));
            Assert.Equal(new[] { hash }, incoming.AbandonAll(owner));
            Assert.Empty(incoming.Snapshot());
            Assert.True(await Wait.Until(() => Partials(store, hash).Count == 0));
            Assert.False(store.Exists(hash));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    // A sender that paces its streams gives one up when its acks stop coming
    // while the link stays up; the receiver then sees no more chunks, and
    // must let the stream go itself (see IncomingFiles.AbandonStalled).
    [Fact]
    public async Task A_stream_that_stops_part_way_is_abandoned_once_it_has_been_quiet_long_enough()
    {
        string label = TestData.NewLabel("stalled");
        try
        {
            var store = new FileStore(label);
            var incoming = new IncomingFiles(store);
            int done = 0;
            incoming.ChunkDone += (_, _, _) => Interlocked.Increment(ref done);
            byte[] data = RandomNumberGenerator.GetBytes(4 * Chunk);
            string hash = Convert.ToHexString(SHA256.HashData(data));
            var owner = new object();
            var other = new object();
            var idle = TimeSpan.FromSeconds(45);

            await incoming.ReceiveAsync(owner, hash, 0, false, ChunkData.Of(data[..Chunk]));
            await incoming.ReceiveAsync(owner, hash, 1, false, ChunkData.Of(data[Chunk..(2 * Chunk)]));
            Assert.True(await Wait.Until(() => Volatile.Read(ref done) == 2));
            long now = Environment.TickCount64;

            // Its latest chunk only just came: left alone.
            Assert.Empty(incoming.AbandonStalled(owner, idle, now));
            // Another sender's check never touches it.
            Assert.Empty(incoming.AbandonStalled(other, idle, now + 60_000));
            Assert.True(incoming.IsReceiving(hash));

            // Quiet for long enough, everything written: let go of, its
            // bytes gone, and the file free for any sender again.
            Assert.Equal(new[] { hash }, incoming.AbandonStalled(owner, idle, now + 60_000));
            Assert.False(incoming.IsReceiving(hash));
            Assert.True(await Wait.Until(() => Partials(store, hash).Count == 0));
            Assert.False(incoming.WouldIgnore(other, hash, 0));
            // What it sends after that is the rest of a stream never seen
            // starting: ignored, as ever.
            Assert.Equal(IncomingFiles.Outcome.Ignored, (await incoming.ReceiveAsync(owner, hash, 2, false, ChunkData.Of(data[..10]))).Outcome);

            // A stream whose last chunk has come is complete, being checked
            // and stored: never abandoned.
            await incoming.ReceiveAsync(owner, hash, 0, true, ChunkData.Of(data));
            Assert.Empty(incoming.AbandonStalled(owner, idle, Environment.TickCount64 + 60_000));
            Assert.True(await Wait.Until(() => store.Exists(hash)));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public async Task A_queued_file_whose_bytes_do_not_match_its_hash_is_not_stored()
    {
        string label = TestData.NewLabel("qbad");
        try
        {
            var store = new FileStore(label);
            var incoming = new IncomingFiles(store);
            var ended = new TaskCompletionSource<IncomingFiles.Result>();
            incoming.Completed += (_, _, result) => ended.TrySetResult(result);
            byte[] data = RandomNumberGenerator.GetBytes(1000);
            string hash = Convert.ToHexString(SHA256.HashData(data));
            data[500] ^= 1;

            await incoming.ReceiveAsync(new object(), hash, 0, true, ChunkData.Of(data));
            var result = await ended.Task.WaitAsync(TimeSpan.FromSeconds(10));

            Assert.Equal(IncomingFiles.Outcome.Failed, result.Outcome);
            Assert.Equal("file transfer failed hash verification", result.Reason);
            Assert.False(store.Exists(hash));
            Assert.True(await Wait.Until(() => Partials(store, hash).Count == 0));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    // ---- speed and words ----

    [Fact]
    public void Speed_is_hidden_at_first_then_taken_over_two_seconds_and_a_file_stalls_after_three()
    {
        var speed = new TransferSpeed();
        long received = 0;
        for (long at = 0; at <= 500; at += 250)
        {
            speed.Add(at, received);
            received += 1_000_000;
        }
        Assert.Null(speed.BytesPerSecond(500));

        // Steady at 4 MB a second.
        for (long at = 750; at <= 3000; at += 250)
        {
            speed.Add(at, received);
            received += 1_000_000;
        }
        Assert.Equal(4_000_000, speed.BytesPerSecond(3000)!.Value, 1);

        // A burst moves it, but only as much as it changes the last two seconds.
        received += 3_000_000;
        speed.Add(3250, received);
        Assert.Equal(5_500_000, speed.BytesPerSecond(3250)!.Value, 1);

        // Nothing new: it falls, and after 3 seconds the file is stalled.
        speed.Add(5000, received);
        Assert.False(speed.IsStalled(6249));
        Assert.True(speed.IsStalled(6250));
        Assert.True(speed.BytesPerSecond(6250) < 2_000_000);

        // Fewer bytes than before: the sender started over.
        speed.Add(6500, 100);
        Assert.Null(speed.BytesPerSecond(6600));
        Assert.False(speed.IsStalled(6600));
    }

    [Fact]
    public void The_numbers_read_as_the_card_shows_them()
    {
        var was = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        try
        {
            const long MB = 1024 * 1024;
            Assert.Equal("8.3 MB/s", TransferText.Speed(8.3 * MB));
            Assert.Equal("120 MB/s", TransferText.Speed(120 * MB));
            Assert.Equal("512 KB/s", TransferText.Speed(512 * 1024));
            Assert.Equal("85.2 KB/s", TransferText.Speed(85.2 * 1024));

            Assert.Equal("0%", TransferText.Percent(0, 290 * MB));
            Assert.Equal("43%", TransferText.Percent(43, 100));
            Assert.Equal("99%", TransferText.Percent(999, 1000));
            Assert.Equal("99%", TransferText.Percent(1000, 1000));
            Assert.Equal("100%", TransferText.Percent(1000, 1000, done: true));

            Assert.Equal("124 of 290 MB", TransferText.OfTotal(124 * MB, 290 * MB));
            Assert.Equal("289 of 290 MB", TransferText.OfTotal(290 * MB - 1, 290 * MB));
            Assert.Equal("290 of 290 MB", TransferText.OfTotal(290 * MB, 290 * MB));
            Assert.Equal("1.5 of 8.5 MB", TransferText.OfTotal(3 * MB / 2, 17 * MB / 2));
            Assert.Equal("300 of 900 bytes", TransferText.OfTotal(300, 900));

            Assert.Equal("12 MB", TransferText.Size(124 * MB / 10));
            Assert.Equal("4.5 MB", TransferText.Size(45 * MB / 10));
            Assert.Equal("1 byte", TransferText.Size(1));
        }
        finally
        {
            CultureInfo.CurrentCulture = was;
        }
    }
}
