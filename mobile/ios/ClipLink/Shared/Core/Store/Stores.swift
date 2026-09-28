import Darwin
import Foundation

// Local persistence. Each store is a small JSON file (or a directory of
// blobs) under one root, written atomically. None of these types lock:
// SyncEngine touches them only from its own serial queue.

// MARK: - Atomic JSON file

struct JSONFile {
    let url: URL

    func read() -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Modification date, to notice another process's writes.
    func stamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func write(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}

// MARK: - Cross-process lock

/// The app and its Share extension are separate processes over the same
/// files. Every store mutation takes this exclusive advisory lock and first
/// re-reads the file if the other process changed it, so neither overwrites
/// the other's additions with a stale copy. Held only for the duration of one
/// mutation (never across a suspension point).
final class StoreLock {
    private static var locks: [String: StoreLock] = [:]
    private static let registry = NSLock()
    private let fd: Int32
    private let local = NSLock()

    static func shared(for directory: URL) -> StoreLock {
        registry.lock()
        defer { registry.unlock() }
        let path = directory.appendingPathComponent(".store.lock").path
        if let existing = locks[path] { return existing }
        let lock = StoreLock(path: path)
        locks[path] = lock
        return lock
    }

    private init(path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fd = open(path, O_CREAT | O_RDWR, 0o600)
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        local.lock()
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 { _ = flock(fd, LOCK_UN) }
            local.unlock()
        }
        return try body()
    }
}

// MARK: - Trust store

/// A device this one has agreed to sync with, plus the last address it was
/// reachable at (for reconnecting without a beacon - off-LAN, or on iOS where
/// broadcast beacons may not be receivable at all) and the latest name it
/// gave itself.
public struct TrustedDevice: Equatable {
    public var publicKey: String
    public var address: String?
    public var name: String?

    public init(publicKey: String, address: String? = nil, name: String? = nil) {
        self.publicKey = publicKey
        self.address = address
        self.name = name
    }
}

/// Mirrors TrustStore.cs / TrustStore.kt / TrustStore.ets, including the
/// deliberate parity gap: public keys and addresses are not encrypted at rest
/// (they are not secrets), but the file sits inside iOS data protection.
public final class TrustStore {
    private let file: JSONFile
    private let lock: StoreLock
    private var devices: [TrustedDevice]
    private var stamp: Date?

