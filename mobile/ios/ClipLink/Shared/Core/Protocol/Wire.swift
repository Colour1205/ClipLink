import Foundation

/// Constants every ClipLink node must agree on byte-for-byte. Each one is
/// mirrored in windows/daemon, mobile/android and mobile/harmonyos; changing
/// any of them here silently partitions this device from the mesh.
public enum Wire {
    /// UDP beacons and the TCP listener share one port number on every platform.
    public static let port: UInt16 = 49000

    /// Beacon cadence - Discovery.cs / Discovery.kt / Discovery.ets all use 2s.
    public static let beaconInterval: TimeInterval = 2

    /// Envelope `Type` values. Anything else is logged and ignored, never fatal.
    public enum MessageType {
        public static let entry = "entry"
        public static let historyBatch = "history_batch"
        public static let fileChunk = "file_chunk"
        public static let fileRequest = "file_request"
    }

    /// `ClipboardEntry.Type` values.
    public enum EntryType {
        public static let text = "text"
        public static let image = "image"
        public static let file = "file"
    }

    /// Sent encrypted like any other line and filtered out before message
    /// handling. Every platform both sends and swallows it.
    public static let pingSentinel = "__ping__"

    /// Raw bytes per `file_chunk` (before base64) - 256 KiB everywhere.
    public static let fileChunkSize = 256 * 1024

    /// History cap with oldest-first eviction - HistoryAccess.cs uses 25.
    public static let historyCap = 25

    /// Passcode auto-trust KDF. The salt is fixed on purpose (see
    /// PassphraseAuth.cs); a different salt, count or length derives a
    /// different key from the same passcode and devices never match.
    public static let passphraseSalt = "ClipboardDaemonPassphraseSaltV1"
    public static let passphraseIterations: UInt32 = 210_000
    public static let passphraseKeyLength = 32

    /// A FileHash as every platform writes it: 64 hex digits of SHA-256
    /// (Windows uppercase, the others lowercase). Anything else is rejected
    /// before it can reach a filesystem path - it's peer-controlled.
    public static func isSHA256Hex(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
        }
    }

    /// Ceiling on a file this node will receive or send - Windows' own limit.
    public static let maxFileBytes: Int64 = 1024 * 1024 * 1024
}
