import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Identity

/// This device's long-lived P-256 signing identity. The device ID *is* the
/// public key: base64 of its X.509 SubjectPublicKeyInfo DER, byte-identical to
/// `ECDsa.ExportSubjectPublicKeyInfo()` on Windows, the Android Keystore's
/// `publicKey.encoded` and HUKS' export - IDs are compared as plain strings.
public protocol IdentitySigner: AnyObject {
    /// Base64 SPKI DER - this device's ID on the wire.
    var publicKeyBase64: String { get }
    /// Raw 64-byte `r || s` ECDSA-P256-SHA256 signature (IEEE P1363) - the wire
    /// format, which is what .NET's `ECDsa.SignData` produces natively.
    func sign(_ data: Data) throws -> Data
}

/// A software P-256 key. The app prefers a Secure Enclave key (see the app's
/// KeychainIdentity); this one backs tests and devices without an enclave.
public final class SoftwareIdentity: IdentitySigner {
    public let privateKey: P256.Signing.PrivateKey
    public let publicKeyBase64: String

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
        self.publicKeyBase64 = privateKey.publicKey.derRepresentation.base64EncodedString()
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}

// MARK: - Signatures

public enum WireSignature {
    /// Verifies a raw `r || s` signature against a base64 SPKI public key.
    /// False - never a throw - for every malformed input: a hostile peer
    /// controls all of these bytes.
    public static func verify(publicKeyBase64: String, data: Data, rawSignature: Data) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKeyBase64),
              let key = try? P256.Signing.PublicKey(derRepresentation: keyBytes),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: rawSignature)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    public static func verify(publicKeyBase64: String, data: Data, signatureBase64: String?) -> Bool {
        guard let signatureBase64, let raw = Data(base64Encoded: signatureBase64) else { return false }
        return verify(publicKeyBase64: publicKeyBase64, data: data, rawSignature: raw)
    }

    /// True when the base64 decodes to a well-formed P-256 SPKI public key.
    public static func isValidPublicKey(_ base64: String) -> Bool {
        guard let bytes = Data(base64Encoded: base64) else { return false }
        return (try? P256.Signing.PublicKey(derRepresentation: bytes)) != nil
    }

    private static let base64Digits = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// The key itself (its raw P-256 point) that a base64 SPKI names, however
    /// the text is spelled: whitespace and other stray characters, missing
    /// padding and non-zero padding bits all decode somewhere in the mesh
    /// (.NET skips whitespace, Java needs no padding). Nil for anything that
    /// isn't a P-256 key.
    public static func canonicalPublicKey(_ base64: String) -> Data? {
        var digits = base64.filter(base64Digits.contains)
        digits += String(repeating: "=", count: (4 - digits.count % 4) % 4)
        guard let bytes = Data(base64Encoded: digits),
              let key = try? P256.Signing.PublicKey(derRepresentation: bytes)
        else { return nil }
        return key.rawRepresentation
    }

    /// True when both name the same public key - a text compare misses a
    /// re-encoded copy of an id.
    public static func isSameKey(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let x = canonicalPublicKey(a), let y = canonicalPublicKey(b) else { return false }
        return x == y
    }
}

// MARK: - Entry signing

public enum EntrySigning {
    /// `"{Content}:{Type}:{DeviceId}:{Timestamp}"`, UTF-8 - SigningService.cs.
    public static func signableData(content: String, type: String, deviceId: String, timestamp: String) -> Data {
        Data("\(content):\(type):\(deviceId):\(timestamp)".utf8)
    }

    public static func sign(content: String, type: String, identity: IdentitySigner, timestamp: String = DotNetTimestamp.now()) throws -> ClipboardEntry {
        let deviceId = identity.publicKeyBase64
        let data = signableData(content: content, type: type, deviceId: deviceId, timestamp: timestamp)
        let signature = try identity.sign(data)
        return ClipboardEntry(content: content, type: type, deviceId: deviceId, timestamp: timestamp, signature: signature.base64EncodedString())
    }

    /// Verifies against the entry's own claimed `deviceId` (callers check
    /// trust separately). Returns the entry exactly as it verified - with its
    /// timestamp canonicalised if only the canonical text verified - or nil.
    ///
    /// The canonical retry is what lets this node accept Windows entries whose
    /// fraction System.Text.Json trimmed (see DotNetTimestamp). Storing the
    /// canonical text also means this node re-relays them in a form every
    /// other peer can verify.
    public static func verified(_ entry: ClipboardEntry) -> ClipboardEntry? {
        guard let signatureBase64 = entry.signature, let raw = Data(base64Encoded: signatureBase64) else { return nil }
        let direct = signableData(content: entry.content, type: entry.type, deviceId: entry.deviceId, timestamp: entry.timestamp)
        if WireSignature.verify(publicKeyBase64: entry.deviceId, data: direct, rawSignature: raw) {
            return entry
        }
        guard let canonical = DotNetTimestamp.canonical(entry.timestamp), canonical != entry.timestamp else { return nil }
        let retry = signableData(content: entry.content, type: entry.type, deviceId: entry.deviceId, timestamp: canonical)
        guard WireSignature.verify(publicKeyBase64: entry.deviceId, data: retry, rawSignature: raw) else { return nil }
        var fixed = entry
        fixed.timestamp = canonical
        return fixed
    }
}