    public init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("trusted_devices.json"))
        lock = StoreLock.shared(for: directory)
        devices = Self.load(file)
        stamp = file.stamp()
    }

    /// Re-reads the file: the Share extension (a separate process) may have
    /// changed it since this process last looked.
    public func reload() {
        lock.withLock {
            devices = Self.load(file)
            stamp = file.stamp()
        }
    }

    /// Lock, catch up with the other process, mutate, save.
    private func mutate(_ body: () -> Bool) {
        lock.withLock {
            if file.stamp() != stamp { devices = Self.load(file) }
            if body() { save() }
            stamp = file.stamp()
        }
    }

    private static func load(_ file: JSONFile) -> [TrustedDevice] {
        let raw = file.read() as? [[String: Any]] ?? [] // corrupt -> start empty, like every other port
        return raw.compactMap { obj in
            guard let key = obj["publicKey"] as? String, !key.isEmpty else { return nil }
            let address = (obj["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return TrustedDevice(publicKey: key, address: address, name: name)
        }
    }

    public var all: [TrustedDevice] { devices }

    public func isTrusted(_ publicKey: String) -> Bool {
        devices.contains { $0.publicKey == publicKey }
    }

    public func device(_ publicKey: String) -> TrustedDevice? {
        devices.first { $0.publicKey == publicKey }
    }

    /// Upsert. A nil address never erases a cached one - back-filling an
    /// address later is what makes reconnect-without-beacon work. A nil name
    /// likewise never erases a known one.
    public func trust(_ publicKey: String, address: String? = nil, name: String? = nil) {
        let address = address.flatMap { $0.isEmpty ? nil : $0 }
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        mutate {
            if let index = devices.firstIndex(where: { $0.publicKey == publicKey }) {
                var changed = false
                if let address, devices[index].address != address {
                    devices[index].address = address
                    changed = true
                }
                if let name, devices[index].name != name {
                    devices[index].name = name
                    changed = true
                }
                return changed
            } else {
                devices.append(TrustedDevice(publicKey: publicKey, address: address, name: name))
            }
            return true
        }
    }

    /// Records the latest name a TRUSTED device gave itself (beacon or
    /// handshake). Never adds trust, never touches the address, and an
    /// unknown (nil/empty) name never erases a known one.
    public func updateName(_ publicKey: String, name: String?) {
        guard let name = name.flatMap({ $0.isEmpty ? nil : $0 }) else { return }
        // Beacons arrive every 2 s: skip the lock and file check when
        // nothing changed.
        guard let current = device(publicKey), current.name != name else { return }
        mutate {
            guard let index = devices.firstIndex(where: { $0.publicKey == publicKey }), devices[index].name != name else { return false }
            devices[index].name = name
            return true
        }
    }

    /// Forgets the cached address but keeps the trust - for when an address
    /// turned out to answer as a different identity (Program.cs's
    /// "clearing that stale address" case).
    public func clearAddress(_ publicKey: String) {
        mutate {
            guard let index = devices.firstIndex(where: { $0.publicKey == publicKey }), devices[index].address != nil else { return false }
            devices[index].address = nil
            return true
        }
    }

    public func untrust(_ publicKey: String) {
        mutate {
            devices.removeAll { $0.publicKey == publicKey }
            return true
        }
    }

    private func save() {
        file.write(devices.map { device -> [String: Any] in
            var obj: [String: Any] = ["publicKey": device.publicKey]
            if let address = device.address { obj["address"] = address }
            if let name = device.name { obj["name"] = name }
            return obj
        })
    }
}

// MARK: - File store

/// Content-addressed blobs keyed by LOWERCASE SHA-256 hex. Windows spells
/// hashes in uppercase; storing by the lowercased form keeps one copy per
/// content on iOS's case-sensitive filesystem regardless of who named it.
public final class FileStore {
    public let root: URL
    private let blobs: URL
    private let incoming: URL
    /// Human-named copies handed to share sheets / Quick Look / the Files app.
    public let exports: URL

    public init(directory: URL) {
        root = directory.appendingPathComponent("files", isDirectory: true)
        blobs = root.appendingPathComponent("blobs", isDirectory: true)
        incoming = root.appendingPathComponent("incoming", isDirectory: true)
        exports = root.appendingPathComponent("exports", isDirectory: true)
        for dir in [blobs, incoming, exports] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Anything half-received when the app last died is unrecoverable
        // (the chunk stream it belonged to is gone). Only STALE parts go:
        // this store is shared with the Share extension, which must not wipe
        // a download the app still has in flight.
        clearIncoming(olderThan: 30 * 60)
    }

    /// Lowercased and reduced to hex digits, so no peer-supplied string can
    /// ever become a path component with "/" or ".." in it (parsers already
    /// reject non-SHA-256 hashes; this is defence in depth).
    public static func key(_ hash: String) -> String {
        let hex = hash.lowercased().filter { $0.isHexDigit && $0.isASCII }
        return hex.isEmpty ? "invalid" : hex
    }

    public func url(for hash: String) -> URL {
        blobs.appendingPathComponent(Self.key(hash))
    }

    public func incomingURL(for hash: String) -> URL {
        incoming.appendingPathComponent(Self.key(hash) + ".part")
    }

    public func exists(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    public func size(_ hash: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: hash).path)[.size] as? NSNumber)?.int64Value
    }

    public func write(_ data: Data, hash: String) throws {
        try data.write(to: url(for: hash), options: [.atomic])
    }

    /// Moves (or copies, when moving isn't possible) an existing file in.
    public func adopt(_ source: URL, hash: String, move: Bool) throws {
        let destination = url(for: hash)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        if move {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    public func delete(_ hash: String) {
        try? FileManager.default.removeItem(at: url(for: hash))
    }

    public func clearIncoming(olderThan age: TimeInterval = 0) {
        let items = (try? FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if age == 0 || modified < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// A copy named for humans (a blob's own name is its hash), for share
    /// sheets and Quick Look. Reuses an existing export of the same size.
    public func exportCopy(hash: String, fileName: String) throws -> URL {
        let folder = exports.appendingPathComponent(Self.key(hash), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Self.sanitize(fileName))
        let source = url(for: hash)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path),
           let a = try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
           let b = try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber,
           a == b {
            return target
        }
        try? fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)
        return target
    }

    public func clearExports() {
        try? FileManager.default.removeItem(at: exports)
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    }

    /// Drops one blob's human-named copies (see exportCopy).
    public func removeExport(_ hash: String) {
        try? FileManager.default.removeItem(at: exports.appendingPathComponent(Self.key(hash), isDirectory: true))
    }

    public static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|\0").union(.newlines).union(.controlCharacters)
        var cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String(cleaned.prefix(120 - min(ext.count + 1, 20)))
            cleaned = ext.isEmpty ? stem : stem + "." + ext
        }
        return cleaned.isEmpty ? "file" : cleaned
    }
}

