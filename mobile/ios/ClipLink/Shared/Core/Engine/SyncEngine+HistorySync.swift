import Foundation

// History sync, version 2 (Wire.protocolVersion). Two devices that both speak it
// no longer swap whole histories on every connect:
//
//  1. Each sends a history_head: the keys of its history (newest first, with
//     their times) and the keys it deleted - no entries.
//  2. Each applies the other's deletions, works out which keys it is missing and
//     is worth keeping, and sends TWO history_requests back to back: the newest
//     missing key alone (the "convenience" item C, the one thing that lands on
//     the clipboard), then the rest. Each request is answered with ONE
//     history_batch, in the order asked.
//  3. A delete on one device is sent to every connected version 2 peer as a
//     `delete`, and the deleted keys ride in every later head, so a device that
//     was offline learns of them too.
//
// With a peer that speaks version 1 nothing of this happens: head (if 2+
// entries) and the whole history_batch, exactly as before (SyncEngine+Sync).
// Everything here runs on the engine queue.

/// One history_request on its way to a peer, waiting for its answer.
struct HistoryRequest: Equatable {
    let keys: [String]
    /// The first request of a sync: its newest new entry is C.
    let convenience: Bool
    let sentAt: Date
    /// Given up on after `Wire.requestTimeout`. It stays in the queue as a marker,
    /// because the peer still answers it, in order: that late answer is stored
    /// quietly (nothing on the clipboard, no notification, no stack). It leaves
    /// the queue with its answer or with the connection, and counts as no open
    /// request meanwhile.
    var expired = false
}

/// What C did to the clipboard last, for `shouldApplyConvenience`.
struct AppliedConvenience: Equatable {
    /// The entry's time, in 100 ns ticks since the Unix epoch.
    let time: Int64
    /// When it went to the clipboard.
    let appliedAt: Date
}

/// What the engine keeps for one version 2 connection.
struct PeerSync {
    let link: PeerLink
    /// Requests sent and not answered yet (some may be expired markers), oldest
    /// first: the peer answers in the order it was asked.
    var requests: [HistoryRequest] = []
    /// A request still waiting for its answer in time: the markers do not count.
    var hasOpenRequests: Bool { requests.contains { !$0.expired } }
    /// The last history_head this connection sent, so a transfer that dies with
    /// another connection can be asked of this one.
    var lastHead: HistoryHeadV2?
    /// How many items the sync in progress asked for: the badge of its stack.
    var syncSize = 0
}

extension SyncEngine {

    // MARK: - Sending

    /// The first thing a version 2 connection says: what this device has and what
    /// it deleted. Sent even with nothing in it, the deleted list matters alone.
    func sendHistoryHead(to link: PeerLink) {
        let head = HistoryHeadV2.make(newestFirst: history.newestFirst, deleted: deleted.recentKeys(limit: Wire.maxHeadDeleted))
        link.send(Envelope(type: Wire.MessageType.historyHead, payload: head.jsonString()).jsonString())
    }

    /// A version 2 link just came up: remember it, and tell it what we have.
    func startHistorySync(with link: PeerLink) {
        peerSyncs[ObjectIdentifier(link)] = PeerSync(link: link)
        sendHistoryHead(to: link)
    }

    /// Tells every connected version 2 peer these entries were deleted here. A
    /// version 1 peer is not told (it would not know the message) and keeps its
    /// copy: our tombstone keeps it out of our history all the same.
    func broadcastDeletion(of entries: [ClipboardEntry]) {
        let keys = entries.map(DeletedStore.key(of:))
        let targets = links.values.filter(\.speaksV2)
        guard !keys.isEmpty, !targets.isEmpty else { return }
        for message in KeysMessage.messages(for: keys) {
            let json = Envelope(type: Wire.MessageType.delete, payload: message.jsonString()).jsonString()
            targets.forEach { $0.send(json) }
        }
    }

    // MARK: - Receiving a head

    /// The peer's head: apply what it deleted, then ask for what is missing.
    func handleHistoryHeadV2(_ head: HistoryHeadV2, from link: PeerLink) {
        let connection = ObjectIdentifier(link)
        var sync = peerSyncs[connection] ?? PeerSync(link: link)
        sync.lastHead = head
        peerSyncs[connection] = sync
        // Its tombstones, most recently deleted first: stored oldest first, so
        // they keep their order.
        applyRemoteDeletions(Array(head.deleted.reversed()))
        requestMissing(using: head, on: link)
    }

