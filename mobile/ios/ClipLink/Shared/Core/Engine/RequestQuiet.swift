import Foundation

/// Devices whose pairing requests are held back for a while.
///
/// A device this one does not trust still gets here whenever the other end
/// trusts this one and dials it: the other end redials for as long as it keeps
/// its trust record, and each connection used to raise a new pairing request. So a
/// request that was ignored, or a device that was removed, came back again and
/// again - the same device, a prompt every few minutes, for ever.
///
/// The cure is in two parts. Removing a device sends it an "unpair" message over the
/// live link, so the other end drops its trust record and stops redialling
/// (`SyncEngine.handleMessage`). And this: a device whose request was ignored, or
/// that was removed, is quiet for a while - its connection is closed without a
/// prompt - which covers a peer that was offline when the message went, or is a
/// build that ignores it. (A link held for a request cannot send anything until it
/// is accepted, so an ignored request is only closed and quieted here.) Blocking is
/// the permanent version (`BlockStore`).
///
/// Lifted early by what asks for it: opening the pairing screen, pairing by address
/// or QR code, trusting the device. In memory only: a restart starts fresh. The same
/// rule is in every platform's engine (ClipLinkEngine.cs, ClipLinkEngine.kt, Index.ets):
/// change them together.
struct RequestQuiet {
    enum State: Equatable { case notQuiet, ignored, removed }

    /// After the user tapped Ignore on its request. Short: Ignore is "not this one", and a
    /// real request from it after that - the user trusting this device from there - must
    /// get through.
    static let afterIgnored: TimeInterval = 2 * 60
    /// After the user removed a device that could not be told (it was not connected).
    static let afterRemoved: TimeInterval = 6 * 60 * 60

    private struct Entry {
        var id: String
        var until: Date
        var removed: Bool
    }

    private var entries: [Entry] = []

    /// `id` is quiet for `span`; `removed` says why (removed, as against ignored).
    mutating func quiet(_ id: String, for span: TimeInterval, removed: Bool = false, now: Date = Date()) {
        guard !id.isEmpty else { return }
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, until: now.addingTimeInterval(span), removed: removed))
    }

    /// Whether `id` is quiet, and if so whether it was removed (as against ignored).
    mutating func state(of id: String, now: Date = Date()) -> State {
        entries.removeAll { $0.until <= now } // over
        guard let entry = entries.first(where: { $0.id == id }) else { return .notQuiet }
        return entry.removed ? .removed : .ignored
    }

    mutating func release(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    mutating func clear() {
        entries.removeAll()
    }
}
