using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Engine;

// What ClipLinkEngine hands the UI - plain immutable snapshots, safe to keep
// and to pass between threads.

public enum EngineState
{
    NotStarted,
    // Listening for peers, discovery and the clipboard watcher running.
    Running,
    // Start() couldn't listen on its TCP port (Error says why) - nothing is
    // running, but the stores (history, device name, passcode...) can still
    // be read and changed. Retry() tries again; Stop() ends it for good.
    Faulted,
    // Stop() was called. Final: a new ClipLinkEngine is needed to run again.
    Stopped,
}

// Error is a user-presentable sentence: why the engine is Faulted, or while
// Running, something that isn't working (e.g. LAN discovery couldn't start
// - peers can still be reached by address). Null when all is well.
public sealed record EngineStatus(EngineState State, string? Error);

public sealed record EngineOptions
{
    // UDP port for LAN discovery beacons. Every device on the network uses
    // the same one, so only tests change it.
    public int DiscoveryPort { get; init; } = 49000;

    // False for tests and tools only: the system clipboard is never read or
    // written (copies to the clipboard stay queued, never applied).
    public bool WatchClipboard { get; init; } = true;

    // True for tests and tools only: accept connections on 127.0.0.1 only
    // and run no LAN discovery - nothing is reachable from the network (and
    // no Windows Firewall prompt).
    public bool LoopbackOnly { get; init; } = false;
}

// A device's pairing payload - what the QR code and "copy pairing info" carry,
// and what TrustPairingPayload / PairByAddressAsync accept: its public key
// plus its optional off-LAN (Tailscale) address, bundled so pairing captures
// both in one exchange. Name (the device's display name) is optional -
// absent from older builds' payloads.
public record PairingInfo(string PublicKey, string? Address = null, string? Name = null);

// One row of GetDevices(): every trusted device plus every untrusted one
// currently beaconing, already in display order - trusted first, then by
// name case-insensitively (unnamed ones last, by id), then by id. Never by
// connection state or last-seen time, so rows don't move on their own. Name
// is null until the device has told us one; Addresses is every address it's
// known at, deduplicated: the LAN address its last beacon came from, then its
// off-LAN (Tailscale) one - the one its beacon advertises and/or the one
// stored with its trust (which the latest connection back-fills).
// PairingOpen: its latest beacon (within the last 30s) says its own pairing
// screen is open.
public record DeviceListing(string PublicKey, string? Name, bool Trusted, bool Connected, bool PairingOpen, IReadOnlyList<string> Addresses);

// A pairing request waiting for Accept/Reject: the peer's (signature-
// verified) device id, the display name its handshake or beacon carried
// (null if unknown - show DeviceLabel.Of) and the address it connected from
// or was dialled at.
public sealed record PendingPairing(string DeviceId, string? Name, string? Address);

// How a pending pairing request ended.
public enum PairingDecision
{
    Accepted,
    Rejected,
    // Nobody decided: pairing mode was turned off, or the engine stopped.
    Abandoned,
}

// What PairByAddressAsync achieved.
public enum PairOutcome
{
    // An already-trusted device: connected (and syncing) straight away.
    Connected,
    // A new device with the same passcode: trusted and connected.
    PairedByPasscode,
    // A new device: a pairing request is now pending here (PairingRequested
    // fired) - Accept it here, and on the other device too.
    Pending,
    // Another pairing request is already pending here - decide that one first.
    Busy,
    // Reached the device but it refused: it doesn't trust this PC and its
    // pairing screen isn't open (and no matching passcode) - or this PC's
    // own pairing mode is off.
    Refused,
    // Nothing answered at that address (or it didn't finish the handshake).
    Unreachable,
    // Not an address, or a pairing payload without one.
    InvalidAddress,
    // The address is this PC's own.
    ThisDevice,
    // The engine isn't running.
    NotRunning,
}

// What ShareFilesAsync did: Shared - the paths now in history and on their
// way to the other devices, in the order given; Skipped - the rest, each with
// why (Error: the system's message, for a file that couldn't be read or
// stored).
public sealed record ShareResult(IReadOnlyList<string> Shared, IReadOnlyList<SkippedShare> Skipped);

public sealed record SkippedShare(string Path, FileSkipReason Reason, string? Error);

// One synced-history row for the UI, newest first from GetHistory(). Light
// on purpose: never the full text, the image or the file bytes - fetch those
// by Key (GetText, GetImageBytes, GetFileToOpen) only when needed. Key is
// stable for the entry's lifetime (ClipboardEntry.Key(): its signature), so
// it also works as a cache key for thumbnails.
//   Type          "text", "image" or "file" (anything else: an unknown kind)
//   DeviceName    the source device's name, null if unknown (DeviceLabel.Of);
//                 this device's own name when FromThisDevice
//   TimestampUtc  when it was copied, in UTC
//   TextPreview   text only: the first PreviewLength characters
//   TextLength    text only: the full length in characters
//   FileName      file only, exactly as the sender named it (untrusted text)
//   SizeBytes     file: its size; image: the image's size; text: null
//   IsAvailable   file: its bytes are stored here (Copy/Open work); false
//                 while they're still arriving or were never received.
//                 Always true for text and images.
public sealed record HistoryItem(
    string Key,
    string Type,
    string DeviceId,
    string? DeviceName,
    bool FromThisDevice,
    DateTime TimestampUtc,
    string? TextPreview,
    int TextLength,
    string? FileName,
    long? SizeBytes,
    bool IsAvailable)
{
    public const int PreviewLength = 1000;
}
