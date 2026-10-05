import Foundation

// Wire message shapes. Every key is PascalCase because that is what
// System.Text.Json emits on the Windows daemon with default settings, and
// its deserializer is case-SENSITIVE: a camelCase key doesn't error there,
// the field just reads back as null. Android (org.json) and HarmonyOS parse
// the same literal keys.
//
// Parsing is deliberately lenient in the same way Android's optString() is -
// a missing optional field falls back to a default, a missing required one
// rejects the whole message - because a hostile or older peer controls every
// byte of it and none of it may crash the app.

// MARK: - JSON helpers

public enum WireJSON {
    /// Compact single-line JSON. Slashes are left unescaped (Foundation escapes
    /// them by default); every parser in the mesh accepts either, but unescaped
    /// output is what the other three platforms produce.
    public static func string(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    public static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func array(_ text: String) -> [Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] { return array }
        // Foundation rejects the whole document over one lone-surrogate escape,
        // which .NET can emit for broken UTF-16 clipboard text. Neutralise those
        // escapes and retry: the damaged entry then fails its signature check on
        // its own, and the rest of the batch survives.
        let repaired = replacingLoneSurrogateEscapes(text)
        guard repaired != text, let data2 = repaired.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data2)) as? [Any]
    }

    static func replacingLoneSurrogateEscapes(_ text: String) -> String {
        let pattern = #"\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})|(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}"#
        return text.replacingOccurrences(of: pattern, with: "\\\\uFFFD", options: .regularExpression)
    }

    /// `optString` semantics: a JSON string, else nil (NSNull, numbers, absent).
    static func str(_ dict: [String: Any], _ key: String) -> String? {
        dict[key] as? String
    }

    static func int64(_ dict: [String: Any], _ key: String) -> Int64? {
        (dict[key] as? NSNumber)?.int64Value
    }

    static func bool(_ dict: [String: Any], _ key: String) -> Bool? {
        (dict[key] as? NSNumber)?.boolValue
    }
}

// MARK: - Envelope

/// `{Type, Payload}` - Payload is itself a JSON *string*, never a nested object.
public struct Envelope: Equatable {
    public var type: String
    public var payload: String

    public init(type: String, payload: String) {
        self.type = type
        self.payload = payload
    }

    public func jsonString() -> String {
        WireJSON.string(["Type": type, "Payload": payload])
    }

    public static func parse(_ json: String) -> Envelope? {
        guard let obj = WireJSON.object(json),
              let type = WireJSON.str(obj, "Type"), !type.isEmpty
        else { return nil }
        return Envelope(type: type, payload: WireJSON.str(obj, "Payload") ?? "")
    }
}

// MARK: - ClipboardEntry

/// One clipboard item on the wire. Mirrors ClipboardEntry.cs.
///
/// `timestamp` is an OPAQUE STRING and stays one. The signature covers
/// .NET's `Timestamp.ToString("o")` text verbatim, so it is never parsed
/// into a Date and re-rendered on the signing/verifying path - see
/// `DotNetTimestamp` for the one principled exception (canonicalising a
/// System.Text.Json-trimmed fraction back to seven digits).
public struct ClipboardEntry: Equatable, Hashable {
    public var content: String
    public var type: String
    public var deviceId: String
    public var timestamp: String
    public var signature: String?

    public init(content: String, type: String, deviceId: String, timestamp: String, signature: String? = nil) {
        self.content = content
        self.type = type
        self.deviceId = deviceId
        self.timestamp = timestamp
        self.signature = signature
    }

    public func jsonObject() -> [String: Any] {
        [
            "Content": content,
            "Type": type,
            "DeviceId": deviceId,
            "Timestamp": timestamp,
            "Signature": signature.map { $0 as Any } ?? NSNull(),
        ]
    }

    public func jsonString() -> String { WireJSON.string(jsonObject()) }

