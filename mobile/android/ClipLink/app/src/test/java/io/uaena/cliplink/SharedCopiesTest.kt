package io.uaena.cliplink

import io.uaena.cliplink.clipboard.ClipboardBridge
import io.uaena.cliplink.clipboard.placeCopy
import io.uaena.cliplink.clipboard.pruneSharedDir
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The human-named copies made for sharing: placed without leaving half a
 * file behind, and cleared out when they have been forgotten for a day.
 */
class SharedCopiesTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val day = ClipboardBridge.SHARED_COPY_MAX_AGE_MS

    private fun folder(root: File, name: String, ageMs: Long, now: Long): File {
        val dir = File(root, name).apply { mkdirs() }
        File(dir, "file.bin").writeBytes(byteArrayOf(1, 2, 3))
        dir.setLastModified(now - ageMs)
        return dir
    }

    // ---- placeCopy ----------------------------------------------------------

    @Test
    fun aPlacedCopyHasTheBlobsBytes() {
        val blob = temp.newFile("blob").apply { writeBytes(ByteArray(10_000) { it.toByte() }) }
        val target = File(temp.newFolder("shared"), "My photo.jpg")

        placeCopy(blob, target)

        assertArrayEquals(blob.readBytes(), target.readBytes())
    }

    @Test
    fun placingOverAnOlderCutShortCopyReplacesIt() {
        val blob = temp.newFile("blob").apply { writeBytes("the whole thing".toByteArray()) }
        val target = temp.newFile("target").apply { writeBytes("the who".toByteArray()) }

        placeCopy(blob, target)

        assertEquals("the whole thing", target.readText())
    }

    @Test
    fun placingLeavesNoPartialFileBesideTheCopy() {
        val blob = temp.newFile("blob").apply { writeBytes(ByteArray(2048)) }
        val dir = temp.newFolder("shared")

        placeCopy(blob, File(dir, "a.bin"))

        assertEquals(listOf("a.bin"), dir.list()!!.toList())
    }

    @Test
    fun aMissingSourceFailsWithAnIoErrorAndLeavesNothingBehind() {
        val dir = temp.newFolder("shared")

        val failure = runCatching { placeCopy(File(temp.root, "gone"), File(dir, "a.bin")) }.exceptionOrNull()

        assertTrue(failure is java.io.IOException)
        assertEquals(emptyList<String>(), dir.list()!!.toList())
    }

    // ---- pruneSharedDir -----------------------------------------------------

    @Test
    fun foldersNotUsedForADayAreDeleted() {
        val root = temp.newFolder("shared")
        val now = 10 * day
        val stale = folder(root, "stale", day + 1, now)

        val removed = pruneSharedDir(root, now, day, keepName = null)

        assertEquals(1, removed)
        assertFalse(stale.exists())
    }

    @Test
    fun recentFoldersStay() {
        val root = temp.newFolder("shared")
        val now = 10 * day
        val fresh = folder(root, "fresh", day - 60_000, now)

        val removed = pruneSharedDir(root, now, day, keepName = null)

        assertEquals(0, removed)
        assertTrue(fresh.exists())
        assertTrue(File(fresh, "file.bin").exists())
    }

    @Test
    fun theClipOnTheClipboardIsSparedHoweverOld() {
        val root = temp.newFolder("shared")
        val now = 10 * day
        val onClipboard = folder(root, "abc123", 5 * day, now)
        val other = folder(root, "def456", 5 * day, now)

        val removed = pruneSharedDir(root, now, day, keepName = "abc123")

        assertEquals(1, removed)
        assertTrue(onClipboard.exists())
        assertFalse(other.exists())
    }

    @Test
    fun anOldBuildsStrayFileIsDeletedToo() {
        val root = temp.newFolder("shared")
        val now = 10 * day
        val stray = File(root, "a3f9").apply {
            writeBytes(byteArrayOf(1))
            setLastModified(now - 3 * day)
        }

        assertEquals(1, pruneSharedDir(root, now, day, keepName = null))
        assertFalse(stray.exists())
    }

    @Test
    fun aMissingFolderIsNothingToPrune() {
        assertEquals(0, pruneSharedDir(File(temp.root, "nope"), 0L, day, keepName = null))
    }

    // ---- limits ---------------------------------------------------------------

    @Test
    fun anInlineImageIsAtMostEightMegabytesOnceEncoded() {
        val png = ClipboardBridge.MAX_INLINE_IMAGE_BYTES.toLong()
        val base64 = (png + 2) / 3 * 4

        assertTrue("$base64 bytes", base64 <= 8L * 1024 * 1024)
    }

    @Test
    fun aTextTooLongForAnIntentExtraIsWellUnderTheBinderLimit() {
        // UTF-16: two bytes a character, against a ~1 MB transaction budget.
        assertTrue(ClipboardBridge.MAX_SHARE_TEXT_CHARS * 2 <= 200 * 1024)
    }
}
