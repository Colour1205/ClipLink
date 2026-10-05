using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Engine;

// Peer connections and everything that travels over them: incoming
// messages, history batches and chunked file transfers.
public sealed partial class ClipLinkEngine
{
    private void HandleMessage(string msg, PeerConnection conn)
    {
        var envelope = JsonSerializer.Deserialize<Envelope>(msg);
        if (envelope == null)
        {
            Console.WriteLine("Received invalid message from peer."); // debug
            return;
        }

        if (envelope.Type == "entry")
        {
            var entry = JsonSerializer.Deserialize<ClipboardEntry>(envelope.Payload);
            if (entry == null)
            {
                Console.WriteLine("Received invalid message from peer."); // debug
                return;
            }
            if (!SigningService.Verify(entry, entry.DeviceId) || !trustStore.IsTrusted(entry.DeviceId))
            {
                Console.WriteLine($"Received {entry.Type} message with invalid signature from peer (verified={SigningService.Verify(entry, entry.DeviceId)}, trusted={trustStore.IsTrusted(entry.DeviceId)}).");
                return;
            }
            if (historyAccess.isEntryDeleted(entry))
            {
                // deleted here earlier - neither back into history nor onto the clipboard
                Console.WriteLine($"[clip] received {entry.Type} entry from {DeviceLabel.ShortId(entry.DeviceId)} - deleted here, ignoring");
                return;
            }
            Console.WriteLine($"[clip] received {entry.Type} entry from {DeviceLabel.ShortId(entry.DeviceId)} - applying");

            if (entry.Type == "file")
            {
                HandleIncomingFileEntry(entry);
            }
            else
            {
                clipboardSync.addToQueue(entry.Content, entry.Type);
            }
            if (historyAccess.addToHistory(entry))
            {
                NotifyHistoryChanged();
            }
        }
        else if (envelope.Type == "history_batch")
        {
            var entries = JsonSerializer.Deserialize<List<ClipboardEntry>>(envelope.Payload);
            if (entries == null)
            {
                Console.WriteLine("Received invalid message from peer."); // debug
                return;
            }
            foreach (var entry in entries)
            {
                if (!SigningService.Verify(entry, entry.DeviceId) || !trustStore.IsTrusted(entry.DeviceId))
                {
                    Console.WriteLine("Received message with invalid signature from peer.");
                    continue; // skip just this bad entry, keep processing the rest of the batch
                }
                if (historyAccess.isEntryDeleted(entry))
                {
                    continue; // deleted here earlier - peers keep resending it in every batch
                }
                if (historyAccess.addToHistory(entry)) // true only if genuinely new, not a duplicate (or deleted)
                {
                    NotifyHistoryChanged();
                    if (entry.Type == "file")
                    {
                        // same handling as a live entry now: if we don't have the
                        // bytes, ask the whole network for them, not just whoever
                        // we're reconciling with
                        HandleIncomingFileEntry(entry);
                    }
                    else
                    {
                        clipboardSync.addToQueue(entry.Content, entry.Type);
                    }
                }
            }
        }
        else if (envelope.Type == "file_chunk")
        {
            HandleFileChunk(envelope.Payload, conn);
        }
        else if (envelope.Type == "file_request")
        {
            HandleFileRequest(envelope.Payload, conn);
        }
        else
        {
            Console.WriteLine("Received message with unknown type from peer.");
            return;
        }
    }

    private void HandleIncomingFileEntry(ClipboardEntry entry)
    {
        FilePayload? payload;
        try
        {
            payload = JsonSerializer.Deserialize<FilePayload>(entry.Content);
        }
        catch (JsonException) { payload = null; }

        if (payload == null || !FileStore.IsValidHash(payload.FileHash))
        {
            Console.WriteLine("Received malformed file entry from peer.");
            return;
        }

        if (FileStore.IsEmptyFile(payload) && !fileStore.Exists(payload.FileHash))
        {
            // Nothing to receive: made here, not asked for (see
            // FileStore.CreateEmpty).
            CreateEmptyFile(payload);
        }

        if (fileStore.Exists(payload.FileHash))
        {
            // already have these exact bytes locally — apply right away
            clipboardSync.addToQueue(entry.Content, entry.Type);
            return;
        }

        // don't have it yet — remember to apply it once file_chunk messages for
        // this hash finish arriving and verify, and ask every connected peer
        // (not just whoever handed us this entry) whether they have it
        fileTransferState.PendingEntries[payload.FileHash] = entry;
        SendFileRequest(payload.FileHash, connectionsByDeviceId.Values);
    }

