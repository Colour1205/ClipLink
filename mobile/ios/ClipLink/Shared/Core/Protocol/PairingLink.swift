import Foundation

/// A pairing code as a link: `https://cliplink.uaena.io/pair/#<the pairing info>`.
///
/// The QR code carries this instead of the bare JSON, so the system camera or
/// any scanner app that reads it opens the ClipLink app if it is installed (the
/// app's Associated Domains claim /pair - see ClipLink.Release.entitlements) and
/// the website, with the downloads, if it is not. The pairing info - the same
/// {PublicKey, Address, Name} JSON as ever - is the part after the #, base64url
/// without padding. A fragment is never sent to a server, so the website never
/// sees a device's address.
///
/// Everything that takes pairing text in (the pair-by-address box, a pasted
/// code, a scan, a link that opened the app) accepts both the link and the bare
/// JSON: `PairingInfo.parse` unwraps. "Copy pairing info" still copies the bare
/// JSON. The same format is in every platform's app (Windows PairingLink.cs,
/// Android PairingLink.kt, HarmonyOS PairingLink.ets): change them together.
public enum PairingLink {
    public static let prefix = "https://cliplink.uaena.io/pair/#"

    /// http or https, with or without the slash after /pair; the host in any case.
    private static let pattern = try! NSRegularExpression(
        pattern: "^https?://cliplink\\.uaena\\.io/pair/?#(.+)$",
        options: [.caseInsensitive]
    )

    public static func wrap(_ pairingJSON: String) -> String {
        let base64 = Data(pairingJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return prefix + base64
    }

    /// Whether the text is a ClipLink pairing link (whatever its info turns out to hold).
    public static func isLink(_ text: String) -> Bool {
        info(in: text) != nil
    }

    /// The pairing info inside a link, or the text as it was: not a ClipLink
    /// pairing link, or one whose info cannot be read.
    public static func unwrap(_ text: String) -> String {
        guard let info = info(in: text) else { return text }
        var base64 = info
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        // String(data:encoding:) is nil for bytes that are not UTF-8.
        guard let data = Data(base64Encoded: base64),
              let json = String(data: data, encoding: .utf8),
              !json.isEmpty
        else { return text }
        return json
    }

    private static func info(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = pattern.firstMatch(in: trimmed, options: [], range: whole),
              let range = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[range])
    }
}
