import Foundation

/// Constants every ClipLink node must agree on byte-for-byte. Each one is
/// mirrored in windows/ClipLink/Engine, mobile/android and mobile/harmonyos; changing
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
        /// Sent just before a history_batch of 2 or more entries: its newest
        /// entry and every key in it, so the peer can show the stack at once.
        public static let historyHead = "history_head"
        /// v2 only: "send me the entries with these keys" - answered with one
        /// history_batch.
        public static let historyRequest = "history_request"
        /// v2 only: the user deleted these items (by key) on the sender.
        public static let delete = "delete"
        public static let fileChunk = "file_chunk"
        public static let fileRequest = "file_request"
        /// "I no longer trust you": sent when a device is removed.
        public static let unpair = "unpair"
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

    /// The sync version this build speaks, sent in the handshake as `Protocol`.
    /// 1 is every build before it (the whole history on every connect); 2 sends
    /// a list of keys first and then only the missing items (history_head,
    /// history_request, delete). A connection speaks the lower of the two sides.
    public static let protocolVersion = 2

    /// The version a connection speaks: the lower of what both sides announced.
    /// A side that announced nothing (or less than 1) is a version 1 build.
    public static func negotiatedProtocol(own: Int?, peer: Int?) -> Int {
        min(max(1, own ?? 1), max(1, peer ?? 1), protocolVersion)
    }

    /// At most this many keys in one history_request or delete; a longer list
    /// is cut (and a sender splits its own).
    public static let maxKeysPerMessage = 100
    /// At most this many tombstone keys in a history_head.
    public static let maxHeadDeleted = 500
    /// A key longer than this is not one of ours (a signature is ~100 characters).
    public static let maxKeyLength = 2048
    /// A history_request unanswered for this long is given up on.
    public static let requestTimeout: TimeInterval = 90

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
