import Foundation

/// Who dials whom when two devices can both see each other.
///
/// Every platform runs the same rule on beacons and on stored-address
/// reconnects: dial a peer only when `peerId < ownId` ORDINALLY. So the device
/// with the LARGER id dials and the smaller one waits to be dialled; exactly
/// one side dials and duplicate sockets are rare.
///
/// Ordinal means UTF-16 code-unit order (`string.CompareOrdinal`, Kotlin's and
/// JavaScript's `<`). Device IDs are ASCII base64, where that equals UTF-8 byte
/// order - compared here explicitly on bytes rather than trusting Swift's
/// `String <`, which is Unicode-aware and not documented as ordinal.
public enum DeviceOrder {
    public static func isOrdinallyLess(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// True when THIS device is the one that should dial `peerId`.
    public static func shouldDial(peerId: String, ownId: String) -> Bool {
        !ownId.isEmpty && isOrdinallyLess(peerId, ownId)
    }
}
