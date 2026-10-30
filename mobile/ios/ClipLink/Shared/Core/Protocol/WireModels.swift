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

// MARK: - History head

/// The small message that goes in front of a big history_batch:
/// `{"Newest": <entry>, "Keys": ["<key>", ...]}`. `newest` is the sender's most
/// recent entry; `keys` has one key (`DeletedStore.key(of:)`, the signature) for
/// every entry of the batch that follows, newest first. A peer that does not
/// know the type skips it, and the batch itself is unchanged.
public struct HistoryHead: Equatable {
    public var newest: ClipboardEntry
    public var keys: [String]

    public init(newest: ClipboardEntry, keys: [String]) {
        self.newest = newest
        self.keys = keys
    }

    /// The head for a history of `newestFirst`, or nil when the batch would
    /// hold fewer than 2 entries (nothing to stack, so no head).
    public static func make(newestFirst entries: [ClipboardEntry]) -> HistoryHead? {
        guard entries.count >= 2, let newest = entries.first else { return nil }
        return HistoryHead(newest: newest, keys: entries.map(DeletedStore.key(of:)))
    }

    public func jsonString() -> String {
        let object: [String: Any] = ["Newest": newest.jsonObject(), "Keys": keys]
        return WireJSON.string(object)
    }

    /// Nil when Newest is missing or malformed. A key that is not a string is
    /// skipped, like a malformed element of a batch.
    public static func parse(_ json: String) -> HistoryHead? {
        guard let obj = WireJSON.object(json),
              let newestObject = obj["Newest"] as? [String: Any],
              let newest = ClipboardEntry.from(newestObject)
        else { return nil }
        let keys = (obj["Keys"] as? [Any])?.compactMap { $0 as? String } ?? []
        return HistoryHead(newest: newest, keys: keys)
    }
}

// MARK: - History head (version 2)

/// The version 2 history_head: `{"Keys": [...], "Times": [...], "Deleted": [...]}`.
/// `keys` is the key (`DeletedStore.key(of:)`) of every entry of the sender's
/// history, newest first, at most 25; `times` the same entries' timestamps in
/// Unix milliseconds, in the same order (it may be missing, or the wrong
/// length: a receiver then cannot rank the keys by age); `deleted` the sender's
/// latest tombstone keys, most recently deleted first, at most 500. There is no
/// `Newest` in it: the peer may already have that entry, and a big one is not
/// sent twice. Sent on every version 2 connection, even with nothing in it.
public struct HistoryHeadV2: Equatable {
    public var keys: [String]
    public var times: [Int64]
    public var deleted: [String]

    public init(keys: [String], times: [Int64], deleted: [String]) {
        self.keys = keys
        self.times = times
        self.deleted = deleted
    }

    /// The head for a history of `newestFirst` (cut to the 25 it holds) and the
    /// sender's tombstone keys, most recently deleted first.
    public static func make(newestFirst entries: [ClipboardEntry], deleted: [String]) -> HistoryHeadV2 {
        let shown = Array(entries.prefix(Wire.historyCap))
        return HistoryHeadV2(
            keys: shown.map(DeletedStore.key(of:)),
            times: shown.map(unixMilliseconds(of:)),
            deleted: Array(deleted.prefix(Wire.maxHeadDeleted))
        )
    }

    /// An entry's timestamp as Unix milliseconds (0 when it does not parse).
    public static func unixMilliseconds(of entry: ClipboardEntry) -> Int64 {
        (DotNetTimestamp.epochTicks(entry.timestamp) ?? 0) / 10_000
    }

    public func jsonString() -> String {
        let object: [String: Any] = [
            "Keys": keys,
            "Times": times.map { NSNumber(value: $0) },
            "Deleted": deleted,
        ]
        return WireJSON.string(object)
    }

