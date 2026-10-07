package io.uaena.cliplink.ui

import io.uaena.cliplink.engine.SyncedItem

/** A [SyncedItem] together with the key every list, cache and saved state refers to it by. */
data class KeyedItem(val key: String, val item: SyncedItem)

/**
 * Pairs every item with a key that is unique within [items], stable while the
 * list changes around it, and cheap to save in a Bundle.
 *
 * NOT `SyncedItem.id`. That is `deviceId|timestamp|type`, which two different
 * entries of one device can share (same timestamp text, same type, different
 * content), and a Lazy list given two equal keys throws "Key ... was already
 * used" - on the Synced tab, which is the start tab, so the app would crash on
 * every launch until enough newer items had pushed one of the two out of the
 * history. The same collision would also have shown one item's bitmap for the
 * other, as the picture caches were keyed by it too.
 *
 * The signature is what identifies an entry on every platform (HarmonyOS keys
 * its list by it, and deletions are recorded under it), so it is the key. An
 * entry without one falls back to its id plus its position, and anything that
 * still repeats - two items with the very same signature - gets a numbered
 * suffix, so the keys are unique whatever the list holds.
 */
fun keyedItems(items: List<SyncedItem>): List<KeyedItem> {
    val keys = uniqueKeys(items.mapIndexed { index, item -> candidateKey(item, index) })
    return items.mapIndexed { index, item -> KeyedItem(keys[index], item) }
}

internal fun candidateKey(item: SyncedItem, index: Int): String =
    item.entry.signature?.takeIf { it.isNotEmpty() } ?: "${item.id}#$index"

/** [candidates], each made different from every one before it by a numbered suffix if need be. */
internal fun uniqueKeys(candidates: List<String>): List<String> {
    val used = HashSet<String>(candidates.size * 2)
    return candidates.map { candidate ->
        var key = candidate
        var attempt = 1
        while (!used.add(key)) key = "$candidate#dup${attempt++}"
        key
    }
}
