using System.Security.Cryptography;
using System.Threading.Channels;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Networking;

// The files arriving as file_chunk streams - the engine's bookkeeping for
// them, kept apart from sockets (as Android's IncomingFiles is). An owner is
// whatever tells one sender from another: the engine passes the
// PeerConnection a chunk came on. Keyed by hash in either case, as FileStore's
// paths are.
//
// One sender per file: the first stream to start one owns it until it is
// stored or abandoned, and every other sender's chunks for it are ignored.
// Keyed by hash alone, two peers answering the same file_request (it goes to
// every peer) used to write their chunks into one file, which then failed its
// hash check.
//
// A stream counts up from chunk 0, and is never resumed: a sender cut off, or
// asked again, starts over at 0. So chunk 0 again starts the file over, a gap
// abandons it, and the rest of a stream whose start this PC never saw (cut
// off, or begun before ClipLink started) is ignored - it could never hash
// right.
//
// Two ways in. ReceiveAsync (the engine's) only decides on the chunk where
// it is called, on the connection's read loop, and leaves writing and hashing
// it to the file's own writer task, through a short queue: the read loop goes
// straight on to the next line instead of waiting on the disk, and waits only
// when the queue is full, so the socket is never read faster than the disk
// keeps up. How a queued stream ends - stored, or failed in writing or in
// its hash check - is then told by Completed. Receive does all of it where
// it is called and returns how it ended (the tests use it). A transfer is
// only ever written one of the two ways.
//
// Calls for one owner must come one at a time, in the order its chunks
// arrived - a connection's read loop handles its messages one by one.
// Different owners' calls may overlap.
public sealed class IncomingFiles
{
    // What one chunk came to - see Receive.
    public enum Outcome
    {
        Written, // written (or queued to be); more to come, or, queued, the end is told by Completed
        Stored,  // the last one: the file is complete, checked, and in FileStore
        Failed,  // the transfer is abandoned and its bytes gone - Reason says why
        Ignored, // not for writing: another sender has this file, it's here already, or its stream started unseen
    }

    public readonly record struct Result(Outcome Outcome, string? Reason = null);

    // A file being received, as GetTransfers shows it: how many bytes of it
    // are written so far, and how many there are in all if its entry said.
    // Finishing: its last chunk has come and it is being checked and stored.
    public readonly record struct Progress(string FileHash, long Received, long? Total, bool Finishing);

    // How many chunks may wait for a file's writer: 16 of 256 KiB, 4 MiB.
    private const int QueueLength = 16;

    private readonly record struct Queued(ChunkData Data, int Index, bool IsLast);

    private sealed class Transfer
    {
        public readonly object Owner;
        public readonly string Hash;
        // A path of this transfer's own (see FileStore.GetTempPath): one
        // abandoned while its writer is still busy can't then get in the way
        // of a new stream of the same file.
        public readonly string TempPath;
        public readonly FileStream File;
        // The SHA-256 of what was written so far, kept as the chunks go to
        // disk: the whole file used to be read back once the last one came,
        // on the connection's read loop - twice the disk I/O, and a stall
        // long enough with a big file on a slow disk for the heartbeat to
        // close the link mid-check.
        public readonly IncrementalHash Hash256 = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public readonly long? Total;
        // The writer's queue (null for a transfer Receive writes).
        public readonly Channel<Queued>? Queue;
        // Done once nothing more will happen to the transfer's file: stored,
        // failed, or abandoned and tidied away.
        public readonly TaskCompletionSource Done = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int NextIndex;    // the owner's calls, under the lock
        public bool LastAdmitted; // under the lock
        // When its owner's latest chunk was taken (Environment.TickCount64),
        // and how many of the chunks taken its writer is done with: what
        // AbandonStalled goes by.
        public long LastTakenAt;  // under the lock
        public int Handled;       // Interlocked: the writer adds
        public volatile bool Dropped;
        public volatile bool Finished;
        public long Received;     // Interlocked: the writer adds, GetTransfers reads

        public Transfer(object owner, string hash, string tempPath, FileStream file, long? total, bool queued)
        {
            Owner = owner;
            Hash = hash;
            TempPath = tempPath;
            File = file;
            Total = total;
            if (queued)
            {
                Queue = Channel.CreateBounded<Queued>(new BoundedChannelOptions(QueueLength)
                {
                    SingleReader = true,
                    SingleWriter = true,
                    FullMode = BoundedChannelFullMode.Wait,
                });
            }
        }
    }

    private readonly FileStore fileStore;
    // How big a file is meant to be (its entry's FileSize), if anyone knows:
    // asked once, when its stream starts, for the progress shown while it
    // arrives. Never under the lock.
    private readonly Func<string, long?>? sizeHint;
    private readonly Dictionary<string, Transfer> transfers = new(StringComparer.OrdinalIgnoreCase);
    private long nextTransferId;

