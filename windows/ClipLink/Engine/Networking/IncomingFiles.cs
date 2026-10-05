using System.Security.Cryptography;
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
// Calls for one owner must come one at a time, in the order its chunks
// arrived - a connection's read loop handles its messages one by one.
// Different owners' calls may overlap.
public sealed class IncomingFiles
{
    // What one chunk came to - see Receive.
    public enum Outcome
    {
        Written, // written; more to come
        Stored,  // the last one: the file is complete, checked, and in FileStore
        Failed,  // the transfer is abandoned and its bytes gone - Reason says why
        Ignored, // not for writing: another sender has this file, it's here already, or its stream started unseen
    }

    public readonly record struct Result(Outcome Outcome, string? Reason = null);

    private sealed class Transfer
    {
        public readonly object Owner;
        public readonly FileStream File;
        public int NextIndex;

        public Transfer(object owner, FileStream file)
        {
            Owner = owner;
            File = file;
        }
    }

    private readonly FileStore fileStore;
    private readonly Dictionary<string, Transfer> transfers = new(StringComparer.OrdinalIgnoreCase);

    public IncomingFiles(FileStore fileStore)
    {
        this.fileStore = fileStore;
    }

    // Whether a stream of fileHash is being written right now.
    public bool IsReceiving(string fileHash)
    {
        lock (transfers) { return transfers.ContainsKey(fileHash); }
    }

    // One chunk from owner (its FileHash already checked - see
    // FileStore.IsValidHash), and its bytes, already decoded.
    public Result Receive(object owner, FileChunkMessage chunk, byte[] bytes)
    {
        string hash = chunk.FileHash;
        Transfer? transfer;
        // Only the lookup is locked. A transfer is only ever written by its
        // owner's calls, which never overlap; anyone else just sees it's taken.
        lock (transfers)
        {
            if (transfers.TryGetValue(hash, out var current))
            {
                if (!ReferenceEquals(current.Owner, owner)) return new(Outcome.Ignored);
                if (chunk.ChunkIndex != current.NextIndex)
                {
                    Drop(hash, current);
                    // Chunk 0 again is its sender starting over - after a
                    // stream of the same file that broke off, say - so start
                    // over with it. Never append to the old one's bytes.
                    if (chunk.ChunkIndex != 0) return new(Outcome.Failed, "file chunk out of order");
                }
            }
            if (!transfers.TryGetValue(hash, out transfer))
            {
                // A stream whose start this PC missed can never hash right,
                // and a file already here needs nothing more.
                if (chunk.ChunkIndex != 0 || fileStore.Exists(hash)) return new(Outcome.Ignored);
                transfer = Start(hash, owner);
                if (transfer == null) return new(Outcome.Failed, "couldn't create a file for an incoming transfer");
            }
        }

        try
        {
            transfer.File.Write(bytes, 0, bytes.Length);
        }
        catch (Exception ex)
        {
            lock (transfers) { Drop(hash, transfer); }
            return new(Outcome.Failed, $"failed writing file chunk ({ex.Message})");
        }
        transfer.NextIndex++;
        if (!chunk.IsLast) return new(Outcome.Written);

        // The hash inside the SIGNED entry is what's trusted here, never
        // whatever bytes actually turned up. Still this sender's while it's
        // checked and stored, so no other stream can start on the same
        // temp file meanwhile.
        string tempPath = fileStore.GetTempPath(hash);
        bool verified;
        try
        {
            transfer.File.Dispose();
            using var verifyStream = File.OpenRead(tempPath);
            verified = string.Equals(Convert.ToHexString(SHA256.HashData(verifyStream)), hash, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            verified = false;
        }
        bool stored = verified && MoveIntoStore(tempPath, hash);
        DeleteQuietly(tempPath); // gone already once it's stored
        lock (transfers)
        {
            if (transfers.TryGetValue(hash, out var current) && current == transfer) transfers.Remove(hash);
        }
        if (stored) return new(Outcome.Stored);
        return new(Outcome.Failed, verified ? "couldn't store a received file" : "file transfer failed hash verification");
    }

    // Abandons every transfer owner was sending - its link is gone, and its
    // streams can't be resumed, only started over. Returns their hashes.
    public List<string> AbandonAll(object owner)
    {
        lock (transfers)
        {
            var owned = transfers.Where(pair => ReferenceEquals(pair.Value.Owner, owner)).ToList();
            foreach (var (hash, transfer) in owned)
            {
                Drop(hash, transfer);
            }
            return owned.Select(pair => pair.Key).ToList();
        }
    }

    // Under the lock. FileMode.Create: a fresh, empty file, whatever a
    // transfer cut short left there.
    private Transfer? Start(string hash, object owner)
    {
        try
        {
            var transfer = new Transfer(owner, new FileStream(fileStore.GetTempPath(hash), FileMode.Create, FileAccess.Write));
            transfers[hash] = transfer;
            return transfer;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // Under the lock. Only while transfer is still hash's: its temp file is
    // then nobody else's.
    private void Drop(string hash, Transfer transfer)
    {
        if (!transfers.TryGetValue(hash, out var current) || current != transfer) return;
        transfers.Remove(hash);
        try { transfer.File.Dispose(); } catch (IOException) { }
        DeleteQuietly(fileStore.GetTempPath(hash));
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
