package io.uaena.cliplink.store

import android.content.Context
import android.content.SharedPreferences
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.core.LineReader
import io.uaena.cliplink.core.describeError
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.net.Limits
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.io.Writer
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * The synced-item history. Mirrors HistoryAccess.cs / HistoryAccess.ets:
 * same 25-item cap, same oldest-first eviction, same blob cleanup when a
 * file-type entry is evicted.
 *
 * Kept in a file of its own - one JSON entry per line, see [HistoryFile] -
 * and parsed once, into memory, the first time it is asked for. It used to
 * be one SharedPreferences string: every change rewrote the whole XML, every
 * [all] parsed all of it again, and a few MB of inline images were enough to
 * run the app out of memory while loading it, which crashed it on every
 * launch. Now a change rewrites one file, atomically (written beside it, then
 * renamed over it), a read is a field, and a history that can't be read
 * whole - corrupt, truncated, too big for the heap - comes back as however
 * much of it could be, with a note in the log, never as a crash.
 *
 * Besides the item count, the history keeps at most [Limits.MAX_STORED_CHARS]
 * characters of content in all, evicting the oldest first (never the only
 * one left): 25 inline images are 25 images' worth of memory, held for as
 * long as the app runs.
 *
 * A history an earlier build kept in SharedPreferences is moved here the
 * first time, and only then removed from there (see [migrate]).
 */
