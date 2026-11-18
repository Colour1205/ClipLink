using System.Text.Json;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Networking;

// Flow control for file streams, between two builds that both announce
// "file-ack" in their handshake (HandshakeMessage.FileAckCap).
//
// A sender used to send a file's chunks as fast as the network took them.
// HarmonyOS can't pause a socket, so a phone that took them in more slowly
// than they came queued the rest in memory, and a 290 MB file from this PC
// ran its heap out (some 365 MB of lines waiting) and crashed the app. So the
// receiver now acknowledges each chunk once it is done with it (file_ack),
// and the sender keeps at most SendWindow.Size chunks sent but not yet
// acknowledged: it never runs more than that far ahead of the receiver.
//
// With a peer that did not announce it, nothing changes in either direction:
// no acks are sent to it, and its streams are not paced.
//
// An ack only paces sending. It never changes what is stored: the bytes are
// still checked against the signed entry's hash, as ever. Acks travel in the
// encrypted session like every other message.

// One acknowledgement: every chunk of the stream of FileHash up to and
// including ChunkIndex is done with on the receiving side (written, or
// ignored). Cumulative, so an ack that is lost or overtaken costs nothing.
public record FileAckMessage(string FileHash, int ChunkIndex)
{
    public const string Type = "file_ack";

    public static ReadOnlyMemory<byte> Envelope(string fileHash, int chunkIndex) =>
        Wire.Envelope(Type, new FileAckMessage(fileHash, chunkIndex));

    // A file_ack's payload, or null for one that isn't for a valid hash and
    // a chunk index of 0 or more. Never throws.
    public static FileAckMessage? Parse(string payloadJson)
    {
        FileAckMessage? ack;
        try
        {
            ack = JsonSerializer.Deserialize<FileAckMessage>(payloadJson);
        }
        catch (Exception ex) when (ex is JsonException or ArgumentNullException)
        {
            return null;
        }
        if (ack == null || !FileStore.IsValidHash(ack.FileHash) || ack.ChunkIndex < 0) return null;
        return ack;
    }
}

// The sending side of one stream: how many chunks have gone out, and how
// many of those the receiver has acknowledged.
public sealed class SendWindow
{
    // 8 chunks of 256 KiB: 2 MiB of file, some 3.7 MB of lines on the wire
    // (Base64 inside JSON inside Base64). Enough to keep the link busy - at
    // 50 MB/s and a Wi-Fi round trip of 10-30 ms, 0.5-1.5 MB is in flight,
    // and the phone's ack for a chunk waits behind the chunks queued before
    // it - while what a phone can ever have waiting for it stays a few MB
    // instead of the whole file.
    public const int Size = 8;

    // With chunks unacknowledged and no ack at all for this long, the stream
    // is given up on: the receiver asks again, as it does for any stream
    // that broke off. Its heartbeat would close a link that went silent
    // after 15 seconds anyway, so this only ends a stream whose receiver is
    // alive but has stopped acknowledging it.
    public static readonly TimeSpan AckTimeout = TimeSpan.FromSeconds(30);

    // The receiving side's half of that: a stream from a sender that paces
    // its streams, with nothing new for this long and everything that came
    // written, is given up on and the file asked for again (see
    // IncomingFiles.AbandonStalled). Its sender has given it up by then -
    // AckTimeout, with some slack for acks still on their way - and, the link
    // staying up, nothing else would ever tell this side so. As on HarmonyOS.
    public static readonly TimeSpan StallTimeout = AckTimeout + TimeSpan.FromSeconds(15);

    private readonly int size;
    private readonly object gate = new();
    private int sent;  // chunks handed to the connection
    private int acked; // every chunk below this index is acknowledged
    // Completed, and replaced, whenever an ack moves the window on.
    private TaskCompletionSource moved = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public SendWindow(int size = Size)
    {
        if (size < 1) throw new ArgumentOutOfRangeException(nameof(size));
        this.size = size;
    }

    // Chunks sent and not acknowledged yet.
    public int Unacked
    {
        get { lock (gate) return sent - acked; }
    }

    // Before a chunk is sent, not after: on a fast link its ack can come back
    // before the send has even returned, and an ack for a chunk not counted
    // as sent would be thrown away.
    public void Sending()
    {
        lock (gate) sent++;
    }

    // The receiver is done with every chunk up to chunkIndex. False (and
    // nothing changes) for one that moves nothing: an older ack, or one for
    // a chunk that was never sent - a late ack from an earlier stream of the
    // same file, say.
    public bool Ack(int chunkIndex)
    {
        TaskCompletionSource wake;
        lock (gate)
        {
            if (chunkIndex < acked || chunkIndex >= sent) return false;
            acked = chunkIndex + 1;
            wake = moved;
            moved = new(TaskCreationOptions.RunContinuationsAsynchronously);
        }
        wake.TrySetResult();
        return true;
    }

    // Returns once fewer than Size chunks are unacknowledged. Throws
    // TimeoutException if no ack comes for timeout while waiting (each ack
    // starts the time again), and OperationCanceledException when
    // cancellationToken is (the connection closed).
    public async Task WaitForRoomAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        while (true)
        {
            Task next;
            lock (gate)
            {
                if (sent - acked < size) return;
                next = moved.Task;
            }
            try
            {
                // Whatever ends the wait, what follows runs on the thread
                // pool. The connection closing cancels cancellationToken on
                // whichever thread closed it - inside the engine's Stop,
                // under its lock, say - and an await straight on WaitAsync's
                // task would run the rest of the stream right there (its
                // error handling, and tidying its blob away on disk) before
                // Cancel even returned. A continuation with no
                // ExecuteSynchronously is queued instead; its result is
                // WaitAsync's, timeout and cancellation included.
                await next.WaitAsync(timeout, cancellationToken).ContinueWith(
                    static woke => woke.GetAwaiter().GetResult(),
                    CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            }
            catch (TimeoutException)
            {
                throw new TimeoutException($"no acknowledgement for {timeout.TotalSeconds:0} s with {Unacked} chunks unacknowledged");
            }
        }
    }
}

// Every stream being sent with a window, by connection (owner) and hash, so
// an ack finds its stream. One per owner and file at a time: opening one
// again (a stream started over from chunk 0) replaces the old, and with it
// the count.
public sealed class SendWindows
{
    private readonly Dictionary<(object Owner, string Hash), SendWindow> open = new();

    private static (object, string) Key(object owner, string fileHash) => (owner, fileHash.ToUpperInvariant());

    public SendWindow Open(object owner, string fileHash, int size = SendWindow.Size)
    {
        var window = new SendWindow(size);
        lock (open) open[Key(owner, fileHash)] = window;
        return window;
    }

    // Once its stream has ended, however it ended. Only while it is still
    // the one open for that owner and file.
    public void Close(object owner, string fileHash, SendWindow window)
    {
        lock (open)
        {
            var key = Key(owner, fileHash);
            if (open.TryGetValue(key, out var current) && current == window) open.Remove(key);
        }
    }

    // An ack from owner. False when no stream of that file is being sent to
    // it (unknown, or finished), or the ack moves nothing: ignored.
    public bool Ack(object owner, string fileHash, int chunkIndex)
    {
        SendWindow? window;
        lock (open)
        {
            if (!open.TryGetValue(Key(owner, fileHash), out window)) return false;
        }
        return window.Ack(chunkIndex);
    }

    public int Count
    {
        get { lock (open) return open.Count; }
    }
}