    /// Which keys of a head are worth asking for, newest first:
    /// - the keys we do not have, did not delete and are not already asking
    ///   another connection for (`missing`);
    /// - of those, the ones among the 25 newest by time of our history and the
    ///   missing together - what the history would keep - plus the first one
    ///   whatever its age (C: it goes on the clipboard and is spared the trim);
    /// - all of `missing` (up to 25) when the head has no usable times.
    /// `local` is the key and Unix-millisecond time of every entry we have.
    static func wantedKeys(head: HistoryHeadV2, local: [(key: String, time: Int64)], isGone: (String) -> Bool, isPending: (String) -> Bool) -> [String] {
        struct Candidate {
            let key: String
            let time: Int64
            let isMissing: Bool
        }
        let have = Set(local.map { $0.key })
        let timed = head.times.count == head.keys.count
        var seen = Set<String>()
        var missing: [Candidate] = []
        for (index, key) in head.keys.enumerated() {
            guard seen.insert(key).inserted, !have.contains(key), !isGone(key), !isPending(key) else { continue }
            missing.append(Candidate(key: key, time: timed ? head.times[index] : 0, isMissing: true))
        }
        guard !missing.isEmpty else { return [] }
        guard timed else { return missing.prefix(Wire.historyCap).map { $0.key } }
        let pool = local.map { Candidate(key: $0.key, time: $0.time, isMissing: false) } + missing
        // Newest first; the earlier of two equally old ones wins, so the result
        // does not depend on the sort being stable.
        let newest = pool.enumerated()
            .sorted { $0.element.time != $1.element.time ? $0.element.time > $1.element.time : $0.offset < $1.offset }
            .prefix(Wire.historyCap)
        let kept = Set(newest.filter { $0.element.isMissing }.map { $0.element.key })
        // The first one (C) plus the kept ones can be 26 when the times are out of
        // order: never more than the history holds.
        let result = missing.enumerated().filter { $0.offset == 0 || kept.contains($0.element.key) }.map { $0.element.key }
        return Array(result.prefix(Wire.historyCap))
    }

    /// Two convenience items closer than this are one reconnect to the clipboard.
    static let convenienceWindow: TimeInterval = 90

    /// Two peers can answer a convenience request at the same moment, each with
    /// its own "newest missing" item. C goes on the clipboard unless a convenience
    /// item went there less than `convenienceWindow` ago and C is not newer (by
    /// its own time) than that one: then it only joins the history. Applies to the
    /// whole engine, not to one connection.
    func shouldApplyConvenience(_ entry: ClipboardEntry, now: Date = Date()) -> Bool {
        guard let last = lastConvenience, now.timeIntervalSince(last.appliedAt) < Self.convenienceWindow else { return true }
        return Self.ticks(of: entry) > last.time
    }

    static func ticks(of entry: ClipboardEntry) -> Int64 {
        DotNetTimestamp.epochTicks(entry.timestamp) ?? Int64.min
    }

    /// Asks `link` for what its head lists and we are missing: TWO requests back
    /// to back - the newest key alone (C), then the rest. With `asConvenience`
    /// false (a connection closed that no longer owed C, see `historySyncLinkClosed`)
    /// everything goes in one plain request: the items still arrive, nothing goes
    /// on the clipboard.
    func requestMissing(using head: HistoryHeadV2, on link: PeerLink, asConvenience: Bool = true) {
        let connection = ObjectIdentifier(link)
        guard var sync = peerSyncs[connection] else { return }
        let local = history.entries.map { (key: DeletedStore.key(of: $0), time: HistoryHeadV2.unixMilliseconds(of: $0)) }
        let live = Set(deleted.removingDeletedKeys(head.keys))
        let wanted = Self.wantedKeys(head: head, local: local, isGone: { !live.contains($0) }, isPending: { self.pendingKeys[$0] != nil })
        guard !wanted.isEmpty else { return }

        let now = Date()
        var requests: [HistoryRequest] = []
        if asConvenience {
            requests.append(HistoryRequest(keys: [wanted[0]], convenience: true, sentAt: now))
            if wanted.count > 1 { requests.append(HistoryRequest(keys: Array(wanted.dropFirst()), convenience: false, sentAt: now)) }
        } else {
            requests.append(HistoryRequest(keys: wanted, convenience: false, sentAt: now))
        }
        sync.syncSize = wanted.count
        for request in requests {
            sync.requests.append(request)
            for key in request.keys { pendingKeys[key] = connection }
            link.send(Envelope(type: Wire.MessageType.historyRequest, payload: KeysMessage(keys: request.keys).jsonString()).jsonString())
        }
        peerSyncs[connection] = sync
        log("asked \(displayName(for: link.peerDeviceId)) for \(wanted.count) item(s)")
    }

    // MARK: - Deleting