    // A 0-byte file's blob, made here - best effort: if it can't be, the
    // entry waits for its bytes as any other would.
    private void CreateEmptyFile(FilePayload payload)
    {
        try
        {
            fileStore.CreateEmpty(payload);
            Console.WriteLine($"[file] {payload.FileHash[..12]}... is an empty file - made here, nothing to receive");
            NotifyHistoryChanged(); // it's available now
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"[file] couldn't make the empty file {payload.FileHash[..12]}...: {ex.Message}");
        }
    }

    private static void SendFileRequest(string fileHash, IEnumerable<PeerConnection> to)
    {
        var request = new FileRequestMessage(fileHash);
        var envelope = new Envelope("file_request", JsonSerializer.Serialize(request));
        var json = JsonSerializer.Serialize(envelope);
        foreach (var conn in to)
        {
            _ = conn.Send(json);
        }
    }

    // Asks a peer that just connected for every file this PC is still
    // missing: a newly received item's whose transfer broke off or failed,
    // and any older item's whose bytes never came (ClipLink quit, or the PC
    // slept, mid-transfer, say). Nothing else would ever ask for them again,
    // and the item would stay unavailable until it left history - restarts
    // included.
    private void RequestMissingFiles(PeerConnection conn)
    {
        var wanted = MissingFiles();
        foreach (var (hash, entry) in fileTransferState.PendingEntries)
        {
            if (!historyAccess.isEntryDeleted(entry)) wanted.Add(hash);
        }
        var asking = wanted.Where(hash => !fileStore.Exists(hash) && !incomingFiles.IsReceiving(hash)).ToList();
        if (asking.Count == 0) return;
        Console.WriteLine($"[file] asking {DeviceLabel.ShortId(conn.PeerDeviceId)} for {asking.Count} missing file(s)");
        foreach (string hash in asking)
        {
            SendFileRequest(hash, new[] { conn });
        }
    }

    // The files history entries point at whose bytes aren't here. A 0-byte
    // one is never missing: it's made here, not received (see
    // CreateEmptyFile).
    private HashSet<string> MissingFiles()
    {
        var missing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in historyAccess.GetHistory())
        {
            if (FilePayloadOf(entry) is FilePayload payload && FileStore.IsValidHash(payload.FileHash)
                && !FileStore.IsEmptyFile(payload) && !IsStored(payload))
            {
                missing.Add(payload.FileHash);
            }
        }
        return missing;
    }

    // Whether an item still waits on fileHash's bytes - one just received,
    // or an older one (see MissingFiles).
    private bool IsWanted(string fileHash) =>
        (fileTransferState.PendingEntries.TryGetValue(fileHash, out var pending) && !historyAccess.isEntryDeleted(pending))
        || MissingFiles().Contains(fileHash);

    // How often a file is asked for again between successes - see
    // RequestAgain.
    private const int MaxFileRetries = 3;

    // Asks from for fileHash again after a transfer of it came to nothing -
    // failed its hash check, broke off, or was turned away - while an item
    // still wants it and nobody is sending it. Only MaxFileRetries times
    // between successes: a sender whose copy is bad would otherwise be asked
    // forever. A peer connecting asks once more anyway (see
    // RequestMissingFiles).
    private void RequestAgain(string fileHash, IEnumerable<PeerConnection> from)
    {
        var live = from.ToList();
        if (live.Count == 0 || stopping.IsCancellationRequested
            || fileStore.Exists(fileHash) || incomingFiles.IsReceiving(fileHash) || !IsWanted(fileHash))
        {
            return;
        }
        int tries = fileTransferState.Retries.AddOrUpdate(fileHash, 1, (_, previous) => previous + 1);
        if (tries > MaxFileRetries)
        {
            if (tries == MaxFileRetries + 1)
            {
                Console.WriteLine($"[file] giving up on {fileHash[..12]}... until a device connects");
            }
            return;
        }
        Console.WriteLine($"[file] asking for {fileHash[..12]}... again ({tries} of {MaxFileRetries})");
        SendFileRequest(fileHash, live);
    }

    // The files conn was still sending can't be resumed, only started over
    // - by another peer that has them, or by this one once it's back (see
    // RequestMissingFiles). Once its read loop has ended: by then every
    // chunk it delivered has been handled.
    private void AbandonTransfersFrom(PeerConnection conn)
    {
        try
        {
            var abandoned = incomingFiles.AbandonAll(conn);
            if (abandoned.Count == 0) return;
            Console.WriteLine($"[file] {abandoned.Count} file transfer(s) from {DeviceLabel.ShortId(conn.PeerDeviceId)} broke off");
            var others = connectionsByDeviceId.Values.Where(other => other != conn).ToList();
            foreach (string hash in abandoned)
            {
                RequestAgain(hash, others);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[file] couldn't tidy up the transfers from {DeviceLabel.ShortId(conn.PeerDeviceId)}: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void HandleFileRequest(string payloadJson, PeerConnection requestingConn)
    {
        FileRequestMessage? request;
        try
        {
            request = JsonSerializer.Deserialize<FileRequestMessage>(payloadJson);
        }
        catch (JsonException) { request = null; }
        // Only ever a hash of something in FileStore - never a path to
        // whatever file a peer names (see FileStore.IsValidHash).
        if (request == null || !FileStore.IsValidHash(request.FileHash)) return;

        if (fileStore.Exists(request.FileHash))
        {
            Console.WriteLine($"[file] {DeviceLabel.ShortId(requestingConn.PeerDeviceId)} requested {request.FileHash[..12]}... - we have it, streaming");
            _ = StreamFileToPeer(requestingConn, fileStore.GetPath(request.FileHash), request.FileHash);
        }
        else
        {
            Console.WriteLine($"[file] {DeviceLabel.ShortId(requestingConn.PeerDeviceId)} requested {request.FileHash[..12]}... - don't have it, ignoring");
        }
        // if we don't have it either, just don't respond — the requester
        // already broadcast to everyone else too; someone else might have it
    }

    // One chunk of a file conn is streaming. Which chunks are written, and
    // which ignored, is IncomingFiles' to say: one sender's stream per file,
    // from chunk 0, with no gaps.
    private void HandleFileChunk(string payloadJson, PeerConnection conn)
    {
        FileChunkMessage? chunk;
        try
        {
            chunk = JsonSerializer.Deserialize<FileChunkMessage>(payloadJson);
        }
        catch (JsonException) { chunk = null; }
        if (chunk == null || !FileStore.IsValidHash(chunk.FileHash) || chunk.DataBase64 == null) return;

        byte[] chunkBytes;
        try
        {
            // "" is no bytes: a 0-byte file's one chunk.
            chunkBytes = Convert.FromBase64String(chunk.DataBase64);
        }
        catch (FormatException) { return; }

        string shortHash = chunk.FileHash[..12];
        string shortPeer = DeviceLabel.ShortId(conn.PeerDeviceId);
        var result = incomingFiles.Receive(conn, chunk, chunkBytes);
        if (chunk.ChunkIndex == 0 && result.Outcome is IncomingFiles.Outcome.Written or IncomingFiles.Outcome.Stored)
        {
            Console.WriteLine($"[file] receiving {shortHash}... from {shortPeer}");
        }
        switch (result.Outcome)
        {
            case IncomingFiles.Outcome.Stored:
                fileTransferState.Retries.TryRemove(chunk.FileHash, out _);
                Console.WriteLine($"[file] received {shortHash}... - verified, saved");
                NotifyHistoryChanged(); // its entry's bytes are here now
                if (!TryFulfillPendingEntry(chunk.FileHash)
                    && historyAccess.DeleteFileIfUnused(chunk.FileHash))
                {
                    // Its history item was deleted while these bytes were
                    // on their way (nothing waits to apply them, and
                    // nothing in history refers to them) - kept, they'd sit
                    // in FileStore forever.
                    Console.WriteLine($"[file] {shortHash}... is no longer in history - discarded");
                }
                break;
            case IncomingFiles.Outcome.Failed:
                // Corrupted in transit or tampered with (the signed entry's
                // hash is what's trusted, not whatever bytes showed up), a
                // stream with a gap, or a disk error. Its entry still waits:
                // another peer's copy, or this one's next stream, may be
                // intact - so ask again.
                Console.WriteLine($"[file] {shortHash}... from {shortPeer}: {result.Reason} - discarded");
                RequestAgain(chunk.FileHash, connectionsByDeviceId.Values);
                break;
            case IncomingFiles.Outcome.Ignored when chunk.IsLast:
                // The end of a stream this PC couldn't use - one under way
                // when another sender's copy failed, say, which this sender
                // then ignored the request for. With nobody else sending the
                // file now, this one may as well start over.
                RequestAgain(chunk.FileHash, new[] { conn });
                break;
        }
    }

    // FileStore can gain a blob through more than one path — chunk-stream
    // completion (above), but also a device's own local capture of a file it
    // happens to have independently obtained (e.g. self-detecting the same
    // file another process just applied, on a shared clipboard during local
    // testing — or, in principle, any other future path that populates
    // FileStore). Whichever way a hash becomes available, a pending entry
    // waiting on exactly that hash should get applied — not just when the
    // chunk-reassembly path happens to be the one that completed it. Not if
    // the user deleted that entry meanwhile - deleting never touches the
    // clipboard (see ForgetPendingApplies, which this backs up if the bytes
    // land mid-delete). Returns whether an entry was applied.
    private bool TryFulfillPendingEntry(string fileHash)
    {
        if (fileTransferState.PendingEntries.TryRemove(fileHash, out var pendingEntry) && !historyAccess.isEntryDeleted(pendingEntry))
        {
            clipboardSync.addToQueue(pendingEntry.Content, pendingEntry.Type);
            return true;
        }
        return false;
    }

    // Deleting never touches the clipboard - so a deleted file entry whose
    // bytes are still arriving mustn't be applied once they finish. Only
    // drops a pending apply for that exact entry.
    private void ForgetPendingApplies(List<ClipboardEntry> removed)
    {
        foreach (var entry in removed)
        {
            string? fileHash = HistoryAccess.FileHashOf(entry);
            if (fileHash != null)
            {
                fileTransferState.PendingEntries.TryRemove(new KeyValuePair<string, ClipboardEntry>(fileHash, entry));
            }
        }
    }

    // Reads a file incrementally and sends it as a sequence of file_chunk
    // envelopes — bounded memory (one chunk at a time) regardless of the
    // file's total size, unlike embedding the whole thing in one message.
    private async Task StreamFileToPeer(PeerConnection conn, string filePath, string fileHash)
    {
        string key = $"{conn.PeerDeviceId}:{fileHash}";
        if (!fileTransferState.StreamingInFlight.TryAdd(key, 0))
        {
            // Already streaming this exact file to this exact peer - see
            // StreamingInFlight's field comment.
            return;
        }
        const int chunkSize = 256 * 1024;
        string shortPeer = DeviceLabel.ShortId(conn.PeerDeviceId);
        Console.WriteLine($"[file] sending {fileHash[..12]}... to {shortPeer}");
        try
        {
            using var stream = File.OpenRead(filePath);
            byte[] buffer = new byte[chunkSize];
            int chunkIndex = 0;
            int bytesRead;
            while ((bytesRead = await stream.ReadAsync(buffer, 0, chunkSize)) > 0)
            {
                bool isLast = stream.Position >= stream.Length;
                byte[] chunkBytes = bytesRead == chunkSize ? buffer : buffer[..bytesRead];
                var chunkMsg = new FileChunkMessage(fileHash, chunkIndex, isLast, Convert.ToBase64String(chunkBytes));
                var envelope = new Envelope("file_chunk", JsonSerializer.Serialize(chunkMsg));
                await conn.Send(JsonSerializer.Serialize(envelope));
                chunkIndex++;
            }
            if (chunkIndex == 0 && FileStore.IsEmptyFileHash(fileHash))
            {
                // A 0-byte file: one empty, final chunk, as the iOS app
                // sends (see docs/protocol.md, Empty files). Receivers now
                // make an empty file themselves and never ask for it; of the
                // older builds that do ask, Windows and iOS finish it with
                // this chunk, while Android and HarmonyOS ones refuse to
                // decode an empty chunk and go on waiting, as they always
                // have.
                var emptyChunk = new FileChunkMessage(fileHash, 0, true, "");
                await conn.Send(JsonSerializer.Serialize(new Envelope("file_chunk", JsonSerializer.Serialize(emptyChunk))));
                chunkIndex++;
            }
            Console.WriteLine($"[file] finished sending {fileHash[..12]}... to {shortPeer} ({chunkIndex} chunks)");
        }
        catch (Exception ex)
        {
            // peer disconnected mid-transfer, or the source file became
            // unreadable — nothing further to do about it, but worth logging
            // since this used to fail completely silently
            Console.WriteLine($"[file] sending {fileHash[..12]}... to {shortPeer} failed: {ex.Message}");
        }
        finally
        {
            fileTransferState.StreamingInFlight.TryRemove(key, out _);
            // Its entry may have left history while this was sending - one
            // of more files than history keeps, shared or copied at once, or
            // deleted - and its blob, open here, couldn't be deleted then.
            // Left, it'd sit in FileStore for good; once nothing is sending
            // it, it can go.
            if (!IsBeingSent(fileHash))
            {
                historyAccess.DeleteFileIfUnused(fileHash);
            }
        }
    }

    // Whether fileHash's blob is being sent to any peer right now.
    private bool IsBeingSent(string fileHash) =>
        fileTransferState.StreamingInFlight.Keys.Any(key => key.EndsWith(":" + fileHash, StringComparison.OrdinalIgnoreCase));

    // Once, as the engine starts running - before any connection, so
    // nothing is being sent or received yet: gives each 0-byte file in
    // history the blob it may lack (one received before this build made
    // them itself - see HandleIncomingFileEntry), then deletes each blob no
    // history entry refers to, and each partly received file a transfer cut
    // short left behind. A blob can outlive its entry - more files arriving
    // at once than history keeps, or a delete that failed because a transfer
    // or an app had the blob open - and nothing else would ever delete it.
    // Best effort: never a blob history refers to, or one being sent or
    // received, and a failure here only costs disk space.
    private void TidyFileStore()
    {
        // A share caches a file's blob before its entry is in history (see
        // ShareFilesAsync). One can only be under way here if it started
        // while Faulted and Retry came mid-share: then tidying waits for the
        // next start. (A copy's blob is cached first too - see PublishLocal
        // - but the clipboard watcher only starts after this.)
        if (!shareGate.Wait(0))
        {
            Console.WriteLine("[file] a share is under way - not tidying stored files this time");
            return;
        }
        try
        {
            foreach (var entry in historyAccess.GetHistory())
            {
                if (FilePayloadOf(entry) is FilePayload payload && FileStore.IsEmptyFile(payload) && !IsStored(payload))
                {
                    CreateEmptyFile(payload);
                }
            }
            int unused = 0;
            foreach (string hash in fileStore.StoredHashes())
            {
                // (DeleteFileIfUnused checks history under its lock.)
                if (!IsBeingSent(hash) && historyAccess.DeleteFileIfUnused(hash)) unused++;
            }
            int partial = fileStore.DeletePartials(incomingFiles.IsReceiving);
            Console.WriteLine($"[file] deleted {unused} stored file(s) no history item uses, and {partial} partly received one(s)");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[file] couldn't tidy stored files: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            shareGate.Release();
        }
    }

    // Without this, a connection that's been idle for a while (this app
    // only sends when the clipboard actually changes, so idle is the common
    // case) can get silently dropped by an intermediate NAT or firewall
    // along the path - especially plausible over Tailscale/WireGuard, where
    // the "connection" is really just a NAT mapping that times out without
    // periodic traffic. TCP keepalive pings keep that mapping (and any
    // stateful firewall's idea of the connection) alive without needing
    // real application data to flow. Cross-platform since .NET 5 - not a
    // Windows-only trick despite this being the Windows engine.
    private static void EnableKeepAlive(TcpClient client)
    {
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 20);
        client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 10);
        client.Client.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 5);
    }

    private void SendHistoryBatch(PeerConnection conn)
    {
        var history = historyAccess.GetHistory();
        var envelope = new Envelope("history_batch", JsonSerializer.Serialize(history));
        var json = JsonSerializer.Serialize(envelope);
        _ = conn.Send(json);
    }

    // Wires up a connection for actual use - history sync, message
    // handling, disconnect cleanup. Shared by every path that ends up with
    // a live, already-trusted connection (reconnects, the TCP accept loop,
    // and AcceptPairing once the user approves a candidate).
    private void RegisterConnection(PeerConnection conn)
    {
        connectionsByDeviceId.TryGetValue(conn.PeerDeviceId, out var previous);
        connectionsByDeviceId[conn.PeerDeviceId] = conn;
        Console.WriteLine($"[conn] connected: {DeviceLabel.ShortId(conn.PeerDeviceId)} ({connectionsByDeviceId.Count} total)");
        try
        {
            SendHistoryBatch(conn);
            RequestMissingFiles(conn);
        }
        catch (Exception ex)
        {
            // Must not stop the rest of this setup: the connection is already
            // in the map, and without its Disconnected handler and Listen()
            // below it would sit there dead but "connected" forever, and
            // nothing would ever redial this peer.
            Console.WriteLine($"[conn] couldn't send history or file requests to {DeviceLabel.ShortId(conn.PeerDeviceId)}: {ex.Message}");
        }
        conn.MessageReceived += msg =>
        {
            // One bad message is skipped, not fatal. An exception escaping
            // here used to end the whole connection with nothing logged (it
            // unwinds PeerConnection.Listen's read loop) - e.g. two peers'
            // history batches saving at once, or a malformed file message -
            // which looked like the connection randomly dropping.
            try
            {
                HandleMessage(msg, conn);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[conn] error handling a message from {DeviceLabel.ShortId(conn.PeerDeviceId)} (connection kept): {ex.GetType().Name}: {ex.Message}");
            }
        };
        // Its handshake's name is stored only now, and off the read loop.
        conn.SessionProven += () => _ = Task.Run(() => RememberProvenName(conn));
        conn.Disconnected += () =>
        {
            // Identity-checked removal, NOT TryRemove(key). When both ends
            // dial each other at once, the second connection replaces the
            // first in this map; removing by key alone meant the first
            // one's eventual teardown evicted the SECOND, live connection.
            // Both sides then believed they were disconnected and redialled,
            // which is the connect/disconnect flapping in the console and
            // why the clipboard stopped flowing - the map sat empty even
            // though a healthy socket existed. This overload only removes
            // the entry if it still points at this exact connection.
            bool removed = connectionsByDeviceId.TryRemove(
                new KeyValuePair<string, PeerConnection>(conn.PeerDeviceId, conn));
            if (removed)
            {
                Console.WriteLine($"[conn] disconnected: {DeviceLabel.ShortId(conn.PeerDeviceId)} ({connectionsByDeviceId.Count} total)");
                NotifyDevicesChanged();
            }
            else
            {
                Console.WriteLine($"[conn] stale link closed for {DeviceLabel.ShortId(conn.PeerDeviceId)}; live connection kept ({connectionsByDeviceId.Count} total)");
            }
            // Either way, what it was still sending is cut short, and is
            // asked for elsewhere - from the live link that replaced it, say.
            AbandonTransfersFrom(conn);
        };
        _ = conn.Listen();
        if (previous != null && previous != conn)
        {
            // A second connection to this same peer just replaced the first
            // one in the map (duplicate connections happen when a
            // beacon-triggered dial races one already in flight - see the
            // connectingTo guard around the discovery handler and the
            // off-LAN reconnect loop). Without this, `previous` was
            // left alive as an orphan: its own Listen() loop and heartbeat
            // timer kept running even though nothing sent on it anymore,
            // and this device's own map already points at the new
            // connection - but the peer on the other end of that orphaned
            // socket has no idea it's been superseded, and may still
            // consider IT the canonical connection. That split-brain (each
            // side treating a different one of the duplicate sockets as
            // "the" connection) is what actually produced "Devices tab
            // shows not connected, but sync still works" on the HarmonyOS
            // side (the orphan was still relaying data) and connections
            // appearing to drop later (whichever side's orphan eventually
            // noticed the other end had stopped using it). Closing it here
            // immediately - instead of waiting for its own heartbeat to
            // eventually notice - means there is only ever one live socket
            // per peer, on both ends.
            previous.Close();
        }
        NotifyDevicesChanged();
        if (stopping.IsCancellationRequested)
        {
            // Registered while Stop() was closing every connection - it may
            // have missed this one, which would then stay open (heartbeat
            // and all) with nothing running here.
            conn.Close();
        }
    }

    // Single funnel for every freshly-created PeerConnection, whichever of
    // the several places created it. An already-trusted peer is registered
    // immediately like always; one newly trusted via a matching passphrase
    // proof (NewlyTrustedViaPassphrase - see PeerConnection.CreateAsync) is
    // persisted to the trust store first, then registered the same way; a
    // genuine pairing candidate (only possible because PairingState.ModeOpen
    // was true) is parked as the pending candidate instead (PairingRequested),
    // for AcceptPairing/RejectPairing to resolve. Never auto-trusted just
    // because a connection formed on its own.
    //
    // Nothing here stores the handshake's name, though every connection path
    // (ConnectToPeer, AcceptConnection, PairByAddress) ends up here: a
    // replayed handshake gets this far too. It's stored once the connection
    // proves its session - see RememberProvenName.
    private PairOutcome HandleNewConnection(PeerConnection conn, string? address)
    {
        if (stopping.IsCancellationRequested)
        {
            conn.Close(); // finished connecting after Stop()
            return PairOutcome.NotRunning;
        }
        if (conn.PeerDeviceId == ownId)
        {
            // CreateAsync already refuses our own handshake (see its
            // answeredAsSelf); this device is never trusted, nor a pairing
            // request with itself, whatever gets here.
            conn.Close();
            return PairOutcome.ThisDevice;
        }
        if (conn.WasAlreadyTrusted)
        {
            if (conn.NewlyTrustedViaPassphrase)
            {
                Console.WriteLine($"Auto-pairing {conn.PeerDeviceId} — matching passphrase proof in handshake");
                // Without its name: the proof vouches for the id, not for the
                // name beside it. Listen() hasn't started yet, so this record
                // exists before anything can prove the session.
                trustStore.Trust(conn.PeerDeviceId, address);
            }
            else if (address != null)
            {
                // Already trusted, but now we know a real address for this
                // peer (e.g. captured off an incoming connection whose
                // remote endpoint we just read, or a fresh dial) - back-fill
                // it. Trust() upserts the address on an existing entry, so
                // this is what actually fixes a trust record that was
                // written back when the accept loop didn't capture an
                // address at all (an old bug - it always passed null),
                // instead of leaving it permanently stuck with no address
                // to reconnect off-LAN with. (Trust() keeps the stored name.)
                trustStore.Trust(conn.PeerDeviceId, address);
            }
            RegisterConnection(conn);
            return conn.NewlyTrustedViaPassphrase ? PairOutcome.PairedByPasscode : PairOutcome.Connected;
        }
        if (!pairingState.TrySetPending(conn, address))
        {
            conn.Close(); // already have a candidate awaiting a decision
            return PairOutcome.Busy;
        }
        if (stopping.IsCancellationRequested)
        {
            // Parked just as Stop() abandoned the pending request - it may
            // have missed this one.
            pairingState.TakePending()?.conn.Close();
            return PairOutcome.NotRunning;
        }
        Console.WriteLine($"[pair] pairing request from {DeviceLabel.ShortId(conn.PeerDeviceId)} ({address ?? "unknown address"}) - waiting for Accept/Reject");
        Raise(PairingRequested, new PendingPairing(conn.PeerDeviceId, NameOfCandidate(conn), address), nameof(PairingRequested));
        return PairOutcome.Pending;
    }

    // Handshake name first; an older peer's may only be in its beacon.
    private string? NameOfCandidate(PeerConnection conn) =>
        conn.PeerDeviceName ?? (seenPeers.TryGetValue(conn.PeerDeviceId, out var seen) ? seen.Name : null);

    // Stores conn's handshake name once its session is proven - the first
    // line from the peer decrypted, and wasn't one of ours echoed back
    // (PeerConnection.SessionProven) - and never before: the handshake
    // signature covers only the ephemeral key, so a captured handshake of a
    // trusted device replays under any DeviceName, but a replayer can't send
    // a line of its own that decrypts. This picks up a trusted
    // peer's rename, and fills in the name a new pairing (accepted, or by
    // passcode) was stored without. The first line is normally the peer's
    // history batch, sent as soon as it registers the connection - else its
    // first heartbeat. Never adds a device (UpdateName skips untrusted ids).
    private void RememberProvenName(PeerConnection conn)
    {
        try
        {
            if (trustStore.UpdateName(conn.PeerDeviceId, conn.PeerDeviceName))
            {
                NotifyDevicesChanged();
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[conn] couldn't store the name of {DeviceLabel.ShortId(conn.PeerDeviceId)}: {ex.GetType().Name}: {ex.Message}");
        }
    }

    // Dials out to a peer at a known address and wires it up exactly the same
    // way regardless of how that address was found — LAN discovery or a
    // cached off-LAN (Tailscale) address from the trust store. Only ever
    // used for peers we already expect to be trusted (the id we dial is
    // exactly the id we require back) - PairByAddress below is the
    // counterpart for a genuinely new, not-yet-identified pairing target.
    private async Task ConnectToPeer(string peerDeviceId, string address, int port, CancellationToken cancellationToken = default)
    {
        TcpClient client = new TcpClient();
        await client.ConnectAsync(address, port, cancellationToken);
        EnableKeepAlive(client);

        PeerConnection? conn;
        bool answeredAsSelf = false;
        try
        {
            // The token above only covers connecting. Without a timeout here
            // too, a peer that accepts TCP but never answers (a frozen app
            // whose OS still holds the socket open) stalled the off-LAN
            // reconnect loop's Task.WhenAll - so no other peer was retried -
            // and kept this peer reserved in connectingTo, blocking beacon
            // dials to it as well.
            conn = await PeerConnection.CreateAsync(client, identity, trustStore, pairingState.ModeOpen, passphraseKeyStore, deviceName.Current,
                    answeredAsSelf: () => answeredAsSelf = true)
                .WaitAsync(HandshakeTimeout);
        }
        catch
        {
            client.Close();
            throw;
        }
        if (conn == null)
        {
            client.Close();
            // This PC answered (see CreateAsync's answeredAsSelf). If that's
            // the address stored for the peer - what the off-LAN loop dials -
            // it's this PC's own now (DHCP gave the peer's old address to
            // this PC, say, or the peer came in through a loopback forward,
            // stored as 127.0.0.1): kept, it'd be dialled, a handshake with
            // itself, every 30 s for good. Only the stored address, though:
            // a beacon comes from wherever its sender likes, under any id,
            // so a reflector answering at its address mustn't wipe the
            // peer's real one.
            if (answeredAsSelf && trustStore.ForgetAddress(peerDeviceId, address))
            {
                Console.WriteLine($"[conn] {address}, stored for {DeviceLabel.ShortId(peerDeviceId)}, is this PC's own - cleared it");
                NotifyDevicesChanged();
            }
            throw new IOException(answeredAsSelf ? $"{address} is this PC" : "Handshake failed, or peer is not trusted");
        }
        if (conn.PeerDeviceId != peerDeviceId)
        {
            // The address we had for peerDeviceId now belongs to a different
            // device - typically the same phone after a reinstall gave it a
            // new identity but kept its IP, leaving the old identity in the
            // trust store with that address. This used to close the
            // connection, but the other end had already completed the same
            // handshake and registered it, so every 30s this off-LAN loop
            // knocked out the phone's live connection (its map entry was
            // evicted while the real link kept syncing - "Devices shows not
            // connected but sync works"), or with the newer replace-on-
            // register logic, dropped the live link outright.
            //
            // Trust is decided by CreateAsync for the identity that actually
            // answered, so it's safe to treat this as a connection to THAT
            // device. The stale entry keeps its trust (and its name - Trust()
            // only ever merges names) but loses the address, so it's never
            // dialled here again (it's re-learned if that device really does
            // come back).
            Console.WriteLine($"[conn] {address} answered as {DeviceLabel.ShortId(conn.PeerDeviceId)}, not {DeviceLabel.ShortId(peerDeviceId)} - clearing that stale address");
            trustStore.Trust(peerDeviceId, null);
        }

        HandleNewConnection(conn, address);
    }

    // Long enough for a first packet over a cold Tailscale relay (DERP), short
    // enough that a peer which connects and never sends its handshake doesn't
    // hold a socket open indefinitely.
    private static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(15);

    // One incoming connection, from the TCP accept loop. Everything is
    // caught here: nothing a single peer does may take the listener down.
    private async Task AcceptConnection(TcpClient client)
    {
        string? remoteAddress = null;
        try
        {
            EnableKeepAlive(client);
            // Without capturing this, a device that only ever DIALED OUT
            // to pair (rather than being dialed) would never learn an
            // address for whoever just connected to it - meaning it could
            // never later reconnect off-LAN on its own (see the off-LAN
            // reconnect loop), only ever be reconnected TO.
            remoteAddress = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString();

            var conn = await PeerConnection.CreateAsync(client, identity, trustStore, pairingState.ModeOpen, passphraseKeyStore, deviceName.Current)
                .WaitAsync(HandshakeTimeout);
            if (conn == null)
            {
                // handshake failed, or whoever connected isn't in our trust
                // store and we're not expecting to pair right now — refuse at
                // the connection level, not just per-message
                Console.WriteLine($"[listen] handshake from {remoteAddress} rejected or incomplete (not trusted with no matching passcode and the pairing window closed, or it disconnected / sent a bad handshake)");
                client.Close();
                return;
            }

            HandleNewConnection(conn, remoteAddress);
        }
        catch (Exception ex)
        {
            // Closing the socket also ends a handshake that timed out above.
            Console.WriteLine($"[listen] connection from {remoteAddress ?? "unknown"} dropped during handshake: {ex.GetType().Name}: {ex.Message}");
            client.Close();
        }
    }

    // Counterpart to ConnectToPeer for a genuinely new pairing target - the
    // peer's identity isn't known in advance (that's what the handshake is
    // for), so there's no id to validate against. Used by PairByAddressAsync
    // and by the beacon handler's untrusted-pairing-candidate path. A
    // candidate counts as reached too (Pending) - the accept/reject decision
    // happens separately, via HandleNewConnection.
    private async Task<PairOutcome> PairByAddress(string address, int port)
    {
        TcpClient client = new TcpClient();
        try
        {
            await client.ConnectAsync(address, port);
            EnableKeepAlive(client);
            // Same reason as ConnectToPeer's timeout.
            bool answeredAsSelf = false;
            var conn = await PeerConnection.CreateAsync(client, identity, trustStore, pairingState.ModeOpen, passphraseKeyStore, deviceName.Current,
                    answeredAsSelf: () => answeredAsSelf = true)
                .WaitAsync(HandshakeTimeout);
            if (conn == null)
            {
                client.Close();
                // answeredAsSelf: the address is one of this PC's own.
                return answeredAsSelf ? PairOutcome.ThisDevice : PairOutcome.Refused;
            }
            return HandleNewConnection(conn, address);
        }
        catch (Exception)
        {
            client.Close();
            return PairOutcome.Unreachable; // not reachable right now
        }
    }

    // An untrusted device drops off GetDevices once it's been this long
    // without a beacon (they come every 2s); trusted ones are always listed.
    private static readonly TimeSpan DiscoveredListingWindow = TimeSpan.FromSeconds(30);

    // Beacons are unauthenticated UDP, so anyone on the LAN can make up
    // device ids. Past this many remembered devices, untrusted ones that have
    // gone quiet are forgotten, and a new untrusted one isn't recorded until
    // there's room again - rather than growing without bound.
    private const int MaxSeenPeers = 256;

    // Records one beacon in seenPeers, keeping the last known name when this
    // beacon carries none.
    private void RememberBeacon(string deviceId, SeenPeer beacon)
    {
        if (!seenPeers.ContainsKey(deviceId) && seenPeers.Count >= MaxSeenPeers && !trustStore.IsTrusted(deviceId))
        {
            DateTime cutoff = DateTime.UtcNow - DiscoveredListingWindow;
            foreach (var (id, seen) in seenPeers)
            {
                if (seen.LastSeenUtc < cutoff && !trustStore.IsTrusted(id)) seenPeers.TryRemove(id, out _);
            }
            if (seenPeers.Count >= MaxSeenPeers) return;
        }
        seenPeers.AddOrUpdate(deviceId, beacon, (_, previous) => beacon with { Name = beacon.Name ?? previous.Name });
    }

    // Backs GetDevices - see DeviceListing for the shape and the
    // (deliberately stable) order.
    private List<DeviceListing> ListDevices()
    {
        var rows = new List<DeviceListing>();
        var trusted = trustStore.GetAllTrustedDevices().ToDictionary(device => device.PublicKey);
        DateTime now = DateTime.UtcNow;
        foreach (var device in trusted.Values)
        {
            seenPeers.TryGetValue(device.PublicKey, out var seen);
            connectionsByDeviceId.TryGetValue(device.PublicKey, out var conn);
            bool recent = seen != null && now - seen.LastSeenUtc <= DiscoveredListingWindow;
            rows.Add(new DeviceListing(
                device.PublicKey,
                // The live connection's handshake name only until a stored
                // one exists (e.g. just paired, session not yet proven).
                device.Name ?? conn?.PeerDeviceName ?? seen?.Name,
                Trusted: true,
                Connected: conn != null,
                PairingOpen: recent && seen!.PairingOpen,
                DistinctAddresses(seen?.LanAddress, seen?.AdvertisedAddress, device.Address)));
        }
        foreach (var (id, seen) in seenPeers)
        {
            if (trusted.ContainsKey(id) || now - seen.LastSeenUtc > DiscoveredListingWindow) continue;
            rows.Add(new DeviceListing(id, seen.Name, Trusted: false, Connected: false, seen.PairingOpen,
                DistinctAddresses(seen.LanAddress, seen.AdvertisedAddress)));
        }
        return rows
            .OrderBy(row => row.Trusted ? 0 : 1)
            .ThenBy(row => row.Name == null ? 1 : 0)
            .ThenBy(row => row.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(row => row.PublicKey, StringComparer.Ordinal)
            .ToList();
    }

    private static List<string> DistinctAddresses(params string?[] candidates) =>
        candidates.Where(address => !string.IsNullOrWhiteSpace(address)).Select(address => address!).Distinct().ToList();
}