    // How a queued stream ended: its owner, its hash, and Stored or Failed
    // (with why). Raised on the file's writer task, never under the lock.
    // Handlers mustn't throw.
    public event Action<object, string, Result>? Completed;

    // A chunk ReceiveAsync took is done with: written to its file (and
    // hashed), or let go of unwritten because its transfer was dropped
    // meanwhile. Its owner, its hash and its index, in the order the owner's
    // chunks were taken. Raised on the file's writer task (or where
    // ReceiveAsync wrote it, for a transfer Receive started), never under
    // the lock; not for a chunk ReceiveAsync returned anything but Written
    // for. The engine's cue to acknowledge it (see FileFlow). Handlers
    // mustn't throw.
    public event Action<object, string, int>? ChunkDone;

    public IncomingFiles(FileStore fileStore, Func<string, long?>? sizeHint = null)
    {
        this.fileStore = fileStore;
        this.sizeHint = sizeHint;
    }

    // Whether a stream of fileHash is being written right now.
    public bool IsReceiving(string fileHash)
    {
        lock (transfers) { return transfers.ContainsKey(fileHash); }
    }

    // Every file being received, as it stands.
    public List<Progress> Snapshot()
    {
        lock (transfers)
        {
            return transfers.Values
                .Select(transfer => new Progress(transfer.Hash, Interlocked.Read(ref transfer.Received), transfer.Total, transfer.LastAdmitted))
                .ToList();
        }
    }

    // Whether a chunk would be ignored as things stand (another sender has
    // the file, it's here already, or its stream started unseen) - so its
    // bytes needn't even be decoded. Only a guess for the chunk that comes
    // next: ReceiveAsync decides again.
    public bool WouldIgnore(object owner, string fileHash, int chunkIndex)
    {
        lock (transfers)
        {
            if (transfers.TryGetValue(fileHash, out var current))
            {
                if (!ReferenceEquals(current.Owner, owner)) return true;
                // Its own stream: written, failed or started over - not ignored.
                if (!current.LastAdmitted || chunkIndex == 0) return false;
            }
            return chunkIndex != 0 || fileStore.Exists(fileHash);
        }
    }

    // One chunk from owner (its FileHash already checked - see
    // FileStore.IsValidHash), and its bytes, already decoded.
    public Result Receive(object owner, FileChunkMessage chunk, byte[] bytes)
    {
        long? total = chunk.ChunkIndex == 0 ? sizeHint?.Invoke(chunk.FileHash) : null;
        Admission admission;
        while ((admission = Admit(owner, chunk.FileHash, chunk.ChunkIndex, chunk.IsLast, total, queued: false)).Wait is { } wait)
        {
            wait.GetAwaiter().GetResult();
        }
        if (admission.Transfer is not { } transfer) return admission.Result;
        if (transfer.Queue != null)
        {
            // Started by ReceiveAsync: its writer has the file.
            return new(Outcome.Failed, "a received file can't be written two ways at once");
        }
        return Write(transfer, bytes, chunk.IsLast) ?? new(Outcome.Written);
    }

    // One chunk from owner, queued for its file's writer; data is this
    // object's to release from here on. Written means queued: if it was the
    // last, or writing it fails, Completed tells how the stream ended. Waits
    // only while the queue is full, or for the end of this owner's previous
    // stream of the same file if that is still being checked.
    public async ValueTask<Result> ReceiveAsync(object owner, string fileHash, int chunkIndex, bool isLast, ChunkData data)
    {
        try
        {
            long? total = chunkIndex == 0 ? sizeHint?.Invoke(fileHash) : null;
            Admission admission;
            while ((admission = Admit(owner, fileHash, chunkIndex, isLast, total, queued: true)).Wait is { } wait)
            {
                await wait;
            }
            if (admission.Transfer is not { } transfer)
            {
                data.Release();
                return admission.Result;
            }
            if (transfer.Queue is not { } queue)
            {
                // Started by Receive: written here, the same way.
                var result = Write(transfer, data.Span, isLast) ?? new(Outcome.Written);
                data.Release();
                if (result.Outcome == Outcome.Written) RaiseChunkDone(transfer, chunkIndex);
                return result;
            }
            var item = new Queued(data, chunkIndex, isLast);
            while (!queue.Writer.TryWrite(item))
            {
                if (!await queue.Writer.WaitToWriteAsync())
                {
                    // Abandoned meanwhile (writing it failed): what comes
                    // after that is ignored, as it always was.
                    data.Release();
                    return new(Outcome.Ignored);
                }
            }
            return new(Outcome.Written);
        }
        catch
        {
            data.Release();
            throw;
        }
    }

    // What to do with one chunk: a transfer to write it to, or a Result
    // (ignored, failed), or a task to wait for before asking again.
    private readonly record struct Admission(Result Result, Transfer? Transfer = null, Task? Wait = null);

