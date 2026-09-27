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
        static let lastHash = "clip.lastHash"
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

    /// Hash of whatever this device last sent or applied (persisted, unlike on
    /// Android, so a relaunch doesn't re-send the same clipboard).
    private(set) var lastKnownHash: String? {
        get { defaults.string(forKey: Keys.lastHash) }
        set { defaults.set(newValue, forKey: Keys.lastHash) }
    }

    /// True when the pasteboard changed since we last wrote or looked, and
    /// holds something we could sync. Never triggers a paste prompt.
    var hasUnseenChange: Bool {
        let count = pasteboard.changeCount
        guard count != ownChangeCount, count != seenChangeCount else { return false }
        return pasteboard.hasStrings || pasteboard.hasImages || pasteboard.hasURLs || pasteboard.numberOfItems > 0
    }

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

    func noteSent(hash: String) {
        lastKnownHash = hash
    }

    // MARK: - Reading

    /// The last capture() came back empty because a read was declined
    /// (iOS 16+ "Don't Allow"), not because there was nothing to read.
    private(set) var lastCaptureDeclined = false

    /// Reads the pasteboard. Prompts on iOS 16+ unless the user allowed paste.
    ///
    /// Marks the pasteboard seen FIRST, even if the read is then declined:
    /// otherwise every open (and the hint) would ask again for the same copy.
    func capture() async -> Capture? {
        markSeen()
        lastCaptureDeclined = false
        // On iOS 16+ a declined read just comes back empty. Stop at the first
        // one instead of asking again with the next accessor.
        let declinedEndsIt = Self.readsAsk
        if pasteboard.hasImages {
            let (read, png) = await imagePNG()
            if let png { return .image(png: png) }
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
            return (true, await Task.detached(priority: .userInitiated) { ItemLoader.pngData(fromImageData: data) }.value)
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

    /// Puts a received (or re-copied) entry on the pasteboard.
    @discardableResult
    func apply(_ entry: ClipboardEntry, fileURL: URL?) -> Bool {
        let before = pasteboard.changeCount
        switch entry.type {
        case Wire.EntryType.text:
            pasteboard.setItems([[UTType.utf8PlainText.identifier: entry.content]], options: Self.writeOptions)
            lastKnownHash = ContentHash.sha256Hex(Data(entry.content.utf8))
        case Wire.EntryType.image:
            guard let data = Data(base64Encoded: entry.content) else { return false }
            let type = (CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) } as String?) ?? UTType.png.identifier
            pasteboard.setItems([[type: data]], options: Self.writeOptions)
            lastKnownHash = ContentHash.sha256Hex(data)
        case Wire.EntryType.file:
            guard let payload = FilePayload.parse(entry.content), let fileURL else { return false }
            guard payload.fileSize <= Self.maxPasteboardFileBytes,
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            else { return false }
            let ext = (payload.fileName as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            pasteboard.setItems([[type.identifier: data]], options: Self.writeOptions)
            lastKnownHash = payload.fileHash.lowercased()
        default:
            return false
        }
        noteOwnWrite(before: before)
        return true
    }

    func copyText(_ text: String) {
        let before = pasteboard.changeCount
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: Self.writeOptions)
        noteOwnWrite(before: before)
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
        DispatchQueue.main.async { [self] in
            let settled = pasteboard.changeCount
            ownChangeCount = settled
            seenChangeCount = settled
            onOwnWriteSettled?()
        }
    }
}
