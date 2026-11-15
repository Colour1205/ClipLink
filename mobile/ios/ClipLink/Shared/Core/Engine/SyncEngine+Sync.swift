import Foundation

// What flows over live links: entries, history catch-up, file bytes.
// Mirrors Program.cs HandleMessage / SendHistoryBatch / ClipboardChanged /
// HandleFileChunk / HandleFileRequest / StreamFileToPeer, with Android's
// dedup-before-apply order and a few receive-side hardenings that never
// change what goes on the wire.
extension SyncEngine {

    // MARK: - Inbound messages

    func handleMessage(_ text: String, from link: PeerLink) {
        handleMessage(Data(text.utf8), from: link)
    }

    /// A message as its decrypted bytes (see PeerLink.onMessageData).
    func handleMessage(_ data: Data, from link: PeerLink) {
        guard let envelope = Envelope.parse(data: data) else {
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
                // A newer block than any before it: its own, of one.
                batchGroups.registerLive(HistoryStore.identity(of: verified))
                received(verified, apply: true)
            }
            schedulePublish()

        case Wire.MessageType.historyHead:
            // The small first part of a history_batch: for the same reason, a
            // short-lived sender (the Share extension) has no use for it.
            guard !config.sendOnly else { return }
            if link.speaksV2 {
                // Keys, times and deletions - a `Newest` in it would be ignored.
                guard let head = HistoryHeadV2.parse(envelope.payload) else {
                    log("received invalid message from peer (bad history_head JSON)")
                    return
                }
                handleHistoryHeadV2(head, from: link)
                return
            }
            // Every real peer lists at most its 25-entry history.
            guard let head = HistoryHead.parse(envelope.payload), head.keys.count <= 4 * Wire.historyCap else {
                log("received invalid message from peer (bad history_head JSON)")
                return
            }
            applyHistoryHead(head, from: link.peerDeviceId, connection: ObjectIdentifier(link))

        case Wire.MessageType.historyBatch:
            // A short-lived sender (the Share extension) has no use for it.
            guard !config.sendOnly else { return }
            guard let entries = ClipboardEntry.parseList(envelope.payload) else {
                log("received invalid message from peer (bad history_batch JSON)")
                // On version 2 it still answers a request: the next one is waiting.
                if link.speaksV2 { handleHistoryAnswer([], from: link) } else { finishProvisional(ObjectIdentifier(link)) }
                return
            }
            // Every real peer sends at most its 25-entry history.
            guard entries.count <= 4 * Wire.historyCap else {
                log("ignored an oversized history batch (\(entries.count) entries)")
                if link.speaksV2 { handleHistoryAnswer([], from: link) } else { finishProvisional(ObjectIdentifier(link)) }
                return
            }
            if link.speaksV2 {
                handleHistoryAnswer(entries, from: link)
            } else {
                applyHistoryBatch(entries, from: link.peerDeviceId, connection: ObjectIdentifier(link))
            }

        case Wire.MessageType.historyRequest:
            // Only a version 2 peer asks. Whatever it sent, it gets an answer:
            // it is waiting for one to every request.
            guard link.speaksV2 else {
                log("ignored a history_request on a version 1 connection")
                return
            }
            answerHistoryRequest(KeysMessage.parse(envelope.payload) ?? KeysMessage(keys: []), to: link)

        case Wire.MessageType.delete:
            // From a trusted device's own session, like everything else here; a
            // short-lived sender (the Share extension) has no use for it.
            guard !config.sendOnly, link.speaksV2 else { return }
            guard let message = KeysMessage.parse(envelope.payload) else {
                log("received invalid message from peer (bad delete JSON)")
                return
            }
            handleDelete(message)

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

        case Wire.MessageType.unpair:
            // The peer removed this device: it no longer trusts it. Dropping it here too
            // ends its redialling - trust on one side only never became a pairing, and
            // only ever produced a request at the other end. Only a peer can say this
            // about itself: the message came over its proven session, and all it changes
            // is whether this device trusts it.
            let id = link.peerDeviceId
            guard trust.isTrusted(id) else { return }
            trust.untrust(id)
            links.removeValue(forKey: id)?.close()
            link.close()
            backoff[id] = nil
            awaitingInbound[id] = nil
            log("\(DeviceLabel.short(id)) removed this device - it is no longer trusted here either")
            schedulePublish()

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

    /// What one history_batch did here. `fresh` is newest first.
    struct HistoryBatchOutcome: Equatable {
        /// New entries that are in history now.
        var fresh: [ClipboardEntry] = []
        /// Skipped because the user deleted them here.
        var deleted = 0
        /// Skipped because the signature or the sender's trust did not check out.
        var rejected = 0
        /// Valid, but already in history (or cut at once by the 25-item cap).
        var known = 0
        /// Set when 2 or more entries were new: the Synced list stacks them.
        /// After a history_head it is the group the head started, which also
        /// holds the head's newest entry.
        var group: BatchGroup?
        /// A convenience answer brought nothing newer than what is here: it was
        /// stored quietly, and so is the rest of its sync (see `applyAnswer`).
        var quiet = false
    }

    /// What one history_head did here.
    struct HistoryHeadOutcome: Equatable {
        /// False when the head was ignored (deleted here, bad signature, an
        /// untrusted signer, or a newest entry no newer than everything here):
        /// the batch behind it then works on its own.
        var accepted = false
        /// Its newest entry was new and is in history now.
        var newestIsNew = false
        /// How many entries of the batch will be new, counted from its keys.
        var expectedNew = 0
        /// The provisional group the head started: only when the newest entry
        /// was new and 2 or more entries are expected.
        var group: BatchGroup?
    }

    /// The small first part of a history_batch: its newest entry and every key.
    /// The newest entry is checked like an `entry` message and added at once,
    /// with its side effects (clipboard, notification) now, so the batch finds
    /// it known and does not repeat them. When 2 or more entries are new, a
    /// provisional group shows the stack straight away, with the badge for the
    /// size the keys announce; the batch fills it in. A head whose newest entry
    /// is not newer than everything here is ignored, as if it had failed its
    /// checks: the batch then works on its own. Runs on the engine queue.
    @discardableResult
    func applyHistoryHead(_ head: HistoryHead, from peerId: String, connection: ObjectIdentifier) -> HistoryHeadOutcome {
        var outcome = HistoryHeadOutcome()
        // Deleted here, or not signed by a trusted device: ignore all of it.
        // Nothing in it is believed beyond what an entry message would be.
        guard !deleted.contains(head.newest), let newest = verifiedAndTrusted(head.newest) else {
            log("dropped a history head from \(displayName(for: peerId)) - failed signature/trust check")
            return outcome
        }
        // Nothing newer than what is here: no early item, no stack, nothing on
        // the clipboard. Known already, trimmed here, or a partly paired peer's.
        guard isFresh(newest) else { return outcome }
        outcome.accepted = true
        // A head that follows another one on this connection: the first one's
        // batch is not coming any more.
        let finished = batchGroups.finish(connection: connection)
        headApplied[connection] = nil

        // Counted before the newest entry goes in: the keys that are neither
        // in history nor deleted here. Never more than a history can hold.
        let have = Set(history.entries.map(DeletedStore.key(of:)))
        var seen = Set<String>()
        let expected = deleted.removingDeletedKeys(head.keys).filter { seen.insert($0).inserted && !have.contains($0) }
        outcome.expectedNew = min(expected.count, Wire.historyCap)

        // Its newest entry is C: spared by the trim and put on the clipboard.
        let identity = HistoryStore.identity(of: newest)
        outcome.newestIsNew = !history.add(contentsOf: [newest], protecting: [identity]).isEmpty
        if outcome.newestIsNew {
            // Remembered in memory only, to stack these items in the Synced list.
            outcome.group = batchGroups.registerProvisional(front: identity, expectedSize: outcome.expectedNew, connection: connection)
            // The batch behind this head has nothing to put on the clipboard.
            headApplied[connection] = Date()
            received(newest, apply: true)
        }
        if outcome.newestIsNew || finished { schedulePublish() }
        return outcome
    }

    /// The batch a head announced is not coming (or added nothing): its group
    /// counts only the members it has, and goes with fewer than 2.
    func finishProvisional(_ connection: ObjectIdentifier) {
        if batchGroups.finish(connection: connection) { schedulePublish() }
    }

    /// A history_batch as ONE unit: every entry is checked as before (deleted
    /// here, signature, trusted sender, already known), then all the new ones
    /// go into history in one write and reach the UI in one snapshot. The side
    /// effects (clipboard, notification) happen once per batch, for the newest
    /// NEW entry only (C) - and only when it is newer than everything already
    /// here: otherwise the whole batch is stored quietly, by time, with no stack
    /// (an item trimmed here would come back on every reconnect). After a
    /// history_head of the same `connection` that put its newest entry there,
    /// the batch puts nothing: the entries the head added are known and
    /// skipped, and the others join its group. Runs on the engine queue.
    @discardableResult
    func applyHistoryBatch(_ entries: [ClipboardEntry], from peerId: String, connection: ObjectIdentifier? = nil) -> HistoryBatchOutcome {
        var outcome = HistoryBatchOutcome()
        // Items deleted here are skipped before anything else: a peer
        // resends everything it still has on every connect.
        let wanted = deleted.removingDeleted(entries)
        outcome.deleted = entries.count - wanted.count
        // What is in history already is skipped before its signature is
        // checked: an older peer resends its whole history on every connect,
        // pictures and all, and the check copies and hashes each entry whole.
        // It would be dropped as known anyway; new entries are checked as ever.
        let known = Set(history.entries.map(HistoryStore.identity(of:)))
        let unknown = wanted.filter { !known.contains(HistoryStore.identity(of: $0)) }
        outcome.known = wanted.count - unknown.count
        // A bad entry is skipped on its own; the rest of the batch stands.
        let verified = unknown.compactMap(verifiedAndTrusted)
        outcome.rejected = unknown.count - verified.count
        // C is the newest new entry - or, when this connection's head already put
        // its newest entry on the clipboard, that one. Either is spared the trim.
        var continuing = false
        if let connection { continuing = headApplied.removeValue(forKey: connection) != nil }
        let convenience = continuing ? nil : newestNew(in: verified).flatMap { isFresh($0) ? $0 : nil }
        var protect = Set<String>()
        if let convenience {
            protect.insert(HistoryStore.identity(of: convenience))
        } else if let current = batchGroups.convenienceID {
            protect.insert(current)
        }
        // Added in one write, not one full rewrite of history per entry.
        let added = history.add(contentsOf: verified, protecting: protect)
        outcome.known += verified.count - added.count
        guard !added.isEmpty else {
            // Nothing more is coming for the stack a head started.
            if let connection { finishProvisional(connection) }
            return outcome
        }

        outcome.fresh = added.sorted { DotNetTimestamp.isEarlier($1.timestamp, than: $0.timestamp) }
        // Remembered in memory only, to stack these items in the Synced list.
        let identities = outcome.fresh.map(HistoryStore.identity(of:))
        if continuing, let connection {
            // The batch of a head that applied C: its entries join the head's stack
            // if that still waits, else they stay ordinary cards. Never a new block
            // (or a new C) for items that did not reach the clipboard.
            outcome.group = batchGroups.joinSync(identities, connection: connection, last: true)
        } else if convenience != nil {
            outcome.group = batchGroups.registerBatch(identities, connection: connection)
        }
        // Otherwise nothing in it is newer than what is here: ordinary cards by time.

        // Apply only the newest new entry (C). The older ports apply each new
        // entry in the sender's order, so their clipboard ends up with whatever
        // came last - often stale content from hours ago.
        let applied = convenience.map(HistoryStore.identity(of:))
        // The loop does nothing for text and pictures that are not applied;
        // a file still has to be asked for, so its card can finish.
        for entry in outcome.fresh {
            received(entry, apply: HistoryStore.identity(of: entry) == applied, quiet: true)
        }
        log("caught up \(outcome.fresh.count) item(s) from \(displayName(for: peerId))")
        schedulePublish()
        return outcome
    }

    /// A genuinely new entry from a peer. `quiet` leaves out the log line
    /// (a history batch writes one line for all its entries).
    func received(_ entry: ClipboardEntry, apply: Bool, quiet: Bool = false) {
        if !quiet { log("received \(entry.type) from \(displayName(for: entry.deviceId))") }
        // Every entry meant for the clipboard counts, in the order they came:
        // a file waiting for its bytes then knows whether a newer one came after.
        if apply { lastApplySerial += 1 }
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
        var pending = PendingFile(entry: entry, apply: false)
        if let earlier = pendingFiles[key], earlier.apply {
            pending = earlier
            pending.entry = entry
        }
        if apply {
            pending.apply = true
            pending.armedAt = Date()
            pending.armedGeneration = clipboardGeneration
            pending.armedSerial = lastApplySerial
        }
        pendingFiles[key] = pending
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

    /// What a version 1 peer gets as this device's history, newest first, with
    /// every picture inline (those kept in files of their own read back in).
    /// A short-lived sender (the Share extension) sends only what it stored
    /// itself: the whole history, pictures and all, built and sealed once per
    /// peer, can be more memory than it has. Still a valid batch - every port
    /// merges by dedup and infers nothing from what is missing, and "[]" is
    /// still the first bytes HarmonyOS waits for - and the app sends
    /// everything on its next connection.
    func historyBatchEntries() -> [ClipboardEntry] {
        var entries = history.newestFirst
        if config.sendOnly { entries = entries.filter { storedHere.contains(HistoryStore.identity(of: $0)) } }
        return history.withContent(entries)
    }

    func sendHistoryBatch(to link: PeerLink) {
        let newestFirst = historyBatchEntries()
        // With 2 or more entries, the newest one and every key go first in a
        // small line, so the peer can show the stack while the big batch is
        // still on its way. The batch itself is the same as ever, and a peer
        // that does not know the head skips it.
        if let head = HistoryHead.make(newestFirst: newestFirst) {
            link.send(Envelope(type: Wire.MessageType.historyHead, payload: head.jsonString()).jsonString())
        }
        // Oldest to newest: every other port applies each new entry in the
        // order given, so the newest must come last to end up on its clipboard.
        let payload = ClipboardEntry.listJSONString(Array(newestFirst.reversed()))
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
        // Not of a peer whose copy keeps failing the hash check.
        let failed = badCopies[key] ?? [:]
        let targets = targets.filter { failed[$0.peerDeviceId, default: 0] < Self.maxBadCopies }
        guard incoming[key] == nil, !verifying.contains(key), !targets.isEmpty else { return }
        if let last = requestedAt[key], Date().timeIntervalSince(last) < 10 { return }
        // Bytes that can't be stored would only be streamed for nothing.
        guard hasRoom(for: key) else {
            noteNeedsSpace(key)
            return
        }
        requestedAt[key] = Date()
        // A fresh request: a stream skipped before it no longer counts.
        skippedStreams[key] = nil
        let json = Envelope(type: Wire.MessageType.fileRequest, payload: FileRequestMessage(fileHash: wireHash).jsonString()).jsonString()
        targets.forEach { $0.send(json) }
    }

    /// Free space a download leaves at the least.
    static let spaceMargin: Int64 = 32 * 1024 * 1024
    /// A peer whose copy of a file failed the hash check this often isn't
    /// asked for that file again until it connects anew.
    static let maxBadCopies = 2

    /// Whether the file we're waiting on under `key` fits in the free space,
    /// with `spaceMargin` to spare. True when the free space can't be told (a
    /// volume that reports nothing says 0): a write that fails still stops it.
    func hasRoom(for key: String) -> Bool {
        guard let free = capacityOverride ?? files.availableCapacity(), free > 0 else { return true }
        let size = pendingFiles[key].flatMap { FilePayload.parse($0.entry.content)?.fileSize } ?? 0
        return free >= max(0, size) + Self.spaceMargin
    }

    /// A file that can't be stored here now: not asked for, and its stream
    /// goes by, until `retryFilesThatNeededSpace` or a new link.
    func noteNeedsSpace(_ key: String) {
        guard needsSpace.insert(key).inserted else { return }
        log("not enough storage for a file - it is fetched once there is room")
        schedulePublish()
    }

    /// Back in the foreground (space may have been freed): every file that
    /// needed room is asked for again on the next tick, its free space
    /// checked first.
    func retryFilesThatNeededSpace() {
        guard !needsSpace.isEmpty else { return }
        for key in needsSpace {
            requestedAt[key] = nil
            unansweredRetries[key] = nil
            skippedStreams[key] = nil
        }
        needsSpace.removeAll()
        schedulePublish()
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
        // Waiting on bytes for an entry that has left the history (trimmed by
        // the 25-item cap): nothing wants them any more.
        if !pendingFiles.isEmpty {
            let referenced = referencedFileKeys()
            pendingFiles = pendingFiles.filter { referenced.contains($0.key) }
        }
        skippedStreams = skippedStreams.filter { pendingFiles[$0.key] != nil }
        unansweredRetries = unansweredRetries.filter { pendingFiles[$0.key] != nil }
        if !needsSpace.isEmpty { needsSpace = needsSpace.filter { pendingFiles[$0] != nil } }
        if !badCopies.isEmpty { badCopies = badCopies.filter { pendingFiles[$0.key] != nil } }
        guard !config.sendOnly, !links.isEmpty, !pendingFiles.isEmpty else { return }
        var free = Self.maxConcurrentIncoming - incoming.count
        let now = Date()
        for entry in history.entries where entry.type == Wire.EntryType.file {
            guard free > 0 else { return }
            guard let payload = FilePayload.parse(entry.content) else { continue }
            let key = FileStore.key(payload.fileHash)
            // One waiting for room is asked for again on the next foreground or link.
            guard pendingFiles[key] != nil, incoming[key] == nil, !verifying.contains(key), !files.exists(key),
                  !needsSpace.contains(key) else { continue }
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
        // Connected anew, a peer's copy gets another chance (see badCopies),
        // and a file that needed room is asked for again - asking checks the
        // free space first.
        let peer = link.peerDeviceId
        for key in Array(badCopies.keys) {
            badCopies[key]?[peer] = nil
            if badCopies[key]?.isEmpty == true { badCopies[key] = nil }
        }
        needsSpace.removeAll()
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
            needsSpace.remove(key)
            badCopies[key] = nil
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
            // Waiting for room: its stream goes by, and is not asked for again
            // (see needsSpace).
            guard !needsSpace.contains(key) else { return }
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
            // Space may have run out since it was asked for.
            guard hasRoom(for: key) else {
                noteNeedsSpace(key)
                return
            }
            let pendingPayload = pendingFiles[key].flatMap { FilePayload.parse($0.entry.content) }
            guard let transfer = IncomingTransfer(
                wireHash: chunk.fileHash,
                fileName: pendingPayload?.fileName ?? "file",
                total: pendingPayload?.fileSize ?? 0,
                owner: owner,
                peerId: link.peerDeviceId,
                url: files.incomingURL(for: key)
            ) else {
                log("failed writing file chunk (could not create file) - abandoning this transfer")
                // Asked for again it would fail the same way: the rest of this
                // stream, and the next, went by unreceived for ever.
                noteNeedsSpace(key)
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
            // Most likely the disk is full: not asked for again, nor taken
            // from the rest of this stream, until there may be room.
            noteNeedsSpace(key)
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
                    // Ask again - maybe another peer's copy is intact. One
                    // whose copy failed `maxBadCopies` times is not asked any
                    // more (until it connects anew): its file is corrupt, and
                    // was downloaded again and again.
                    if self.pendingFiles[key] != nil {
                        self.badCopies[key, default: [:]][transfer.peerId, default: 0] += 1
                        if self.badCopies[key]?[transfer.peerId] == SyncEngine.maxBadCopies {
                            self.log("\(self.displayName(for: transfer.peerId))'s copy of a file is corrupt - not asking it again")
                        }
                        self.requestFile(transfer.wireHash, from: Array(self.links.values))
                    }
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
    /// itself; either way an entry waiting on it can now be applied - unless
    /// that would replace something newer (see `PendingFile.mayApply`).
    func fulfillPendingFile(_ key: String) {
        guard let pending = pendingFiles.removeValue(forKey: key) else { return }
        requestedAt[key] = nil
        skippedStreams[key] = nil
        unansweredRetries[key] = nil
        needsSpace.remove(key)
        badCopies[key] = nil
        if pending.mayApply(now: Date(), generation: clipboardGeneration, serial: lastApplySerial),
           history.contains(pending.entry), !deleted.contains(pending.entry) {
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

    /// Signs and sends text from this device. With a `filter` (a share or a
    /// drop, see makeSendFilter), text every device already has is not signed
    /// again.
    public func sendText(_ text: String, filter: SendFilter? = nil, completion: ((SendResult) -> Void)? = nil) {
        queue.async { [self] in
            broadcast(content: text, type: Wire.EntryType.text, name: nil,
                      print: filter == nil ? nil : ContentPrint.text(text), filter: filter, completion: completion)
        }
    }

    /// Images travel inline as base64 PNG - never through the file path.
    /// Callers must pass PNG bytes (Windows' System.Drawing can't decode HEIC).
    public func sendImage(png: Data, filter: SendFilter? = nil, completion: ((SendResult) -> Void)? = nil) {
        queue.async { [self] in
            broadcast(content: png.base64EncodedString(), type: Wire.EntryType.image, name: nil,
                      print: filter == nil ? nil : ContentPrint.image(png), filter: filter, completion: completion)
        }
    }

    /// Stores the file, sends its signed descriptor, then streams the bytes to
    /// every connected peer. Hashes are sent UPPERCASE: Windows echo-suppresses
    /// an applied file by comparing uppercase hashes, so a lowercase one makes
    /// it re-broadcast our file back to everyone. An empty file goes like any
    /// other (size 0, the hash of nothing): receivers write it themselves.
    public func sendFile(at url: URL, name: String, moveIntoStore: Bool, filter: SendFilter? = nil, completion: ((SendResult) -> Void)? = nil) {
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
                let signed = broadcast(content: payload.jsonString(), type: Wire.EntryType.file, name: name,
                                       print: ContentPrint.file(hash: hash), filter: filter, completion: completion)
                if signed {
                    for link in links.values { streamFile(hash: payload.fileHash, to: link) }
                }
                // Its bytes are here now either way.
                fulfillPendingFile(FileStore.key(hash))
            }
        }
    }

    /// False when nothing was signed: it failed, or `filter` says every device
    /// has this content already - which is still reported as sent, since what
    /// the user wanted, the content on their devices, is done.
    @discardableResult
    func broadcast(content: String, type: String, name: String?, print: String? = nil, filter: SendFilter? = nil, completion: ((SendResult) -> Void)?) -> Bool {
        if let filter, let print, !filter.prints.insert(print).inserted {
            finish(completion, .sent(type: type, peers: links.count, name: name))
            return false
        }
        let entry: ClipboardEntry
        do {
            entry = try EntrySigning.sign(content: content, type: type, identity: identity)
        } catch {
            finish(completion, .failed("Couldn't sign that item."))
            return false
        }
        let json = Envelope(type: Wire.MessageType.entry, payload: entry.jsonString()).jsonString()
        for link in links.values { link.send(json) }
        // Recorded even with nobody connected: a history_batch or head carries it
        // to peers the next time they connect. Our own copy is a block of one, on
        // top of the Synced list.
        if history.add(entry) {
            batchGroups.registerLive(HistoryStore.identity(of: entry))
            if config.sendOnly { storedHere.insert(HistoryStore.identity(of: entry)) }
        }
        log("sent \(type) to \(links.count) peer(s)")
        schedulePublish()
        finish(completion, .sent(type: type, peers: links.count, name: name))
        return true
    }

    /// Older Windows builds apply a received file by copying it to
    /// ReceivedFiles under this exact name, unsanitised: characters or names
    /// Windows rejects would make the file land in their store but never on
    /// their clipboard. `sanitize` already replaces those characters and
    /// drops trailing dots and spaces; this adds the reserved device names,
    /// cut again if the "_" takes one over the caps (as FileNames.Safe does).
    static func windowsSafeName(_ name: String) -> String {
        let cleaned = FileStore.sanitize(name)
        // Up to the first dot: "con.txt" is a device, ".con" (no stem) isn't.
        let stem = cleaned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })
        return reserved.contains(stem) ? FileStore.sanitize("_" + cleaned) : cleaned
    }

    /// Incoming streams at once; any more go past and are asked for again
    /// as slots free up (retryStalledFiles).
    static let maxConcurrentIncoming = 8

    private func finish(_ completion: ((SendResult) -> Void)?, _ result: SendResult) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(result) }
    }
}
