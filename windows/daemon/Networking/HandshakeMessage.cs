namespace ClipboardDaemon.Networking;

// The first (and only unencrypted) thing exchanged on every connection.
// EphemeralPublicKey sets up session encryption via ECDH — fresh per
// connection, so a leaked long-term key can't decrypt past sessions
// (forward secrecy). IdentityPublicKey + Signature (over EphemeralPublicKey)
// prove which device this really is: plain ECDH alone is vulnerable to a
// man-in-the-middle who swaps in their own ephemeral key, but they can't
// produce a valid signature without the real device's private key.
//
// PassphraseProof is optional — HMAC-SHA256(sharedPassphraseKey, own
// IdentityPublicKey), same computation as the LAN beacon's own proof (see
// PassphraseAuth.cs). Lets two devices with the same passcode auto-accept a
// pairing over a direct connection (e.g. Tailscale, via Pair by Address)
// the same way they already auto-trust from a LAN beacon — no beacon
// needed, since this rides along on the handshake itself instead.
//
// DeviceName is optional too - the sender's display name (see
// Identity/DeviceNameStore.cs), trimmed and capped at 64 characters. Absent
// (an older build), null or empty all mean "unknown"; the default keeps
// older JSON deserializing, and older builds ignore the extra key.
public record HandshakeMessage(string EphemeralPublicKey, string IdentityPublicKey, string Signature, string? PassphraseProof = null, string? DeviceName = null);
