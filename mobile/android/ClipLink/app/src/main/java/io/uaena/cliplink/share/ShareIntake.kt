package io.uaena.cliplink.share

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.IntentCompat
import io.uaena.cliplink.clipboard.ClipboardBridge
import io.uaena.cliplink.store.FileNames
import io.uaena.cliplink.store.FileStore
import io.uaena.cliplink.store.HistoryStore
import java.io.Closeable
import java.io.InputStream

/**
 * Reads what another app shares into ClipLink (ACTION_SEND / SEND_MULTIPLE)
 * and copies its files into the FileStore.
 *
 * Each shared URI has to be opened while the receiving activity is still
 * alive: the read grant that comes with it is temporary and goes when that
 * activity does (see [copyAll]). Everything a provider says about a file -
 * its name, its size - is only a claim, and treated as one.
 */
class ShareIntake(context: Context, private val fileStore: FileStore) {

    private val resolver: ContentResolver = context.applicationContext.contentResolver
    private val ownAuthority = ClipboardBridge.fileProviderAuthority(context)

    /** What became of one shared URI. */
    sealed interface Copy {
        data class Stored(val name: String, val hash: String, val size: Long) : Copy
        data class TooLarge(val name: String) : Copy
        data object Unreadable : Copy
    }

    /**
     * Every URI [intent] shares, in order and once each (see [pickSharedUris]):
     * EXTRA_STREAM - one for SEND, a list for SEND_MULTIPLE - and the ClipData
     * the system mirrors it into. Unfiltered: [copyAll] refuses the ones it
     * mustn't read, so they are reported as unreadable rather than vanishing
     * into "Nothing to share".
     *
     * Empty, never a crash, when the extras can't be read: this activity is
     * exported, and on Android 12 one unknown Parcelable anywhere in the
     * extras makes reading any of them throw - which here would take the
     * whole process, sync and all, down with it.
     */
    fun sharedUris(intent: Intent): List<Uri> = try {
        val streams = when (intent.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))

            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?.filterNotNull().orEmpty()

            else -> emptyList()
        }
        val clipUris = intent.clipData?.let { clip -> (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri } }
        pickSharedUris(streams, clipUris.orEmpty(), hasText = sharedText(intent) != null)
    } catch (e: Exception) {
        emptyList()
    }

    /**
     * The shared text: EXTRA_TEXT read as a CharSequence - a styled share
     * (a SpannableString) is null to getStringExtra - else the text of the
     * ClipData the system mirrors it into. Null when the extras can't be
     * read, like [sharedUris].
     */
    fun sharedText(intent: Intent): String? = try {
        intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotEmpty() }
            ?: intent.clipData?.let { clip ->
                (0 until clip.itemCount).firstNotNullOfOrNull { i ->
                    clip.getItemAt(i).text?.toString()?.takeIf { it.isNotEmpty() }
                }
            }
    } catch (e: Exception) {
        null
    }

    /**
     * Copies each of [uris] into the FileStore, streamed and hashed on the
     * way in, refusing anything over [MAX_FILE_BYTES]. Blocking - call it off
     * the main thread.
     *
     * Every one is opened before any is copied. The read grants go with the
     * share activity, and a Back press, the screen going off (it is
     * noHistory) or a recreation finishes that while a long copy is still
     * running: a stream already open keeps reading, but a URI not yet opened
     * could no longer be - and every file after the first would be lost.
     */
    fun copyAll(uris: List<Uri>): List<Copy> {
        val opened = uris.map(::open)
        try {
            return opened.map { it.copy() }
        } finally {
            opened.forEach { it.close() }
        }
    }

    /** A shared URI [open] got a stream for - or, when it couldn't, already the answer ([settled]). */
    private class Opened(val name: String, val input: InputStream?, val settled: Copy?) : Closeable {
        override fun close() {
            runCatching { input?.close() }
        }
    }

    private fun open(uri: Uri): Opened {
        if (!isShareableUri(uri.scheme, uri.authority, ownAuthority)) return Opened("", null, Copy.Unreadable)
        val (displayName, size) = nameAndSize(uri)
        val extension = runCatching {
            resolver.getType(uri)?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
        }.getOrNull()
        val name = sharedFileName(displayName, uri.lastPathSegment, extension)
        if (size != null && size > MAX_FILE_BYTES) return Opened(name, null, Copy.TooLarge(name))
        return try {
            resolver.openInputStream(uri)?.let { Opened(name, it, null) } ?: Opened(name, null, Copy.Unreadable)
        } catch (e: Exception) {
            // Gone, revoked, a folder - all the same here.
            Opened(name, null, Copy.Unreadable)
        }
    }

    private fun Opened.copy(): Copy {
        val stream = input ?: return settled ?: Copy.Unreadable
        return try {
            val stored = stream.use { fileStore.importStream(it, MAX_FILE_BYTES) } ?: return Copy.TooLarge(name)
            Copy.Stored(name, stored.hash, stored.size)
        } catch (e: Exception) {
            // Stopped partway, or the disk is full.
            Copy.Unreadable
        }
    }

    /**
     * DISPLAY_NAME and SIZE, each null when the provider doesn't say. No
     * projection, like ClipboardBridge: a provider that doesn't know a
     * requested column may throw, but every one answers with its defaults.
     */
    private fun nameAndSize(uri: Uri): Pair<String?, Long?> = runCatching {
        resolver.query(uri, null, null, null, null)
            ?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                val name = if (nameIndex >= 0 && !cursor.isNull(nameIndex)) cursor.getString(nameIndex) else null
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null
                name to size?.takeIf { it >= 0 }
            }
    }.getOrNull() ?: (null to null)

    companion object {
        /** The same ceiling the Windows app puts on a file it syncs. */
        const val MAX_FILE_BYTES = 1024L * 1024 * 1024

        /**
         * One share adds at most this many files - the most the history
         * holds. Any more and the first ones would be evicted, their bytes
         * released, before a peer ever asked for them.
         */
        const val MAX_FILES = HistoryStore.MAX_ITEMS
    }
}

