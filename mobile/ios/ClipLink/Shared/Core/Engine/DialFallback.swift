import Foundation

/// Trusting a device is one-sided: it only decides whether THIS device accepts it. To keep two
/// devices that hear each other from opening two connections, only one of them dials - the one
/// whose key sorts after the other's. When both trust each other that is fine. But when only one
/// does - the user just tapped Trust here, and the other device has not been asked yet - and
/// the other's key is the larger, nobody dials: the other never trusts this device, so it does not
/// dial, and this one waits for it to. The pairing request never reaches the other device.
///
/// So a trusted device that should have dialled this one, but has not connected after a few
/// seconds, is dialled by this one after all (and again every half minute while it stays
/// unconnected). If it does trust this device it has long since connected and this never fires; if
/// it does not, the dial is what raises the pairing request there. The same rule is in every
/// platform's engine: change them together.
struct DialFallback {
    /// How long a trusted device that should dial this one is given to do so.
    static let wait: TimeInterval = 8
    /// How often it is dialled after that while it stays unconnected.
    static let every: TimeInterval = 30

    private var since: [String: Date] = [:]
    private var lastDial: [String: Date] = [:]

    /// True when a trusted device that should have dialled this one has waited long
    /// enough, and was not dialled in the last `every`. Counts the call as the dial.
    mutating func due(_ id: String, now: Date = Date()) -> Bool {
        let first = since[id] ?? now
        since[id] = first
        guard now.timeIntervalSince(first) >= Self.wait else { return false }
        if let last = lastDial[id], now.timeIntervalSince(last) < Self.every { return false }
        lastDial[id] = now
        return true
    }

    /// It is connected (or gone): start counting again next time.
    mutating func connected(_ id: String) {
        since[id] = nil
        lastDial[id] = nil
    }
}
