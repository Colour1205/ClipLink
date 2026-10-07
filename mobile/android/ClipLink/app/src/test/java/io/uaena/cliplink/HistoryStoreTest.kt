package io.uaena.cliplink

import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryFile
import io.uaena.cliplink.store.HistoryStore
import io.uaena.cliplink.store.LegacyHistory
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.StringWriter

/**
 * The history file: it round-trips, trims, migrates what the old
 * SharedPreferences string held, and survives being corrupt or cut short -
 * with a note in the log, never a crash. Temp folders and fakes, no device.
 */
class HistoryStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var storage: File
    private lateinit var blobs: File
    private lateinit var files: FileStore
    private val deleted = mutableSetOf<String>()
    private val problems = mutableListOf<String>()

    @Before
    fun setUp() {
        storage = File(temp.root, "data/cliplink_history.jsonl")
        blobs = temp.newFolder("blobs")
        files = FileStore(blobs, temp.newFolder("shared"))
    }

    private fun store(
        legacy: LegacyHistory? = null,
        maxStoredChars: Long = Long.MAX_VALUE,
        file: File = storage,
    ) = HistoryStore(file, legacy, files, { it in deleted }, { deleted.addAll(it) }, maxStoredChars)
        .also { it.onProblem = { message -> problems.add(message) } }

    private fun ts(n: Int) = "2026-09-26T%02d:%02d:%02d.0000001Z".format(n / 3600, (n / 60) % 60, n % 60)

    private fun entry(content: String, n: Int, device: String = "DEVICE", signature: String? = "sig-$content-$n") =
        ClipboardEntry(content, ClipboardEntry.TYPE_TEXT, device, ts(n), signature)

    /** The old SharedPreferences value, and whether it has been removed. */
    private class FakeLegacy(var text: String?, private val readFails: Throwable? = null) : LegacyHistory {
        var removed = false
        override fun read(): String? {
            readFails?.let { throw it }
            return text
        }

        override fun remove() {
            removed = true
            text = null
        }
    }

    private fun legacyJson(entries: List<ClipboardEntry>) = ClipboardEntry.listToJson(entries).toString()

    // ---- round trip -------------------------------------------------------------

    @Test
    fun `entries survive a restart exactly as stored`() {
        val tricky = listOf(
            entry("plain", 1),
            entry("quotes \" and \\ backslashes and / slashes", 2),
            entry("line one\nline two\r\n\ttabbed\u0000nul\u0007bell", 3),
            entry("emoji 😀 and é and 我 and    separators", 4),
            entry("a lone high \uD83D surrogate and a lone low \uDE00 one", 5),
            entry("unsigned", 6, signature = null),
            entry("{\"nested\":[1,2,{\"json\":true}]}", 7),
        )
        store().addAll(tricky)

        val reloaded = store().all()
        assertEquals(tricky.toSet(), reloaded.toSet())
        // Not one line more than entries: the file is one entry per line.
        assertEquals(tricky.size, storage.readLines().size)
        assertTrue(problems.isEmpty())
    }

    @Test
    fun `the file is the entry's own json one to a line`() {
        store().addAll(listOf(entry("hi", 1)))
        val obj = JSONObject(storage.readLines().single())
        assertEquals("hi", obj.getString("Content"))
        assertEquals("text", obj.getString("Type"))
        assertEquals("DEVICE", obj.getString("DeviceId"))
        assertEquals(ts(1), obj.getString("Timestamp"))
        assertEquals("sig-hi-1", obj.getString("Signature"))
    }

    @Test
    fun `json strings are escaped to the letter`() {
        fun roundTrip(text: String): String {
            val out = StringWriter()
            HistoryFile.writeJsonString(out, text)
            return JSONArray("[${out}]").getString(0)
        }
        for (text in listOf("", "\"", "\\", "\n\r\t", "\u0001\u001f", " ", "😀", "\uD83D", "\uDE00x\uD83D")) {
            assertEquals(text, roundTrip(text))
        }
    }

    @Test
    fun `all returns a snapshot that later writes don't change`() {
        val history = store()
        history.addAll(listOf(entry("a", 1)))
        val before = history.all()
        history.addAll(listOf(entry("b", 2)))
        assertEquals(1, before.size)
        assertEquals(2, history.all().size)
    }

    // ---- trimming and counting ----------------------------------------------------

    @Test
    fun `the history keeps the newest 25 and releases an evicted file's bytes`() {
        val history = store()
        val bytes = ByteArray(10) { 7 }
        val hash = FileStore.hashOf(bytes)
        files.write(hash, bytes)
        val fileEntry = ClipboardEntry(
            FilePayload("a.bin", hash, 10).toJson(), ClipboardEntry.TYPE_FILE, "DEVICE", ts(1), "sig-file",
        )
        history.addAll(listOf(fileEntry))
        assertTrue(files.exists(hash))

        history.addAll((2..26).map { entry("item$it", it) }) // 25 newer ones push the file out

        assertEquals(HistoryStore.MAX_ITEMS, history.all().size)
        assertFalse(history.all().contains(fileEntry))
        assertFalse(files.exists(hash))
        assertEquals((2..26).map { "item$it" }.toSet(), history.all().map { it.content }.toSet())
    }

    @Test
    fun `an entry older than everything a full history keeps is not counted as new`() {
        val history = store()
        history.addAll((100..124).map { entry("kept$it", it) })

        assertEquals(0, history.addAll(listOf(entry("ancient", 1))))
        assertFalse(history.add(entry("ancient two", 2)))
        assertTrue(history.addAllNew(listOf(entry("ancient three", 3))).isEmpty())
        assertEquals(25, history.all().size)
        // A newer one is new, and still there.
        assertTrue(history.add(entry("fresh", 200)))
    }

    @Test
    fun `addAll counts the entries that survived the trim, not those it evicted along the way`() {
        val history = store()
        history.addAll((100..123).map { entry("kept$it", it) }) // 24 of 25

        val old = entry("old", 1)
        val fresh = entry("fresh", 300)
        // Both go in (26 entries), then the oldest - "old" - is evicted.
        val survivors = history.addAllNew(listOf(old, fresh))
        assertEquals(listOf(fresh), survivors)
        assertEquals(1, history.addAll(listOf(entry("fresh2", 301))))
        assertFalse(history.all().contains(old))
    }

    @Test
    fun `a duplicate is not new, whatever way it is spelt`() {
        val history = store()
        val signed = ClipboardEntry("hi", ClipboardEntry.TYPE_TEXT, "D", "2026-09-26T12:34:56.1234500Z", "sig")
        assertEquals(1, history.addAll(listOf(signed, signed)))
        // A relay trimmed the timestamp: the same instant, the same entry.
        assertFalse(history.add(signed.copy(timestamp = "2026-09-26T12:34:56.12345Z")))
        // Same device, time and type, different content: a different entry, with its own key.
        assertTrue(history.add(signed.copy(content = "other", signature = "sig2")))
        assertEquals(2, history.all().size)
    }

    @Test
    fun `a deleted entry stays deleted and can't be added again`() {
        val history = store()
        val e = entry("secret", 1)
        history.addAll(listOf(e, entry("keep", 2)))
        history.delete(e)
        assertEquals(listOf("keep"), history.all().map { it.content })
        assertTrue(history.isDeleted(e))
        assertFalse(history.add(e))
        // And it is gone from the file too.
        assertEquals(listOf("keep"), store().all().map { it.content })

        history.clear()
        assertTrue(history.all().isEmpty())
        assertTrue(store().all().isEmpty())
        assertTrue(deleted.contains(entry("keep", 2).deletionKey))
    }

    @Test
    fun `the oldest are evicted first when the content gets too big, never the only one left`() {
        val history = store(maxStoredChars = 100)
        history.addAll(listOf(entry("a".repeat(40), 1), entry("b".repeat(40), 2)))
        assertEquals(2, history.all().size)
        history.addAll(listOf(entry("c".repeat(40), 3))) // 120 characters: the oldest goes
        assertEquals(listOf("b".repeat(40), "c".repeat(40)), history.all().map { it.content })

        history.addAll(listOf(entry("d".repeat(500), 4))) // alone over the budget: kept, the rest go
        assertEquals(listOf("d".repeat(500)), history.all().map { it.content })
    }

    // ---- migration from SharedPreferences -------------------------------------------

    @Test
    fun `the old SharedPreferences history is moved to the file and then removed`() {
        val old = (1..5).map { entry("old$it", it) }
        val legacy = FakeLegacy(legacyJson(old))

        val history = store(legacy)
        assertEquals(old.toSet(), history.all().toSet())

        assertTrue("the old copy is removed once the file has it", legacy.removed)
        assertTrue(storage.isFile)
        // A restart reads the file, not the (gone) old value.
        assertEquals(old.toSet(), store(FakeLegacy(null)).all().toSet())
        assertTrue(problems.any { it.contains("moved 5") })
    }

    @Test
    fun `nothing is migrated twice and nothing is lost when both exist`() {
        val inFile = listOf(entry("new1", 100), entry("new2", 101))
        store().addAll(inFile)
        // Left behind by a run that was killed between writing the file and removing this.
        val old = listOf(entry("old1", 1), inFile[0])
        val legacy = FakeLegacy(legacyJson(old))

        val all = store(legacy).all()

        assertEquals(setOf("new1", "new2", "old1"), all.map { it.content }.toSet())
        assertEquals(3, all.size) // new1 once, not twice
        assertTrue(legacy.removed)
    }

    @Test
    fun `an empty or missing old history is just removed or ignored`() {
        val empty = FakeLegacy("[]")
        assertTrue(store(empty).all().isEmpty())
        assertTrue(empty.removed)
        val none = FakeLegacy(null)
        assertTrue(store(none).all().isEmpty())
        assertFalse(none.removed)
    }

    @Test
    fun `an old history that can't be read at all is dropped so it doesn't fail on every launch`() {
        val legacy = FakeLegacy("this is {not json")
        assertTrue(store(legacy).all().isEmpty())
        assertTrue(legacy.removed)
        assertTrue(problems.any { it.contains("unreadable") })
    }

    @Test
    fun `an old history that can't be read yet is kept for the next launch`() {
        val legacy = FakeLegacy(legacyJson(listOf(entry("precious", 1))), readFails = OutOfMemoryError("test"))
        assertTrue(store(legacy).all().isEmpty()) // nothing to show this time
        assertFalse("its entries are not thrown away", legacy.removed)
        assertEquals("precious", legacy.text?.let { JSONArray(it).getJSONObject(0).getString("Content") })
    }

    @Test
    fun `an old history that can't be written to the new file is kept, and still shown`() {
        // The folder the file would go in is a plain file: the write can't succeed.
        val blocker = temp.newFile("not-a-folder")
        val legacy = FakeLegacy(legacyJson(listOf(entry("precious", 1))))

        val history = store(legacy, file = File(blocker, "history.jsonl"))

        assertEquals(listOf("precious"), history.all().map { it.content })
        assertFalse(legacy.removed)
        assertTrue(problems.any { it.contains("kept for next time") })
    }

    // ---- corruption -------------------------------------------------------------------

    @Test
    fun `a corrupt or cut-off line costs that entry and no other`() {
        val good1 = entry("good1", 1)
        val good2 = entry("good2", 2)
        val line1 = JSONObject().put("Content", good1.content).put("Type", "text").put("DeviceId", "DEVICE")
            .put("Timestamp", good1.timestamp).put("Signature", good1.signature).toString()
        val line2 = line1.replace("good1", "good2").replace(good1.timestamp, good2.timestamp).replace("sig-good1-1", "sig-good2-2")
        storage.parentFile!!.mkdirs()
        storage.writeText(line1 + "\n" + "{\"Content\":\"broken" + "\n" + "\u0000\u0001garbage\n" + line2 + "\n" + line1.take(30))

        val loaded = store().all()

        assertEquals(setOf("good1", "good2"), loaded.map { it.content }.toSet())
        assertTrue(problems.any { it.contains("skipped 3") })
    }

    @Test
    fun `a file of nothing but garbage is an empty history, not a crash`() {
        storage.parentFile!!.mkdirs()
        storage.writeBytes(ByteArray(5000) { (it * 31).toByte() })
        assertTrue(store().all().isEmpty())
        // And the store still works afterwards.
        val history = store()
        assertTrue(history.add(entry("fresh", 1)))
        assertEquals(listOf("fresh"), store().all().map { it.content })
    }

    @Test
    fun `a file nested far too deep to parse is skipped without overflowing the stack`() {
        storage.parentFile!!.mkdirs()
        storage.writeText("{\"a\":".repeat(100_000) + "1" + "}".repeat(100_000) + "\n")
        assertTrue(store().all().isEmpty())
        assertTrue(problems.any { it.contains("skipped 1") })
    }

    @Test
    fun `a missing file is an empty history`() {
        assertFalse(storage.exists())
        val history = store()
        assertTrue(history.all().isEmpty())
        assertTrue(problems.isEmpty())
        assertFalse("reading doesn't create the file", storage.exists())
    }

    // ---- atomic writes ------------------------------------------------------------------

    @Test
    fun `a save leaves only the file, never a temporary one`() {
        val history = store()
        repeat(5) { history.addAll(listOf(entry("n$it", it))) }
        assertEquals(listOf("cliplink_history.jsonl"), storage.parentFile!!.list()!!.toList())
    }

    @Test
    fun `a write that fails leaves the previous file exactly as it was`() {
        val history = store()
        history.addAll(listOf(entry("kept", 1)))
        val before = storage.readText()

        // The temporary file's name is taken by a folder that can't be cleared
        // away, so the next write can't even start.
        File(storage.parentFile!!, storage.name + ".tmp").also { it.mkdirs() }.resolve("occupied").writeText("x")
        assertFalse(HistoryFile.write(storage, listOf(entry("lost", 2))))
        assertEquals(before, storage.readText())

        // Through the store: the entry is still held in memory, with a note in the log.
        assertTrue(history.add(entry("held", 3)))
        assertEquals(listOf("kept", "held"), history.all().map { it.content })
        assertTrue(problems.any { it.contains("couldn't save") })
        assertEquals(before, storage.readText())
    }

    @Test
    fun `reading the history does not parse it again`() {
        val history = store()
        history.addAll(listOf(entry("a", 1)))
        // The file is gone, but the store has what it read: a read is a field.
        storage.delete()
        assertEquals(listOf("a"), history.all().map { it.content })
    }
}