// MARK: - History store

/// The synced-item history. Mirrors HistoryAccess.cs: 25-item cap,
/// oldest-first eviction, file blobs released with their entries.
public final class HistoryStore {
    private let file: JSONFile
    private let fileStore: FileStore
    private let lock: StoreLock
    private var stamp: Date?
    private(set) public var entries: [ClipboardEntry]

    public init(directory: URL, fileStore: FileStore) {
        self.fileStore = fileStore
        file = JSONFile(url: directory.appendingPathComponent("history.json"))
        lock = StoreLock.shared(for: directory)
        entries = (file.read() as? [[String: Any]] ?? []).compactMap(ClipboardEntry.from)
        stamp = file.stamp()
    }

    /// Re-reads the file (see TrustStore.reload).
    public func reload() {
        lock.withLock {
            entries = (file.read() as? [[String: Any]] ?? []).compactMap(ClipboardEntry.from)
            stamp = file.stamp()
        }
    }

    /// Lock, catch up with the other process if it wrote meanwhile, mutate, save.
    private func mutate<T>(_ body: () -> (T, Bool)) -> T {
        lock.withLock {
            if file.stamp() != stamp {
                entries = (file.read() as? [[String: Any]] ?? []).compactMap(ClipboardEntry.from)
            }
            let (result, changed) = body()
            if changed { save() }
            stamp = file.stamp()
            return result
        }
    }

    /// Identity for dedup: who, when (canonicalised, so a Windows-trimmed copy
    /// of an entry matches the original), what kind, and the signature.
    public static func identity(of entry: ClipboardEntry) -> String {
        let ts = DotNetTimestamp.canonical(entry.timestamp) ?? entry.timestamp
        return "\(entry.deviceId)|\(ts)|\(entry.type)|\(entry.signature ?? "")"
    }

    public func contains(_ entry: ClipboardEntry) -> Bool {
        let id = Self.identity(of: entry)
        return entries.contains { Self.identity(of: $0) == id }
    }

    /// True only when the entry was genuinely new. Callers use that to decide
    /// whether to apply it - saying true for a duplicate would bounce the
    /// same item between peers forever.
    @discardableResult
    public func add(_ entry: ClipboardEntry) -> Bool {
        !add(contentsOf: [entry]).isEmpty
    }

    /// Adds every entry not already present (by identity, also within the
    /// batch), trims once and saves once. Returns the new entries that are
    /// still in history after trimming - one evicted straight away by the
    /// 25-item cap isn't "new" in any useful sense.
    @discardableResult
    public func add(contentsOf batch: [ClipboardEntry]) -> [ClipboardEntry] {
        mutate {
            var known = Set(entries.map(Self.identity(of:)))
            var added: [ClipboardEntry] = []
            for entry in batch where known.insert(Self.identity(of: entry)).inserted {
                entries.append(entry)
                added.append(entry)
            }
            guard !added.isEmpty else { return ([], false) }
            trim()
            let survivors = Set(entries.map(Self.identity(of:)))
            return (added.filter { survivors.contains(Self.identity(of: $0)) }, true)
        }
    }

    public func remove(identity: String) {
        mutate {
            guard let index = entries.firstIndex(where: { Self.identity(of: $0) == identity }) else { return ((), false) }
            let removed = entries.remove(at: index)
            releaseBlobIfUnreferenced(removed)
            return ((), true)
        }
    }

    public func clear() {
        mutate {
            let old = entries
            entries.removeAll()
            old.forEach(releaseBlobIfUnreferenced)
            return ((), true)
        }
    }

    /// Newest first, chronologically (not by raw string - see DotNetTimestamp).
    public var newestFirst: [ClipboardEntry] {
        entries.sorted { DotNetTimestamp.isEarlier($1.timestamp, than: $0.timestamp) }
    }

    public var newest: ClipboardEntry? { newestFirst.first }