    private Admission Admit(object owner, string hash, int chunkIndex, bool isLast, long? total, bool queued)
    {
        // Only the decision is locked. A transfer is only ever written by its
        // owner's calls (or its writer), which never overlap; anyone else just
        // sees it's taken.
        lock (transfers)
        {
            if (transfers.TryGetValue(hash, out var current))
            {
                if (!ReferenceEquals(current.Owner, owner)) return new(new(Outcome.Ignored));
                // Its last chunk is still being checked: what it comes to
                // first, as it was when the check happened right here.
                if (current.LastAdmitted) return new(default, Wait: current.Done.Task);
                if (chunkIndex != current.NextIndex)
                {
                    Drop(hash, current);
                    // Chunk 0 again is its sender starting over - after a
                    // stream of the same file that broke off, say - so start
                    // over with it. Never append to the old one's bytes.
                    if (chunkIndex != 0) return new(new(Outcome.Failed, "file chunk out of order"));
                }
            }
            if (!transfers.TryGetValue(hash, out var transfer))
            {
                // A stream whose start this PC missed can never hash right,
                // and a file already here needs nothing more.
                if (chunkIndex != 0 || fileStore.Exists(hash)) return new(new(Outcome.Ignored));
                transfer = Start(hash, owner, total, queued);
                if (transfer == null) return new(new(Outcome.Failed, "couldn't create a file for an incoming transfer"));
            }
            transfer.NextIndex++;
            transfer.LastTakenAt = Environment.TickCount64;
            if (isLast) transfer.LastAdmitted = true;
            return new(new(Outcome.Written), transfer);
        }
    }

    // Writes one chunk; for the last, checks and stores the file. Null while
    // more is to come. On the owner's calls (Receive) or the writer.
    private Result? Write(Transfer transfer, ReadOnlySpan<byte> bytes, bool isLast)
    {
        try
        {
            transfer.File.Write(bytes);
            transfer.Hash256.AppendData(bytes);
        }
        catch (Exception ex)
        {
            lock (transfers) { Drop(transfer.Hash, transfer); }
            return new(Outcome.Failed, $"failed writing file chunk ({ex.Message})");
        }
        Interlocked.Add(ref transfer.Received, bytes.Length);
        return isLast ? Finish(transfer) : null;
    }

    // The last chunk is written: the file is checked and stored. The hash
    // inside the SIGNED entry is what's trusted here, never whatever bytes
    // actually turned up. Still this sender's while it's checked and stored,
    // so no other stream can start on the same file meanwhile.
    private Result Finish(Transfer transfer)
    {
        string hash = transfer.Hash;
        bool verified;
        try
        {
            // Disposing flushes what's still buffered: a write that fails
            // there fails the transfer, as one that failed above did.
            transfer.File.Dispose();
            verified = string.Equals(Convert.ToHexString(transfer.Hash256.GetHashAndReset()), hash, StringComparison.OrdinalIgnoreCase);
        }
        // (Disposed: abandoned just now.)
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
        {
            verified = false;
        }
        finally
        {
            transfer.Hash256.Dispose();
        }
        bool stored = verified && !transfer.Dropped && MoveIntoStore(transfer.TempPath, hash);
        DeleteQuietly(transfer.TempPath); // gone already once it's stored
        transfer.Finished = true;
        lock (transfers)
        {
            if (transfers.TryGetValue(hash, out var current) && current == transfer) transfers.Remove(hash);
        }
        transfer.Done.TrySetResult();
        if (stored) return new(Outcome.Stored);
        return new(Outcome.Failed, verified ? "couldn't store a received file" : "file transfer failed hash verification");
    }

    // A queued transfer's writer: writes its chunks in order, until the last
    // is stored or the transfer is dropped. Every chunk's buffer is released
    // here, written or not.
    private async Task RunWriter(Transfer transfer)
    {
        var reader = transfer.Queue!.Reader;
        try
        {
            while (await reader.WaitToReadAsync())
            {
                while (reader.TryRead(out var item))
                {
                    Result? ended = null;
                    try
                    {
                        if (!transfer.Dropped && !transfer.Finished) ended = Write(transfer, item.Data.Span, item.IsLast);
                    }
                    finally
                    {
                        item.Data.Release();
                    }
                    Interlocked.Increment(ref transfer.Handled);
                    RaiseChunkDone(transfer, item.Index);
                    if (ended is { } result)
                    {
                        try
                        {
                            Completed?.Invoke(transfer.Owner, transfer.Hash, result);
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[file] a finished transfer's handler failed: {ex.GetType().Name}: {ex.Message}");
                        }
                    }
                    if (transfer.Finished) transfer.Queue.Writer.TryComplete();
                }
            }
        }
        finally
        {
            if (!transfer.Finished)
            {
                // Dropped, or (should anything above ever throw) a writer that
                // died: either way the transfer is let go of here, as Drop
                // does, so that its owner's next chunk isn't left waiting for
                // room in a queue nobody reads, nor for a check that won't
                // happen, and the file can be asked for again. What's still
                // queued is released, and told as done with like any chunk
                // let go of unwritten: a sender waiting for its ack would
                // otherwise stall until it gave up.
                lock (transfers) { Drop(transfer.Hash, transfer); }
                transfer.Queue.Writer.TryComplete();
                while (reader.TryRead(out var left))
                {
                    left.Data.Release();
                    RaiseChunkDone(transfer, left.Index);
                }
                CloseAndDelete(transfer);
            }
        }
    }