    public static func from(_ obj: [String: Any]) -> ClipboardEntry? {
        let content = WireJSON.str(obj, "Content") ?? ""
        guard let type = WireJSON.str(obj, "Type"), !type.isEmpty,
              let deviceId = WireJSON.str(obj, "DeviceId"), !deviceId.isEmpty,
              let timestamp = WireJSON.str(obj, "Timestamp"), !timestamp.isEmpty
        else { return nil }
        let signature = WireJSON.str(obj, "Signature").flatMap { $0.isEmpty ? nil : $0 }
        return ClipboardEntry(content: content, type: type, deviceId: deviceId, timestamp: timestamp, signature: signature)
    }

    public static func parse(_ json: String) -> ClipboardEntry? {
        WireJSON.object(json).flatMap(from)
    }

    /// Nil only when the payload isn't a JSON array at all. Individual
    /// malformed elements are skipped, keeping the rest of the batch.
    public static func parseList(_ json: String) -> [ClipboardEntry]? {
        guard let array = WireJSON.array(json) else { return nil }
        return array.compactMap { ($0 as? [String: Any]).flatMap(from) }
    }

    public static func listJSONString(_ entries: [ClipboardEntry]) -> String {
        WireJSON.string(entries.map { $0.jsonObject() })
    }
}

// MARK: - File transfer

/// What `ClipboardEntry.Content` holds when `Type == "file"` - a descriptor,
/// never the bytes. Mirrors FilePayload.cs.
///
/// `fileHash` is SHA-256 hex. Windows emits UPPERCASE (`Convert.ToHexString`),
/// Android and HarmonyOS lowercase; compare case-insensitively and always
/// echo a peer's own spelling back to it in `file_chunk` replies.
public struct FilePayload: Equatable {
    public var fileName: String
    public var fileHash: String
    public var fileSize: Int64

    public init(fileName: String, fileHash: String, fileSize: Int64) {
        self.fileName = fileName
        self.fileHash = fileHash
        self.fileSize = fileSize
    }

    public func jsonString() -> String {
        WireJSON.string(["FileName": fileName, "FileHash": fileHash, "FileSize": NSNumber(value: fileSize)])
    }

    /// The sender's FileName comes out through `FileStore.sanitize`, as
    /// Android's parser and HarmonyOS' views have it: it is shown as the
    /// item's title, where a right-to-left override would make
    /// "invoice\u{202E}txt.exe" read as "invoiceexe.txt". Only the parsed
    /// copy changes - the signed entry is stored and relayed as it arrived.
    public static func parse(_ json: String) -> FilePayload? {
        guard let obj = WireJSON.object(json),
              let hash = WireJSON.str(obj, "FileHash"), Wire.isSHA256Hex(hash)
        else { return nil }
        let name = FileStore.sanitize(WireJSON.str(obj, "FileName") ?? "")
        return FilePayload(fileName: name, fileHash: hash, fileSize: WireJSON.int64(obj, "FileSize") ?? 0)
    }
}

public struct FileChunkMessage: Equatable {
    public var fileHash: String
    public var chunkIndex: Int
    public var isLast: Bool
    public var dataBase64: String

    public init(fileHash: String, chunkIndex: Int, isLast: Bool, dataBase64: String) {
        self.fileHash = fileHash
        self.chunkIndex = chunkIndex
        self.isLast = isLast
        self.dataBase64 = dataBase64
    }

    public func jsonString() -> String {
        WireJSON.string([
            "FileHash": fileHash,
            "ChunkIndex": NSNumber(value: chunkIndex),
            "IsLast": isLast,
            "DataBase64": dataBase64,
        ])
    }

    public static func parse(_ json: String) -> FileChunkMessage? {
        guard let obj = WireJSON.object(json),
              let hash = WireJSON.str(obj, "FileHash"), Wire.isSHA256Hex(hash)
        else { return nil }
        return FileChunkMessage(
            fileHash: hash,
            chunkIndex: Int(WireJSON.int64(obj, "ChunkIndex") ?? 0),
            isLast: WireJSON.bool(obj, "IsLast") ?? false,
            dataBase64: WireJSON.str(obj, "DataBase64") ?? ""
        )
    }
}

