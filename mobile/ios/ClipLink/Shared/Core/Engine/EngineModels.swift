import Foundation

/// Everything the UI renders, as one immutable value published from the
/// engine queue. Recomputed after every state change - it is small.
public struct EngineSnapshot: Equatable {
    public var ownDeviceId: String = ""
    public var items: [SyncedItem] = []
    public var devices: [DeviceRow] = []
    public var connectedCount: Int = 0
    public var network = NetworkStatus()
    public var log: [LogLine] = []
    public var pairingOpen = false
    public var pairingRequest: PairingRequest?
    public var hasPassphrase = false
    public var tailscaleIP = ""
    public var localAddresses: [String] = []
    /// What this device's QR / "Copy pairing info" carries.
    public var pairingPayload = ""
    /// Incoming file transfers in flight, keyed by lowercase hash.
    public var transfers: [String: TransferProgress] = [:]
    public var sweeping = false
    /// Local names the user gave trusted devices (never sent anywhere).
    public var nicknames: [String: String] = [:]
    /// The names peers give themselves: the stored one (handshake, pairing),
    /// else - never overriding it - the latest heard in a beacon.
    public var deviceNames: [String: String] = [:]
    /// The name this device goes by on the wire ("" when it has none).
    public var deviceName = ""
    /// The user's "Device name" setting ("" = use `systemDeviceName`).
    public var deviceNameOverride = ""
    /// The OS default name, as the app last stored it.
    public var systemDeviceName = ""

    public init() {}

    /// A local nickname, else the name the device gives itself, else a
    /// short label derived from its id.
    public func name(for deviceId: String) -> String {
        nicknames[deviceId] ?? deviceNames[deviceId] ?? DeviceLabel.short(deviceId)
    }
}

public struct NetworkStatus: Equatable {
    public enum Broadcast: Equatable {
        case unknown
        /// Sends to 255.255.255.255 succeed: the multicast entitlement is present.
        case available
        /// iOS refused the broadcast (no multicast entitlement): the engine
        /// falls back to direct beacons and sweeps.
        case unavailable
    }

    public enum LocalNetwork: Equatable {
        case unknown
        case allowed
        /// Unicast to the LAN is being blocked: the user denied (or hasn't yet
        /// answered) the Local Network prompt.
        case denied
    }

    public var running = false
    public var listening = false
    public var broadcast: Broadcast = .unknown
    public var localNetwork: LocalNetwork = .unknown
    /// This device's Wi-Fi IPv4, when on a LAN.
    public var lanAddress: String?
    public var lastError: String?

    public init() {}
}

public struct TransferProgress: Equatable {
    public var fileName: String
    public var received: Int64
    public var total: Int64
}

/// One history entry plus everything the list needs that isn't on the wire.
public struct SyncedItem: Identifiable, Equatable {
    public enum Kind: Equatable { case text, link, opaque, image, file }

    public let id: String
    public let entry: ClipboardEntry
    public let isOwn: Bool
    public let kind: Kind
    public let filePayload: FilePayload?
    public let fileAvailable: Bool
    public let date: Date?
    /// "This device", a device label, or "Other device".
    public let sourceLabel: String

    public var preview: String {
        switch kind {
        case .image: return "Image"
        case .file: return filePayload?.fileName ?? "File"
        default: return entry.content
        }
    }

    static func kind(for entry: ClipboardEntry) -> Kind {
        switch entry.type {
        case Wire.EntryType.image: return .image
        case Wire.EntryType.file: return .file
        default:
            let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: #"^(https?|ftp)://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .link }
            // HarmonyOS' "Encoded data" heuristic: 40+ chars of base64/hex-ish
            // text with no spaces reads as a token or key, not prose.
            if trimmed.count >= 40, trimmed.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil { return .opaque }
            return .text
        }
    }
}

