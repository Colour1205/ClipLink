package io.uaena.cliplink

import io.uaena.cliplink.core.LineReader
import io.uaena.cliplink.core.LineReader.Line
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.SocketTimeoutException

/**
 * The line cap that stands between a stranger's bytes and the heap: lines
 * split correctly, a line over the cap is dropped without being held, and
 * the next line is still there.
 */
class LineReaderTest {

    private fun reader(text: String, bufferSize: Int = LineReader.DEFAULT_BUFFER_SIZE) =
        LineReader(ByteArrayInputStream(text.toByteArray(Charsets.UTF_8)), bufferSize)

    private fun Line.text(): String = String((this as Line.Data).bytes, Charsets.UTF_8)

    @Test
    fun `lines end at a newline or a carriage return and newline`() {
        val lines = reader("one\ntwo\r\nthree\n\nfour")
        assertEquals("one", lines.readLine(100).text())
        assertEquals("two", lines.readLine(100).text())
        assertEquals("three", lines.readLine(100).text())
        assertEquals("", lines.readLine(100).text()) // an empty line is a line
        assertEquals("four", lines.readLine(100).text()) // the last one needs no newline
        assertTrue(lines.readLine(100) is Line.Eof)
    }

    @Test
    fun `nothing at all is the end of the stream`() {
        assertTrue(reader("").readLine(10) is Line.Eof)
        val lines = reader("a\n")
        assertEquals("a", lines.readLine(10).text())
        assertTrue(lines.readLine(10) is Line.Eof)
    }

    @Test
    fun `a line and its ending can be split across reads however small they are`() {
        val text = "hello world\r\nsecond line\nthird"
        for (size in listOf(1, 2, 3, 5, 7, 64)) {
            val lines = reader(text, bufferSize = size)
            assertEquals("size $size", "hello world", lines.readLine(100).text())
            assertEquals("size $size", "second line", lines.readLine(100).text())
            assertEquals("size $size", "third", lines.readLine(100).text())
            assertTrue(lines.readLine(100) is Line.Eof)
        }
    }

    @Test
    fun `a line right at the cap is kept and one byte over is not`() {
        val atCap = "x".repeat(100)
        val over = "y".repeat(101)
        val lines = reader("$atCap\n$over\nnext\n", bufferSize = 16)
        assertEquals(atCap, lines.readLine(100).text())
        val dropped = lines.readLine(100)
        assertTrue(dropped is Line.TooLong)
        assertEquals(101L, (dropped as Line.TooLong).bytes)
        // The line after it is untouched.
        assertEquals("next", lines.readLine(100).text())
    }

    @Test
    fun `a stream with no newline is dropped at the end and never held`() {
        // 40 MB of "data" and not one newline: what made BufferedReader.readLine
        // run the app out of memory. Here it is counted and thrown away.
        val endless = object : InputStream() {
            private var remaining = 40L * 1024 * 1024
            override fun read(): Int = if (remaining-- > 0) 'a'.code else -1
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (remaining <= 0) return -1
                val n = minOf(len.toLong(), remaining).toInt()
                java.util.Arrays.fill(b, off, off + n, 'a'.code.toByte())
                remaining -= n
                return n
            }
        }
        val line = LineReader(endless).readLine(8 * 1024)
        assertTrue(line is Line.TooLong)
        assertEquals(40L * 1024 * 1024, (line as Line.TooLong).bytes)
    }

    @Test
    fun `a cut-off line over the cap is still dropped once the stream ends`() {
        val lines = reader("z".repeat(50))
        assertTrue(lines.readLine(10) is Line.TooLong)
        assertTrue(lines.readLine(10) is Line.Eof)
    }

    @Test
    fun `any bytes arriving are reported, even mid-line`() {
        var reads = 0
        val lines = reader("abcdefghij\n", bufferSize = 4)
        lines.onBytes = { reads++ }
        assertEquals("abcdefghij", lines.readLine(100).text())
        assertEquals(3, reads) // 4 + 4 + 3 bytes
    }

    @Test
    fun `the handshake deadline can abort a read before it blocks`() {
        val lines = reader("slow\n", bufferSize = 2)
        var calls = 0
        lines.beforeRead = {
            if (++calls > 2) throw SocketTimeoutException("handshake took too long")
        }
        try {
            lines.readLine(100)
            fail("expected the deadline to end the read")
        } catch (e: SocketTimeoutException) {
            assertEquals(3, calls)
        }
    }

    @Test
    fun `a line is returned as exactly its bytes`() {
        val bytes = byteArrayOf(0x41, 0xC3.toByte(), 0xA9.toByte(), 0x00, 0x7F)
        val lines = LineReader(ByteArrayInputStream(bytes + '\n'.code.toByte()))
        assertArrayEquals(bytes, (lines.readLine(100) as Line.Data).bytes)
        assertFalse(lines.readLine(100) is Line.Data)
    }
}
