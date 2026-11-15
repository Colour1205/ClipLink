import Foundation

// What a piece of content IS, whoever signed it and whenever: the "print" of
// design/sync-dedupe-spec.md, the same on every platform. Local only. Nothing
// here goes on the wire, and no entry is ever stored, kept or dropped because
// of its print: prints only decide what is sent, what goes on the clipboard
// and what the Synced list shows, so no peer, old or new, sees any difference.

public enum ContentPrint {
    /// Text as it is compared, never as it is sent, stored or put on the
    /// clipboard: every CRLF and lone CR becomes LF, then ONE trailing LF goes.
    /// Other apps rewrite line endings, and add or drop a final newline, when
    /// the same text is pasted and copied again.
    public static func norm(_ text: String) -> String {
        // On the UTF-8 bytes, not by Character (Swift sees "\r\n" as one), and
        // not as an array of scalars (four bytes each: a pasted log of a few
        // megabytes is compared on the main thread). CR and LF never occur
        // inside a multi-byte character.
        let utf8 = text.utf8
        guard utf8.contains(0x0D) else {
            // A lone LF is a Character of its own: dropLast takes just it.
            return utf8.last == 0x0A ? String(text.dropLast()) : text
        }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count)
        var afterCR = false
        for byte in utf8 {
            if byte == 0x0A, afterCR {
                afterCR = false
                continue
            }
            afterCR = byte == 0x0D
            out.append(afterCR ? 0x0A : byte)
        }
        if out.last == 0x0A { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    public static func text(_ text: String) -> String {
        "t:" + ContentHash.sha256Hex(Data(norm(text).utf8))
    }

    /// A picture's bytes: the base64 of an image entry, decoded.
    public static func image(_ bytes: Data) -> String {
        "i:" + ContentHash.sha256Hex(bytes)
    }

    /// Nil for anything but 64 hex digits. Either case gives the same print:
    /// iOS sends its hashes in upper case, the others in lower.
    public static func file(hash: String) -> String? {
        Wire.isSHA256Hex(hash) ? "f:" + hash.lowercased() : nil
    }

    /// What the single "last hash" of older builds held, carried over: it
    /// matches a capture whose RAW hash (of the exact text, of the picture's
    /// bytes, or the file's) is `hash`.
    public static func legacy(_ hash: String) -> String {
        "x:" + hash.lowercased()
    }

    /// The print of an entry's content; nil (which matches nothing) for a
    /// picture that does not decode, a file whose descriptor does not parse,
    /// and any other type. Decoding a picture costs: callers that ask often
    /// keep the result (SyncEngine.contentKey).
    public static func key(of entry: ClipboardEntry) -> String? {
        switch entry.type {
        case Wire.EntryType.text:
            return text(entry.content)
        case Wire.EntryType.image:
            return Data(base64Encoded: entry.content).map { image($0) }
        case Wire.EntryType.file:
            return FilePayload.parse(entry.content).flatMap { file(hash: $0.fileHash) }
        default:
            return nil
        }
    }

    /// The `count` items with the latest timestamps, newest first, and every
    /// item as old as the last of them as well: two at the same moment are
    /// both "the newest".
    public static func newest<T>(_ items: [T], count: Int, timestamp: (T) -> String) -> [T] {
        guard count > 0, !items.isEmpty else { return [] }
        let timed = items.map { (item: $0, ticks: DotNetTimestamp.epochTicks(timestamp($0)) ?? Int64.min) }
        let sorted = timed.enumerated()
            .sorted { $0.element.ticks != $1.element.ticks ? $0.element.ticks > $1.element.ticks : $0.offset < $1.offset }
            .map { $0.element }
        let boundary = sorted[min(count, sorted.count) - 1].ticks
        return sorted.filter { $0.ticks >= boundary }.map { $0.item }
    }
}

/// A capture's print, and the hash the single slot of older builds would have
/// held for it (see `ContentPrint.legacy`).
public struct CapturePrint: Equatable {
    public let print: String
    public let raw: String
    /// What the same content is known as in another form: a picture read off
    /// the clipboard as JPEG or HEIC and sent as PNG is also the file with
    /// those exact bytes ("f:" + their hash) - a received photo file, say, or
    /// the one the Share extension just sent.
    public var alternates: Set<String> = []

