import Foundation

/// .NET round-trip ("o") timestamps, the text every entry signature covers.
///
/// Two facts drive everything here:
///
/// 1. SigningService.cs signs `Timestamp.ToString("o")`: exactly seven
///    fractional digits, e.g. `2026-09-26T12:34:56.1234500Z`.
/// 2. System.Text.Json SERIALIZES that same DateTime with trailing fractional
///    zeros trimmed: `2026-09-26T12:34:56.12345Z` (and no fraction at all when
///    it is zero). Verified against the real serializer.
///
/// So the text a Windows peer puts on the wire is not always the text it
/// signed - about one entry in ten, and every entry it relays in a
/// `history_batch`. A verifier that treats the wire text as opaque (as the
/// Android and HarmonyOS ports do) rejects those genuine entries. This node
/// verifies the wire text first and falls back to `canonical(_:)`, which
/// re-renders it exactly the way .NET's "o" would after parsing.
public enum DotNetTimestamp {

    private static let secondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// A fresh UTC timestamp in .NET's `"o"` shape: `yyyy-MM-ddTHH:mm:ss.fffffffZ`.
    ///
    /// The last fractional digit is forced non-zero (a shift of at most 100ns).
    /// That makes the text immune to System.Text.Json's trailing-zero trimming,
    /// so when a Windows node relays this entry in its history the text stays
    /// byte-identical and even peers that verify the raw text (Android,
    /// HarmonyOS) still accept it.
    public static func now(_ date: Date = Date()) -> String {
        let interval = date.timeIntervalSince1970
        let wholeSeconds = interval.rounded(.down)
        var ticks = Int(((interval - wholeSeconds) * 10_000_000).rounded(.down))
        ticks = min(max(ticks, 0), 9_999_999)
        if ticks % 10 == 0 { ticks += 1 }
        let seconds = secondsFormatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        let fraction = String(ticks)
        return "\(seconds).\(String(repeating: "0", count: 7 - fraction.count))\(fraction)Z"
    }

    private struct Parts {
        var dateTime: Substring   // yyyy-MM-ddTHH:mm:ss
        var fraction: Substring?  // 1...7 digits, nil when absent
        var suffix: Substring     // "Z", "+hh:mm", "-hh:mm" or "" (DateTimeKind.Unspecified)
    }

    private static func split(_ s: String) -> Parts? {
        // yyyy-MM-ddTHH:mm:ss is 19 ASCII characters.
        guard s.utf8.count >= 19, s.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        let dateTime = s.prefix(19)
        guard isDateTime(dateTime) else { return nil }
        var rest = s.dropFirst(19)
        var fraction: Substring?
        if rest.first == "." {
            rest = rest.dropFirst()
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...7).contains(digits.count) else { return nil }
            fraction = digits
            rest = rest.dropFirst(digits.count)
        }
        guard rest.isEmpty || rest == "Z" || isOffset(rest) else { return nil }
        return Parts(dateTime: dateTime, fraction: fraction, suffix: rest)
    }

    private static func isDateTime(_ s: Substring) -> Bool {
        let chars = Array(s.utf8)
        let pattern = Array("dddd-dd-ddTdd:dd:dd".utf8)
        guard chars.count == pattern.count else { return false }
        for (c, p) in zip(chars, pattern) {
            if p == UInt8(ascii: "d") {
                if !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { return false }
            } else if c != p {
                return false
            }
        }
        return true
    }

    private static func isOffset(_ s: Substring) -> Bool {
        let chars = Array(s.utf8)
        guard chars.count == 6, chars[0] == UInt8(ascii: "+") || chars[0] == UInt8(ascii: "-"), chars[3] == UInt8(ascii: ":") else { return false }
        return [1, 2, 4, 5].allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(chars[$0]) }
    }

    /// The exact text .NET's `"o"` would produce for this timestamp after
    /// parsing it: fraction right-padded to seven digits (`.0000000` when
    /// absent), offset kept verbatim. Nil for anything that isn't an ISO-8601
    /// timestamp .NET could have written.
    public static func canonical(_ s: String) -> String? {
        guard let parts = split(s) else { return nil }
        let fraction = String(parts.fraction ?? "")
        return "\(parts.dateTime).\(fraction)\(String(repeating: "0", count: 7 - fraction.count))\(parts.suffix)"
    }

    /// 100ns ticks since the Unix epoch, for ordering only (never for
    /// signing). Handles trimmed fractions and explicit offsets, which plain
    /// string comparison gets wrong: ".12345Z" sorts after ".1234567Z".
    public static func epochTicks(_ s: String) -> Int64? {
        guard let parts = split(s),
              let base = secondsFormatter.date(from: String(parts.dateTime))
        else { return nil }
        var ticks = Int64(base.timeIntervalSince1970) * 10_000_000
        if let fraction = parts.fraction {
            let padded = String(fraction) + String(repeating: "0", count: 7 - fraction.count)
            ticks += Int64(padded) ?? 0
        }
        if parts.suffix.count == 6 {
            let chars = Array(parts.suffix)
            let hours = Int64(String(chars[1...2])) ?? 0
            let minutes = Int64(String(chars[4...5])) ?? 0
            let offset = (hours * 3600 + minutes * 60) * 10_000_000
            // "+02:00" means local = UTC + 2h, so UTC = local - offset.
            ticks += chars[0] == "+" ? -offset : offset
        }
        return ticks
    }

    /// Wall-clock Date for display.
    public static func date(_ s: String) -> Date? {
        epochTicks(s).map { Date(timeIntervalSince1970: TimeInterval($0) / 10_000_000) }
    }

    /// Chronological comparison, unparseable timestamps first, ties broken by text.
    public static func isEarlier(_ a: String, than b: String) -> Bool {
        let ta = epochTicks(a) ?? Int64.min
        let tb = epochTicks(b) ?? Int64.min
        return ta != tb ? ta < tb : a < b
    }
}
