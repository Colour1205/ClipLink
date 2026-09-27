import CryptoKit
import Foundation
import Security

/// Minimal generic-password Keychain access.
///
/// Items are `AfterFirstUnlockThisDeviceOnly`: readable by background refresh
/// while the phone is locked (but not before the first unlock after boot),
/// never synced to iCloud or restored onto another device - a device's
/// identity must stay on that device.
enum Keychain {
    private static let service = "io.uaena.ClipLink"

    enum ReadResult {
        case found(Data)
        case notFound
        /// Locked before first unlock, or any other failure: NOT "absent".
        /// Treating this as absent would mint a new identity and silently
        /// orphan every pairing.
        case unavailable(OSStatus)
    }

    static func read(_ account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map(ReadResult.found) ?? .unavailable(status)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    /// Items live in the App Group's keychain access group so the Share
    /// extension can use the same identity and passcode key. If the group
    /// isn't provisioned they fall back to the app's own default group.
    ///
    /// Never deletes before the new copy is safely stored: losing the
    /// identity item would silently mint a new device ID and orphan every
    /// pairing.
    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SharedContainer.isAvailable {
            var shared = base
            shared[kSecAttrAccessGroup as String] = SharedContainer.appGroupID
            var status = SecItemUpdate(shared as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(shared.merging(attributes) { $1 } as CFDictionary, nil)
            }
            if status == errSecSuccess {
                removeCopies(of: account, except: SharedContainer.appGroupID)
                return true
            }
        }
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Deletes copies of an item held in any access group other than `keep`.
    private static func removeCopies(of account: String, except keep: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let group = item[kSecAttrAccessGroup as String] as? String, group != keep else { continue }
            let target: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group,
            ]
            SecItemDelete(target as CFDictionary)
        }
    }

    /// Moves an item created before the App Group existed into the shared
    /// group (same bytes, same account), so the extension can read it.
    static func migrateToSharedGroup(_ account: String) {
        guard SharedContainer.isAvailable else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              (item[kSecAttrAccessGroup as String] as? String) != SharedContainer.appGroupID
        else { return }
        write(data, account: account)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The engine's secret storage (the passcode-derived key), in the Keychain.
/// Stronger than the other ports (Windows DPAPI file, Android/HarmonyOS
/// private preferences) at no interop cost - the key never leaves the device.
final class KeychainSecretStore: SecretStore {
    func data(for key: String) -> Data? {
        Keychain.migrateToSharedGroup("secret." + key)
        if case .found(let data) = Keychain.read("secret." + key) { return data }
        return nil
    }

    func set(_ data: Data?, for key: String) {
        if let data {
            Keychain.write(data, account: "secret." + key)
        } else {
            Keychain.delete("secret." + key)
        }
    }
}

/// This device's long-lived P-256 identity. The device ID is the public key's
/// base64 SPKI - byte-identical to what Windows, Android and HarmonyOS
/// produce - so it is created once and never regenerated.
///
/// Prefers a Secure Enclave key: the private key can't leave the chip, the
/// same posture as Android Keystore / HarmonyOS HUKS. The enclave produces
/// ordinary P-256 signatures, so the wire format is unchanged. Devices without
/// one (the simulator) get a software key kept in the Keychain.
final class KeychainIdentity: IdentitySigner {
    private enum Key {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private static let account = "identity.v1"
    private static let enclaveTag: UInt8 = 0x45 // "E"
    private static let softwareTag: UInt8 = 0x53 // "S"

    private let key: Key
    let publicKeyBase64: String
    let isHardwareBacked: Bool

    enum LoadError: Error, CustomStringConvertible {
        case keychainUnavailable(OSStatus)
        case corrupt
        case couldNotSave

        var description: String {
            switch self {
            case .keychainUnavailable(let s): return "The Keychain isn't available yet (\(s)). Unlock your device — ClipLink starts as soon as it can."
            case .corrupt: return "This device's identity key couldn't be read."
            case .couldNotSave: return "Couldn't save this device's identity key."
            }
        }
    }

    private init(key: Key) {
        self.key = key
        switch key {
        case .enclave(let k):
            publicKeyBase64 = k.publicKey.derRepresentation.base64EncodedString()
            isHardwareBacked = true
        case .software(let k):
            publicKeyBase64 = k.publicKey.derRepresentation.base64EncodedString()
            isHardwareBacked = false
        }
    }

    static func loadOrCreate() throws -> KeychainIdentity {
        Keychain.migrateToSharedGroup(account)
        switch Keychain.read(account) {
        case .found(let stored):
            guard let tag = stored.first else { throw LoadError.corrupt }
            let body = stored.dropFirst()
            if tag == enclaveTag, let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body) {
                return KeychainIdentity(key: .enclave(k))
            }
            if tag == softwareTag, let k = try? P256.Signing.PrivateKey(rawRepresentation: body) {
                return KeychainIdentity(key: .software(k))
            }
            throw LoadError.corrupt
        case .unavailable(let status):
            throw LoadError.keychainUnavailable(status)
        case .notFound:
            break
        }

        let identity: KeychainIdentity
        var stored = Data()
        if SecureEnclave.isAvailable,
           let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil),
           let k = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) {
            // Deliberately no user-presence flag: sync must sign while the
            // phone sits in a pocket.
            identity = KeychainIdentity(key: .enclave(k))
            stored.append(enclaveTag)
            stored.append(k.dataRepresentation)
        } else {
            let k = P256.Signing.PrivateKey()
            identity = KeychainIdentity(key: .software(k))
            stored.append(softwareTag)
            stored.append(k.rawRepresentation)
        }
        guard Keychain.write(stored, account: account) else { throw LoadError.couldNotSave }
        return identity
    }

    func sign(_ data: Data) throws -> Data {
        switch key {
        case .enclave(let k): return try k.signature(for: data).rawRepresentation
        case .software(let k): return try k.signature(for: data).rawRepresentation
        }
    }
}
