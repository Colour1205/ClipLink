import Foundation

// What flows over live links: entries, history catch-up, file bytes.
// Mirrors Program.cs HandleMessage / SendHistoryBatch / ClipboardChanged /
// HandleFileChunk / HandleFileRequest / StreamFileToPeer, with Android's
// dedup-before-apply order and a few receive-side hardenings that never
// change what goes on the wire.
extension SyncEngine {

    // MARK: - Inbound messages

    func handleMessage(_ text: String, from link: PeerLink) {
        guard let envelope = Envelope.parse(text) else {
            log("received invalid message from peer (bad JSON)")
            return
        }
        switch envelope.type {
        case Wire.MessageType.entry:
            guard let entry = ClipboardEntry.parse(envelope.payload) else {
                log("received invalid message from peer (bad entry JSON)")
                return
            }
            // Deleted here: neither back into history nor onto the clipboard.
            guard !deleted.contains(entry) else { return }
            guard let verified = verifiedAndTrusted(entry) else {
                log("dropped \(entry.type) entry from \(DeviceLabel.short(entry.deviceId)) - failed signature/trust check")
                return
            }
            if history.add(verified) {
                received(verified, apply: true)
            }
            schedulePublish()

        case Wire.MessageType.historyBatch:
            // A short-lived sender (the Share extension) has no use for it.
            guard !config.sendOnly else { return }
            guard let entries = ClipboardEntry.parseList(envelope.payload) else {
                log("received invalid message from peer (bad history_batch JSON)")
                return
            }
            // Every real peer sends at most its 25-entry history.
            guard entries.count <= 4 * Wire.historyCap else {
                log("ignored an oversized history batch (\(entries.count) entries)")
                return
            }
            // Items deleted here are skipped before anything else: a peer
            // resends everything it still has on every connect.
            // A bad entry is skipped on its own; the rest of the batch stands.
            // Added in one write, not one full rewrite of history per entry.
            let fresh = history.add(contentsOf: deleted.removingDeleted(entries).compactMap(verifiedAndTrusted))
            guard !fresh.isEmpty else { return }
            // Apply only the newest new entry, and only if it is the newest
            // thing we have at all. Every other port applies each new entry in
            // the sender's order, so the clipboard ends up with whatever came
            // last - often stale content from hours ago.
            let newest = history.newest
            for entry in fresh {
                received(entry, apply: HistoryStore.identity(of: entry) == newest.map(HistoryStore.identity(of:)))
            }
            log("caught up \(fresh.count) item(s) from \(displayName(for: link.peerDeviceId))")
            schedulePublish()

        case Wire.MessageType.fileChunk:
            guard !config.sendOnly else { return }
            handleFileChunk(envelope.payload, from: link)

        case Wire.MessageType.fileRequest:
            guard let request = FileRequestMessage.parse(envelope.payload) else { return }
            if files.exists(request.fileHash) {
                // Echo the requester's own spelling of the hash: its pending
                // map is keyed by it, case-sensitively (Windows uses UPPERCASE).
                streamFile(hash: request.fileHash, to: link)
            }
            // Otherwise stay silent - the request went to everyone.

        default:
            log("received message with unknown type from peer: \(envelope.type)")
        }
    }

    /// Signature must verify against the entry's own DeviceId, and that
    /// device must be trusted HERE - relaying through a trusted peer is not
    /// enough, exactly as on every other platform.
    func verifiedAndTrusted(_ entry: ClipboardEntry) -> ClipboardEntry? {
        guard trust.isTrusted(entry.deviceId) else { return nil }
        // A file entry must carry a well-formed descriptor, or it would sit in
        // history (and be relayed) with a hash we refuse to act on.
        if entry.type == Wire.EntryType.file, FilePayload.parse(entry.content) == nil { return nil }
        return EntrySigning.verified(entry)
    }

    /// A genuinely new entry from a peer.
    func received(_ entry: ClipboardEntry, apply: Bool) {
        log("received \(entry.type) from \(displayName(for: entry.deviceId))")
        guard entry.type == Wire.EntryType.file else {
            if apply { deliverToApp(entry, fileURL: nil) }
            return
        }
        guard let payload = FilePayload.parse(entry.content) else {
            log("received malformed file entry from peer")
            return
        }
        let key = FileStore.key(payload.fileHash)
        if files.exists(payload.fileHash) || materialiseEmptyFile(payload) {
            if apply { deliverToApp(entry, fileURL: files.url(for: key)) }
            return
        }
        pendingFiles[key] = PendingFile(entry: entry, apply: apply || (pendingFiles[key]?.apply ?? false))
        requestFile(payload.fileHash, from: Array(links.values))
    }

