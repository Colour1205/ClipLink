package io.uaena.cliplink.share

/** What sharing into ClipLink came to, for whoever shows the result. */
data class ShareOutcome(
    /** The names the synced files went out under, in order. */
    val files: List<String> = emptyList(),
    val text: Boolean = false,
    val unreadable: Int = 0,
    val tooLarge: List<String> = emptyList(),
    /** Files past [ShareIntake.MAX_FILES], never copied. */
    val skipped: Int = 0,
    /** Devices connected when it went out - with none, it waits in the history for one. */
    val connected: Int = 0,
    /** Nothing was shared: the engine never got a key to sign with, or something threw. */
    val failed: Boolean = false,
) {
    val message: String
        get() {
            if (failed) return "ClipLink couldn't share that - open it and try again."
            val parts = mutableListOf<String>()
            val what = when {
                text -> "text"
                files.size == 1 -> files[0]
                files.size > 1 -> "${files.size} files"
                else -> null
            }
            if (what != null) {
                parts += if (connected > 0) {
                    "Synced $what."
                } else {
                    "Saved $what - ${if (files.size > 1) "they'll" else "it'll"} sync when a device connects."
                }
            }
            when (tooLarge.size) {
                0 -> Unit
                1 -> parts += "${tooLarge[0]} is over 1 GB, too big to sync."
                else -> parts += "${tooLarge.size} files are over 1 GB, too big to sync."
            }
            if (unreadable > 0) {
                parts += when {
                    parts.isNotEmpty() -> "Couldn't read ${count(unreadable, "file")}."
                    unreadable == 1 -> "ClipLink couldn't read that file."
                    else -> "ClipLink couldn't read those files."
                }
            }
            if (skipped > 0) {
                parts += "ClipLink keeps ${ShareIntake.MAX_FILES} items, so ${count(skipped, "more file")} " +
                    "${if (skipped == 1) "was" else "were"} left out."
            }
            return parts.joinToString(" ").ifEmpty { "Nothing to share." }
        }

    private fun count(n: Int, noun: String) = if (n == 1) "1 $noun" else "$n ${noun}s"
}
