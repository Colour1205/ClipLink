using System.Buffers;

namespace ClipboardDaemon.Networking;

// Byte buffers for the receive path: a line, its decoded bytes, a file
// chunk's bytes. Up to MaxPooled they come from the shared pool, so a big
// transfer reuses the same few buffers instead of putting three or four new
// half-megabyte arrays on the large object heap for every chunk. Bigger ones
// (a history batch full of pictures can be a line of tens of MB) are plain
// arrays: kept in the pool, they would sit in memory long after that one
// line.
internal static class ByteBuffers
{
    public const int MaxPooled = 4 * 1024 * 1024;

    // At least minLength bytes, not cleared.
    public static byte[] Rent(int minLength) =>
        minLength <= MaxPooled ? ArrayPool<byte>.Shared.Rent(minLength) : GC.AllocateUninitializedArray<byte>(minLength);

    // Only for an array Rent gave: the pool only ever hands out arrays of
    // MaxPooled or less, and anything longer was never its.
    public static void Return(byte[] buffer)
    {
        if (buffer.Length is > 0 and <= MaxPooled) ArrayPool<byte>.Shared.Return(buffer);
    }
}

// A file chunk's bytes: the first Length bytes of Buffer, which goes back to
// ByteBuffers on Release when Pooled. Whoever holds one releases it once.
public readonly record struct ChunkData(byte[] Buffer, int Length, bool Pooled)
{
    public ReadOnlySpan<byte> Span => Buffer.AsSpan(0, Length);

    public void Release()
    {
        if (Pooled) ByteBuffers.Return(Buffer);
    }

    // Bytes that belong to nobody else (decoded by Convert, or in a test).
    public static ChunkData Of(byte[] bytes) => new(bytes, bytes.Length, false);
}