/**
 * Which URIs a share is: [streams] (EXTRA_STREAM) and whatever else its
 * [clipUris] carry - the ClipData normally just mirrors EXTRA_STREAM, but
 * some apps only fill in the ClipData.
 *
 * Except next to text: a text share whose only URI is in the ClipData is a
 * link with a preview image there for the share sheet to show - that is
 * where Android's sharesheet looks for one, and browsers share a page that
 * way. The text is what's being shared; syncing the preview image instead,
 * and dropping the link as its "caption", is not.
 */
internal fun <T> pickSharedUris(streams: List<T>, clipUris: List<T>, hasText: Boolean): List<T> = when {
    streams.isNotEmpty() -> (streams + clipUris).distinct()
    hasText -> emptyList()
    else -> clipUris.distinct()
}

/**
 * Only `content://` URIs, and never this app's own FileProvider. A
 * `file://` URI would be opened with ClipLink's own permissions - an app
 * sharing `file:///data/data/io.uaena.cliplink/...` could get its private
 * files synced out - and a URI into its own provider is the same trick one
 * step removed. A cross-profile authority ("10@authority") is compared
 * without its user id, the way ContentResolver resolves it.
 */
internal fun isShareableUri(scheme: String?, authority: String?, ownAuthority: String): Boolean {
    // Exactly "content", as ContentResolver itself matches it.
    if (scheme != "content") return false
    val bareAuthority = authority?.substringAfterLast('@')?.takeIf { it.isNotEmpty() } ?: return false
    return !bareAuthority.equals(ownAuthority, ignoreCase = true)
}

/**
 * The name a shared file goes out under: the provider's DISPLAY_NAME, else
 * the URI's last segment, made safe (see [FileNames.safe]) - and given the
 * extension its MIME type implies when it has none, so a receiver can still
 * tell a photo from a PDF when the provider only offered ".../media/1234".
 */
internal fun sharedFileName(displayName: String?, lastPathSegment: String?, mimeExtension: String?): String {
    val name = FileNames.safe(displayName?.takeIf { it.isNotBlank() } ?: lastPathSegment, "file")
    val extension = mimeExtension?.takeIf { it.isNotEmpty() && it.all(Char::isLetterOrDigit) }
    return if (extension == null || name.contains('.')) name else FileNames.safe("$name.$extension", name)
}