    /// SHA-256 of nothing, lowercase like every FileStore key.
    static let emptyFileKey = ContentHash.sha256Hex(Data())

    /// An empty file (size 0, the hash of nothing - either case) needs no
    /// transfer: its bytes are known, so it is written here and never asked
    /// for - asking could wait forever on a sender with no chunks to send.
    /// False for any other file.
    func materialiseEmptyFile(_ payload: FilePayload) -> Bool {
        let key = FileStore.key(payload.fileHash)
        guard payload.fileSize == 0, key == Self.emptyFileKey else { return false }
        if !files.exists(key) { try? files.write(Data(), hash: key) }
        return files.exists(key)
    }

    func deliverToApp(_ entry: ClipboardEntry, fileURL: URL?) {
        if backgroundSession != nil { backgroundReceived.append(entry) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncEngine(self, didReceive: entry, fileURL: fileURL)
        }
    }

    // MARK: - History batch

    func sendHistoryBatch(to link: PeerLink) {
        // Oldest to newest: every other port applies each new entry in the
        // order given, so the newest must come last to end up on its clipboard.
        let payload = ClipboardEntry.listJSONString(Array(history.newestFirst.reversed()))
        link.send(Envelope(type: Wire.MessageType.historyBatch, payload: payload).jsonString())
    }

    // MARK: - Files: requesting

    /// Ask peers for a blob we're missing. Rate-limited per hash so every
    /// history batch doesn't re-ask for the same thing.
    func requestFile(_ wireHash: String, from targets: [PeerLink]) {
        // A sender only drops file bytes (see handleMessage): asking would
        // just have the peer stream the whole file for nothing. The app
        // fetches what's missing on its own next connection.
        guard !config.sendOnly else { return }
        let key = FileStore.key(wireHash)
        guard incoming[key] == nil, !verifying.contains(key), !targets.isEmpty else { return }
        if let last = requestedAt[key], Date().timeIntervalSince(last) < 10 { return }
        requestedAt[key] = Date()
        // A fresh request: a stream skipped before it no longer counts.
        skippedStreams[key] = nil
        let json = Envelope(type: Wire.MessageType.fileRequest, payload: FileRequestMessage(fileHash: wireHash).jsonString()).jsonString()
        targets.forEach { $0.send(json) }
    }

    /// How long a request may go unanswered before it is sent again: every
    /// sender ignores one for a file it is already streaming (or has queued)
    /// for us, and a peer without the bytes says nothing.
    static let fileRetryInterval: TimeInterval = 15
    /// Unanswered requests for one file sent again, at most, until a stream
    /// of it is seen or a new link comes up: a file no peer here has (its
    /// sender gone, its bytes deleted there) isn't asked for every 15 s for
    /// as long as the app is open - each a log line on every peer.
    static let maxUnansweredRetries = 3
    /// A skipped stream whose chunks stop coming has died: ask again after this.
    static let skippedStreamQuiet: TimeInterval = 10
    /// After a skipped stream's last chunk: long enough for its sender to
    /// take a new request for that file.
    static let skippedStreamEndGrace: TimeInterval = 1

    /// Asks again for files we're waiting on whose bytes aren't coming - a
    /// stream that went by unreceived (see handleFileChunk), or a request
    /// nobody answered (a few times) - oldest first, no more at a time than
    /// there are free slots. Every beacon tick and whenever a transfer
    /// finishes. No sender ever sends a file again unasked, so without this
    /// a share of more than `maxConcurrentIncoming` files stalls until the
    /// next link.
    func retryStalledFiles() {
        skippedStreams = skippedStreams.filter { pendingFiles[$0.key] != nil }
        unansweredRetries = unansweredRetries.filter { pendingFiles[$0.key] != nil }
        guard !config.sendOnly, !links.isEmpty, !pendingFiles.isEmpty else { return }
        var free = Self.maxConcurrentIncoming - incoming.count
        let now = Date()
        for entry in history.entries where entry.type == Wire.EntryType.file {
            guard free > 0 else { return }
            guard let payload = FilePayload.parse(entry.content) else { continue }
            let key = FileStore.key(payload.fileHash)
            guard pendingFiles[key] != nil, incoming[key] == nil, !verifying.contains(key), !files.exists(key) else { continue }
            if let retryAt = skippedStreams[key] {
                // Still going past us: its sender would ignore the request.
                guard now >= retryAt else { continue }
            } else {
                if let last = requestedAt[key], now.timeIntervalSince(last) < Self.fileRetryInterval { continue }
                guard unansweredRetries[key, default: 0] < Self.maxUnansweredRetries else { continue }
                unansweredRetries[key, default: 0] += 1
            }
            requestedAt[key] = nil
            requestFile(payload.fileHash, from: Array(links.values))
            free -= 1
        }
    }