class HistoryStore internal constructor(
    private val storage: File,
    private val legacy: LegacyHistory?,
    private val fileStore: FileStore,
    private val isDeletedKey: (String) -> Boolean,
    private val recordDeleted: (Collection<String>) -> Unit,
    private val maxStoredChars: Long = Limits.MAX_STORED_CHARS,
    /** The newest deleted keys, most recently deleted first - what a v2 history_head tells a peer. */
    private val recentDeleted: (Int) -> List<String> = { emptyList() },
) {

    constructor(context: Context, fileStore: FileStore, deleted: DeletedStore) : this(
        storage = File(context.applicationContext.filesDir, FILE_NAME),
        legacy = PrefsLegacyHistory(
            context.applicationContext.getSharedPreferences("cliplink_history", Context.MODE_PRIVATE),
        ),
        fileStore = fileStore,
        isDeletedKey = deleted::contains,
        recordDeleted = { keys -> deleted.record(keys) },
        recentDeleted = deleted::recent,
    )

    /** Where a note goes when the history couldn't be read or written whole - the Activity log. */
    @Volatile
    var onProblem: ((String) -> Unit)? = null

    /** The history in the order it was stored; replaced - never changed - by every write. Null until first needed. */
    private var cache: List<ClipboardEntry>? = null

    /**
     * The key of the convenience item of the last sync that brought one (see [Arrival.Sync]): the trim
     * spares it. Memory only - after a restart the history is trimmed by age alone - and ended by the
     * next arrival that starts a block of its own, or replaced when a newer convenience item goes to the
     * clipboard. A convenience item that is skipped (see [addAllNew]) leaves it as it is.
     */
    private var protectedKey: String? = null

    /** An immutable snapshot: the caller may keep it, sort it, and no later write changes it. */
    @Synchronized
    fun all(): List<ClipboardEntry> = loaded()

    /**
     * Returns true only when the entry was genuinely new. Callers depend on
     * that to decide whether to also apply or re-broadcast it - returning
     * true for a duplicate would make two peers bounce the same item back and
     * forth indefinitely.
     *
     * An entry deleted on this device is never new again: every peer's
     * history_batch still carries it, and it would otherwise be stored and put
     * on the clipboard all over again on the next connection. Checked under
     * the same lock [delete] and [clear] write under, so an entry arriving
     * mid-delete can't slip in between the check and the removal.
     *
     * Nor is an entry older than everything a full history keeps: it would be
     * stored and evicted in the same breath.
     */
    @Synchronized
    fun add(entry: ClipboardEntry): Boolean = addAll(listOf(entry)) > 0

    /**
     * [add] for several entries at once - the files of one share. Trimmed
     * once, after they are all in: trimming after each would release the
     * blob of an evicted older entry that a later one of these shares
     * (the same file shared again), before that later one is recorded.
     * Returns how many were new and are still here after the trim.
     */
    @Synchronized
    fun addAll(entries: List<ClipboardEntry>): Int = addAllNew(entries).size

    /**
     * [addAll], returning the entries themselves - those that were new and
     * survived the trim, in the order given. A peer's history_batch is
     * applied from this: an entry that was stored only to be evicted at once
     * is not one to put on the clipboard or fetch a file for.
     *
     * One batch is one change: one update in memory, one write to the file.
     * With [Arrival.Sync], [protectFront] is asked whether the newest of the new
     * entries (the sync's convenience item) is the one that goes on the clipboard;
     * only then does the trim spare it. When the answer is no, the item that went to the clipboard before
     * stays spared instead. Asked under the lock: it must be quick.
     * [onStored] is called with the survivors while the lock is still held,
     * so nothing reading [all] can see them before whoever is told here
     * (the batch groups, see BatchGroups) knows they belong together. It must
     * be quick and must not call back into this store.
     */
    @Synchronized
    fun addAllNew(
        entries: List<ClipboardEntry>,
        arrival: Arrival = Arrival.Live,
        protectFront: ((ClipboardEntry) -> Boolean)? = null,
        onStored: ((List<ClipboardEntry>) -> Unit)? = null,
    ): List<ClipboardEntry> {
        var history = loaded()
        val added = ArrayList<ClipboardEntry>()
        for (entry in entries) {
            history = history.withAdded(entry, isDeletedKey)?.also { added.add(entry) } ?: continue
        }
        if (added.isEmpty()) return emptyList()
        // What the trim must not drop. A new block ends the protection of the last one's item.
        // A convenience item that did not go to the clipboard is no new block of protection: the one that
        // did stays spared (here and after), until a newer one goes there.
        val grantedFront = if (arrival == Arrival.Sync) newestOf(added)?.takeIf { protectFront?.invoke(it) ?: true }?.deletionKey else null
        val spared = when (arrival) {
            Arrival.Sync -> grantedFront ?: protectedKey
            Arrival.SyncMore -> protectedKey
            Arrival.Live, Arrival.SyncByAge -> null
        }
        val trimmed = history.toMutableList()
        trimEntries(trimmed, release = true, spared = spared)
        commit(trimmed)
        // By identity: an entry equal to a survivor isn't one if it was a duplicate.
        val survivors = added.filter { candidate -> trimmed.any { it === candidate } }
        if (survivors.isNotEmpty()) {
            when (arrival) {
                Arrival.Live -> protectedKey = null
                Arrival.Sync -> if (grantedFront != null) protectedKey = grantedFront
                Arrival.SyncByAge -> protectedKey = newestOf(survivors)?.deletionKey
                Arrival.SyncMore -> Unit
            }
            onStored?.invoke(survivors)
        }
        return survivors
    }

    /**
     * How an entry (or several) came to be added - see [addAllNew]. It decides whether the trim spares
     * one of them: the item that goes to the clipboard on a sync stays, even when it is older than
     * everything else the history keeps, and the oldest other item goes instead.
     */
    enum class Arrival {
        /** One live item, such as a copy on either device: a block of its own, nothing to spare. */
        Live,

        /**
         * The first entries of a v2 sync: the newest of the new ones is its convenience item, which is spared
         * by this trim too, even when it is older than everything else - the oldest other entry goes instead.
         */
        Sync,

        /**
         * The same from an older peer, which sends its whole history: what is older than a full history keeps
         * is not stored, as ever, and the newest of what is stored is spared from the next trim on.
         */
        SyncByAge,

        /** More entries of a sync whose first part is in already: whatever is spared stays spared. */
        SyncMore,
    }

    /**
     * How many of [keys] (entry deletion keys, see ClipboardEntry.deletionKey)
     * a history_batch carrying them would add: those neither in the history
     * nor deleted here, each counted once. Never more than the history holds.
     * Read from a history_head, to show the size of the stack that is coming.
     */
    @Synchronized
    fun countNew(keys: Collection<String>): Int {
        val here = loaded().mapTo(HashSet()) { it.deletionKey }
        return keys.toSet().count { it !in here && !isDeletedKey(it) }.coerceAtMost(MAX_ITEMS)
    }

    /**
     * Deletes one entry for good: out of the history, its bytes released, and
     * remembered so no peer brings it back. Leaves the clipboard and the peers
     * alone (telling them is the caller's, see SyncManager.broadcastDelete).
     */
    @Synchronized
    fun delete(entry: ClipboardEntry) {
        recordDeleted(listOf(entry.deletionKey))
        val remaining = loaded().filterNot { it.isSameAs(entry) }
        commit(remaining)
        releaseBlob(entry, remaining)
    }

    /** [delete] for every entry at once. Returns their keys, the ones to tell the peers. */
    @Synchronized
    fun clear(): List<String> {
        val entries = loaded()
        val keys = entries.map { it.deletionKey }
        recordDeleted(keys)
        commit(emptyList())
        entries.forEach { releaseBlob(it, emptyList()) }
        return keys
    }

    /**
     * Deletes what a peer says was deleted there ([keys]): each key is remembered as deleted - also one
     * for an entry that never was here, so it can't arrive later - and the entries with those keys leave
     * the history, their bytes released if nothing else uses them. Returns the entries removed. Same as a
     * local delete, except that a key already remembered is not stamped again (a peer's head repeats its
     * whole list on every connect), and that nothing is sent on from here.
     */
    @Synchronized
    fun applyDeleted(keys: Collection<String>): List<ClipboardEntry> {
        if (keys.isEmpty()) return emptyList()
        // Reversed: they come most recently deleted first, and are stamped in the order given.
        val unknown = keys.filterNot(isDeletedKey).reversed()
        if (unknown.isNotEmpty()) recordDeleted(unknown)
        val doomed = keys.toSet()
        val history = loaded()
        val gone = history.filter { it.deletionKey in doomed }
        if (gone.isEmpty()) return emptyList()
        val remaining = history.filterNot { it.deletionKey in doomed }
        commit(remaining)
        gone.forEach { releaseBlob(it, remaining) }
        return gone
    }

    fun isDeleted(entry: ClipboardEntry): Boolean = isDeletedKey(entry.deletionKey)

    /** Whether [key] is remembered as deleted here. */
    fun isKeyDeleted(key: String): Boolean = isDeletedKey(key)

    /** The newest [limit] deleted keys, most recently deleted first. */
    fun recentDeletedKeys(limit: Int): List<String> = recentDeleted(limit)

    /** For bytes that finished arriving after their entry was deleted. */
    @Synchronized
    fun releaseBlobIfUnused(fileHash: String) {
        if (loaded().none { it.usesBlob(fileHash) }) fileStore.delete(fileHash)
    }

    /**
     * Startup housekeeping, before any peer connects: deletes the blobs no
     * entry points at (see [FileStore.sweepUnreferenced]), and gives a 0-byte
     * file entry received before this build could store one its empty blob -
     * it would otherwise say "Transferring…" for good. Returns how many
     * blobs were deleted.
     */
    @Synchronized
    fun tidyBlobs(): Int {
        val files = loaded().mapNotNull { entry ->
            if (entry.type == ClipboardEntry.TYPE_FILE) FilePayload.parse(entry.content) else null
        }
        val swept = fileStore.sweepUnreferenced(files.mapTo(HashSet()) { it.fileHash })
        files.filter { it.isEmptyFile }.forEach { fileStore.storeEmpty(it.fileHash) }
        return swept
    }

    // ---- storage -----------------------------------------------------------

    private fun loaded(): List<ClipboardEntry> {
        cache?.let { return it }
        val entries = try {
            loadFromDisk()
        } catch (e: Throwable) {
            // Never a crash on launch: an unreadable history is an empty one.
            problem("couldn't load the history (${describeError(e)}) - starting with what could be read")
            emptyList()
        }
        cache = entries
        return entries
    }

    private fun loadFromDisk(): List<ClipboardEntry> {
        val read = HistoryFile.read(storage)
        if (read.skipped > 0) problem("skipped ${read.skipped} unreadable history item(s)")
        read.failure?.let { problem("couldn't read the whole history file ($it)") }
        val source = legacy ?: return read.entries
        return migrate(source, read.entries)
    }

    /**
     * Moves a history an earlier build kept in SharedPreferences into the
     * file: read, merged under whatever the file already holds (older, so it
     * goes after), written - and only then removed from there. Never
     * removed unless it was either written or genuinely unreadable; one that
     * couldn't be read for want of memory stays for the next launch, and
     * one that couldn't be written stays too. Nothing else is touched: not
     * the identity key, the trust store, the passcode key, nor the record of
     * what was deleted.
     */
    private fun migrate(source: LegacyHistory, current: List<ClipboardEntry>): List<ClipboardEntry> {
        val text = try {
            source.read()
        } catch (e: Throwable) {
            problem("couldn't read the old history (${describeError(e)}) - keeping it for next time")
            return current
        } ?: return current

        val old = try {
            ClipboardEntry.listFromJson(JSONArray(text))
        } catch (e: OutOfMemoryError) {
            problem("not enough memory to move the old history - keeping it for next time")
            return current
        } catch (e: Throwable) {
            // Not JSON, or nested too deep: nothing in it can be read, now or
            // later, so it isn't kept to fail again on every launch.
            problem("the old history was unreadable (${describeError(e)}) - dropped")
            source.remove()
            return current
        }

        val merged = current.toMutableList()
        for (entry in old) if (merged.none { it.isSameAs(entry) }) merged.add(entry)
        // No blob release: these entries were all in a history a moment ago,
        // and the startup sweep deletes whatever ends up unreferenced.
        trimEntries(merged, release = false)
        if (HistoryFile.write(storage, merged)) {
            source.remove()
            if (old.isNotEmpty()) problem("moved ${old.size} history item(s) to the new store")
        } else {
            problem("couldn't write the new history file - the old history is kept for next time")
        }
        return merged
    }

    private fun commit(entries: List<ClipboardEntry>) {
        cache = entries
        if (!HistoryFile.write(storage, entries)) {
            problem("couldn't save the history - it is kept in memory until a save works")
        }
    }

    private fun problem(message: String) {
        try {
            onProblem?.invoke("history: $message")
        } catch (e: Throwable) {
            // A log that throws must not break the store.
        }
    }

    /** Drops the oldest entries until the history fits; the one with key [spared], if any, stays whatever its age. */
    private fun trimEntries(entries: MutableList<ClipboardEntry>, release: Boolean, spared: String? = null) {
        while (entries.size > MAX_ITEMS || (entries.size > 1 && contentChars(entries) > maxStoredChars)) {
            // Timestamps are .NET round-trip format, which is fixed-width and
            // UTC - so lexicographic order IS chronological order, no parsing.
            // Canonical form restores the fixed width if a relay trimmed it.
            var oldest = -1
            for (i in entries.indices) {
                if (spared != null && entries[i].deletionKey == spared) continue
                if (oldest < 0 || DotNetTimestamp.canonical(entries[i].timestamp) <
                    DotNetTimestamp.canonical(entries[oldest].timestamp)
                ) {
                    oldest = i
                }
            }
            // Only the spared one is left.
            if (oldest < 0) return
            val evicted = entries.removeAt(oldest)
            if (release) releaseBlob(evicted, entries)
        }
    }

    private fun contentChars(entries: List<ClipboardEntry>): Long = entries.sumOf { it.content.length.toLong() }

    private fun releaseBlob(entry: ClipboardEntry, remaining: List<ClipboardEntry>) {
        entry.blobToRelease(remaining)?.let(fileStore::delete)
    }

    companion object {
        const val FILE_NAME = "cliplink_history.jsonl"

        /** How many items the history keeps - the newest win. */
        const val MAX_ITEMS = 25
    }
}