    private func trim() {
        while entries.count > Wire.historyCap {
            var oldest = 0
            for i in 1..<entries.count where DotNetTimestamp.isEarlier(entries[i].timestamp, than: entries[oldest].timestamp) {
                oldest = i
            }
            releaseBlobIfUnreferenced(entries.remove(at: oldest))
        }
    }

    /// Only drops the blob when no remaining entry still points at the same
    /// bytes (two devices can sync the same file under two entries).
    private func releaseBlobIfUnreferenced(_ entry: ClipboardEntry) {
        guard entry.type == Wire.EntryType.file, let payload = FilePayload.parse(entry.content) else { return }
        let key = FileStore.key(payload.fileHash)
        let stillUsed = entries.contains { other in
            other.type == Wire.EntryType.file && FilePayload.parse(other.content).map { FileStore.key($0.fileHash) } == key
        }
        if !stillUsed { fileStore.delete(payload.fileHash) }
    }

    private func save() {
        file.write(entries.map { $0.jsonObject() })
    }
}

// MARK: - Deleted-entries store

/// Tombstones for items the user deleted or cleared on this device, so a
/// peer - which resends its whole history on every connect - can't bring
/// them back. Local only: nothing about a deletion goes on the wire. Windows
/// keeps the same list in deleted{label}.json. Capped, oldest dropped first.
public final class DeletedStore {
    public static let cap = 2000

    private struct Tombstone {
        let key: String
        /// Milliseconds since the epoch.
        let deletedAt: Int64
    }

    private let file: JSONFile
    private let lock: StoreLock
    /// Oldest first.
    private var tombstones: [Tombstone] = []
    private var keys: Set<String> = []
    private var stamp: Date?

    public init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("deleted_entries.json"))
        lock = StoreLock.shared(for: directory)
        load()
    }

    /// What an entry is remembered by: its signature, exactly as stored.
    /// Every synced entry has one; the fallback only covers unsigned ones.
    public static func key(of entry: ClipboardEntry) -> String {
        if let signature = entry.signature, !signature.isEmpty { return signature }
        return "\(entry.deviceId)|\(entry.type)|\(entry.timestamp)|\(ContentHash.sha256Hex(Data(entry.content.utf8)))"
    }

    public var count: Int { tombstones.count }

    /// Re-reads the file (see TrustStore.reload).
    public func reload() {
        lock.withLock { load() }
    }

    public func contains(_ entry: ClipboardEntry) -> Bool {
        removingDeleted([entry]).isEmpty
    }

    /// The entries that were NOT deleted here. Costs one stat per call; the
    /// file is re-read only when the other process (the app, for the Share
    /// extension's node) changed it meanwhile.
    public func removingDeleted(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        if file.stamp() != stamp { reload() }
        guard !keys.isEmpty else { return entries }
        return entries.filter { !keys.contains(Self.key(of: $0)) }
    }

    /// Remembers these entries as deleted now. One deleted again moves up to
    /// newest, so the cap evicts it last.
    public func add(_ entries: [ClipboardEntry]) {
        let added = entries.map(Self.key(of:))
        guard !added.isEmpty else { return }
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        lock.withLock {
            if file.stamp() != stamp { load() }
            let addedSet = Set(added)
            tombstones.removeAll { addedSet.contains($0.key) }
            var seen = Set<String>()
            for key in added where seen.insert(key).inserted {
                tombstones.append(Tombstone(key: key, deletedAt: now))
            }
            if tombstones.count > Self.cap {
                tombstones.removeFirst(tombstones.count - Self.cap)
            }
            keys = Set(tombstones.map(\.key))
            save()
            stamp = file.stamp()
        }
    }

    private func load() {
        let raw = file.read() as? [[String: Any]] ?? [] // corrupt -> start empty
        tombstones = raw.compactMap { obj -> Tombstone? in
            guard let key = obj["Key"] as? String, !key.isEmpty else { return nil }
            return Tombstone(key: key, deletedAt: (obj["DeletedAt"] as? NSNumber)?.int64Value ?? 0)
        }
        keys = Set(tombstones.map(\.key))
        stamp = file.stamp()
    }

    private func save() {
        file.write(tombstones.map { tombstone -> [String: Any] in
            ["Key": tombstone.key, "DeletedAt": NSNumber(value: tombstone.deletedAt)]
        })
    }
}
