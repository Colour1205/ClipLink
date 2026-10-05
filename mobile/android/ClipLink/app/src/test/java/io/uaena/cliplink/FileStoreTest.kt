package io.uaena.cliplink

import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.ImageFiles
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File

/**
 * What the FileStore holds besides what peers stream into it: the empty
 * file no peer ever sends, the sweep of blobs nothing refers to, and which
 * file entries are pictures.
 */
class FileStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val empty = FileStore.EMPTY_FILE_HASH
    private val other = "a".repeat(64)

    private fun store(base: File = temp.newFolder("cliplink_files")) = FileStore(base, temp.newFolder())

    private fun payload(hash: String, size: Long) = FilePayload.parse(
        JSONObject().put("FileName", "empty.txt").put("FileHash", hash).put("FileSize", size).toString(),
    )!!

    // ---- 0-byte files -------------------------------------------------------

    @Test
    fun `the empty file's hash is the sha-256 of nothing`() {
        assertEquals(FileStore.hashOf(ByteArray(0)), empty)
    }

    @Test
    fun `a 0-byte file entry is recognised by its size and hash in either case`() {
        assertTrue(payload(empty, 0).isEmptyFile)
        assertTrue(payload(empty.uppercase(), 0).isEmptyFile) // as Windows spells it
        // A size of 0 on some other hash is a claim no bytes could ever meet.
        assertFalse(payload(other, 0).isEmptyFile)
        assertFalse(payload(empty, 1).isEmptyFile)
    }

    @Test
    fun `a 0-byte file is stored without anything arriving`() {
        val base = temp.newFolder("cliplink_files")
        val store = store(base)

        store.storeEmpty(empty)
        assertTrue(store.exists(empty))
        assertEquals(0L, store.path(empty).length())

        // Again is fine, and still no temp files.
        store.storeEmpty(empty)
        assertEquals(listOf(empty), base.list()!!.toList())

        // Named exactly as the entry spells it, like every other blob.
        val upperBase = temp.newFolder("upper")
        store(upperBase).storeEmpty(empty.uppercase())
        assertEquals(listOf(empty.uppercase()), upperBase.list()!!.toList())

        val refused = try {
            store.storeEmpty(other)
            false
        } catch (e: IllegalArgumentException) {
            true
        }
        assertTrue("only the empty file's hash", refused)
        assertFalse(store.exists(other))
    }

    @Test
    fun `a 0-byte share makes a well-formed entry`() {
        val stored = store().importStream(ByteArrayInputStream(ByteArray(0)), 10)!!
        val entry = FilePayload.parse(FilePayload("empty.txt", stored.hash, stored.size).toJson())!!
        assertEquals(empty, entry.fileHash)
        assertEquals(0L, entry.fileSize)
        assertTrue(entry.isEmptyFile)
    }

    // ---- sweeping unreferenced blobs ------------------------------------------

    @Test
    fun `the startup sweep deletes only what nothing refers to`() {
        val base = temp.newFolder("cliplink_files")
        val referenced = "b".repeat(64)
        val orphan = "c".repeat(64)
        listOf(referenced, orphan, other.uppercase(), "$orphan.tmp", "notes.txt").forEach {
            File(base, it).writeText("x")
        }
        val store = store(base)

        assertEquals(3, store.sweepUnreferenced(setOf(referenced, other)))
        // "AAA…" isn't "aaa…": a blob is named exactly as its entry spells it.
        assertEquals(setOf(referenced, "notes.txt"), base.list()!!.toSet())
    }

    @Test
    fun `the sweep spares whatever this process already touched`() {
        val base = temp.newFolder("cliplink_files")
        val imported = "d".repeat(64)
        val receiving = "e".repeat(64)
        File(base, imported).writeText("x")
        File(base, "$receiving.tmp").writeText("x")
        val store = store(base)

        // A share's import, not yet in the history; a transfer under way.
        store.path(imported)
        store.tempPath(receiving)
        val shared = store.importStream(ByteArrayInputStream(byteArrayOf(1, 2, 3)), 10)!!

        assertEquals(0, store.sweepUnreferenced(emptySet()))
        assertEquals(setOf(imported, "$receiving.tmp", shared.hash), base.list()!!.toSet())
    }

    @Test
    fun `the sweep runs once`() {
        val base = temp.newFolder("cliplink_files")
        val store = store(base)
        assertEquals(0, store.sweepUnreferenced(emptySet()))

        File(base, other).writeText("x")
        assertEquals(0, store.sweepUnreferenced(emptySet()))
        assertTrue(File(base, other).exists())
    }

    // ---- which files are pictures -------------------------------------------

    @Test
    fun `an image file is known by its extension`() {
        listOf("IMG_1.jpg", "a.JPEG", "b.png", "c.gif", "d.webp", "IMG_2.HEIC", "e.heif", "f.bmp").forEach {
            assertTrue(it, ImageFiles.isImageName(it))
        }
        listOf("report.pdf", "png", "photo.jpg.zip", "", null).forEach {
            assertFalse("$it", ImageFiles.isImageName(it))
        }
    }

    @Test
    fun `an image file with no telling name is known by its first bytes`() {
        fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
        fun ascii(text: String) = text.toByteArray(Charsets.ISO_8859_1)

        assertTrue(ImageFiles.isImageHeader(bytes(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0)))
        assertTrue(ImageFiles.isImageHeader(bytes(0xFF, 0xD8, 0xFF, 0xE1)))
        assertTrue(ImageFiles.isImageHeader(ascii("GIF89a....")))
        assertTrue(ImageFiles.isImageHeader(ascii("RIFF\u0000\u0001\u0000\u0000WEBPVP8 ")))
        assertTrue(ImageFiles.isImageHeader(ascii("\u0000\u0000\u0000\u0018ftypheic\u0000\u0000\u0000\u0000")))
        assertTrue(ImageFiles.isImageHeader(ascii("BM6\u0000\u0000\u0000\u0000\u0000\u0000\u00006\u0000\u0000\u0000(\u0000\u0000\u0000")))

        // Text that merely starts with "BM", and things that aren't pictures.
        assertFalse(ImageFiles.isImageHeader(ascii("BMW 3 series service history")))
        assertFalse(ImageFiles.isImageHeader(ascii("%PDF-1.7")))
        assertFalse(ImageFiles.isImageHeader(ascii("\u0000\u0000\u0000\u0018ftypmp42")))
        assertFalse(ImageFiles.isImageHeader(bytes(0xFF, 0xD8)))
        assertFalse(ImageFiles.isImageHeader(ByteArray(0)))

        val base = temp.newFolder("files")
        val jpeg = File(base, "1234").apply { writeBytes(bytes(0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10)) }
        val text = File(base, "file").apply { writeText("hello") }
        assertTrue(ImageFiles.looksLikeImage("1234", jpeg))
        assertFalse(ImageFiles.looksLikeImage("file", text))
        assertTrue(ImageFiles.looksLikeImage("photo.png", text)) // the name is enough to try
        assertFalse(ImageFiles.looksLikeImage("gone", File(base, "missing")))
    }
}
