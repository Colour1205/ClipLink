package io.uaena.cliplink.ui

/**
 * Most of a text entry a list card hands to `Text`. A card shows four to
 * twelve lines, but `Text` measures everything it is given, and a copied
 * log or a whole file's text is megabytes - measured again on every
 * recomposition of every card, which froze the list.
 */
const val CARD_TEXT_LIMIT = 2_000

/**
 * Most of a text entry the detail view lays out. Far more than anyone reads
 * on a phone, and still far less than a layout pass can choke on; the Copy
 * button takes all of it regardless.
 */
const val DETAIL_TEXT_LIMIT = 100_000

/**
 * The first [limit] characters of [text] - or all of it when that is fewer -
 * never ending halfway through a surrogate pair (an emoji cut in two would
 * draw as a replacement glyph).
 */
fun previewTextOf(text: String, limit: Int): String {
    if (text.length <= limit) return text
    var end = limit
    if (end > 0 && Character.isHighSurrogate(text[end - 1])) end--
    return text.substring(0, end)
}
