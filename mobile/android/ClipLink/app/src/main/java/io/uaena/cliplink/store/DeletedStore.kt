package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.core.optStringOrNull
import org.json.JSONArray
import org.json.JSONObject

/** One deleted history entry: its ClipboardEntry.deletionKey, and when (ms since the epoch). */
data class Tombstone(val key: String, val deletedAt: Long)

/**
 * The synced items deleted on this device - one at a time or by clearing the
 * history - remembered so that a peer's next history_batch, or an entry it
 * relays again, can't quietly bring them back. Local only: nothing here goes
 * on the wire, and the peers keep their own copies.
 *
 * The same `{Key, DeletedAt}` list as the Windows daemon's deleted.json,
 * capped at [MAX_TOMBSTONES] with the oldest dropped first.
 */
class DeletedStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_deleted", Context.MODE_PRIVATE)

    /**
     * Parsed once, then kept in step with every write - [contains] runs for
     * every entry that arrives, and a history_batch is up to 25 of them.
     */
    private var tombstones: List<Tombstone>? = null
    private var keys: Set<String> = emptySet()

    @Synchronized
    fun contains(key: String): Boolean {
        load()
        return key in keys
    }

    /** Records [newKeys] as deleted now. One that already was just gets the newer time. */
    @Synchronized
    fun record(newKeys: Collection<String>, now: Long = System.currentTimeMillis()) {
        if (newKeys.isEmpty()) return
        val updated = load().withTombstones(newKeys, now)
        prefs.edit().putString(ENTRIES_KEY, updated.toTombstoneJson()).commit()
        cache(updated)
    }

    private fun load(): List<Tombstone> =
        tombstones ?: tombstonesFromJson(prefs.getString(ENTRIES_KEY, "[]") ?: "[]").also(::cache)

    private fun cache(list: List<Tombstone>) {
        tombstones = list
        keys = list.mapTo(HashSet()) { it.key }
    }

    private companion object {
        const val ENTRIES_KEY = "entries"
    }
}

internal const val MAX_TOMBSTONES = 2000

/**
 * [DeletedStore.record]'s merge, kept apart from SharedPreferences so it is
 * unit-testable: [keys] added at [now] (or moved there, if already present),
 * then only the newest [cap] kept.
 */
internal fun List<Tombstone>.withTombstones(
    keys: Collection<String>,
    now: Long,
    cap: Int = MAX_TOMBSTONES,
): List<Tombstone> {
    val added = keys.toSet()
    // sortedBy is stable, so equal times keep their order and the cut below
    // always drops the genuinely oldest - whatever order was read back.
    return (filterNot { it.key in added } + added.map { Tombstone(it, now) })
        .sortedBy { it.deletedAt }
        .takeLast(cap)
}

/** A corrupt value reads as empty rather than crashing startup, like the other stores. */
internal fun tombstonesFromJson(json: String): List<Tombstone> = try {
    val array = JSONArray(json)
    (0 until array.length()).mapNotNull { i ->
        val obj = array.optJSONObject(i) ?: return@mapNotNull null
        val key = obj.optStringOrNull("Key") ?: return@mapNotNull null
        Tombstone(key, obj.optLong("DeletedAt", 0L))
    }
} catch (e: Exception) {
    emptyList()
}

internal fun List<Tombstone>.toTombstoneJson(): String {
    val array = JSONArray()
    forEach { array.put(JSONObject().put("Key", it.key).put("DeletedAt", it.deletedAt)) }
    return array.toString()
}
