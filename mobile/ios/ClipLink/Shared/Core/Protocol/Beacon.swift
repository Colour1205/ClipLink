import Foundation

/// The UDP presence beacon: `{tcpPort}:{deviceId}:{proof}:{address}:{pairing}`,
/// `-` for an absent field, UTF-8, one datagram. Mirrors Discovery.cs,
/// Discovery.kt and Discovery.ets exactly.
///
/// Splitting on `:` is safe only because device IDs and proofs are base64
/// (no colon in the alphabet). `address` is an IPv4 address in practice;
/// an IPv6 literal would break every implementation's parser, so this node
/// never advertises one.
public struct Beacon: Equatable {
    public var tcpPort: Int
    public var deviceId: String
    /// base64 HMAC-SHA256(passcodeKey, deviceId), or nil when no passcode is set.
    public var proof: String?
    /// The sender's self-advertised off-LAN (Tailscale) address, if any.
    public var address: String?
    /// True only while the sender's own pairing screen is open.
    public var pairing: Bool
    /// Where the datagram actually came from - the address to dial on a LAN.
    public var senderIP: String

    public init(tcpPort: Int, deviceId: String, proof: String?, address: String?, pairing: Bool, senderIP: String) {
        self.tcpPort = tcpPort
        self.deviceId = deviceId
        self.proof = proof
        self.address = address
        self.pairing = pairing
        self.senderIP = senderIP
    }

    public static func build(tcpPort: Int, deviceId: String, proof: String?, address: String?, pairing: Bool) -> String {
        func field(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "-" }
            return value
        }
        return "\(tcpPort):\(deviceId):\(field(proof)):\(field(address)):\(pairing ? "1" : "-")"
    }

    /// Nil for anything that isn't a beacon; tolerates the legacy three-field form.
    public static func parse(_ text: String, senderIP: String) -> Beacon? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let port = Int(parts[0]), (1...65535).contains(port), !parts[1].isEmpty else { return nil }
        func optional(_ index: Int) -> String? {
            guard index < parts.count else { return nil }
            let value = parts[index]
            return value == "-" || value.isEmpty ? nil : value
        }
        return Beacon(
            tcpPort: port,
            deviceId: parts[1],
            proof: optional(2),
            address: optional(3),
            pairing: parts.count > 4 && parts[4] == "1",
            senderIP: senderIP
        )
    }
}
