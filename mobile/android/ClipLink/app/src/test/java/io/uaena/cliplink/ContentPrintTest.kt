package io.uaena.cliplink

import io.uaena.cliplink.core.Base64Codec
import io.uaena.cliplink.core.CaptureVerdict
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.ContentKeys
import io.uaena.cliplink.core.ContentPrint
import io.uaena.cliplink.core.classifyCapture
import io.uaena.cliplink.core.newestEntries
import io.uaena.cliplink.core.ownWriteVerdict
import io.uaena.cliplink.engine.foldTwins
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.store.isLater
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * The content prints of design/sync-dedupe-spec.md - the same vectors every
 * platform tests - and the rules built on them: classifying a capture, and
 * folding the list to one card per content.
 */
class ContentPrintTest {

    private val codec = object : Base64Codec {
        override fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
        override fun decodeOrNull(text: String?): ByteArray? =
            text?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
    }

    // ---- norm and print vectors (rule 5) ------------------------------------------------

    @Test
    fun `norm and the text print match the shared vectors`() {
        val abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        val lines = "683376e290829b482c2655745caffa7a1dccfa10afaa62dac2b42dd6c68d0f83"
        val vectors = listOf(
            Triple("abc", "abc", abc),
            Triple("abc\n", "abc", abc),
            Triple("abc\r\n", "abc", abc),
            Triple("abc\n\n", "abc\n", "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb"),
            Triple("line1\r\nline2", "line1\nline2", lines),
            Triple("line1\rline2\r", "line1\nline2", lines),
            Triple("  abc  ", "  abc  ", "e1df0bfff7ba8ed81085b91ad7dde5d31777855835b80db6d99b56ef9f3aaa6b"),
            Triple("日本語\r\n", "日本語", "77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5"),
            Triple("a\r\n\r\n", "a\n", "87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0fde60c4cf25c7"),
            Triple("\n", "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        )
        for ((input, normed, hex) in vectors) {
            assertEquals("norm of ${input.escaped()}", normed, ContentPrint.norm(input))
            assertEquals("print of ${input.escaped()}", "t:$hex", ContentPrint.text(input))
        }
    }

    @Test
    fun `a file print is the hash in lowercase, and never collides with a text print`() {
        val upper = "ABCDEF" + "0".repeat(58)
        assertEquals("f:" + upper.lowercase(), ContentPrint.file(upper))
        assertEquals(ContentPrint.file(upper), ContentPrint.file(upper.lowercase()))
        val empty = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        assertEquals("f:" + empty.lowercase(), ContentPrint.file(empty))
        assertFalse(ContentPrint.file(empty) == ContentPrint.text(""))
        assertNull(ContentPrint.file("not a hash"))
    }

    @Test
    fun `an entry's key is its content's print, and null for what cannot be read`() {
        val text = entry("hello\r\n", ClipboardEntry.TYPE_TEXT)
        assertEquals(ContentPrint.text("hello"), ContentPrint.key(text, codec))

        val bytes = byteArrayOf(1, 2, 3, 4)
        val image = entry(codec.encode(bytes), ClipboardEntry.TYPE_IMAGE)
        assertEquals(ContentPrint.image(bytes), ContentPrint.key(image, codec))
        assertTrue(ContentPrint.key(image, codec)!!.startsWith("i:"))

        val hash = "ab".repeat(32)
        val lower = entry(FilePayload("a.txt", hash, 3).toJson(), ClipboardEntry.TYPE_FILE)
        val upper = entry(FilePayload("b.txt", hash.uppercase(), 3).toJson(), ClipboardEntry.TYPE_FILE)
        assertEquals("f:$hash", ContentPrint.key(lower, codec))
        assertEquals(ContentPrint.key(lower, codec), ContentPrint.key(upper, codec))

        assertNull(ContentPrint.key(entry("%%% not base64", ClipboardEntry.TYPE_IMAGE), codec))
        assertNull(ContentPrint.key(entry("{not json", ClipboardEntry.TYPE_FILE), codec))
        assertNull(ContentPrint.key(entry("x", "video"), codec))
    }

    @Test
    fun `the key cache answers again without decoding, and notices changed content`() {
        val keys = ContentKeys(codec)
        val first = entry("one", ClipboardEntry.TYPE_TEXT, signature = "same")
        assertEquals(ContentPrint.text("one"), keys.of(first))
        assertEquals(ContentPrint.text("one"), keys.of(first.copy()))
        assertEquals(ContentPrint.text("other"), keys.of(first.copy(content = "other")))
    }

    // ---- classify (rule 1.3) -----------------------------------------------------------

    private fun classify(
        auto: Boolean,
        prints: Set<String>,
        lastWrite: Set<String> = emptySet(),
        history: Set<String> = emptySet(),
        newest: Set<String> = emptySet(),
        raw: Set<String> = emptySet(),
    ) = classifyCapture(auto, prints, raw, lastWrite, { p -> p.any { it in history } }, { p -> p.any { it in newest } })

    @Test
    fun `ClipLink's own clip is left alone automatically, and on a tap while it is still in the history`() {
        assertEquals(CaptureVerdict.Already, ownWriteVerdict(auto = true, holdsOwnWrite = true) { false })
        assertEquals(CaptureVerdict.Already, ownWriteVerdict(auto = false, holdsOwnWrite = true) { true })
        // A tap after the item was deleted: read it, and go on - the user wants it back.
        assertNull(ownWriteVerdict(auto = false, holdsOwnWrite = true) { false })
        assertNull(ownWriteVerdict(auto = true, holdsOwnWrite = false) { true })
    }

    @Test
    fun `what was last written or captured is not sent again by itself`() {
        val p = setOf("t:a")
        assertEquals(CaptureVerdict.Already, classify(auto = true, prints = p, lastWrite = p))
        // On a tap only while it is in the history; deleted, it goes out again.
        assertEquals(CaptureVerdict.Already, classify(auto = false, prints = p, lastWrite = p, history = p))
        assertEquals(CaptureVerdict.New, classify(auto = false, prints = p, lastWrite = p))
    }

    @Test
    fun `the newest entry's content is already everyone's, either way`() {
        val p = setOf("t:a")
        assertEquals(CaptureVerdict.Already, classify(auto = true, prints = p, history = p, newest = p))
        assertEquals(CaptureVerdict.Already, classify(auto = false, prints = p, history = p, newest = p))
    }

    @Test
    fun `an A, B, A re-copy goes out again`() {
        // A is in the history but not the newest (B is), and the clipboard record says B.
        val a = setOf("t:a")
        assertEquals(
            CaptureVerdict.New,
            classify(auto = true, prints = a, lastWrite = setOf("t:b"), history = setOf("t:a", "t:b"), newest = setOf("t:b")),
        )
    }

    @Test
    fun `an older build's single hash matches the raw hash of the capture`() {
        val raw = ContentPrint.rawText("abc\r\n")
        val legacy = setOf(ContentPrint.legacy(raw.uppercase()))
        val prints = setOf(ContentPrint.text("abc\r\n"))
        assertEquals(CaptureVerdict.Already, classify(auto = true, prints = prints, lastWrite = legacy, raw = setOf(raw)))
        assertEquals(CaptureVerdict.New, classify(auto = true, prints = prints, lastWrite = legacy, raw = setOf("other")))
        assertTrue(ContentPrint.matches(legacy, emptySet(), setOf(raw)))
    }

    @Test
    fun `the newest entries include every one tied at the boundary`() {
        val a = entryOf("a", 1)
        val b = entryOf("b", 5)
        val c = entryOf("c", 5)
        val d = entryOf("d", 3)
        assertEquals(setOf(b, c), newestEntries(listOf(a, b, c, d)).toSet())
        assertEquals(setOf(b, c, d), newestEntries(listOf(a, b, c, d), 3).toSet())
        assertEquals(setOf(b, c), newestEntries(listOf(a, b, c, d), 2).toSet())
        assertTrue(newestEntries(emptyList()).isEmpty())
    }

    // ---- the fold (rule 2) ---------------------------------------------------------------

    @Test
    fun `one card per content, the topmost wins`() {
        val live = entryOf("same", 9, "ME")
        val older = entryOf("same\r\n", 2)
        val other = entryOf("other", 5)
        val ordered = listOf(live, other, older)
        val keys = ContentKeys(codec)
        assertEquals(listOf(live, other), foldTwins(ordered) { keys.of(it) })
        // After a restart the list is by time: the newest is on top and wins.
        assertEquals(listOf(other, older), foldTwins(listOf(other, older, entryOf("same", 1))) { keys.of(it) })
    }

    @Test
    fun `entries without a key are never folded`() {
        val bad1 = entry("%%%", ClipboardEntry.TYPE_IMAGE, signature = "1")
        val bad2 = entry("%%%", ClipboardEntry.TYPE_IMAGE, signature = "2")
        assertEquals(listOf(bad1, bad2), foldTwins(listOf(bad1, bad2)) { ContentPrint.key(it, codec) })
    }

    // ---- freshness ----------------------------------------------------------------------

    @Test
    fun `later is by instant, and the same instant in another spelling is not later`() {
        assertTrue(isLater(ts(2), ts(1)))
        assertFalse(isLater(ts(1), ts(1)))
        assertFalse(isLater(ts(1), ts(2)))
        // An hour later, though it sorts lower as text.
        assertTrue(isLater("2026-09-26T09:00:04.0000001-02:00", ts(3)))
        // The same instant with another offset, or with no zone (UTC).
        assertFalse(isLater("2026-09-26T12:00:03.0000001+02:00", ts(3)))
        assertFalse(isLater("2026-09-26T10:00:03.0000001", ts(3)))
        // One tick later in the same millisecond.
        assertTrue(isLater("2026-09-26T10:00:03.0000002Z", ts(3)))
    }

    private fun entry(content: String, type: String, signature: String = "sig-$type-${content.hashCode()}") =
        ClipboardEntry(content, type, "PEER", ts(1), signature)

    private fun String.escaped() = replace("\r", "\\r").replace("\n", "\\n")
}