/// One row on the Devices tab: trusted, discovered, or both.
public struct DeviceRow: Identifiable, Equatable {
    public var id: String { deviceId }
    public let deviceId: String
    /// What the row is titled: the local nickname, else the name the device
    /// gives itself; nil when neither is known.
    public let name: String?
    public let trusted: Bool
    public let connected: Bool
    /// Where this device is reachable: the LAN address it was last heard
    /// from or reached at, then its stored and self-advertised (off-LAN)
    /// addresses.
    public let addresses: [String]
    /// The peer's beacon says its own pairing screen is open right now.
    public let pairing: Bool
    public let lastSeen: Date?
    /// Recently heard from (beacon, probe or connection) - within ~30s.
    public let nearby: Bool

    public var shortId: String { String(deviceId.prefix(12)) }

    /// The one row order every platform uses: paired devices first, then by
    /// name (case-insensitive; named rows before unnamed ones), then by id.
    /// Deliberately never by last-seen time or connection state - a beacon
    /// arriving or a link coming up must not move a row.
    public static func displayOrder(_ a: DeviceRow, _ b: DeviceRow) -> Bool {
        if a.trusted != b.trusted { return a.trusted }
        switch (a.name, b.name) {
        case let (.some(x), .some(y)):
            let order = x.caseInsensitiveCompare(y)
            if order != .orderedSame { return order == .orderedAscending }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return DeviceOrder.isOrdinallyLess(a.deviceId, b.deviceId)
    }
}

public struct LogLine: Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let message: String

    public init(message: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.message = message
    }
}

/// A peer that completed a handshake but isn't trusted yet - awaiting an
/// explicit Accept/Reject on this device.
public struct PairingRequest: Equatable {
    public let deviceId: String
    public let address: String?
    /// The name its handshake gave; nil for older builds.
    public let name: String?
}

/// How a manual (QR / typed) pairing dial ended. Mirrors the richest set, the
/// HarmonyOS one from commit 2e0139d, plus Android's own-code check.
public enum PairOutcome: Equatable {
    case ownCode
    case empty
    /// `name` is the pairing code's optional `Name`.
    case noAddress(key: String, name: String? = nil)
    case searching(key: String, name: String? = nil)
    case connected(String)
    case passcode(String)
    case prompt(String)
    case awaitingOther(String)
    case busy
    case refused(String)
    case silent(String)
    case unreachable(String)
    case localNetworkDenied

    public var message: String {
        switch self {
        case .ownCode: return "That's this device's own code."
        case .empty: return "Enter a pairing code or address first."
        case .noAddress(let key, let name):
            return "\(name ?? "\(key.prefix(12))…") has no address in its code. If it's on the same network, keep this screen open on both devices and it will pair automatically."
        case .searching(let key, let name):
            return "Looking for \(name ?? "\(key.prefix(12))…") on this network — keep this screen open on both devices."
        case .connected(let a): return "Already paired with \(a) - connected."
        case .passcode(let a): return "Paired with \(a) using your passcode."
        case .prompt(let a): return "Reached \(a) - accept the pairing prompt on both devices to finish."
        case .awaitingOther(let a): return "Reached \(a) - accept the request on that device to finish."
        case .busy: return "Another pairing request is already waiting here - accept or reject it first."
        case .refused(let a):
            return "\(a) answered but didn't accept this device. Set the same passcode on both, or open its Pairing screen (and finish any other pairing request there), then try again."
        case .silent(let a):
            return "\(a) accepted the connection but ClipLink there didn't respond - try restarting it on that device."
        case .unreachable(let a):
            return "Couldn't connect to \(a). Check ClipLink is running there and both devices are on the same network (or Tailscale)."
        case .localNetworkDenied:
            return "iOS is blocking local network access for ClipLink. Turn it on in Settings › Privacy & Security › Local Network."
        }
    }
}

/// Result of sending something from this device, for toasts.
public enum SendResult: Equatable {
    case sent(type: String, peers: Int, name: String?)
    case failed(String)
}