    /// Keys a peer says were deleted (a `delete`, or the `Deleted` of a head): they
    /// become tombstones - even the ones we never had - and the entries leave
    /// history, their stack, and their file blob if nothing else uses it. The
    /// clipboard is never touched. True when an entry went.
    @discardableResult
    func applyRemoteDeletions(_ keys: [String]) -> Bool {
        guard !keys.isEmpty else { return false }
        deleted.addRemote(keys: keys)
        let gone = Set(keys)
        let doomed = history.entries.filter { gone.contains(DeletedStore.key(of: $0)) }
        guard !doomed.isEmpty else { return false }
        removeFromHistory(doomed)
        log("\(doomed.count) item(s) deleted on another device")
        schedulePublish()
        return true
    }

    /// Takes entries out of history, one write: their file blobs unless another
    /// entry uses the bytes, their waiting or running transfers, and their place in
    /// a stack. The tombstones are the caller's.
    func removeFromHistory(_ entries: [ClipboardEntry]) {
        history.remove(identities: Set(entries.map(HistoryStore.identity(of:))))
        for entry in entries where entry.type == Wire.EntryType.file {
            if let payload = FilePayload.parse(entry.content), !files.exists(payload.fileHash) {
                files.removeExport(payload.fileHash)
            }
        }
        dropUnreferencedFiles()
        batchGroups.prune(keeping: Set(history.entries.map(HistoryStore.identity(of:))))
    }

    func handleDelete(_ message: KeysMessage) {
        applyRemoteDeletions(message.keys)
    }

    // MARK: - Answering a request

    /// ONE history_batch with the entries we have for these keys, newest first;
    /// keys we no longer have are skipped, and with none the array is empty (the
    /// asker is waiting for an answer to every request). Sent in the order the
    /// requests came in: the link's queue keeps call order.
    func answerHistoryRequest(_ message: KeysMessage, to link: PeerLink) {
        let wanted = Set(message.keys)
        let entries = history.newestFirst.filter { wanted.contains(DeletedStore.key(of: $0)) }
        link.send(Envelope(type: Wire.MessageType.historyBatch, payload: ClipboardEntry.listJSONString(entries)).jsonString())
    }

    // MARK: - Receiving an answer

    /// A history_batch on a version 2 connection answers the oldest request still
    /// waiting - an expired marker included: its late answer is stored quietly.
    /// With none waiting nobody asked: it is handled as a version 1 batch.
    func handleHistoryAnswer(_ entries: [ClipboardEntry], from link: PeerLink) {
        let connection = ObjectIdentifier(link)
        guard var sync = peerSyncs[connection], !sync.requests.isEmpty else {
            applyHistoryBatch(entries, from: link.peerDeviceId, connection: connection)
            return
        }
        let request = sync.requests.removeFirst()
        peerSyncs[connection] = sync
        // An expired request gave up its keys long ago: they may be asked of this
        // connection again by now, and that request is not this one.
        if !request.expired {
            for key in request.keys where pendingKeys[key] == connection { pendingKeys[key] = nil }
        }
        applyAnswer(entries, to: request, last: !sync.hasOpenRequests, expectedSize: sync.syncSize, from: link.peerDeviceId, connection: connection)
    }

    /// An answer as ONE unit, like a version 1 batch: every entry is checked
    /// (deleted here, signature, trusted sender, already known - one that was not
    /// in the request is still taken if valid), all the new ones go into history
    /// in one write with one trim and reach the UI in one snapshot. The answer to
    /// the convenience request puts its newest new entry, C, on the clipboard
    /// (once, with the usual notification) and starts the stack; the later answers
    /// join that stack and put nothing on the clipboard, though a file still
    /// has its bytes asked for. `last`: no more answers are waiting.
    ///
    /// Two exceptions. The answer to an expired request (a late one) only stores
    /// what is valid and new: nothing on the clipboard, no stack, no change to
    /// the stack the connection may be filling. And C itself stays off the
    /// clipboard when another convenience item went there less than 90 seconds
    /// ago and C is not newer (see `shouldApplyConvenience`): it is added, and
    /// still leads its stack, but only the item that reached the clipboard is
    /// spared by the trim.
    @discardableResult
    func applyAnswer(_ entries: [ClipboardEntry], to request: HistoryRequest, last: Bool, expectedSize: Int, from peerId: String, connection: ObjectIdentifier, now: Date = Date()) -> HistoryBatchOutcome {
        var outcome = HistoryBatchOutcome()
        let wanted = deleted.removingDeleted(entries)
        outcome.deleted = entries.count - wanted.count
        let verified = wanted.compactMap(verifiedAndTrusted)
        outcome.rejected = wanted.count - verified.count

        let late = request.expired
        let convenience = (request.convenience && !late) ? newestNew(in: verified) : nil
        let toClipboard = convenience.map { shouldApplyConvenience($0, now: now) } ?? false
        // The trim spares the item that went to the clipboard, even when it is the
        // oldest thing: this answer's C, or the one the stack's earlier answer
        // (or an earlier block) put there.
        var protect = Set<String>()
        if let convenience, toClipboard {
            protect.insert(HistoryStore.identity(of: convenience))
        } else if let current = batchGroups.convenienceID {
            protect.insert(current)
        }
        let added = history.add(contentsOf: verified, protecting: protect)
        outcome.known = verified.count - added.count
        guard !added.isEmpty else {
            // Nothing more is coming for the stack this sync started.
            if !late, last, batchGroups.finish(connection: connection) { schedulePublish() }
            return outcome
        }

        outcome.fresh = added.sorted { DotNetTimestamp.isEarlier($1.timestamp, than: $0.timestamp) }
        let identities = outcome.fresh.map(HistoryStore.identity(of:))
        let frontID = convenience.map(HistoryStore.identity(of:))
        if late {
            // No stack for a late answer: its items are ordinary cards by timestamp.
        } else if let convenience, let frontID, identities.contains(frontID) {
            if toClipboard { lastConvenience = AppliedConvenience(time: Self.ticks(of: convenience), appliedAt: now) }
            // The badge counts everything the sync asked for until the rest is here.
            let announced = (last || expectedSize < BatchGroupTracker.groupMinItems) ? nil : expectedSize
            outcome.group = batchGroups.registerSync(front: frontID, others: identities.filter { $0 != frontID }, expectedSize: announced, connection: connection, protectFront: toClipboard)
        } else {
            outcome.group = batchGroups.joinSync(identities, connection: connection, last: last)
        }
        for entry in outcome.fresh {
            received(entry, apply: toClipboard && HistoryStore.identity(of: entry) == frontID, quiet: true)
        }
        log("caught up \(outcome.fresh.count) item(s) from \(displayName(for: peerId))")
        schedulePublish()
        return outcome
    }

