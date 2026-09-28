import Foundation

/// A device's display name as it travels in beacons, handshakes and pairing
/// codes. Every platform trims it and caps it at 64 characters before sending
/// it, and reads an absent or empty one as "unknown" - never as a reason to
/// reject the message that carried it.
public enum DeviceName {
    public static let maxLength = 64

    /// Trimmed and capped at 64 Unicode scalars; nil when nothing is left.
    /// Applied to names from peers too: they control every byte.
    public static func clean(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.count > maxLength else { return trimmed }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(maxLength))
        return String(scalars)
    }

    /// The beacon's sixth field: standard (padded) base64 of the UTF-8 name.
    /// Base64 has no `:` in its alphabet, so the colon split stays safe.
    static func beaconField(_ name: String?) -> String? {
        clean(name).map { Data($0.utf8).base64EncodedString() }
    }

    /// Nil for an absent field, bad base64 or bad UTF-8. Stray whitespace
    /// around the field is tolerated, as Android's and Windows' decoders do.
    static func fromBeaconField(_ field: String?) -> String? {
        guard let field, let data = Data(base64Encoded: field.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        // Decoding repairs bad sequences to U+FFFD; the bytes then no longer
        // round-trip, which is how invalid UTF-8 is spotted.
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { return nil }
        return clean(text)
    }
}
