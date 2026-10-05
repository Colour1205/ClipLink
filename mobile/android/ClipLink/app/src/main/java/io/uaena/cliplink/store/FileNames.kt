package io.uaena.cliplink.store

/**
 * File names that came from somewhere else - a peer's FilePayload, or the
 * DISPLAY_NAME another app's content provider reports for a shared file.
 * Mirrors FileNames.cs on Windows.
 */
object FileNames {

    private const val MAX_LENGTH = 120
    private const val MAX_EXTENSION_LENGTH = 20

    /**
     * Android's file systems (ext4, f2fs) - and APFS and HarmonyOS's - cap a
     * name at 255 bytes of UTF-8, not 255 characters: 120 Chinese characters
     * are 360 bytes, and creating that name fails. Kept under 255 so a
     * receiver can still add a " (1)" to it.
     */
    private const val MAX_UTF8_BYTES = 240

    /** Characters no file system here or on a peer accepts in a name, plus the separators. */
    private const val INVALID = "\\/:*?\"<>|"

    /**
     * Right-to-left and other bidi overrides: "invoice\u202Etxt.exe" is shown
     * as "invoiceexe.txt". Legal in a name, but only ever used to disguise one.
     */
    private fun isBidiControl(c: Char): Boolean =
        c in '\u202A'..'\u202E' || c in '\u2066'..'\u2069' || c == '\u200E' || c == '\u200F' || c == '\u061C'

    /**
     * [name] made safe to create inside a folder and to hand to another app:
     * only its last path segment (a "../../x" or "C:\Users\...\x.exe" must
     * land in the folder it's put in, not there), invalid and control
     * characters replaced, no trailing dots or spaces (so "." and ".." are
     * nothing), and at most 120 characters and 240 UTF-8 bytes with the
     * extension kept. Blank after all that: [fallback].
     *
     * Windows' reserved device names (CON, NUL...) are left alone - they mean
     * nothing here, and a Windows peer renames them itself on receipt.
     */
    fun safe(name: String?, fallback: String): String {
        var safe = name.orEmpty().replace('\\', '/').substringAfterLast('/')
        safe = buildString(safe.length) {
            for (c in safe) {
                append(if (c in INVALID || Character.isISOControl(c) || isBidiControl(c)) '_' else c)
            }
        }.trim().trimEnd('.', ' ')
        if (safe.isEmpty()) return fallback
        if (safe.length > MAX_LENGTH || utf8Length(safe) > MAX_UTF8_BYTES) {
            val dot = safe.lastIndexOf('.')
            var extension = if (dot >= 0) safe.substring(dot) else ""
            if (extension.length > MAX_EXTENSION_LENGTH) extension = ""
            val stem = prefix(safe, MAX_LENGTH - extension.length, MAX_UTF8_BYTES - utf8Length(extension))
            // A stem of nothing but dots and spaces trims away entirely - and
            // with no extension left either, "" would name the folder itself.
            safe = (stem.trimEnd('.', ' ') + extension).ifEmpty { return fallback }
        }
        return safe
    }

    /** The longest start of [s] within [maxChars] and [maxBytes] of UTF-8 - never half a character. */
    private fun prefix(s: String, maxChars: Int, maxBytes: Int): String {
        var end = 0
        var bytes = 0
        while (end < s.length) {
            val codePoint = s.codePointAt(end)
            val next = end + Character.charCount(codePoint)
            bytes += utf8Length(codePoint)
            if (next > maxChars || bytes > maxBytes) break
            end = next
        }
        return s.substring(0, end)
    }

    private fun utf8Length(s: String): Int {
        var bytes = 0
        var i = 0
        while (i < s.length) {
            val codePoint = s.codePointAt(i)
            bytes += utf8Length(codePoint)
            i += Character.charCount(codePoint)
        }
        return bytes
    }

    // A lone surrogate counts as 3 - the most any encoder writes for one.
    private fun utf8Length(codePoint: Int): Int = when {
        codePoint < 0x80 -> 1
        codePoint < 0x800 -> 2
        codePoint < 0x10000 -> 3
        else -> 4
    }
}