    /// Nil when the payload is not a JSON object. Everything in it is optional,
    /// and unknown keys (a version 1.5 head's `Newest`) are skipped. A key that
    /// is not a string, is empty, or is longer than `Wire.maxKeyLength`, is skipped; more
    /// than 25 keys or 500 deleted ones are cut. `times` is kept only when it was
    /// as long as `Keys` and held nothing but numbers - otherwise it is empty.
    public static func parse(_ json: String) -> HistoryHeadV2? {
        guard let obj = WireJSON.object(json) else { return nil }
        let rawKeys = (obj["Keys"] as? [Any]) ?? []
        var rawTimes: [Int64]?
        if let list = obj["Times"] as? [Any], list.count == rawKeys.count {
            let numbers = list.compactMap { ($0 as? NSNumber)?.int64Value }
            if numbers.count == list.count { rawTimes = numbers }
        }
        var keys: [String] = []
        var times: [Int64] = []
        for (index, raw) in rawKeys.enumerated() {
            guard keys.count < Wire.historyCap else { break }
            guard let key = raw as? String, !key.isEmpty, key.count <= Wire.maxKeyLength else { continue }
            keys.append(key)
            if let rawTimes { times.append(rawTimes[index]) }
        }
        return HistoryHeadV2(keys: keys, times: times, deleted: KeysMessage.validKeys(obj["Deleted"], limit: Wire.maxHeadDeleted))
    }
}

/// `{"Keys": [...]}`: the payload of both history_request ("send me these") and
/// delete ("these were deleted"). At most 100 keys; a sender with more splits
/// them over several messages.
public struct KeysMessage: Equatable {
    public var keys: [String]

    public init(keys: [String]) { self.keys = keys }

    public func jsonString() -> String { WireJSON.string(["Keys": keys]) }

    /// Nil when the payload is not a JSON object. The strings among its keys, the
    /// first 100 of them; anything else (an empty key, and a key over 2048 characters) is skipped.
    public static func parse(_ json: String) -> KeysMessage? {
        guard let obj = WireJSON.object(json) else { return nil }
        return KeysMessage(keys: validKeys(obj["Keys"], limit: Wire.maxKeysPerMessage))
    }

    /// `keys` cut into messages of at most 100.
    public static func messages(for keys: [String]) -> [KeysMessage] {
        stride(from: 0, to: keys.count, by: Wire.maxKeysPerMessage).map { start in
            KeysMessage(keys: Array(keys[start..<min(start + Wire.maxKeysPerMessage, keys.count)]))
        }
    }

    /// The first `limit` usable keys of a JSON array.
    static func validKeys(_ raw: Any?, limit: Int) -> [String] {
        var keys: [String] = []
        for element in (raw as? [Any]) ?? [] {
            guard keys.count < limit else { break }
            if let key = element as? String, !key.isEmpty, key.count <= Wire.maxKeyLength { keys.append(key) }
        }
        return keys
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
    /// The sync version the sender speaks (`Protocol`, optional - builds
    /// before version 2 don't send it; see `Wire.protocolVersion`). Not signed
    /// either: a man in the middle who strips it only forces version 1, the
    /// safe fallback, and one who adds it gets nothing a peer would not
    /// answer anyway - every message is still encrypted and checked.
    public var protocolVersion: Int?

    public init(ephemeralPublicKey: String, identityPublicKey: String, signature: String, passphraseProof: String?, deviceName: String? = nil, protocolVersion: Int? = nil) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.identityPublicKey = identityPublicKey
        self.signature = signature
        self.passphraseProof = passphraseProof
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
    }

    public func jsonString() -> String {
        var obj: [String: Any] = [
            "EphemeralPublicKey": ephemeralPublicKey,
            "IdentityPublicKey": identityPublicKey,
            "Signature": signature,
        ]
        if let passphraseProof { obj["PassphraseProof"] = passphraseProof }
        if let name = DeviceName.clean(deviceName) { obj["DeviceName"] = name }
        if let protocolVersion { obj["Protocol"] = NSNumber(value: protocolVersion) }
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
            deviceName: DeviceName.sanitize(WireJSON.str(obj, "DeviceName")),
            // A number, else nothing: absent, null and text all mean version 1.
            protocolVersion: WireJSON.int64(obj, "Protocol").map { Int(clamping: $0) }
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
    /// address (which callers treat as an address to dial, never as a key). The
    /// payload may come wrapped as a pairing link (what the QR code carries,
    /// see `PairingLink`).
    public static func parse(_ raw: String) -> PairingInfo? {
        let trimmed = PairingLink.unwrap(raw).trimmingCharacters(in: .whitespacesAndNewlines)
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