    /// On every new link: ask for any file whose entry we have but whose bytes
    /// never arrived (a failed or interrupted transfer). No other platform
    /// ever re-requests, so without this a lost file stays lost.
    func requestMissingBlobs(from link: PeerLink) {
        for entry in history.entries where entry.type == Wire.EntryType.file {
            guard let payload = FilePayload.parse(entry.content), !files.exists(payload.fileHash),
                  !materialiseEmptyFile(payload) else { continue }
            let key = FileStore.key(payload.fileHash)
            if pendingFiles[key] == nil { pendingFiles[key] = PendingFile(entry: entry, apply: false) }
            requestedAt[key] = nil
            // A new peer may have it: worth a few more tries.
            unansweredRetries[key] = nil
            requestFile(payload.fileHash, from: [link])
        }
    }

    /// Lowercase keys of every blob a history entry points at.
    func referencedFileKeys() -> Set<String> {
        Set(history.entries.compactMap { entry -> String? in
            guard entry.type == Wire.EntryType.file, let payload = FilePayload.parse(entry.content) else { return nil }
            return FileStore.key(payload.fileHash)
        })
    }

    /// After a delete or clear: stop waiting for, or receiving, bytes no
    /// remaining entry points at - a transfer finishing later must neither
    /// apply nor leave an orphaned blob behind.
    func dropUnreferencedFiles() {
        let referenced = referencedFileKeys()
        for key in Array(pendingFiles.keys) where !referenced.contains(key) {
            pendingFiles[key] = nil
            requestedAt[key] = nil
            skippedStreams[key] = nil
            unansweredRetries[key] = nil
        }
        for (key, transfer) in incoming where !referenced.contains(key) {
            transfer.abort()
            incoming[key] = nil
        }
    }

    // MARK: - Files: receiving

