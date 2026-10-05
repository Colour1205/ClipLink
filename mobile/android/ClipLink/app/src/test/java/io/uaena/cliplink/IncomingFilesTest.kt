package io.uaena.cliplink

import io.uaena.cliplink.net.FileChunkMessage
import io.uaena.cliplink.net.IncomingFiles
import io.uaena.cliplink.net.IncomingFiles.Result
import io.uaena.cliplink.store.FileStore
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Files arriving as chunk streams: one sender's stream per file, in order,
 * and nothing ever appended to a stream that broke off.
 */
class IncomingFilesTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var base: File
    private lateinit var store: FileStore
    private lateinit var incoming: IncomingFiles<String>

    private val bytes = ByteArray(20_000) { (it * 7 % 251).toByte() }
    private val hash = FileStore.hashOf(bytes)

    /** [bytes] in 4 KB chunks - five of them - as a sender numbers them. */
    private val chunks = bytes.toList().chunked(4096).map { it.toByteArray() }

    @Before
    fun setUp() {
        base = temp.newFolder("cliplink_files")
        store = FileStore(base, temp.newFolder("shared"))
        incoming = IncomingFiles(store)
    }

    private fun chunk(index: Int, hash: String = this.hash) =
        FileChunkMessage(hash, index, isLast = index == chunks.lastIndex, dataBase64 = "-")

    /** Every chunk of [bytes] from [owner], from [from] on; the last result. */
    private fun stream(owner: String, from: Int = 0): Result =
        (from..chunks.lastIndex).map { incoming.receive(owner, chunk(it), chunks[it]) }.last()

    private fun assertStored() {
        assertTrue(store.exists(hash))
        assertArrayEquals(bytes, store.path(hash).readBytes())
        assertEquals(listOf(hash), base.list()!!.toList()) // no temp file left
        assertFalse(incoming.isReceiving(hash))
    }

    @Test
    fun `a stream in order is stored under its hash`() {
        assertEquals(Result.Written, incoming.receive("A", chunk(0), chunks[0]))
        assertTrue(incoming.isReceiving(hash))
        assertEquals(Result.Stored, stream("A", from = 1))
        assertStored()
    }

    @Test
    fun `a second sender's stream of the same file is ignored`() {
        // Two peers answered the same file_request.
        assertEquals(Result.Written, incoming.receive("A", chunk(0), chunks[0]))
        assertEquals(Result.Ignored, incoming.receive("B", chunk(0), chunks[0]))
        assertEquals(Result.Written, incoming.receive("A", chunk(1), chunks[1]))
        assertEquals(Result.Ignored, incoming.receive("B", chunk(1), chunks[1]))
        assertEquals(Result.Stored, stream("A", from = 2))
        assertStored()

        // B's stream goes on after A's is stored: nothing more to write.
        assertEquals(Result.Ignored, incoming.receive("B", chunk(2), chunks[2]))
        assertEquals(Result.Ignored, incoming.receive("B", chunk(0), chunks[0]))
        assertStored()
    }

    @Test
    fun `a gap in a stream abandons it`() {
        incoming.receive("A", chunk(0), chunks[0])
        val result = incoming.receive("A", chunk(2), chunks[2])
        assertTrue(result is Result.Failed)
        assertFalse(incoming.isReceiving(hash))
        assertEquals(emptyList<String>(), base.list()!!.toList())

        // What's left of that stream can't make a file...
        assertEquals(Result.Ignored, incoming.receive("A", chunk(3), chunks[3]))
        // ...but the next one from the start can.
        assertEquals(Result.Stored, stream("A"))
        assertStored()
    }

    @Test
    fun `a stream that starts over is never appended to the old one`() {
        // A transfer cut off halfway, then the same file sent again from chunk 0.
        incoming.receive("A", chunk(0), chunks[0])
        incoming.receive("A", chunk(1), chunks[1])
        assertEquals(Result.Stored, stream("A"))
        assertStored()
    }

    @Test
    fun `a stream whose start was missed is ignored`() {
        assertEquals(Result.Ignored, incoming.receive("A", chunk(1), chunks[1]))
        assertEquals(Result.Ignored, incoming.receive("A", chunk(chunks.lastIndex), chunks.last()))
        assertFalse(store.exists(hash))
        assertEquals(emptyList<String>(), base.list()!!.toList())
    }

    @Test
    fun `a sender that goes takes its transfers with it`() {
        incoming.receive("A", chunk(0), chunks[0])
        assertEquals(listOf(hash), incoming.abandonAll("A"))
        assertEquals(emptyList<String>(), incoming.abandonAll("A"))
        assertFalse(incoming.isReceiving(hash))
        assertEquals(emptyList<String>(), base.list()!!.toList())

        // Its leftover chunks write nothing; another sender can now send it whole.
        assertEquals(Result.Ignored, incoming.receive("A", chunk(1), chunks[1]))
        assertEquals(Result.Stored, stream("B"))
        assertStored()
    }

    @Test
    fun `bytes that don't hash to their name are discarded`() {
        val wrong = "b".repeat(64)
        incoming.receive("A", chunk(0, wrong), chunks[0])
        val result = incoming.receive("A", FileChunkMessage(wrong, 1, isLast = true, dataBase64 = "-"), chunks[1])
        assertTrue(result is Result.Failed)
        assertFalse(store.exists(wrong))
        assertFalse(incoming.isReceiving(wrong))
        assertEquals(emptyList<String>(), base.list()!!.toList())
    }

    @Test
    fun `an empty last chunk ends a file - and an empty file`() {
        // iOS ends a stream with an empty chunk when the file shrank to fit.
        chunks.forEachIndexed { i, data -> incoming.receive("A", FileChunkMessage(hash, i, false, "-"), data) }
        assertEquals(Result.Stored, incoming.receive("A", FileChunkMessage(hash, chunks.size, true, ""), ByteArray(0)))
        assertStored()

        // A 0-byte file is one empty chunk.
        val empty = FileStore.EMPTY_FILE_HASH
        assertEquals(Result.Stored, incoming.receive("A", FileChunkMessage(empty, 0, true, ""), ByteArray(0)))
        assertEquals(0L, store.path(empty).length())
        // Already here (storeEmpty, say): nothing to write.
        assertEquals(Result.Ignored, incoming.receive("B", FileChunkMessage(empty, 0, true, ""), ByteArray(0)))
    }

    @Test
    fun `different files arrive side by side`() {
        val other = ByteArray(5000) { (it % 13).toByte() }
        val otherHash = FileStore.hashOf(other)
        incoming.receive("A", chunk(0), chunks[0])
        assertEquals(
            Result.Written,
            incoming.receive("B", FileChunkMessage(otherHash, 0, false, "-"), other.copyOf(2500)),
        )
        assertEquals(Result.Stored, stream("A", from = 1))
        assertEquals(
            Result.Stored,
            incoming.receive("B", FileChunkMessage(otherHash, 1, true, "-"), other.copyOfRange(2500, 5000)),
        )
        assertArrayEquals(bytes, store.path(hash).readBytes())
        assertArrayEquals(other, store.path(otherHash).readBytes())
    }
}