/// "Does anyone have this file?" - sent to every connected peer.
public struct FileRequestMessage: Equatable {
    public var fileHash: String

    public init(fileHash: String) { self.fileHash = fileHash }

    public func jsonString() -> String { WireJSON.string(["FileHash": fileHash]) }

    public static func parse(_ json: String) -> FileRequestMessage? {
        guard let obj = WireJSON.object(json),
              let hash = WireJSON.str(obj, "FileHash"), Wire.isSHA256Hex(hash)
        else { return nil }
        return FileRequestMessage(fileHash: hash)
    }
}

// MARK: - Handshake

/// The one unencrypted line each side writes before anything else. Mirrors
/// HandshakeMessage.cs. Keys are base64 X.509 SubjectPublicKeyInfo DER; the
/// signature is base64 raw `r||s` over the ephemeral key's SPKI bytes.
public struct HandshakeMessage: Equatable {
    public var ephemeralPublicKey: String
    public var identityPublicKey: String
    public var signature: String
    public var passphraseProof: String?
    /// The sender's display name (`DeviceName`, optional - older builds
    /// don't send it). Not covered by the signature, like the proof.
    public var deviceName: String?

    public init(ephemeralPublicKey: String, identityPublicKey: String, signature: String, passphraseProof: String?, deviceName: String? = nil) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.identityPublicKey = identityPublicKey
        self.signature = signature
        self.passphraseProof = passphraseProof
        self.deviceName = deviceName
    }

    public func jsonString() -> String {
        var obj: [String: Any] = [
            "EphemeralPublicKey": ephemeralPublicKey,
            "IdentityPublicKey": identityPublicKey,
            "Signature": signature,
        ]
        if let passphraseProof { obj["PassphraseProof"] = passphraseProof }
        if let name = DeviceName.clean(deviceName) { obj["DeviceName"] = name }
        return WireJSON.string(obj)
    }

    public static func parse(_ json: String) -> HandshakeMessage? {
        guard let obj = WireJSON.object(json),
              let ephemeral = WireJSON.str(obj, "EphemeralPublicKey"), !ephemeral.isEmpty,
              let identity = WireJSON.str(obj, "IdentityPublicKey"), !identity.isEmpty,
              let signature = WireJSON.str(obj, "Signature"), !signature.isEmpty
        else { return nil }
        let proof = WireJSON.str(obj, "PassphraseProof").flatMap { $0.isEmpty ? nil : $0 }
        return HandshakeMessage(
            ephemeralPublicKey: ephemeral,
            identityPublicKey: identity,
            signature: signature,
            passphraseProof: proof,
            deviceName: DeviceName.sanitize(WireJSON.str(obj, "DeviceName"))
        )
    }
}

// MARK: - Pairing payload

/// What a pairing QR code / "copy pairing info" carries: `{PublicKey, Address}`,
/// plus an optional `Name` (the device's display name).
/// Windows serializes a null Address as `"Address":null`; Android omits it.
public struct PairingInfo: Equatable {
    public var publicKey: String
    public var address: String?
    public var name: String?

    public init(publicKey: String, address: String?, name: String? = nil) {
        self.publicKey = publicKey
        self.address = address
        self.name = name
    }

    public func jsonString() -> String {
        var obj: [String: Any] = ["PublicKey": publicKey]
        if let address, !address.isEmpty { obj["Address"] = address }
        if let name = DeviceName.clean(name) { obj["Name"] = name }
        return WireJSON.string(obj)
    }

    /// Only the JSON pairing payload - nil for anything else, including a bare
    /// address (which callers treat as an address to dial, never as a key).
    public static func parse(_ raw: String) -> PairingInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = WireJSON.object(trimmed),
              let key = WireJSON.str(obj, "PublicKey"), !key.isEmpty
        else { return nil }
        let address = WireJSON.str(obj, "Address")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingInfo(
            publicKey: key,
            address: (address?.isEmpty ?? true) ? nil : address,
            name: DeviceName.sanitize(WireJSON.str(obj, "Name"))
        )
    }
}
