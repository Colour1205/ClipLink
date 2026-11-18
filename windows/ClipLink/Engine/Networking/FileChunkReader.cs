using System.Buffers;
using System.Buffers.Text;
using System.Text;
using System.Text.Json;

namespace ClipboardDaemon.Networking;

// A file_chunk message read straight from its UTF-8 bytes: the envelope, the
// FileChunkMessage inside its Payload, and DataBase64 decoded into a pooled
// buffer. The same message used to become a string of the whole envelope,
// another of the Payload, a third of DataBase64 and then a new byte array, for
// every 256 KiB of a file - all of them on the large object heap.
//
// Only the common shape is read here: an envelope whose Type is "file_chunk"
// and whose Payload is a string, holding an object whose fields have the
// types FileChunkMessage gives them. For anything else - another type, a
// field of some other type, JSON that isn't valid - TryRead returns null and
// the message goes the old way (JsonSerializer and Convert, see
// ClipLinkEngine.HandleMessage), so it comes to exactly what it always did.
// The fields are matched as JsonSerializer matches them by default: by exact
// name, the last of two with the same name winning, unknown ones skipped.
public sealed class FileChunk : IDisposable
{
    public string? FileHash { get; }
    public int ChunkIndex { get; }
    public bool IsLast { get; }
    // False when DataBase64 was missing or null, which the old way drops.
    public bool HasData { get; }

    // The Payload unescaped (pooled), and DataBase64 unescaped when it had
    // escapes of its own ("\/", as Android writes '/'), else a slice of the
    // payload.
    private byte[]? payload;
    private byte[]? unescapedData;
    private readonly ReadOnlyMemory<byte> dataText;

    private FileChunk(byte[] payload, byte[]? unescapedData, string? fileHash, int chunkIndex, bool isLast, bool hasData, ReadOnlyMemory<byte> dataText)
    {
        this.payload = payload;
        this.unescapedData = unescapedData;
        FileHash = fileHash;
        ChunkIndex = chunkIndex;
        IsLast = isLast;
        HasData = hasData;
        this.dataText = dataText;
    }

    // The message as a file chunk, or null if it isn't one, or isn't one of
    // the shape read here (see above).
    public static FileChunk? TryRead(ReadOnlySpan<byte> message)
    {
        int payloadStart = -1, payloadLength = 0;
        bool isChunk = false;
        try
        {
            var reader = new Utf8JsonReader(message);
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return null;
            while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
            {
                bool type = reader.ValueTextEquals("Type"u8);
                bool payloadField = !type && reader.ValueTextEquals("Payload"u8);
                reader.Read();
                if (type)
                {
                    if (reader.TokenType != JsonTokenType.String) return null;
                    isChunk = reader.ValueTextEquals("file_chunk"u8);
                    // Not a chunk (Type comes first in what every build
                    // sends): the old way, without reading the rest of a
                    // history batch that can be many MB.
                    if (!isChunk) return null;
                }
                else if (payloadField)
                {
                    if (reader.TokenType != JsonTokenType.String) return null;
                    // Where the string is, quotes and all, to unescape once
                    // the Type is known.
                    payloadStart = (int)reader.TokenStartIndex;
                    payloadLength = reader.ValueSpan.Length + 2;
                }
                else
                {
                    reader.Skip();
                }
            }
            // Nothing but white space after the object (anything else throws).
            if (reader.Read()) return null;
        }
        catch (JsonException)
        {
            return null;
        }
        if (!isChunk || payloadStart < 0) return null;

        byte[] payload = ByteBuffers.Rent(payloadLength);
        byte[]? unescapedData = null;
        try
        {
            var quoted = new Utf8JsonReader(message.Slice(payloadStart, payloadLength));
            quoted.Read();
            int length = quoted.CopyString(payload);
            if (Read(payload, length, ref unescapedData) is { } chunk) return chunk;
        }
        catch (JsonException)
        {
        }
        catch (InvalidOperationException)
        {
            // (CopyString: invalid UTF-8 in the string.)
        }
        ByteBuffers.Return(payload);
        if (unescapedData != null) ByteBuffers.Return(unescapedData);
        return null;
    }

    // The FileChunkMessage in the first length bytes of payloadBuffer
    // (unescaped JSON text), or null. A chunk returned owns both buffers.
    private static FileChunk? Read(byte[] payloadBuffer, int length, ref byte[]? unescapedData)
    {
        var payload = payloadBuffer.AsMemory(0, length);
        string? fileHash = null;
        int chunkIndex = 0;
        bool isLast = false;
        bool hasData = false;
        ReadOnlyMemory<byte> dataText = default;
        var reader = new Utf8JsonReader(payload.Span);
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("FileHash"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.String) fileHash = reader.GetString();
                else if (reader.TokenType == JsonTokenType.Null) fileHash = null;
                else return null;
            }
            else if (reader.ValueTextEquals("ChunkIndex"u8))
            {
                reader.Read();
                if (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt32(out chunkIndex)) return null;
            }
            else if (reader.ValueTextEquals("IsLast"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.True) isLast = true;
                else if (reader.TokenType == JsonTokenType.False) isLast = false;
                else return null;
            }
            else if (reader.ValueTextEquals("DataBase64"u8))
            {
                reader.Read();
                if (reader.TokenType == JsonTokenType.Null)
                {
                    hasData = false;
                    dataText = default;
                }
                else if (reader.TokenType != JsonTokenType.String)
                {
                    return null;
                }
                else if (!reader.ValueIsEscaped)
                {
                    hasData = true;
                    dataText = payload.Slice((int)reader.TokenStartIndex + 1, reader.ValueSpan.Length);
                }
                else
                {
                    if (unescapedData == null || unescapedData.Length < reader.ValueSpan.Length)
                    {
                        if (unescapedData != null) ByteBuffers.Return(unescapedData);
                        unescapedData = ByteBuffers.Rent(reader.ValueSpan.Length);
                    }
                    int unescaped = reader.CopyString(unescapedData);
                    hasData = true;
                    dataText = unescapedData.AsMemory(0, unescaped);
                }
            }
            else
            {
                reader.Read();
                reader.Skip();
            }
        }
        if (reader.Read()) return null;
        return new FileChunk(payloadBuffer, unescapedData, fileHash, chunkIndex, isLast, hasData, dataText);
    }

    // DataBase64 decoded, as Convert.FromBase64String would have: "" is no
    // bytes (a 0-byte file's one chunk). False for text it refuses, which
    // the old way dropped too. The bytes are the caller's to release.
    public bool TryDecode(out ChunkData data)
    {
        var text = dataText.Span;
        byte[] buffer = ByteBuffers.Rent(Base64.GetMaxDecodedFromUtf8Length(text.Length));
        var status = Base64.DecodeFromUtf8(text, buffer, out int consumed, out int written);
        if (status == OperationStatus.Done && consumed == text.Length)
        {
            data = new ChunkData(buffer, written, Pooled: true);
            return true;
        }
        ByteBuffers.Return(buffer);
        try
        {
            data = ChunkData.Of(Convert.FromBase64String(Encoding.UTF8.GetString(text)));
            return true;
        }
        catch (FormatException)
        {
            data = default;
            return false;
        }
    }

    public void Dispose()
    {
        if (payload != null) ByteBuffers.Return(payload);
        if (unescapedData != null) ByteBuffers.Return(unescapedData);
        payload = unescapedData = null;
    }
}
