import ImageIO
import UIKit
import UniformTypeIdentifiers

/// The system pasteboard in both directions.
///
/// READING: iOS 15 reads freely (with a "pasted from" banner); iOS 16+ asks
/// "Allow Paste?" for every programmatic read unless the user set Settings >
/// ClipLink > Paste from Other Apps > Allow. `changeCount`, `hasStrings`,
/// `hasImages` and `hasURLs` never trigger either, so they drive the "new
/// item" hint and gate every real read. The system Paste control (iOS 16+)
/// reads without asking.
///
/// WRITING needs no permission. After every write we record the resulting
/// `changeCount`: that is how the next capture knows the pasteboard still
/// holds what WE put there - robust even for images, whose bytes change when
/// iOS re-encodes them (a hash comparison alone would miss that, the same
/// leak Windows and Android have).
@MainActor
final class ClipboardService {
    private let pasteboard = UIPasteboard.general
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let ownChangeCount = "clip.ownChangeCount"
        static let seenChangeCount = "clip.seenChangeCount"
        static let lastWrite = "clip.lastWrite"
        /// Builds up to 2.1.2 kept one hash here instead of `lastWrite`.
        static let legacyLastHash = "clip.lastHash"
    }

    /// Biggest file we'll put on the pasteboard (it goes in memory).
    static let maxPasteboardFileBytes: Int64 = 100 * 1024 * 1024
    /// Biggest received file that lands on the pasteboard by itself: the
    /// write is a synchronous copy of the whole file on the main thread (at
    /// the worst moment, scene activation, for held items), and most apps
    /// can't paste a nameless file anyway. Bigger ones wait in Synced.
    static let maxAutoApplyFileBytes: Int64 = 10 * 1024 * 1024

    /// Runs once the pasteboard has settled after one of our own writes, when
    /// the "new item" hint has to be worked out again.
    var onOwnWriteSettled: (() -> Void)?

    init() {
        discardStaleCounts()
    }

    var changeCount: Int { pasteboard.changeCount }

    /// changeCount right after our own last write.
    private var ownChangeCount: Int {
        get { defaults.object(forKey: Keys.ownChangeCount) as? Int ?? -1 }
        set { defaults.set(newValue, forKey: Keys.ownChangeCount) }
    }

    /// changeCount the user has "seen" (captured, or dismissed the hint for).
    private var seenChangeCount: Int {
        get { defaults.object(forKey: Keys.seenChangeCount) as? Int ?? -1 }
        set { defaults.set(newValue, forKey: Keys.seenChangeCount) }
    }

    /// What ClipLink last put on the clipboard, or last read off it and sent or
    /// found already synced (see LastWrite). Persisted, so a relaunch doesn't
    /// re-send the same clipboard; read from the older single hash when this
    /// build has not written one yet.
    private(set) lazy var lastWrite: LastWrite = LastWrite.load(json: self.defaults.string(forKey: Keys.lastWrite),
                                                                legacyHash: self.defaults.string(forKey: Keys.legacyLastHash))

    /// Bumped by every write of ours: a read that suspended checks it did not
    /// change meanwhile (sync-dedupe-spec 1.6). Memory only.
    private(set) var writeSerial = 0

    /// Replaces the record, only ever after the clipboard write (or the
    /// classification) it describes succeeded.
    func noteLastWrite(_ prints: Set<String>) {
        lastWrite = LastWrite(prints: prints)
        defaults.set(lastWrite.jsonString(), forKey: Keys.lastWrite)
        defaults.removeObject(forKey: Keys.legacyLastHash)
    }

    /// True when the pasteboard changed since we last wrote or looked, and
    /// holds something we could sync. Never triggers a paste prompt.
    var hasUnseenChange: Bool {
        let count = pasteboard.changeCount
        guard count != ownChangeCount, count != seenChangeCount else { return false }
        // What it holds can't change without the count changing: asked once
        // per count, not on every snapshot (each is a round trip to the
        // pasteboard server, on the main thread).
        if let known = contentCheck, known.count == count { return known.hasContent }
        let hasContent = pasteboard.hasStrings || pasteboard.hasImages || pasteboard.hasURLs || pasteboard.numberOfItems > 0
        contentCheck = (count, hasContent)
        return hasContent
    }

    /// The last answer `hasUnseenChange` got from the pasteboard, and for which count.
    private var contentCheck: (count: Int, hasContent: Bool)?

    /// True when the pasteboard still holds what this app last wrote.
    var holdsOwnWrite: Bool { pasteboard.changeCount == ownChangeCount }

    /// ClipLink has never looked at the pasteboard on this install (first
    /// launch): whatever is on it was copied before ClipLink existed here.
    var neverLooked: Bool { defaults.object(forKey: Keys.seenChangeCount) == nil }

    func markSeen() {
        seenChangeCount = pasteboard.changeCount
    }

    /// changeCount starts again from 0 when the device restarts, so counts
    /// saved before a reboot would make a genuine copy that later lands on the
    /// same number look like ours, or already seen. Within one boot the count
    /// only grows: a saved value above the current one is from before it.
    func discardStaleCounts() {
        let now = pasteboard.changeCount
        if ownChangeCount > now { ownChangeCount = -1 }
        if seenChangeCount > now { seenChangeCount = -1 }
    }

    // MARK: - Reading

    /// The last capture() came back empty because a read was declined
    /// (iOS 16+ "Don't Allow"), not because there was nothing to read.
    private(set) var lastCaptureDeclined = false

    /// The last capture() was a picture held in another format (JPEG, HEIC...)
    /// and re-encoded as PNG: the hash of the bytes as they were, which a file
    /// with those bytes goes by (see CapturePrint.alternates).
    private(set) var lastCaptureSourceHash: String?

    /// Reads the pasteboard. Prompts on iOS 16+ unless the user allowed paste.
    ///
    /// Marks the pasteboard seen FIRST, even if the read is then declined:
    /// otherwise every open (and the hint) would ask again for the same copy.
    func capture() async -> Capture? {
        markSeen()
        lastCaptureDeclined = false
        lastCaptureSourceHash = nil
        // On iOS 16+ a declined read just comes back empty. Stop at the first
        // one instead of asking again with the next accessor.
        let declinedEndsIt = Self.readsAsk
        if pasteboard.hasImages {
            let (read, png) = await imagePNG()
            // An empty .png file copied in Files goes as that (empty) file.
            if let png, !png.isEmpty { return .image(png: png) }
            if !read, declinedEndsIt { return declined() }
        }
        if pasteboard.hasStrings {
            let text = pasteboard.string
            if let text, !text.isEmpty { return .text(text) }
            if text == nil, declinedEndsIt { return declined() }
        }
        if pasteboard.hasURLs {
            if let url = pasteboard.url { return url.isFileURL ? copiedFile(url) : .text(url.absoluteString) }
            if declinedEndsIt { return declined() }
        }
        return await capture(from: pasteboard.itemProviders)
    }

    private func declined() -> Capture? {
        lastCaptureDeclined = true
        return nil
    }

    /// Whether reading the pasteboard can raise "Allow Paste?".
    private static var readsAsk: Bool {
        if #available(iOS 16, *) { return true }
        return false
    }

    /// Exactly one read: the PNG itself if there is one, else another image
    /// type's bytes (or, failing that, the UIImage), re-encoded off the main
    /// thread. `read` is false when nothing came back at all - on iOS 16+,
    /// the user said Don't Allow. `types` never asks.
    private func imagePNG() async -> (read: Bool, png: Data?) {
        let types = pasteboard.types
        if types.contains(UTType.png.identifier) {
            let png = pasteboard.data(forPasteboardType: UTType.png.identifier)
            return (png != nil, png)
        }
        if let type = types.first(where: { UTType($0)?.conforms(to: .image) == true }) {
            guard let data = pasteboard.data(forPasteboardType: type) else { return (false, nil) }
            let (png, source) = await Task.detached(priority: .userInitiated) {
                (ItemLoader.pngData(fromImageData: data), ContentHash.sha256Hex(data))
            }.value
            lastCaptureSourceHash = source
            return (true, png)
        }
        guard let image = pasteboard.image else { return (false, nil) }
        return (true, await Task.detached(priority: .userInitiated) { ItemLoader.pngData(image) }.value)
    }

    /// For the system Paste control and drag & drop.
    func capture(from providers: [NSItemProvider]) async -> Capture? {
        await ItemLoader.capture(from: providers)
    }

    private func copiedFile(_ url: URL) -> Capture? { ItemLoader.copiedFile(url) }

    nonisolated static func tempURL(named name: String) -> URL { ItemLoader.tempURL(named: name) }

    // MARK: - Writing

    /// A picture ready for the pasteboard: its bytes, their type, and their
    /// print (see `decodePicture`).
    struct Picture {
        let data: Data
        let type: String
        let print: String
    }

    /// Decodes a picture entry's base64 - the entry's own, or the file the
    /// history keeps a big one in (SyncedItem.inlineURL) - and works out its
    /// type and print. Megabytes of decoding and hashing: off the main thread.
    nonisolated static func decodePicture(content: String, inlineURL: URL?) async -> Picture? {
        await Task.detached(priority: .userInitiated) { () -> Picture? in
            let data: Data?
            if !content.isEmpty {
                data = Data(base64Encoded: content)
            } else if let inlineURL, let text = try? Data(contentsOf: inlineURL, options: .mappedIfSafe) {
                data = Data(base64Encoded: text)
            } else {
                data = nil
            }
            guard let data else { return nil }
            let type = (CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) } as String?) ?? UTType.png.identifier
            return Picture(data: data, type: type, print: ContentPrint.image(data))
        }.value
    }

    /// Puts a decoded picture on the pasteboard.
    func apply(_ picture: Picture) {
        let before = pasteboard.changeCount
        pasteboard.setItems([[picture.type: picture.data]], options: Self.writeOptions)
        noteOwnWrite(before: before)
        noteLastWrite([picture.print])
    }

    /// Puts a received (or re-copied) entry on the pasteboard. Pictures go
    /// through `decodePicture` and `apply(_: Picture)` instead.
    @discardableResult
    func apply(_ entry: ClipboardEntry, fileURL: URL?) -> Bool {
        let before = pasteboard.changeCount
        let print: String?
        switch entry.type {
        case Wire.EntryType.text:
            pasteboard.setItems([[UTType.utf8PlainText.identifier: entry.content]], options: Self.writeOptions)
            print = ContentPrint.text(entry.content)
        case Wire.EntryType.image:
            guard let data = Data(base64Encoded: entry.content) else { return false }
            let type = (CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) } as String?) ?? UTType.png.identifier
            pasteboard.setItems([[type: data]], options: Self.writeOptions)
            print = ContentPrint.image(data)
        case Wire.EntryType.file:
            // The size of the bytes that are here, not the one the sender
            // declared: a peer that leaves it out says 0.
            guard let payload = FilePayload.parse(entry.content), let fileURL,
                  let size = Self.fileSize(at: fileURL), size <= Self.maxPasteboardFileBytes,
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            else { return false }
            let ext = (payload.fileName as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            pasteboard.setItems([[type.identifier: data]], options: Self.writeOptions)
            print = ContentPrint.file(hash: payload.fileHash)
        default:
            return false
        }
        noteOwnWrite(before: before)
        noteLastWrite(Set([print].compactMap { $0 }))
        return true
    }

    func copyText(_ text: String) {
        let before = pasteboard.changeCount
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: Self.writeOptions)
        noteOwnWrite(before: before)
        noteLastWrite([ContentPrint.text(text)])
    }

    /// Bytes on disk, nil when the file can't be looked at.
    nonisolated static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Items ClipLink writes stay on this device: Universal Clipboard would
    /// otherwise hand them to the user's other Apple devices as brand-new
    /// copies, which is ClipLink's job (and would double them up).
    private static let writeOptions: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]

    /// Everything the app itself puts on the pasteboard is marked as ours, so
    /// "send my clipboard when I open ClipLink" never echoes it back - Android
    /// forgets to do this for "Copy device ID".
    private func noteOwnWrite(before: Int) {
        // One write is one bump. Current iOS bumps changeCount inside setItems
        // (and posts changedNotification there); the docs say at the end of the
        // run loop. Counting from the value BEFORE the write is right either
        // way, and the next turn of the run loop records the settled value.
        let expected = before + 1
        ownChangeCount = expected
        seenChangeCount = expected
        writeSerial += 1
        DispatchQueue.main.async { [self] in
            let settled = pasteboard.changeCount
            ownChangeCount = settled
            seenChangeCount = settled
            onOwnWriteSettled?()
        }
    }
}
