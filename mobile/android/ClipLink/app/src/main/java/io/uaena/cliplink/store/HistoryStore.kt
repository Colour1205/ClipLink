package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.core.DotNetTimestamp
import io.uaena.cliplink.net.FilePayload
import org.json.JSONArray

/**
 * The synced-item history. Mirrors HistoryAccess.cs / HistoryAccess.ets:
 * same 25-item cap, same oldest-first eviction, same blob cleanup when a
 * file-type entry is evicted.
 */
class HistoryStore(
    context: Context,
    private val fileStore: FileStore,
    private val deleted: DeletedStore,
) {

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_history", Context.MODE_PRIVATE)

    @Synchronized
    fun all(): List<ClipboardEntry> {
        val json = prefs.getString(HISTORY_KEY, "[]") ?: "[]"
        return try {
            ClipboardEntry.listFromJson(JSONArray(json))
        } catch (e: Exception) {
            emptyList()
        }
    }

    @Synchronized
    private fun save(entries: List<ClipboardEntry>) {
        prefs.edit().putString(HISTORY_KEY, ClipboardEntry.listToJson(entries).toString()).commit()
    }

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
     */
    @Synchronized
    fun add(entry: ClipboardEntry): Boolean {
        val entries = all().withAdded(entry, deleted::contains)?.toMutableList() ?: return false
        trim(entries)
        save(entries)
        return true
    }

    /**
     * Deletes one entry for good: out of the history, its bytes released, and
     * remembered so no peer brings it back. Leaves the clipboard and the peers
     * alone.
     */
    @Synchronized
    fun delete(entry: ClipboardEntry) {
        deleted.record(listOf(entry.deletionKey))
        val remaining = all().filterNot { it.isSameAs(entry) }
        save(remaining)
        releaseBlob(entry, remaining)
    }

    /** [delete] for every entry at once. */
    @Synchronized
    fun clear() {
        val entries = all()
        deleted.record(entries.map { it.deletionKey })
        save(emptyList())
        entries.forEach { releaseBlob(it, emptyList()) }
    }

    fun isDeleted(entry: ClipboardEntry): Boolean = deleted.contains(entry.deletionKey)

    /** For bytes that finished arriving after their entry was deleted. */
    @Synchronized
    fun releaseBlobIfUnused(fileHash: String) {
        if (all().none { it.usesBlob(fileHash) }) fileStore.delete(fileHash)
    }

    private fun trim(entries: MutableList<ClipboardEntry>) {
        while (entries.size > MAX_ITEMS) {
            // Timestamps are .NET round-trip format, which is fixed-width and
            // UTC - so lexicographic order IS chronological order, no parsing.
            // Canonical form restores the fixed width if a relay trimmed it.
            var oldest = 0
            for (i in 1 until entries.size) {
                if (DotNetTimestamp.canonical(entries[i].timestamp) <
                    DotNetTimestamp.canonical(entries[oldest].timestamp)
                ) {
                    oldest = i
                }
            }
            releaseBlob(entries.removeAt(oldest), entries)
        }
    }

    private fun releaseBlob(entry: ClipboardEntry, remaining: List<ClipboardEntry>) {
        entry.blobToRelease(remaining)?.let(fileStore::delete)
    }

    private companion object {
        const val HISTORY_KEY = "entries"
        const val MAX_ITEMS = 25
    }
}

/**
 * [HistoryStore.add]'s decision, kept apart from SharedPreferences so it is
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
private fun ClipboardEntry.isSameAs(other: ClipboardEntry): Boolean =
    content == other.content && type == other.type && deviceId == other.deviceId &&
        DotNetTimestamp.canonical(timestamp) == DotNetTimestamp.canonical(other.timestamp) &&
        signature == other.signature

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