    public init(print: String, raw: String) {
        self.print = print
        self.raw = raw.lowercased()
    }

    /// Every print it goes by.
    public var all: Set<String> { alternates.union([self.print]) }

    public static func text(_ text: String) -> CapturePrint {
        CapturePrint(print: ContentPrint.text(text), raw: ContentHash.sha256Hex(Data(text.utf8)))
    }

    /// A picture is also the file with exactly its bytes.
    public static func image(_ bytes: Data) -> CapturePrint {
        let hash = ContentHash.sha256Hex(bytes)
        var capture = CapturePrint(print: "i:" + hash, raw: hash)
        capture.alternates = ["f:" + hash]
        return capture
    }

    /// `hash` is the file's SHA-256, any case.
    public static func file(hash: String) -> CapturePrint {
        CapturePrint(print: "f:" + hash.lowercased(), raw: hash)
    }
}

/// What this device believes is on its clipboard because of ClipLink: the
/// last thing it wrote there, or the last capture it sent or found already
/// synced. Kept until replaced - there is no timer, and a stale record can
/// only hold back content equal to what it names.
public struct LastWrite: Equatable {
    public var prints: Set<String>

    public init(prints: Set<String> = []) {
        self.prints = prints
    }

    public func contains(_ capture: CapturePrint) -> Bool {
        !prints.isDisjoint(with: capture.all) || prints.contains(ContentPrint.legacy(capture.raw))
    }

    /// `{"prints":[...]}`.
    public func jsonString() -> String {
        WireJSON.string(["prints": prints.sorted()])
    }

    /// The stored record, else the hash an older build stored in its place
    /// (`legacyHash`), else nothing.
    public static func load(json: String?, legacyHash: String?) -> LastWrite {
        if let json, let object = WireJSON.object(json), let prints = object["prints"] as? [Any] {
            return LastWrite(prints: Set(prints.compactMap { $0 as? String }))
        }
        if let legacyHash, !legacyHash.isEmpty { return LastWrite(prints: [ContentPrint.legacy(legacyHash)]) }
        return LastWrite()
    }
}

/// Whether something read off the clipboard is new, or is already what every
/// device has (spec 1.3).
public enum CaptureVerdict: Equatable {
    case new
    case already
}

public enum CaptureMode: Equatable {
    /// On its own: the capture as the app opens.
    case auto
    /// A Paste button or control the user tapped.
    case manual
}

public enum CaptureCheck {
    /// Before reading, when the clipboard still holds ClipLink's own last
    /// write: nothing to read in auto mode. In manual mode only while that
    /// content is still in the history - a Paste after the user deleted it is
    /// a deliberate re-send. Nil: read and go on (`classify`).
    public static func ownWrite(mode: CaptureMode, lastWrite: LastWrite, historyKeys: Set<String>) -> CaptureVerdict? {
        if mode == .auto || !lastWrite.prints.isDisjoint(with: historyKeys) { return .already }
        return nil
    }

    /// After reading. What ClipLink last wrote or classified stays held back
    /// (in manual mode only while it is still in the history), and so does
    /// whatever the newest entry already is. Re-copying an older item is NEW:
    /// that is how the user gets it back onto the other devices.
    public static func classify(_ capture: CapturePrint, mode: CaptureMode, lastWrite: LastWrite,
                                historyKeys: Set<String>, newestKeys: Set<String>) -> CaptureVerdict {
        let prints = capture.all
        if lastWrite.contains(capture), mode == .auto || !historyKeys.isDisjoint(with: prints) { return .already }
        if !newestKeys.isDisjoint(with: prints) { return .already }
        return .new
    }
}