    private void RaiseChunkDone(Transfer transfer, int index)
    {
        try
        {
            ChunkDone?.Invoke(transfer.Owner, transfer.Hash, index);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[file] a written chunk's handler failed: {ex.GetType().Name}: {ex.Message}");
        }
    }

    // Abandons every transfer owner was sending - its link is gone, and its
    // streams can't be resumed, only started over. Returns their hashes. Not
    // one whose last chunk has come already: it is complete, and is being
    // checked and stored (Completed says how that went).
    public List<string> AbandonAll(object owner)
    {
        lock (transfers)
        {
            var owned = transfers.Where(pair => ReferenceEquals(pair.Value.Owner, owner) && !pair.Value.LastAdmitted).ToList();
            foreach (var (hash, transfer) in owned)
            {
                Drop(hash, transfer);
            }
            return owned.Select(pair => pair.Key).ToList();
        }
    }

    // Abandons every stream from owner that has stopped part-way: its latest
    // chunk taken at least idle before now (Environment.TickCount64), every
    // chunk taken written already, and its last chunk not come. Returns their
    // hashes. Only for a sender that paces its streams (see FileFlow): one
    // gives a stream up when this PC acknowledges nothing for its timeout
    // while the link stays up (a write held up by a virus scanner, say), and
    // then no more chunks come - the stream would hold its file, and keep
    // every other sender's copy out, until the link closed, and the file
    // would never be asked for again. An older sender never stops part-way
    // on a live link. Only streams ReceiveAsync takes: this may run while
    // the owner's calls do, and only a queued transfer is tidied away by its
    // writer rather than right here, under a write.
    public List<string> AbandonStalled(object owner, TimeSpan idle, long now)
    {
        long idleMs = (long)idle.TotalMilliseconds;
        lock (transfers)
        {
            var stalled = transfers
                .Where(pair => ReferenceEquals(pair.Value.Owner, owner) && pair.Value.Queue != null && !pair.Value.LastAdmitted
                    && now - pair.Value.LastTakenAt >= idleMs
                    && Volatile.Read(ref pair.Value.Handled) == pair.Value.NextIndex)
                .ToList();
            foreach (var (hash, transfer) in stalled)
            {
                Drop(hash, transfer);
            }
            return stalled.Select(pair => pair.Key).ToList();
        }
    }

    // Under the lock. A fresh, empty file, on a path no other transfer of
    // this run has had.
    private Transfer? Start(string hash, object owner, long? total, bool queued)
    {
        try
        {
            string tempPath = fileStore.GetTempPath(hash, Interlocked.Increment(ref nextTransferId));
            var transfer = new Transfer(owner, hash, tempPath, new FileStream(tempPath, FileMode.Create, FileAccess.Write), total, queued);
            transfers[hash] = transfer;
            if (queued) _ = Task.Run(() => RunWriter(transfer));
            return transfer;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // Under the lock. Only while transfer is still hash's. A queued one is
    // tidied away by its writer once it has let go of the file; one Receive
    // writes, right here.
    private void Drop(string hash, Transfer transfer)
    {
        if (!transfers.TryGetValue(hash, out var current) || current != transfer) return;
        transfers.Remove(hash);
        transfer.Dropped = true;
        if (transfer.Queue != null) transfer.Queue.Writer.TryComplete();
        else CloseAndDelete(transfer);
    }

    // A transfer that won't be stored: its file closed and deleted.
    private static void CloseAndDelete(Transfer transfer)
    {
        try { transfer.File.Dispose(); } catch (IOException) { }
        transfer.Hash256.Dispose();
        DeleteQuietly(transfer.TempPath);
        transfer.Done.TrySetResult();
    }

    // Received bytes, checked, into FileStore under hash.
    private bool MoveIntoStore(string tempPath, string hash)
    {
        try
        {
            File.Move(tempPath, fileStore.GetPath(hash), overwrite: true);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Stored meanwhile some other way (this PC copied the same file,
            // say) and open, so it can't be replaced - the same bytes.
            return fileStore.Exists(hash);
        }
    }

    private static void DeleteQuietly(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