    /// The newest of these entries that is not in history yet: C.
    func newestNew(in entries: [ClipboardEntry]) -> ClipboardEntry? {
        let known = Set(history.entries.map(HistoryStore.identity(of:)))
        return entries
            .filter { !known.contains(HistoryStore.identity(of: $0)) }
            .max { DotNetTimestamp.isEarlier($0.timestamp, than: $1.timestamp) }
    }

    // MARK: - Connections that end, requests that time out

    /// A link closed: the answers it owed will not come, so its keys are free to
    /// be asked of someone else - every other version 2 connection re-runs the
    /// head it last sent. C is asked for again (as a convenience request) only
    /// when the closed link still owed it; if its C was answered already, the rest
    /// is asked in one plain request. Expired markers owe nothing: their keys were
    /// given up on and are not asked again. Closing the connection drops its
    /// markers with the rest.
    func historySyncLinkClosed(_ link: PeerLink) {
        let connection = ObjectIdentifier(link)
        headApplied[connection] = nil
        guard let sync = peerSyncs.removeValue(forKey: connection) else { return }
        for key in pendingKeys.filter({ $0.value == connection }).keys { pendingKeys[key] = nil }
        guard sync.hasOpenRequests else { return }
        let owedConvenience = sync.requests.contains { $0.convenience && !$0.expired }
        for other in Array(peerSyncs.values) where !other.link.isClosed {
            if let head = other.lastHead { requestMissing(using: head, on: other.link, asConvenience: owedConvenience) }
        }
    }

    /// Gives up on what has been waiting for `Wire.requestTimeout`: a request
    /// loses its keys (the next reconnect does the work, no retry on the same
    /// connection) and turns into an expired marker that stays in the queue for
    /// its late answer, and a stack waiting for it stops waiting - as does the one
    /// of a version 1.5 head whose batch never came. Markers are never counted
    /// again. On every engine tick.
    func expireHistoryRequests(now: Date = Date()) {
        var changed = false
        func isDue(_ request: HistoryRequest) -> Bool {
            !request.expired && now.timeIntervalSince(request.sentAt) >= Wire.requestTimeout
        }
        for (connection, sync) in peerSyncs where sync.requests.contains(where: isDue) {
            var remaining = sync
            for index in remaining.requests.indices where isDue(remaining.requests[index]) {
                remaining.requests[index].expired = true
                for key in remaining.requests[index].keys where pendingKeys[key] == connection { pendingKeys[key] = nil }
            }
            peerSyncs[connection] = remaining
            log("a request to \(displayName(for: sync.link.peerDeviceId)) went unanswered")
            if !remaining.hasOpenRequests, batchGroups.finish(connection: connection) { changed = true }
        }
        // The marker itself stays (see headApplied): a late batch is still that head's.
        for (connection, since) in headApplied where now.timeIntervalSince(since) >= Wire.requestTimeout {
            if batchGroups.finish(connection: connection) { changed = true }
        }
        if changed { schedulePublish() }
    }
}