// MARK: - Session transport

/// AES-256-GCM, no AAD. Wire layout per line is base64(`nonce(12) || tag(16)
/// || ciphertext`) - the TAG COMES BEFORE THE CIPHERTEXT, unlike CryptoKit's
/// `combined` (nonce || ciphertext || tag). Getting the order wrong fails
/// every message, including from a perfectly behaved peer.
public struct SessionCipher {
    public static let nonceSize = 12
    public static let tagSize = 16

    public let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    public init(keyBytes: Data) { self.key = SymmetricKey(data: keyBytes) }

    public func seal(_ plaintext: String) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: AES.GCM.Nonce())
        var packed = Data(capacity: Self.nonceSize + Self.tagSize + box.ciphertext.count)
        box.nonce.withUnsafeBytes { packed.append(contentsOf: $0) }
        packed.append(box.tag)
        packed.append(box.ciphertext)
        return packed.base64EncodedString()
    }

    /// Throws on corrupt, forged or truncated input - the caller treats that
    /// as a dead connection, same as every other platform's single catch-all.
    public func open(_ line: Data) throws -> String {
        guard let packed = Data(base64Encoded: line), packed.count >= Self.nonceSize + Self.tagSize else {
            throw WireError.malformed("session line")
        }
        let nonce = try AES.GCM.Nonce(data: packed.prefix(Self.nonceSize))
        let tag = packed.subdata(in: (packed.startIndex + Self.nonceSize)..<(packed.startIndex + Self.nonceSize + Self.tagSize))
        let ciphertext = packed.suffix(from: packed.startIndex + Self.nonceSize + Self.tagSize)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plain = try AES.GCM.open(box, using: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw WireError.malformed("session plaintext") }
        return text
    }

    public func open(_ line: String) throws -> String {
        try open(Data(line.utf8))
    }
}

// MARK: - Handshake key agreement

public enum HandshakeCrypto {
    /// SHA256(raw ECDH shared secret) - exactly .NET's
    /// `DeriveKeyFromHash(theirKey, SHA256)` with no prepend/append. NOT HKDF:
    /// any salt or info here derives a different key and nothing decrypts.
    public static func sessionKey(myEphemeral: P256.KeyAgreement.PrivateKey, theirEphemeralSPKI: Data) throws -> SymmetricKey {
        let theirs = try P256.KeyAgreement.PublicKey(derRepresentation: theirEphemeralSPKI)
        let shared = try myEphemeral.sharedSecretFromKeyAgreement(with: theirs)
        let raw = shared.withUnsafeBytes { Data($0) }
        return SymmetricKey(data: Data(SHA256.hash(data: raw)))
    }
}

// MARK: - Passcode auto-trust

public enum PassphraseAuth {
    /// PBKDF2-HMAC-SHA256 over the passcode's UTF-8 bytes, fixed salt, 210,000
    /// rounds, 32 bytes - PassphraseAuth.cs. Callers trim the passcode first
    /// (every platform does), so a stray space can't derive a different key.
    /// Takes a noticeable fraction of a second: never call it on the main thread.
    public static func deriveKey(passphrase: String) -> Data {
        pbkdf2SHA256(password: Data(passphrase.utf8), salt: Data(Wire.passphraseSalt.utf8), iterations: Wire.passphraseIterations, keyLength: Wire.passphraseKeyLength)
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: UInt32, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { out -> Int32 in
            password.withUnsafeBytes { pw -> Int32 in
                salt.withUnsafeBytes { s -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "CCKeyDerivationPBKDF failed: \(status)")
        return derived
    }

    /// base64(HMAC-SHA256(key, UTF-8(deviceId))) - what beacons and handshakes carry.
    public static func proof(key: Data, deviceId: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(deviceId.utf8), using: SymmetricKey(data: key))
        return Data(mac).base64EncodedString()
    }

    /// Constant-time, like `CryptographicOperations.FixedTimeEquals`.
    public static func verifyProof(key: Data, deviceId: String, proofBase64: String?) -> Bool {
        guard let proofBase64, let actual = Data(base64Encoded: proofBase64),
              let expected = Data(base64Encoded: proof(key: key, deviceId: deviceId))
        else { return false }
        return fixedTimeEquals(expected, actual)
    }

    public static func fixedTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

// MARK: - Hashing

public enum ContentHash {
    /// Lowercase SHA-256 hex - Android/HarmonyOS spelling. Windows compares
    /// case-insensitively, so lowercase is safe to originate.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file - these can be up to 1 GB.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum WireError: Error, CustomStringConvertible {
    case malformed(String)
    case lineTooLong(Int)
    case closed
    case timeout(String)
    case refused(String)

    public var description: String {
        switch self {
        case .malformed(let what): return "malformed \(what)"
        case .lineTooLong(let n): return "line exceeds \(n) bytes"
        case .closed: return "connection closed"
        case .timeout(let what): return "timed out: \(what)"
        case .refused(let why): return "refused: \(why)"
        }
    }
}
