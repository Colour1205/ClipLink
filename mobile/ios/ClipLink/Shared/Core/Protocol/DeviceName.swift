import Foundation

/// A device's display name as it travels in beacons, handshakes and pairing
/// codes. Every platform trims it and caps it at 64 characters before sending
/// it, and reads an absent or empty one as "unknown" - never as a reason to
/// reject the message that carried it.
public enum DeviceName {
    public static let maxLength = 64

    /// Trimmed and capped at 64 Unicode scalars; nil when nothing is left.
    /// Names from peers go through `sanitize`, which ends here.
    public static func clean(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.count > maxLength else { return trimmed }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(maxLength))
        return String(scalars)
    }

    /// The one gate for a name another device chose (beacon, handshake,
    /// pairing code, and what earlier builds stored from them). It controls
    /// every byte, so control characters and the invisible bidi/format ones
    /// are removed: they could split a row, or hide or reorder the id and
    /// address shown beside the name. Then it is trimmed and capped like our
    /// own. Nil when nothing is left. The same rule on every mobile port.
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !isHidden(scalar) {
            kept.append(scalar)
        }
        return clean(String(kept))
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, // C0, DEL, C1
             0x061C, 0x200E, 0x200F, // Arabic letter mark, LRM, RLM
             0x202A...0x202E, 0x2066...0x2069, // bidi embeddings, overrides, isolates
             0x200B...0x200D, 0xFEFF: // zero-width space / non-joiner / joiner, BOM
            return true
        default:
            return false
        }
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
        return sanitize(text)
    }
}
