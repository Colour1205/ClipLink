using System.Buffers;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace ClipboardDaemon.Networking;

// How messages are written as JSON for the wire (and the history file).
//
// Json skips the escapes JSON doesn't need: the default encoder writes '+' as
// a six-character \u escape, '"' inside a string as another, and every
// non-ASCII character as one too; and every message is JSON inside JSON (an
// Envelope's Payload), so a file chunk's Base64 went out about 9% bigger than
// it had to and Chinese text at 6-7 bytes a character instead of 3. Still
// standard JSON, which every build on every platform parses the same; a value
// decodes to the same string either way, and signatures cover those strings
// (SigningService), not the JSON text. Not for anything whose JSON text is
// itself signed content: a file entry's Content (its FilePayload) is written
// as before.
public static class Wire
{
    public static readonly JsonSerializerOptions Json = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static readonly byte[] TypeStart = "{\"Type\":\""u8.ToArray();
    private static readonly byte[] PayloadStart = "\",\"Payload\":\""u8.ToArray();
    private static readonly byte[] End = "\"}"u8.ToArray();
    // What has to be escaped to put JSON text inside a JSON string.
    private static readonly SearchValues<byte> Escaped = SearchValues.Create(
        Enumerable.Range(0, 0x20).Select(b => (byte)b).Append((byte)'"').Append((byte)'\\').ToArray());
    private const string Hex = "0123456789ABCDEF";

    // An Envelope as UTF-8 JSON - the same text as
    // JsonSerializer.Serialize(new Envelope(type, payloadJson), Json) - made
    // from the payload's own UTF-8 JSON, without either ever being a string:
    // for a picture, each string was another copy twice its size. (Not an
    // overload of Envelope: given a byte[], Envelope<T> would be picked, and
    // serialize the bytes as Base64 into yet another envelope, without end.)
    //
    // The payload is escaped here rather than by Utf8JsonWriter, which sets
    // aside six bytes for every byte of a value it has to escape at all - for
    // a 20 MB picture, a buffer of some 170 MB. JSON text needs only '"', '\'
    // and control characters (whitespace between its tokens) escaped to go
    // inside a string: anything else the encoder would escape, the payload's
    // own serializer escaped already.
    public static ReadOnlyMemory<byte> EnvelopeOfUtf8(string type, ReadOnlySpan<byte> payloadUtf8)
    {
        ReadOnlySpan<byte> typeJson = JsonEncodedText.Encode(type, JavaScriptEncoder.UnsafeRelaxedJsonEscaping).EncodedUtf8Bytes;
        int length = TypeStart.Length + typeJson.Length + PayloadStart.Length + End.Length + payloadUtf8.Length;
        var rest = payloadUtf8;
        for (int next; (next = rest.IndexOfAny(Escaped)) >= 0; rest = rest[(next + 1)..])
        {
            length += EscapedLength(rest[next]) - 1;
        }

        byte[] envelope = new byte[length];
        var to = envelope.AsSpan();
        TypeStart.CopyTo(to);
        to = to[TypeStart.Length..];
        typeJson.CopyTo(to);
        to = to[typeJson.Length..];
        PayloadStart.CopyTo(to);
        to = to[PayloadStart.Length..];
        rest = payloadUtf8;
        while (true)
        {
            int next = rest.IndexOfAny(Escaped);
            int plain = next < 0 ? rest.Length : next;
            rest[..plain].CopyTo(to);
            to = to[plain..];
            if (next < 0) break;
            to = to[Escape(rest[next], to)..];
            rest = rest[(next + 1)..];
        }
        End.CopyTo(to);
        return envelope;
    }

    private static int EscapedLength(byte b) => ShortEscape(b) != 0 ? 2 : 6;

    // The letter after the backslash, for the bytes JSON has one for; else 0.
    private static byte ShortEscape(byte b) => b switch
    {
        (byte)'"' => (byte)'"',
        (byte)'\\' => (byte)'\\',
        (byte)'\b' => (byte)'b',
        (byte)'\t' => (byte)'t',
        (byte)'\n' => (byte)'n',
        (byte)'\f' => (byte)'f',
        (byte)'\r' => (byte)'r',
        _ => 0,
    };

    // b escaped into to, the way Utf8JsonWriter writes it; returns its length.
    private static int Escape(byte b, Span<byte> to)
    {
        to[0] = (byte)'\\';
        byte letter = ShortEscape(b);
        if (letter != 0)
        {
            to[1] = letter;
            return 2;
        }
        "u00"u8.CopyTo(to[1..]);
        to[4] = (byte)Hex[b >> 4];
        to[5] = (byte)Hex[b & 0xF];
        return 6;
    }

    // An Envelope whose Payload is payload as JSON.
    public static ReadOnlyMemory<byte> Envelope<T>(string type, T payload) =>
        EnvelopeOfUtf8(type, JsonSerializer.SerializeToUtf8Bytes(payload, Json));

    // An Envelope whose Payload is this JSON text already.
    public static ReadOnlyMemory<byte> Envelope(string type, string payloadJson) =>
        EnvelopeOfUtf8(type, System.Text.Encoding.UTF8.GetBytes(payloadJson));
}
