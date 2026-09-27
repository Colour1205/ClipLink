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
class HistoryStore(context: Context, private val fileStore: FileStore) {

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
     */
    @Synchronized
    fun add(entry: ClipboardEntry): Boolean {
        val entries = all().toMutableList()
        if (entries.any { it.isSameAs(entry) }) return false
        entries.add(entry)
        trim(entries)
        save(entries)
        return true
    }

    @Synchronized
    fun remove(entry: ClipboardEntry) {
        val entries = all().filterNot { it.isSameAs(entry) }
        releaseBlob(entry)
        save(entries)
    }

    @Synchronized
    fun clear() {
        all().forEach(::releaseBlob)
        save(emptyList())
    }

    // Timestamps compare in canonical form so a trimmed and an untrimmed
    // spelling of one instant (see DotNetTimestamp) count as the same entry.
    private fun ClipboardEntry.isSameAs(other: ClipboardEntry): Boolean =
        content == other.content && type == other.type && deviceId == other.deviceId &&
            DotNetTimestamp.canonical(timestamp) == DotNetTimestamp.canonical(other.timestamp) &&
            signature == other.signature

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
            releaseBlob(entries.removeAt(oldest))
        }
    }

    private fun releaseBlob(entry: ClipboardEntry) {
        if (entry.type != ClipboardEntry.TYPE_FILE) return
        FilePayload.parse(entry.content)?.let { fileStore.delete(it.fileHash) }
    }

    private companion object {
        const val HISTORY_KEY = "entries"
        const val MAX_ITEMS = 25
    }
}
