package io.uaena.cliplink.core

import java.io.InputStream

/**
 * Newline-terminated lines off a stream, with a hard cap on how long one may
 * be. `BufferedReader.readLine` has none: a peer that streams bytes and never
 * sends a newline makes it buffer until the process runs out of memory, and
 * that is an Error, not an Exception - it sails past every `catch (e:
 * Exception)` and takes the whole app down. Here a line over the cap is read
 * and thrown away, a buffer at a time, so memory stays bounded whatever the
 * peer sends.
 *
 * Works on bytes, not characters: a line is UTF-8 or base64, and the caller
 * decodes it - which also saves the String a base64 line would otherwise be
 * turned into first. `\n` and `\r\n` both end a line.
 *
 * Plain JVM on purpose (no Android classes), so the limits can be unit-tested.
 * Not thread-safe: one reader, one thread.
 */
class LineReader(
    private val input: InputStream,
    bufferSize: Int = DEFAULT_BUFFER_SIZE,
) {

    /** What one call came to. */
    sealed interface Line {
        /** A whole line, without its line ending. May be empty. */
        class Data(val bytes: ByteArray) : Line

        /** The line was longer than the cap and was dropped; it had at least [bytes] bytes. */
        class TooLong(val bytes: Long) : Line

        /** The stream ended with nothing left over. */
        data object Eof : Line
    }

    /**
     * Called before every read that may block. May throw to abort the read -
     * the handshake sets the socket's timeout from the time it has left here,
     * so a peer that drips one byte at a time can't hold a thread past a total
     * deadline.
     */
    var beforeRead: (() -> Unit)? = null

    /** Called after every read that brought bytes: the peer is alive, even mid-line. */
    var onBytes: (() -> Unit)? = null

    private val buffer = ByteArray(bufferSize)
    private var position = 0
    private var limit = 0

    /**
     * The next line, at most [maxBytes] long (line ending not counted). A
     * final line the stream ends without a newline still counts as a line,
     * as `readLine` treats it. Throws what the stream throws.
     */
    fun readLine(maxBytes: Int): Line {
        var parts: ArrayList<ByteArray>? = null
        var total = 0L // of the line so far - counted, not kept, once it is over the cap
        var discarding = false
        var sawAny = false

        while (true) {
            if (position == limit && !fill()) {
                // The end of the stream.
                if (discarding) return Line.TooLong(total)
                if (!sawAny) return Line.Eof
                return Line.Data(join(parts, total.toInt()))
            }
            sawAny = true

            var end = position
            while (end < limit && buffer[end] != NEWLINE) end++
            val found = end < limit
            val length = end - position

            if (!discarding) {
                if (total + length > maxBytes) {
                    discarding = true
                    parts = null // let it go: nothing of this line is kept
                    total += length
                } else if (found && parts == null) {
                    // The common case: the whole line is in the buffer.
                    val line = trimCr(buffer, position, end)
                    position = end + 1
                    return Line.Data(line)
                } else {
                    if (length > 0) {
                        (parts ?: ArrayList<ByteArray>().also { parts = it }).add(buffer.copyOfRange(position, end))
                    }
                    total += length
                }
            } else {
                total += length
            }

            position = if (found) end + 1 else end
            if (found) {
                return if (discarding) Line.TooLong(total) else Line.Data(join(parts, total.toInt()))
            }
        }
    }

    /** False at the end of the stream. */
    private fun fill(): Boolean {
        while (true) {
            beforeRead?.invoke()
            val read = input.read(buffer, 0, buffer.size)
            if (read < 0) return false
            if (read == 0) continue // never for a non-empty buffer, but never spin on it either
            position = 0
            limit = read
            onBytes?.invoke()
            return true
        }
    }

    private fun join(parts: List<ByteArray>?, total: Int): ByteArray {
        if (parts == null || total == 0) return ByteArray(0)
        var length = total
        if (parts.last().last() == CARRIAGE_RETURN) length-- // the \r of a \r\n split across reads
        val out = ByteArray(length)
        var offset = 0
        for (part in parts) {
            val count = minOf(part.size, length - offset)
            if (count <= 0) break
            System.arraycopy(part, 0, out, offset, count)
            offset += count
        }
        return out
    }

    private fun trimCr(source: ByteArray, from: Int, to: Int): ByteArray {
        val end = if (to > from && source[to - 1] == CARRIAGE_RETURN) to - 1 else to
        return source.copyOfRange(from, end)
    }

    companion object {
        const val DEFAULT_BUFFER_SIZE = 32 * 1024
        private const val NEWLINE = '\n'.code.toByte()
        private const val CARRIAGE_RETURN = '\r'.code.toByte()
    }
}
