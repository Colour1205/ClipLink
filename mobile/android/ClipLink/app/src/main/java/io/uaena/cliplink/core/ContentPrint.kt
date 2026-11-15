package io.uaena.cliplink.core

import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.store.FileStore
import java.security.MessageDigest

/**
 * What identifies a clip's content, whoever signed it and whenever - the
 * "print" of design/sync-dedupe-spec.md, spelled the same on every platform:
 * a kind prefix and lowercase SHA-256 hex. `t:` for text (of [norm]'s text),
 * `i:` for a picture's bytes, `f:` for a file's hash, and `x:` for the single
 * hash an older build remembered (see [legacy]).
 *
 * Local decisions only - what to send, what to put on the clipboard, which
 * card to show. Nothing that is sent, stored, signed or put on the clipboard
 * is ever changed by it, so no peer, old or new, sees a difference.
 */
object ContentPrint {

    /**
     * [text] as it is compared: every CRLF and every lone CR as LF, then one
     * trailing LF dropped. Nothing else - no trimming of spaces, no Unicode
     * normalisation - so text that differs in anything a user could see
     * still differs here. A Windows app that hands back synced text with
     * CRLF endings or one more newline gives the same print.
     */
    fun norm(text: String): String {
        val lf = text.replace("\r\n", "\n").replace('\r', '\n')
        return if (lf.endsWith('\n')) lf.dropLast(1) else lf
    }

    fun text(text: String): String = "t:" + sha256Hex(norm(text).toByteArray(Charsets.UTF_8))

    fun image(bytes: ByteArray): String = "i:" + sha256Hex(bytes)

    /** Null for anything that is not a SHA-256 in hex - such a hash names no blob, and matches nothing. */
    fun file(hash: String): String? = if (FileStore.isValidHash(hash)) "f:" + hash.lowercase() else null

    /** The print of the one hash an older build kept - see [matchesLegacy]. */
    fun legacy(hash: String): String = "x:" + hash.lowercase()

    /** The raw hash a legacy `x:` print is compared with: of the exact text, not of [norm]'s. */
    fun rawText(text: String): String = sha256Hex(text.toByteArray(Charsets.UTF_8))

    /**
     * The print of [entry]'s content, or null when it has none: an image whose
     * base64 does not decode, a file whose payload does not parse, a type this
     * build does not know. A null print never matches anything. Decoding an
     * image is megabytes of work - see [ContentKeys] for the cached form.
     */
    fun key(entry: ClipboardEntry, codec: Base64Codec = B64): String? = when (entry.type) {
        ClipboardEntry.TYPE_TEXT -> text(entry.content)
        // No memory to decode a big picture is no print, not a crash: it is then only never folded.
        ClipboardEntry.TYPE_IMAGE -> try {
            codec.decodeOrNull(entry.content)?.let(::image)
        } catch (e: OutOfMemoryError) {
            null
        }
        ClipboardEntry.TYPE_FILE -> FilePayload.parse(entry.content)?.fileHash?.let(::file)
        else -> null
    }

    /**
     * Whether [remembered] (a LastWrite record's prints) names the content of
     * a capture whose prints are [prints] and whose raw hashes - of the exact
     * text, the picture's bytes, the lowercase file hash - are [rawHashes]:
     * an `x:` print an older build left behind matches a raw hash.
     */
    fun matches(remembered: Set<String>, prints: Set<String>, rawHashes: Set<String> = emptySet()): Boolean =
        prints.any { it in remembered } || matchesLegacy(remembered, rawHashes)

    private fun matchesLegacy(remembered: Set<String>, rawHashes: Set<String>): Boolean =
        rawHashes.any { legacy(it) in remembered }

    private fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
}

/**
 * [ContentPrint.key] for the entries of the history, worked out once each:
 * an image entry's print means decoding its base64, and the list is folded,
 * and captures are checked, against every entry on every change. Keyed by the
 * entry's deletion key (its signature), which no two entries share; the
 * content's length guards against a stale answer all the same. Bounded - the
 * history is 25 entries, and a cache that is cleared now and then costs only
 * one more round of hashing.
 */
class ContentKeys(private val codec: Base64Codec = B64) {
    private val cache = HashMap<String, Pair<Int, String?>>()

    @Synchronized
    fun of(entry: ClipboardEntry): String? {
        val id = entry.type + "|" + entry.deletionKey
        cache[id]?.takeIf { it.first == entry.content.length }?.let { return it.second }
        val key = ContentPrint.key(entry, codec)
        if (cache.size >= MAX_CACHED) cache.clear()
        cache[id] = entry.content.length to key
        return key
    }

    private companion object {
        const val MAX_CACHED = 256
    }
}

/** What a capture comes to - see [classifyCapture]. */
enum class CaptureVerdict {
    /** Nothing to sign or send: everyone has it already, or it is ClipLink's own. */
    Already,

    /** A copy to sign and send. */
    New,
}

/**
 * Step 1 of the capture rules, before anything is read: the clipboard still
 * holds ClipLink's own last write ([holdsOwnWrite], told without reading the
 * content). An automatic capture leaves it there; a tap leaves it there too
 * while its content is still in the history ([ownWriteInHistory]), and
 * otherwise reads it - the user deleted that item and is pasting it again.
 * Null means read the clipboard and go on with [classifyCapture].
 */
fun ownWriteVerdict(auto: Boolean, holdsOwnWrite: Boolean, ownWriteInHistory: () -> Boolean): CaptureVerdict? =
    if (holdsOwnWrite && (auto || ownWriteInHistory())) CaptureVerdict.Already else null

/**
 * Steps 3 to 5 of the capture rules, once the clipboard has been read into
 * [prints] (and [rawHashes], for an older build's record). [lastWrite] is what
 * this device last wrote to the clipboard or last captured. Content it names
 * is not sent again by itself ([auto]), nor on a tap while it is still in the
 * history ([inHistory]); content that is the newest entry already
 * ([inNewest]) is not sent again either way. Anything else is new - a
 * re-copy of an older item included, which is how the user gets it back
 * onto the other devices.
 */
fun classifyCapture(
    auto: Boolean,
    prints: Set<String>,
    rawHashes: Set<String>,
    lastWrite: Set<String>,
    inHistory: (Set<String>) -> Boolean,
    inNewest: (Set<String>) -> Boolean,
): CaptureVerdict {
    if (prints.isEmpty()) return CaptureVerdict.New
    if (ContentPrint.matches(lastWrite, prints, rawHashes) && (auto || inHistory(prints))) return CaptureVerdict.Already
    if (inNewest(prints)) return CaptureVerdict.Already
    return CaptureVerdict.New
}

/**
 * The entries of [entries] with the latest timestamp, all of them when
 * several share it - the "newest(1)" the capture rules compare with. [n] more
 * than one takes the [n] latest, and everything tied with the last of them.
 */
fun newestEntries(entries: List<ClipboardEntry>, n: Int = 1): List<ClipboardEntry> {
    if (entries.isEmpty() || n <= 0) return emptyList()
    val sorted = entries.sortedByDescending { DotNetTimestamp.canonical(it.timestamp) }
    if (sorted.size <= n) return sorted
    val boundary = DotNetTimestamp.canonical(sorted[n - 1].timestamp)
    return sorted.filterIndexed { index, entry -> index < n || DotNetTimestamp.canonical(entry.timestamp) == boundary }
}