/** Where history was kept before it had a file - read once, removed once it has been moved. */
internal interface LegacyHistory {
    /** The old JSON text, or null when there is none. */
    fun read(): String?

    fun remove()
}

internal class PrefsLegacyHistory(private val prefs: SharedPreferences) : LegacyHistory {
    override fun read(): String? = prefs.getString(KEY, null)

    override fun remove() {
        prefs.edit().remove(KEY).commit()
    }

    private companion object {
        const val KEY = "entries"
    }
}

/**
 * The history file: UTF-8, one entry per line, each line the entry's own JSON
 * (`{"Content":…,"Type":…,"DeviceId":…,"Timestamp":…,"Signature":…}` - the
 * wire shape, which the old SharedPreferences string held as an array). A line
 * to an entry means one that can't be parsed - cut short by a crash, or
 * corrupt - costs that entry and no other, and neither writing nor reading
 * ever builds the whole history's JSON in memory: the text of one entry at a
 * time is the most either holds besides the entries themselves.
 */
internal object HistoryFile {

    class Loaded(
        val entries: List<ClipboardEntry>,
        /** Lines that couldn't be turned into an entry. */
        val skipped: Int,
        /** Set when reading stopped early: what the file's reader threw. */
        val failure: String?,
    )

    /** Everything readable in [file] - empty, with no complaint, if there is no such file. */
    fun read(file: File): Loaded {
        if (!file.isFile) return Loaded(emptyList(), 0, null)
        val entries = ArrayList<ClipboardEntry>()
        var skipped = 0
        var failure: String? = null
        try {
            FileInputStream(file).use { stream ->
                val reader = LineReader(stream)
                while (true) {
                    when (val line = reader.readLine(Limits.MAX_LINE_BYTES)) {
                        LineReader.Line.Eof -> break
                        is LineReader.Line.TooLong -> skipped++
                        is LineReader.Line.Data -> {
                            if (line.bytes.isEmpty()) continue
                            val entry = parseLine(line.bytes)
                            if (entry == null) skipped++ else entries.add(entry)
                        }
                    }
                }
            }
        } catch (e: Throwable) {
            failure = "${e.javaClass.simpleName}: ${e.message?.take(100)}"
        }
        return Loaded(entries, skipped, failure)
    }

