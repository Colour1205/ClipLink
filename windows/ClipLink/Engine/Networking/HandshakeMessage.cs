using System.Text.Json;
using System.Text.Json.Serialization;

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
//
// Protocol is the sync protocol the sender speaks (CurrentProtocol), the
// same way: absent, null, not a number or below 2 all mean 1, and older
// builds ignore the key. A connection speaks 2 only when both sides sent 2
// (see Negotiate). It is not signed (the signature covers only the ephemeral
// key, as for DeviceName), so a man in the middle can strip it - which only
// makes the connection speak 1, the safe fallback every build still has.
public record HandshakeMessage(string EphemeralPublicKey, string IdentityPublicKey, string Signature, string? PassphraseProof = null, string? DeviceName = null,
    [property: JsonConverter(typeof(ProtocolConverter))] int? Protocol = null)
{
    // 1: the whole history is sent on connect (history_head and history_batch).
    // 2: heads of keys and times, history_request and delete.
    public const int CurrentProtocol = 2;

    // What a peer's handshake said, as a protocol: 1 when it said nothing, or less
    // than 2.
    public static int Normalize(int? peerProtocol) => peerProtocol is >= 2 ? peerProtocol.Value : 1;

    // The protocol a connection speaks, from what the peer's handshake said.
    public static int Negotiate(int? peerProtocol) => Math.Min(CurrentProtocol, Normalize(peerProtocol));
}

// A Protocol that is not a whole number (a string, a fraction, an object) is
// read as absent: it must never fail the whole handshake.
internal sealed class ProtocolConverter : JsonConverter<int?>
{
    public override int? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt32(out int value)) return value;
        reader.Skip();
        return null;
    }

    public override void Write(Utf8JsonWriter writer, int? value, JsonSerializerOptions options)
    {
        if (value is int number) writer.WriteNumberValue(number);
        else writer.WriteNullValue();
    }
}