    func handleFileChunk(_ payload: String, from link: PeerLink) {
        guard let chunk = FileChunkMessage.parse(payload),
              let bytes = Data(base64Encoded: chunk.dataBase64)
        else { return }
        let key = FileStore.key(chunk.fileHash)
        let owner = ObjectIdentifier(link)

        if incoming[key] == nil {
            // Already have it (a second sender answered the same request), one
            // still being verified, or bytes we never asked for (no entry
            // waiting on them): nothing to do. The last guard stops a peer
            // filling the disk with unreferenced blobs.
            guard !files.exists(key), !verifying.contains(key), pendingFiles[key] != nil else { return }
            guard chunk.chunkIndex == 0, incoming.count < Self.maxConcurrentIncoming else {
                // A file we're waiting on, going past unreceived: no free slot
                // for it, or a stream we didn't see start (or gave up on).
                // Its sender won't send it again unasked, and ignores a
                // request while this stream lasts: asked for again once it
                // has ended (retryStalledFiles).
                skippedStreams[key] = Date().addingTimeInterval(chunk.isLast ? Self.skippedStreamEndGrace : Self.skippedStreamQuiet)
                unansweredRetries[key] = nil
                return
            }
            let pendingPayload = pendingFiles[key].flatMap { FilePayload.parse($0.entry.content) }
            guard let transfer = IncomingTransfer(
                wireHash: chunk.fileHash,
                fileName: pendingPayload?.fileName ?? "file",
                total: pendingPayload?.fileSize ?? 0,
                owner: owner,
                url: files.incomingURL(for: key)
            ) else {
                log("failed writing file chunk (could not create file) - abandoning this transfer")
                return
            }
            incoming[key] = transfer
            unansweredRetries[key] = nil
        }
        guard let transfer = incoming[key] else { return }

        // One sender per file. Every other port keys this by hash only, so two
        // peers answering the same broadcast request interleave their chunks
        // into one file that then fails verification - forever, since nobody
        // re-requests. Here the first stream owns it; others are ignored.
        guard transfer.owner == owner else { return }
        if chunk.chunkIndex == 0 && transfer.nextIndex != 0 {
            // The sender restarted its stream: start over.
            transfer.abort()
            incoming[key] = nil
            handleFileChunk(payload, from: link)
            return
        }
        guard chunk.chunkIndex == transfer.nextIndex else {
            log("file chunk out of order - abandoning this transfer")
            transfer.abort()
            incoming[key] = nil
            requestedAt[key] = nil
            return
        }

        do {
            try transfer.handle.write(contentsOf: bytes)
        } catch {
            log("failed writing file chunk (\(error)) - abandoning this transfer")
            transfer.abort()
            incoming[key] = nil
            return
        }
        transfer.nextIndex += 1
        transfer.received += Int64(bytes.count)
        guard transfer.received <= Wire.maxFileBytes else {
            log("incoming file exceeds 1 GB - abandoning this transfer")
            transfer.abort()
            incoming[key] = nil
            return
        }
        if Date().timeIntervalSince(transfer.lastProgressPublish) > 0.25 {
            transfer.lastProgressPublish = Date()
            schedulePublish()
        }

        guard chunk.isLast else { return }
        incoming[key] = nil
        verifying.insert(key)
        // A slot is free: a file skipped for want of one can be asked for.
        retryStalledFiles()
        try? transfer.handle.close()
        let url = transfer.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let actual = (try? ContentHash.sha256Hex(fileAt: url)) ?? ""
            self?.queue.async {
                guard let self else { return }
                self.verifying.remove(key)
                // The hash inside the SIGNED entry is what's trusted, never
                // whatever bytes turned up.
                guard actual == key else {
                    self.log("file transfer failed hash verification - discarding")
                    try? FileManager.default.removeItem(at: url)
                    self.requestedAt[key] = nil
                    // Ask again - maybe another peer's copy is intact.
                    if self.pendingFiles[key] != nil { self.requestFile(transfer.wireHash, from: Array(self.links.values)) }
                    self.schedulePublish()
                    return
                }
                // Its item was deleted (or history cleared) while this was
                // being checked: nothing wants these bytes any more.
                guard self.pendingFiles[key] != nil || self.referencedFileKeys().contains(key) else {
                    try? FileManager.default.removeItem(at: url)
                    self.schedulePublish()
                    return
                }
                do {
                    try self.files.adopt(url, hash: key, move: true)
                } catch {
                    self.log("could not store received file: \(error)")
                    return
                }
                self.fulfillPendingFile(key)
                self.schedulePublish()
            }
        }
    }

    /// A blob can arrive by stream or by this device sending the same file
    /// itself; either way an entry waiting on it can now be applied.
    func fulfillPendingFile(_ key: String) {
        guard let pending = pendingFiles.removeValue(forKey: key) else { return }
        requestedAt[key] = nil
        skippedStreams[key] = nil
        unansweredRetries[key] = nil
        if pending.apply, history.contains(pending.entry) {
            deliverToApp(pending.entry, fileURL: files.url(for: key))
        }
    }

    // MARK: - Files: sending

    /// At most this many files stream to one peer at once; the rest wait
    /// their turn, in order. More at once makes none of them faster over one
    /// link, but each stream holds over a megabyte until the network takes
    /// its chunk - and the Share extension may send 25 files to several
    /// peers in about 120 MB. It also stays under a receiver's own limit
    /// (`maxConcurrentIncoming`; older iOS builds never ask again).
    static let maxStreamsPerLink = 3

    /// Streams a stored blob to one peer in 256 KiB chunks, pacing on the
    /// network stack (each chunk waits for the previous to be handed off) so
    /// memory stays at one chunk per stream regardless of file size.
    func streamFile(hash wireHash: String, to link: PeerLink) {
        let key = FileStore.key(wireHash)
        // Guards against streaming the same file to the same peer twice at
        // once - interleaved chunks fail verification at the far end. One
        // still waiting its turn counts: it will go.
        let inFlightKey = "\(ObjectIdentifier(link).hashValue)|\(key)"
        guard !streaming.contains(inFlightKey) else { return }
        streaming.insert(inFlightKey)
        let stream = OutgoingStream(wireHash: wireHash, link: link, inFlightKey: inFlightKey)
        let id = ObjectIdentifier(link)
        if streamsRunning[id, default: 0] < Self.maxStreamsPerLink {
            startStream(stream)
        } else {
            streamsQueued[id, default: []].append(stream)
        }
    }

    /// One stream ended (sent, failed, or its link closed): the next one
    /// waiting for that link starts - on a closed link it ends at once.
    private func streamEnded(_ stream: OutgoingStream) {
        streaming.remove(stream.inFlightKey)
        let id = ObjectIdentifier(stream.link)
        streamsRunning[id, default: 1] -= 1
        if streamsRunning[id] == 0 { streamsRunning[id] = nil }
        guard var waiting = streamsQueued[id], !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        streamsQueued[id] = waiting.isEmpty ? nil : waiting
        startStream(next)
    }

    private func startStream(_ stream: OutgoingStream) {
        streamsRunning[ObjectIdentifier(stream.link), default: 0] += 1
        let link = stream.link
        let wireHash = stream.wireHash
        let url = files.url(for: FileStore.key(wireHash))
        Task.detached(priority: .utility) { [weak self] in
            defer { self?.queue.async { self?.streamEnded(stream) } }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            var sent: Int64 = 0
            var index = 0
            repeat {
                let data = (try? handle.read(upToCount: Wire.fileChunkSize)) ?? Data()
                sent += Int64(data.count)
                // An empty file still gets one (empty, final) chunk: Windows
                // accepts it and completes; nobody else can do better.
                let isLast = sent >= total || data.isEmpty
                let message = FileChunkMessage(fileHash: wireHash, chunkIndex: index, isLast: isLast, dataBase64: data.base64EncodedString())
                let json = Envelope(type: Wire.MessageType.fileChunk, payload: message.jsonString()).jsonString()
                guard await link.sendAndWait(json) else { return }
                index += 1
                if isLast { return }
            } while true
        }
    }

    // MARK: - Local capture → peers

    /// Signs and sends text from this device.
    public func sendText(_ text: String, completion: ((SendResult) -> Void)? = nil) {
        queue.async { [self] in
            broadcast(content: text, type: Wire.EntryType.text, name: nil, completion: completion)
        }
    }

    /// Images travel inline as base64 PNG - never through the file path.
    /// Callers must pass PNG bytes (Windows' System.Drawing can't decode HEIC).
    public func sendImage(png: Data, completion: ((SendResult) -> Void)? = nil) {
        queue.async { [self] in
            broadcast(content: png.base64EncodedString(), type: Wire.EntryType.image, name: nil, completion: completion)
        }
    }

    /// Stores the file, sends its signed descriptor, then streams the bytes to
    /// every connected peer. Hashes are sent UPPERCASE: Windows echo-suppresses
    /// an applied file by comparing uppercase hashes, so a lowercase one makes
    /// it re-broadcast our file back to everyone. An empty file goes like any
    /// other (size 0, the hash of nothing): receivers write it themselves.
    public func sendFile(at url: URL, name: String, moveIntoStore: Bool, completion: ((SendResult) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size >= 0 else {
                return finish(completion, .failed("Couldn't read that file."))
            }
            guard size <= Wire.maxFileBytes else {
                return finish(completion, .failed("That file is larger than 1 GB."))
            }
            guard let hash = try? ContentHash.sha256Hex(fileAt: url) else {
                return finish(completion, .failed("Couldn't read that file."))
            }
            queue.async { [self] in
                do {
                    try files.adopt(url, hash: hash, move: moveIntoStore)
                } catch {
                    return finish(completion, .failed("Couldn't store that file."))
                }
                // Bytes are in the store BEFORE the entry goes out: receivers
                // send file_request the instant they see the entry.
                let payload = FilePayload(fileName: Self.windowsSafeName(name), fileHash: hash.uppercased(), fileSize: size)
                broadcast(content: payload.jsonString(), type: Wire.EntryType.file, name: name, completion: completion)
                for link in links.values { streamFile(hash: payload.fileHash, to: link) }
                fulfillPendingFile(FileStore.key(hash))
            }
        }
    }

    func broadcast(content: String, type: String, name: String?, completion: ((SendResult) -> Void)?) {
        let entry: ClipboardEntry
        do {
            entry = try EntrySigning.sign(content: content, type: type, identity: identity)
        } catch {
            return finish(completion, .failed("Couldn't sign that item."))
        }
        let json = Envelope(type: Wire.MessageType.entry, payload: entry.jsonString()).jsonString()
        for link in links.values { link.send(json) }
        // Recorded even with nobody connected: history_batch carries it to
        // peers the next time they connect.
        history.add(entry)
        log("sent \(type) to \(links.count) peer(s)")
        schedulePublish()
        finish(completion, .sent(type: type, peers: links.count, name: name))
    }

    /// Older Windows builds apply a received file by copying it to
    /// ReceivedFiles under this exact name, unsanitised: characters or names
    /// Windows rejects would make the file land in their store but never on
    /// their clipboard. `sanitize` already replaces those characters and
    /// drops trailing dots and spaces; this adds the reserved device names.
    static func windowsSafeName(_ name: String) -> String {
        let cleaned = FileStore.sanitize(name)
        // Up to the first dot: "con.txt" is a device, ".con" (no stem) isn't.
        let stem = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })
        return reserved.contains(stem) ? "_" + cleaned : cleaned
    }

    /// Incoming streams at once; any more go past and are asked for again
    /// as slots free up (retryStalledFiles).
    static let maxConcurrentIncoming = 8

    private func finish(_ completion: ((SendResult) -> Void)?, _ result: SendResult) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(result) }
    }
}