    private fun parseLine(bytes: ByteArray): ClipboardEntry? = try {
        ClipboardEntry.fromJson(JSONObject(String(bytes, Charsets.UTF_8)))
    } catch (e: Throwable) {
        // Corrupt, or too big to hold: this entry is lost, the rest are not.
        null
    }

    /**
     * Writes [entries] to [file] all at once or not at all: to a temporary
     * file beside it, flushed to disk, then renamed over it. False if that
     * couldn't be done - the old file is then still there, untouched.
     */
    fun write(file: File, entries: List<ClipboardEntry>): Boolean {
        val temp = File(file.parentFile, file.name + ".tmp")
        return try {
            file.parentFile?.mkdirs()
            FileOutputStream(temp).use { stream ->
                val writer = OutputStreamWriter(stream, Charsets.UTF_8).buffered(64 * 1024)
                for (entry in entries) {
                    writeEntry(writer, entry)
                    writer.write("\n")
                }
                writer.flush()
                stream.fd.sync()
            }
            move(temp, file)
            true
        } catch (e: Throwable) {
            temp.delete()
            false
        }
    }

    private fun move(temp: File, target: File) {
        try {
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (e: AtomicMoveNotSupportedException) {
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    /** [ClipboardEntry.toJson]'s text, streamed: a big entry's content is escaped as it is written, not copied first. */
    internal fun writeEntry(out: Writer, entry: ClipboardEntry) {
        out.write("{\"Content\":")
        writeJsonString(out, entry.content)
        out.write(",\"Type\":")
        writeJsonString(out, entry.type)
        out.write(",\"DeviceId\":")
        writeJsonString(out, entry.deviceId)
        out.write(",\"Timestamp\":")
        writeJsonString(out, entry.timestamp)
        out.write(",\"Signature\":")
        if (entry.signature == null) out.write("null") else writeJsonString(out, entry.signature)
        out.write("}")
    }

    /**
     * [text] as a JSON string literal. Quotes, backslashes and control
     * characters are escaped, and so is a surrogate with no partner: a UTF-8
     * writer would turn it into "?", and the content is signed - it has to
     * come back as it went in. Runs of plain text go out in one write.
     */
    internal fun writeJsonString(out: Writer, text: String) {
        out.write("\"")
        var runStart = 0
        var i = 0
        while (i < text.length) {
            val c = text[i]
            var step = 1
            val escape: String? = when {
                c == '"' -> "\\\""
                c == '\\' -> "\\\\"
                c == '\n' -> "\\n"
                c == '\r' -> "\\r"
                c == '\t' -> "\\t"
                c < ' ' || c == ' ' || c == ' ' -> unicodeEscape(c)
                Character.isHighSurrogate(c) ->
                    if (i + 1 < text.length && Character.isLowSurrogate(text[i + 1])) {
                        step = 2
                        null
                    } else {
                        unicodeEscape(c)
                    }
                Character.isLowSurrogate(c) -> unicodeEscape(c)
                else -> null
            }
            if (escape != null) {
                out.write(text, runStart, i - runStart)
                out.write(escape)
                runStart = i + 1
            }
            i += step
        }
        out.write(text, runStart, text.length - runStart)
        out.write("\"")
    }

    private fun unicodeEscape(c: Char): String = "\\u" + c.code.toString(16).padStart(4, '0')
}

/**
 * The entry with the latest timestamp; the first of them if several share it. The one a sync puts on the
 * clipboard, and the one the trim spares for it - they must be the same.
 */
internal fun newestOf(entries: List<ClipboardEntry>): ClipboardEntry? =
    entries.maxByOrNull { DotNetTimestamp.canonical(it.timestamp) }

/**
 * [HistoryStore.add]'s decision, kept apart from the file so it is
 * unit-testable: the history with [entry] appended, or null when it isn't
 * new - already there, or deleted on this device.
 */
internal fun List<ClipboardEntry>.withAdded(
    entry: ClipboardEntry,
    isDeleted: (String) -> Boolean,
): List<ClipboardEntry>? {
    if (isDeleted(entry.deletionKey)) return null
    if (any { it.isSameAs(entry) }) return null
    return this + entry
}

// Timestamps compare in canonical form so a trimmed and an untrimmed
// spelling of one instant (see DotNetTimestamp) count as the same entry.
// The cheap fields first: content can be megabytes.
private fun ClipboardEntry.isSameAs(other: ClipboardEntry): Boolean =
    signature == other.signature && type == other.type && deviceId == other.deviceId &&
        DotNetTimestamp.canonical(timestamp) == DotNetTimestamp.canonical(other.timestamp) &&
        content == other.content

/**
 * The blob to delete along with this entry: a file entry's bytes, unless an
 * entry still in [remaining] points at the same blob - the same file sent
 * twice is two entries but one blob. Null when nothing should go.
 */
internal fun ClipboardEntry.blobToRelease(remaining: List<ClipboardEntry>): String? {
    val hash = fileHash() ?: return null
    return hash.takeIf { remaining.none { it.usesBlob(hash) } }
}

// Exact, case and all: FileStore names a blob by the hash string exactly as
// the entry spells it, on a case-sensitive filesystem - so "abc" and "ABC"
// are two different files, and a case-insensitive match here would leave one
// orphaned when the other spelling's entry is deleted.
private fun ClipboardEntry.usesBlob(hash: String): Boolean = fileHash() == hash

private fun ClipboardEntry.fileHash(): String? =
    if (type == ClipboardEntry.TYPE_FILE) FilePayload.parse(content)?.fileHash else null
