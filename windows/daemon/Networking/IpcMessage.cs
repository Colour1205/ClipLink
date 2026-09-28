namespace ClipboardDaemon.Networking;

// Request/response shape for local IPC between the daemon and its tray app
// companion, over a named pipe. Same one-JSON-line-per-message idea as the
// peer-to-peer Envelope, just for a different (local-only) channel.
public record IpcRequest(string Command, string? Payload = null);
public record IpcResponse(bool Success, string? Data = null);

// What "get_pairing_info" returns and "trust_device" accepts — a device's
// public key plus its optional off-LAN (Tailscale) address, bundled together
// so pairing captures both in one exchange (QR code, or pasted text). Name
// (the device's display name) is optional - absent from older builds' payloads.
public record PairingInfo(string PublicKey, string? Address = null, string? Name = null);

// One row of "list_devices": every trusted device plus every untrusted one
// currently beaconing, already in display order - trusted first, then by
// name case-insensitively (unnamed ones last, by id), then by id. Never by
// connection state or last-seen time, so rows don't move on their own. Name
// is null until the device has told us one; Addresses is every address it's
// known at, deduplicated: the LAN address its last beacon came from, then its
// off-LAN (Tailscale) one - the one its beacon advertises and/or the one
// stored with its trust (which the latest connection back-fills).
public record DeviceListing(string PublicKey, string? Name, bool Trusted, bool Connected, bool PairingOpen, List<string> Addresses);

// What "get_pending_pairing_info" returns while a pairing request awaits
// Accept/Reject ("" when none): get_pending_pairing's peer id, plus the
// peer's display name (null if unknown) and the address it connected from.
public record PendingPairingInfo(string PublicKey, string? Name, string? Address);
