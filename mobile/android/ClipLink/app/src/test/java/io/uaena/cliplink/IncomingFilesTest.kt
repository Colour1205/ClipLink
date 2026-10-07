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

    // ---- limits on what a peer may make this device store -------------------------

    private class FakeClock(var now: Long = 1_000L)

    @Test
    fun `a file bigger than the cap is refused as it grows, not after it is on disk`() {
        incoming = IncomingFiles(store, maxFileBytes = 10_000)
        assertEquals(Result.Written, incoming.receive("A", chunk(0), chunks[0])) // 4096
        assertEquals(Result.Written, incoming.receive("A", chunk(1), chunks[1])) // 8192
        val result = incoming.receive("A", chunk(2), chunks[2]) // 12288 > 10000
        assertTrue(result is Result.Failed)
        assertFalse(incoming.isReceiving(hash))
        assertEquals(emptyList<String>(), base.list()!!.toList()) // the .tmp went too
    }

    @Test
    fun `an entry that claims more than the cap is refused before any byte is written`() {
        incoming = IncomingFiles(store, sizeHint = { 5_000_000_000L }, maxFileBytes = 1L shl 30)
        val result = incoming.receive("A", chunk(0), chunks[0])
        assertTrue(result is Result.Failed)
        assertEquals(emptyList<String>(), base.list()!!.toList())
    }

    @Test
    fun `a file that is not the size its entry says is refused even if it hashes right`() {
        // The right bytes under a wrong claimed size: not the file the sender vouched for.
        incoming = IncomingFiles(store, sizeHint = { bytes.size.toLong() + 1 })
        val result = stream("A")
        assertEquals(Result.Failed("file size doesn't match its entry"), result)
        assertFalse(store.exists(hash))
        assertEquals(emptyList<String>(), base.list()!!.toList())
    }

    @Test
    fun `a file may not run past the size its entry says`() {
        incoming = IncomingFiles(store, sizeHint = { 5_000L })
        assertEquals(Result.Written, incoming.receive("A", chunk(0), chunks[0])) // 4096 <= 5000
        val result = incoming.receive("A", chunk(1), chunks[1]) // 8192 > 5000
        assertTrue(result is Result.Failed)
        assertEquals(emptyList<String>(), base.list()!!.toList())
    }

    @Test
    fun `a file of exactly the stated size is stored`() {
        incoming = IncomingFiles(store, sizeHint = { bytes.size.toLong() })
        assertEquals(Result.Stored, stream("A"))
        assertStored()
    }

    @Test
    fun `an entry that doesn't say a size is no bar`() {
        incoming = IncomingFiles(store, sizeHint = { null })
        assertEquals(Result.Stored, stream("A"))
        assertStored()
    }

    @Test
    fun `only so many files are received at once, and one peer only so many`() {
        incoming = IncomingFiles(store, maxStreams = 3, maxStreamsPerOwner = 2)
        fun hashOf(n: Int) = n.toString(16).padStart(64, '0')
        fun start(owner: String, n: Int) = incoming.receive(owner, FileChunkMessage(hashOf(n), 0, false, "-"), chunks[0])

        assertEquals(Result.Written, start("A", 1))
        assertEquals(Result.Written, start("A", 2))
        // A third from the same peer: over its share. Turned away, not failed.
        assertEquals(Result.Ignored, start("A", 3))
        assertEquals(Result.Written, start("B", 4)) // another peer is fine: 3 in all
        assertEquals(Result.Ignored, start("C", 5)) // and now the total is reached
        assertEquals(3, base.list()!!.size) // only the three .tmp files exist

        // One ends: a place frees up.
        incoming.abandonAll("B")
        assertEquals(Result.Written, start("C", 5))
        assertFalse(incoming.isReceiving(hashOf(3)))
    }

    @Test
    fun `a stream that stops getting chunks is let go, and its file with it`() {
        val clock = FakeClock()
        incoming = IncomingFiles(store, idleMs = 60_000, clock = { clock.now })
        incoming.receive("A", chunk(0), chunks[0])
        clock.now += 30_000
        incoming.receive("A", chunk(1), chunks[1]) // still going: its idle time starts over

        clock.now += 59_000
        assertEquals(emptyList<String>(), incoming.dropStale())
        assertTrue(incoming.isReceiving(hash))

        clock.now += 2_000
        assertEquals(listOf(hash), incoming.dropStale())
        assertFalse(incoming.isReceiving(hash))
        assertEquals(emptyList<String>(), base.list()!!.toList())
        // Another sender can now send it whole.
        assertEquals(Result.Stored, stream("B"))
        assertStored()
    }

    @Test
    fun `dropping a stale stream late never deletes a newer stream's file`() {
        val clock = FakeClock()
        incoming = IncomingFiles(store, idleMs = 1_000, clock = { clock.now })
        incoming.receive("A", chunk(0), chunks[0])
        clock.now += 5_000
        incoming.dropStale()
        // B starts the same file; A's late chunks must not touch B's temp file.
        incoming.receive("B", chunk(0), chunks[0])
        assertEquals(Result.Ignored, incoming.receive("A", chunk(1), chunks[1]))
        assertTrue(incoming.isReceiving(hash))
        assertEquals(listOf("$hash.tmp"), base.list()!!.toList())
        assertEquals(Result.Stored, stream("B", from = 1))
        assertStored()
    }
}
