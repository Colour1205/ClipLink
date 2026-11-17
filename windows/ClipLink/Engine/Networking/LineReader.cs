namespace ClipboardDaemon.Networking;

// A connection's lines, read as bytes. The read loop used to go through a
// StreamReader: with its default 1 KiB buffer, a 466 KB file chunk line took
// about 500 reads, and every line became a string of the same length in
// characters (twice that in bytes), only to be turned back into bytes by
// Convert.FromBase64String. Here a line is a slice of one buffer, grown to the
// longest line seen and reused for every line after it.
//
// The lines are what the StreamReader gave, so nothing on the wire changes:
// ReadLineAsync ends a line at "\n", "\r" or "\r\n" (every build sends
// "\n" or "\r\n"), and a last line with no ending is still a line.
// ReadHandshakeLineAsync keeps the handshake's own rules (see there).
//
// One reader per stream, used by one caller at a time: the handshake, then
// the read loop.
public sealed class LineReader : IDisposable
{
    private const int InitialSize = 64 * 1024;

    private readonly Stream stream;
    private byte[] buffer;
    private int start; // the first byte not yet handed out
    private int end;   // one past the last byte read from the stream
    // The last line ended at "\r": a "\n" straight after it is part of that
    // ending, not an empty line (StreamReader's rule).
    private bool skipLf;

    public LineReader(Stream stream, int initialSize = InitialSize)
    {
        this.stream = stream;
        buffer = ByteBuffers.Rent(Math.Max(16, initialSize));
    }

    // The next line, without its ending, or null once the stream has ended
    // with nothing left. The bytes are only good until the next call: the
    // caller may change them (the read loop decodes in them), but must not
    // keep them.
    public async ValueTask<ReadOnlyMemory<byte>?> ReadLineAsync(CancellationToken cancellationToken = default)
    {
        ShrinkAfterLongLine();
        int scanned = 0; // bytes after start known to hold no line ending
        while (true)
        {
            if (skipLf)
            {
                if (start == end && await FillAsync(cancellationToken) == 0)
                {
                    skipLf = false;
                    return null;
                }
                if (buffer[start] == (byte)'\n') start++;
                skipLf = false;
            }
            int at = buffer.AsSpan(start + scanned, end - start - scanned).IndexOfAny((byte)'\n', (byte)'\r');
            if (at >= 0)
            {
                int length = scanned + at;
                var line = buffer.AsMemory(start, length);
                skipLf = buffer[start + length] == (byte)'\r';
                start += length + 1;
                return line;
            }
            scanned = end - start;
            if (await FillAsync(cancellationToken) == 0)
            {
                if (start == end) return null;
                var rest = buffer.AsMemory(start, end - start);
                start = end;
                return rest;
            }
        }
    }

    // The handshake line as the handshake reader always read it: up to "\n",
    // with every "\r" left out; null if the stream ends first or the line
    // has more than maxBytes bytes besides those, or more than twice that
    // with them (anyone on the network can
    // connect and send this before proving anything, so it can't grow
    // without end). What follows the line stays here for ReadLineAsync.
    public async ValueTask<byte[]?> ReadHandshakeLineAsync(int maxBytes, CancellationToken cancellationToken = default)
    {
        int scanned = 0;
        int kept = 0; // bytes other than "\r" in the scanned part
        while (true)
        {
            var unscanned = buffer.AsSpan(start + scanned, end - start - scanned);
            int at = unscanned.IndexOf((byte)'\n');
            var part = at >= 0 ? unscanned[..at] : unscanned;
            // The bytes looked at count too, not only the ones kept: each is
            // held here until the "\n", so an endless run of "\r" would
            // otherwise grow the buffer for as long as the sender likes. Every
            // build sends at most one "\r" before the "\n", so twice the limit
            // refuses nothing that was ever sent.
            if ((long)scanned + part.Length > 2L * maxBytes) return null;
            kept += part.Length - part.Count((byte)'\r');
            if (kept > maxBytes) return null;
            if (at >= 0)
            {
                var line = buffer.AsSpan(start, scanned + at);
                byte[] result = new byte[kept];
                int written = 0;
                foreach (byte b in line)
                {
                    if (b != (byte)'\r') result[written++] = b;
                }
                start += scanned + at + 1;
                return result;
            }
            scanned = end - start;
            if (await FillAsync(cancellationToken) == 0) return null;
        }
    }

    // Reads more from the stream after what is buffered, making room first:
    // what was handed out already is let go of, and a buffer full of one
    // unfinished line is doubled. 0 at the end of the stream.
    private async ValueTask<int> FillAsync(CancellationToken cancellationToken)
    {
        if (start == end)
        {
            start = end = 0;
        }
        else if (end == buffer.Length)
        {
            int pending = end - start;
            if (start > 0 && pending <= buffer.Length / 2)
            {
                buffer.AsSpan(start, pending).CopyTo(buffer);
            }
            else
            {
                if (buffer.Length >= Array.MaxLength) throw new InvalidDataException("A line too long to read.");
                byte[] bigger = ByteBuffers.Rent((int)Math.Min(Array.MaxLength, (long)buffer.Length * 2));
                buffer.AsSpan(start, pending).CopyTo(bigger);
                ByteBuffers.Return(buffer);
                buffer = bigger;
            }
            start = 0;
            end = pending;
        }
        int read = await stream.ReadAsync(buffer.AsMemory(end), cancellationToken);
        end += read;
        return read;
    }

    // After a line of many MB (a history batch of pictures), back to a buffer
    // of the usual size, so that one line isn't held for the connection's life.
    private void ShrinkAfterLongLine()
    {
        int pending = end - start;
        if (buffer.Length <= ByteBuffers.MaxPooled || pending > InitialSize) return;
        byte[] smaller = ByteBuffers.Rent(InitialSize);
        buffer.AsSpan(start, pending).CopyTo(smaller);
        ByteBuffers.Return(buffer);
        buffer = smaller;
        start = 0;
        end = pending;
    }

    public void Dispose()
    {
        var was = buffer;
        buffer = Array.Empty<byte>();
        start = end = 0;
        ByteBuffers.Return(was);
    }
}
