package io.uaena.cliplink

import io.uaena.cliplink.clipboard.sharedCopyOf
import io.uaena.cliplink.net.FileChunkMessage
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.net.FileRequestMessage
import io.uaena.cliplink.share.ShareIntake
import io.uaena.cliplink.share.ShareOutcome
import io.uaena.cliplink.share.isShareableUri
import io.uaena.cliplink.share.pickSharedUris
import io.uaena.cliplink.share.sharedFileName
import io.uaena.cliplink.store.FileNames
import io.uaena.cliplink.store.FileStore
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Sharing into ClipLink, and the file hashes and names that come with any
 * file - shared in here, or sent by a peer: which URIs are read at all, what
 * a file is called on the wire, and that a hash can only ever name a blob in
 * the FileStore.
 */
class ShareTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // ---- which shared URIs are read ----------------------------------------

    @Test
    fun `only content uris from other apps are read`() {
        val own = "io.uaena.cliplink.files"
        assertTrue(isShareableUri("content", "com.android.providers.media.documents", own))
        assertTrue(isShareableUri("content", "com.google.android.apps.photos.contentprovider", own))

        // file:// is opened with ClipLink's own permissions - its private files.
        assertFalse(isShareableUri("file", null, own))
        assertFalse(isShareableUri("file", "", own))
        // ContentResolver only treats exactly "content" as a provider URI.
        assertFalse(isShareableUri("CONTENT", "com.example.provider", own))
        assertFalse(isShareableUri("android.resource", "com.example", own))
        assertFalse(isShareableUri("https", "example.com", own))
        assertFalse(isShareableUri(null, "com.example.provider", own))
        assertFalse(isShareableUri("content", null, own))
        assertFalse(isShareableUri("content", "", own))
    }

    @Test
    fun `this app's own file provider is refused however it is spelled`() {
        val own = "io.uaena.cliplink.files"
        assertFalse(isShareableUri("content", own, own))
        assertFalse(isShareableUri("content", "IO.UAENA.CLIPLINK.FILES", own))
        // A user id prefix still resolves to this app's provider.
        assertFalse(isShareableUri("content", "0@$own", own))
        assertFalse(isShareableUri("content", "10@$own", own))
        assertFalse(isShareableUri("content", "0@", own))
        // Another app's authority that merely contains ours is someone else's.
        assertTrue(isShareableUri("content", "$own.other", own))
    }

    @Test
    fun `a share is its streams, plus whatever else its clip data carries`() {
        // SEND_MULTIPLE: the system mirrors EXTRA_STREAM into the ClipData.
        assertEquals(listOf("a", "b"), pickSharedUris(listOf("a", "b"), listOf("a", "b"), hasText = false))
        // A caption next to files doesn't change which files.
        assertEquals(listOf("a"), pickSharedUris(listOf("a"), listOf("a"), hasText = true))
        assertEquals(listOf("a", "b"), pickSharedUris(listOf("a", "a"), listOf("b"), hasText = false))
        // Some apps only fill in the ClipData.
        assertEquals(listOf("c"), pickSharedUris(emptyList(), listOf("c", "c"), hasText = false))
        assertEquals(emptyList<String>(), pickSharedUris(emptyList<String>(), emptyList(), hasText = false))
    }

    @Test
    fun `a link's preview thumbnail is not what was shared`() {
        // A browser sharing a page: EXTRA_TEXT is the link, the ClipData only
        // the image the share sheet previews it with. The link gets synced.
        assertEquals(emptyList<String>(), pickSharedUris(emptyList(), listOf("thumbnail"), hasText = true))
    }

    // ---- file names -------------------------------------------------------

    @Test
    fun `a name keeps only its last path segment`() {
        assertEquals("passwd", FileNames.safe("../../etc/passwd", "file"))
        assertEquals("evil.exe", FileNames.safe("C:\\Users\\me\\AppData\\Roaming\\Startup\\evil.exe", "file"))
        assertEquals("x.txt", FileNames.safe("/data/data/io.uaena.cliplink/shared_prefs/../x.txt", "file"))
        assertEquals("report.pdf", FileNames.safe("report.pdf", "file"))
    }

    @Test
    fun `nothing left of a name falls back`() {
        assertEquals("file", FileNames.safe(null, "file"))
        assertEquals("file", FileNames.safe("", "file"))
        assertEquals("file", FileNames.safe("   ", "file"))
        assertEquals("file", FileNames.safe(".", "file"))
        assertEquals("file", FileNames.safe("..", "file"))
        assertEquals("file", FileNames.safe("../..", "file"))
        assertEquals("file", FileNames.safe("dir/", "file"))
        assertEquals("file", FileNames.safe(". . .", "file"))
    }

    @Test
    fun `invalid characters are replaced and invisible ones removed`() {
        assertEquals("a_b_c_d_e_f_g_.txt", FileNames.safe("a:b*c?d\"e<f>g|.txt", "file"))
        // Removed, as Windows' FileNames.Safe removes them - the same set a
        // device name loses.
        val unsafe = (0x00..0x1F) + (0x7F..0x9F) + 0x061C + (0x200B..0x200F) +
            (0x202A..0x202E) + (0x2066..0x2069) + 0xFEFF
        for (codePoint in unsafe) {
            val name = "a" + String(Character.toChars(codePoint)) + "b.txt"
            assertEquals("U+%04X".format(codePoint), "ab.txt", FileNames.safe(name, "file"))
        }
        assertEquals("linebreak.txt", FileNames.safe("line\nbreak.txt", "file"))
        assertEquals("nul.txt", FileNames.safe("nul\u0000.txt", "file"))
        // Shown as "invoiceexe.txt" if the override were kept.
        assertEquals("invoicetxt.exe", FileNames.safe("invoice\u202Etxt.exe", "file"))
        assertEquals("report.pdf", FileNames.safe("report\u200B.pdf", "file"))
        // Removed, THEN trimmed: the spaces they were hiding go too.
        assertEquals("name.txt", FileNames.safe("\uFEFF name.txt \u200E", "file"))
        assertEquals("file", FileNames.safe("\u202E\u200B\u0007", "file"))
        assertEquals("name.txt", FileNames.safe("  name.txt . ", "file"))
        assertEquals("Café 日本語 😀.png", FileNames.safe("Café 日本語 😀.png", "file"))
    }

    @Test
    fun `a long name is cut to 120 characters keeping its extension`() {
        val long = "a".repeat(200) + ".jpeg"
        val safe = FileNames.safe(long, "file")
        assertEquals(120, safe.length)
        assertTrue(safe.endsWith("a.jpeg"))

        // An "extension" that long is just part of the name.
        val noExtension = FileNames.safe("x." + "b".repeat(200), "file")
        assertEquals(120, noExtension.length)
        assertEquals("x.", noExtension.take(2))
    }

    @Test
    fun `a long name also fits the file system's 255 bytes`() {
        // 100 CJK characters: under the character cap, but 300 bytes of UTF-8.
        val cjk = FileNames.safe("文".repeat(100) + ".pdf", "file")
        assertTrue(cjk.endsWith("文.pdf"))
        assertTrue(cjk.toByteArray(Charsets.UTF_8).size <= 240)
        assertEquals(78 + 4, cjk.length) // 78 * 3 + 4 bytes = 238

        // Four-byte emoji are never split either.
        val emoji = FileNames.safe("😀".repeat(70), "file")
        assertTrue(emoji.toByteArray(Charsets.UTF_8).size <= 240)
        assertEquals("😀".repeat(60), emoji)
    }

    @Test
    fun `a long name that cuts down to nothing falls back`() {
        // The cut keeps only dots, which are trimmed, and the "extension" is
        // too long to keep: without the fallback this named the folder itself.
        assertEquals("file", FileNames.safe(".".repeat(150) + "b".repeat(21), "file"))
        assertEquals("file", FileNames.safe(". ".repeat(75) + "." + "b".repeat(30), "file"))
    }

    @Test
    fun `a received file name is made safe when parsed`() {
        fun parsedName(name: String) = FilePayload.parse(
            JSONObject().put("FileName", name).put("FileHash", hash).put("FileSize", 1).toString(),
        )?.fileName
        assertEquals("report.pdf", parsedName("report.pdf"))
        assertEquals("invoicetxt.exe", parsedName("invoice\u202Etxt.exe"))
        assertEquals("passwd", parsedName("../../etc/passwd"))
        assertEquals("file", parsedName(".."))
        assertEquals("file", FilePayload.parse(JSONObject().put("FileHash", hash).toString())?.fileName)
    }

    @Test
    fun `cutting a long name never splits a character`() {
        // 119 chars then an emoji (a surrogate pair) straddling the cut.
        val name = "a".repeat(119) + "😀" + "tail"
        val safe = FileNames.safe(name, "file")
        assertEquals("a".repeat(119), safe)
        assertFalse(Character.isHighSurrogate(safe.last()))
    }

    @Test
    fun `a shared file is named from its provider then its uri`() {
        assertEquals("IMG_1.jpg", sharedFileName("IMG_1.jpg", "1234", "jpg"))
        assertEquals("secret", sharedFileName("../../secret", null, null))
        // Only a media id to go on: the MIME type supplies the extension.
        assertEquals("1234.jpg", sharedFileName(null, "1234", "jpg"))
        assertEquals("1234.jpg", sharedFileName("  ", "1234", "jpg"))
        assertEquals("file.pdf", sharedFileName(null, null, "pdf"))
        assertEquals("file", sharedFileName(null, null, null))
        // A name with an extension already keeps it.
        assertEquals("notes.txt", sharedFileName("notes.txt", null, "bin"))
        // An extension that isn't one is ignored.
        assertEquals("1234", sharedFileName(null, "1234", "../x"))
    }

    @Test
    fun `two files with one name get a shared copy each`() {
        val shared = temp.newFolder("shared")
        val first = File(temp.root, hash)
        val second = File(temp.root, "a".repeat(64))
        // Same name - and say the same length: still two copies, never the first one's bytes twice.
        assertEquals(File(shared, "$hash/id_ed25519"), sharedCopyOf(shared, first, "id_ed25519"))
        assertEquals(File(shared, "${"a".repeat(64)}/id_ed25519"), sharedCopyOf(shared, second, "id_ed25519"))
        // And a peer's name still only ever names a file in that folder.
        assertEquals(File(shared, "$hash/passwd"), sharedCopyOf(shared, first, "../../etc/passwd"))
        assertEquals(File(shared, "$hash/file"), sharedCopyOf(shared, first, ".."))
    }

    // ---- file hashes ------------------------------------------------------

    @Test
    fun `only 64 hex digits are a file hash`() {
        assertTrue(FileStore.isValidHash(hash))
        assertTrue(FileStore.isValidHash(hash.uppercase())) // what Windows sends

        assertFalse(FileStore.isValidHash(null))
        assertFalse(FileStore.isValidHash(""))
        assertFalse(FileStore.isValidHash(hash.dropLast(1)))
        assertFalse(FileStore.isValidHash(hash + "0"))
        assertFalse(FileStore.isValidHash(hash.dropLast(1) + "g"))
        assertFalse(FileStore.isValidHash("../shared_prefs/cliplink_trust.xml"))
        assertFalse(FileStore.isValidHash("../" + hash.drop(3)))
        assertFalse(FileStore.isValidHash(hash.dropLast(4) + ".tmp"))
        // Non-ASCII digits are digits to Char.isDigit, not to this.
        assertFalse(FileStore.isValidHash(hash.dropLast(1) + "\u0661"))
    }

    @Test
    fun `peer messages naming anything but a hash are refused`() {
        val traversal = "../shared_prefs/cliplink_passphrase.xml"

        fun payload(fileHash: String) =
            JSONObject().put("FileName", "x").put("FileHash", fileHash).put("FileSize", 1).toString()
        assertEquals(hash, FilePayload.parse(payload(hash))?.fileHash)
        assertNull(FilePayload.parse(payload(traversal)))
        assertNull(FilePayload.parse(payload("")))

        fun chunk(fileHash: String) = JSONObject().put("FileHash", fileHash).put("ChunkIndex", 0)
            .put("IsLast", true).put("DataBase64", "AA==").toString()
        assertEquals(hash, FileChunkMessage.parse(chunk(hash))?.fileHash)
        assertNull(FileChunkMessage.parse(chunk(traversal)))

        assertEquals(hash, FileRequestMessage.parse(FileRequestMessage(hash).toJson())?.fileHash)
        assertNull(FileRequestMessage.parse(FileRequestMessage(traversal).toJson()))
        assertNull(FileRequestMessage.parse(FileRequestMessage("/data/data/x").toJson()))
    }

    @Test
    fun `the file store never turns a bad hash into a path`() {
        val base = temp.newFolder("cliplink_files")
        val store = FileStore(base, temp.newFolder("shared"))
        val outside = File(temp.root, "cliplink_trust.xml").apply { writeText("trusted devices") }
        val escape = "../cliplink_trust.xml"

        assertFalse(store.exists(escape))
        store.delete(escape)
        assertTrue(outside.exists())
        assertThrows { store.path(escape) }
        assertThrows { store.tempPath(escape) }
        assertThrows { store.write(escape, byteArrayOf(1)) }
        assertEquals("trusted devices", outside.readText())

        assertEquals(File(base, hash), store.path(hash))
        assertFalse(store.exists(hash))
    }

    // ---- streaming a shared file into the store ------------------------------

    @Test
    fun `a shared file is stored under its hash`() {
        val base = temp.newFolder("cliplink_files")
        val store = FileStore(base, temp.newFolder("shared"))
        val bytes = ByteArray(700_000) { (it % 251).toByte() } // several buffers' worth

        val stored = store.importStream(ByteArrayInputStream(bytes), ShareIntake.MAX_FILE_BYTES)!!
        assertEquals(FileStore.hashOf(bytes), stored.hash)
        assertEquals(bytes.size.toLong(), stored.size)
        assertArrayEquals(bytes, store.path(stored.hash).readBytes())
        // Only the blob is left - no temp file.
        assertEquals(listOf(stored.hash), base.list()!!.toList())

        // The same bytes again: same blob, still one file.
        assertEquals(stored, store.importStream(ByteArrayInputStream(bytes), ShareIntake.MAX_FILE_BYTES))
        assertEquals(listOf(stored.hash), base.list()!!.toList())

        // Empty is a file too.
        assertEquals(FileStore.Stored(hash, 0), store.importStream(ByteArrayInputStream(ByteArray(0)), 10))
    }

    @Test
    fun `a file over the cap is refused and nothing is kept`() {
        val base = temp.newFolder("cliplink_files")
        val store = FileStore(base, temp.newFolder("shared"))

        assertNull(store.importStream(ByteArrayInputStream(ByteArray(1001)), maxBytes = 1000))
        assertEquals(0, base.list()!!.size)
        // Exactly at the cap is fine.
        assertEquals(1000L, store.importStream(ByteArrayInputStream(ByteArray(1000)), maxBytes = 1000)?.size)
    }

    @Test
    fun `copying stops reading once past the cap`() {
        var read = 0L
        val endless = object : java.io.InputStream() {
            override fun read(): Int = 0.also { read++ }
            override fun read(b: ByteArray, off: Int, len: Int): Int = len.also { read += it }
        }
        assertNull(FileStore.copyHashed(endless, ByteArrayOutputStream(), maxBytes = 1_000_000))
        assertTrue("read $read bytes", read < 2_000_000)
    }

    @Test
    fun `an import a killed process left behind is swept on start`() {
        val base = temp.newFolder("cliplink_files")
        val leftover = File(base, "import_123.part").apply { writeText("half") }
        val blob = File(base, hash).apply { writeText("") }
        FileStore(base, temp.newFolder("shared"))
        assertFalse(leftover.exists())
        assertTrue(blob.exists())
    }

    // ---- what the user is told ---------------------------------------------

    @Test
    fun `the result names what was shared and whether it went anywhere`() {
        assertEquals("Synced text.", ShareOutcome(text = true, connected = 1).message)
        assertEquals("Synced IMG_1.jpg.", ShareOutcome(files = listOf("IMG_1.jpg"), connected = 2).message)
        assertEquals("Synced 3 files.", ShareOutcome(files = listOf("a", "b", "c"), connected = 1).message)
        assertEquals(
            "Saved IMG_1.jpg - it'll sync when a device connects.",
            ShareOutcome(files = listOf("IMG_1.jpg")).message,
        )
        assertEquals(
            "Saved 2 files - they'll sync when a device connects.",
            ShareOutcome(files = listOf("a", "b")).message,
        )
        assertEquals("Nothing to share.", ShareOutcome().message)
    }

    @Test
    fun `the result says what couldn't be shared`() {
        assertEquals("ClipLink couldn't read that file.", ShareOutcome(unreadable = 1).message)
        assertEquals("ClipLink couldn't read those files.", ShareOutcome(unreadable = 3).message)
        assertEquals(
            "Synced a.png. Couldn't read 2 files.",
            ShareOutcome(files = listOf("a.png"), unreadable = 2, connected = 1).message,
        )
        assertEquals("movie.mkv is over 1 GB, too big to sync.", ShareOutcome(tooLarge = listOf("movie.mkv")).message)
        assertEquals(
            "2 files are over 1 GB, too big to sync. Couldn't read 1 file.",
            ShareOutcome(tooLarge = listOf("a", "b"), unreadable = 1).message,
        )
        assertEquals(
            "Synced 25 files. ClipLink keeps 25 items, so 5 more files were left out.",
            ShareOutcome(files = List(25) { "f$it" }, skipped = 5, connected = 1).message,
        )
        assertEquals(
            "ClipLink couldn't share that - open it and try again.",
            ShareOutcome(files = listOf("a"), failed = true).message,
        )
    }

    private fun assertThrows(block: () -> Unit) {
        val threw = try {
            block()
            false
        } catch (e: IllegalArgumentException) {
            true
        }
        assertTrue("expected IllegalArgumentException", threw)
    }
}
