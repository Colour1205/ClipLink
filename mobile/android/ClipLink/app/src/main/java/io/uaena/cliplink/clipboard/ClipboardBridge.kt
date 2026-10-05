package io.uaena.cliplink.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.share.ShareIntake
import io.uaena.cliplink.share.isShareableUri
import io.uaena.cliplink.store.FileNames
import io.uaena.cliplink.store.FileStore
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.SequenceInputStream

/** Something captured locally, on its way to becoming a signed entry. */
sealed interface Capture {
    data class Text(val text: String) : Capture
    data class Image(val pngBytes: ByteArray) : Capture {
        override fun equals(other: Any?) = this === other
        override fun hashCode() = System.identityHashCode(this)
    }

    /** A copied file, already in the FileStore under [hash]. */
    data class Payload(val fileName: String, val hash: String, val size: Long) : Capture

    /** A copied file over the 1 GB a synced file may be - nothing of it kept. */
    data class TooLarge(val fileName: String) : Capture

    /** A clip this app put there itself - already synced, so nothing to send. */
    data object Ours : Capture
}

/**
 * The system clipboard, in both directions.
 *
 * READING IS FOREGROUND-ONLY. Since Android 10 an app may only read the
 * clipboard while it holds focus or is the default IME - there is no
 * background watcher on this platform, and `addPrimaryClipChangedListener`
 * simply doesn't fire for other apps' copies. That is a platform constraint,
 * not a missing feature: the Windows daemon's silent background capture has
 * no Android equivalent. The app therefore offers two honest paths instead -
 * capture on foreground/paste, and a share-sheet target (see
 * ShareReceiverActivity) for pushing from any other app.
 *
 * WRITING is unrestricted, so received items land on the clipboard normally.
 */
class ClipboardBridge(private val context: Context, private val fileStore: FileStore) {

    private val manager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_clipboard", Context.MODE_PRIVATE)

    /**
     * Hash of whatever this device last put on, or took off, the clipboard.
     * Without it, applying a received entry immediately looks like a fresh
     * local copy and gets broadcast straight back to the peer that sent it.
     *
     * Persisted, because the clipboard outlives this process: after the OS
     * kills the app, the capture on the next launch would otherwise take the
     * item it last sent - one the user may have deleted from the history
     * since - for a fresh copy, and sync it all over again.
     */
    var lastKnownHash: String? = prefs.getString(LAST_HASH_KEY, null)
        private set(value) {
            field = value
            prefs.edit().putString(LAST_HASH_KEY, value).apply()
        }

    fun addListener(listener: () -> Unit) {
        manager.addPrimaryClipChangedListener(listener)
    }

    fun removeListener(listener: () -> Unit) {
        manager.removePrimaryClipChangedListener(listener)
    }

    /** Null when the clipboard is empty, unreadable (backgrounded), or holds nothing we handle. */
    fun capture(): Capture? {
        // A clip this app wrote - a received item it applied, or one copied
        // from the history - is already synced. The hash check alone misses
        // it for an image (re-encoded below, it no longer hashes to what
        // arrived) and after a restart, and a deleted item would then come
        // straight back as a new one. The label is read without the content.
        val description = try {
            manager.primaryClipDescription
        } catch (e: SecurityException) {
            null
        }
        if (description?.label?.toString() == CLIP_LABEL) return Capture.Ours

        val clip = try {
            manager.primaryClip
        } catch (e: SecurityException) {
            null
        } ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)

        // URI first: a copied image or file also carries a coerced text
        // label, and taking the text would sync the label instead of the
        // thing the user actually copied.
        item.uri?.let { uri ->
            readUri(uri)?.let { return it }
            // Not one readUri reads. coerceToText would read a content URI's
            // stream whole instead, however big it is - so only the item's
            // own text, if it has any. Any other scheme it merely spells out.
            if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
                return item.text?.toString()?.takeIf { it.isNotEmpty() }?.let { Capture.Text(it) }
            }
        }

        val text = item.coerceToText(context)?.toString()
        if (!text.isNullOrEmpty()) return Capture.Text(text)
        return null
    }

    /**
     * A copied file or image - only ever another app's `content://` URI, by
     * the share sheet's rule (see [isShareableUri]): a `file://` one opens
     * with this app's own permissions, and whatever put
     * `file:///data/user/0/io.uaena.cliplink/shared_prefs/...` on the
     * clipboard would get this app's private files synced out.
     *
     * Never read whole: streamed into the FileStore, up to the 1 GB a share
     * may be. Only an image small enough to travel inline is held in memory,
     * to become a PNG; a bigger one, or one that doesn't decode - an empty
     * file, an SVG - goes as the file it is. Every miss is null rather than a
     * crash: the on-open capture would otherwise crash the app on every open
     * for as long as that clip stayed on the clipboard.
     */
    private fun readUri(uri: Uri): Capture? {
        if (!isShareableUri(uri.scheme, uri.authority, fileProviderAuthority(context))) return null
        val resolver = context.contentResolver
        return try {
            val mime = resolver.getType(uri) ?: ""
            resolver.openInputStream(uri)?.use { input ->
                if (!mime.startsWith("image/")) return@use store(uri, input)
                val head = input.readAtMost(MAX_INLINE_IMAGE_BYTES + 1)
                if (head.size <= MAX_INLINE_IMAGE_BYTES) toPng(head)?.let { return@use Capture.Image(it) }
                store(uri, SequenceInputStream(ByteArrayInputStream(head), input))
            }
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        }
    }

    private fun store(uri: Uri, input: InputStream): Capture {
        val name = displayName(uri)
        val stored = fileStore.importStream(input, ShareIntake.MAX_FILE_BYTES) ?: return Capture.TooLarge(name)
        return Capture.Payload(name, stored.hash, stored.size)
    }

    /** Up to [limit] bytes - fewer only at the end of the stream. */
    private fun InputStream.readAtMost(limit: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (out.size() < limit) {
            val read = read(buffer, 0, minOf(buffer.size, limit - out.size()))
            if (read < 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    /**
     * The provider's name for [uri], made safe (see [FileNames.safe]) - it is
     * another app's claim, and it goes on the wire as the FileName.
     */
    private fun displayName(uri: Uri): String {
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    cursor.getString(index)?.takeIf { it.isNotEmpty() }?.let { return FileNames.safe(it, "file") }
                }
            }
        }
        return FileNames.safe(uri.lastPathSegment, "file")
    }

    /**
     * Re-encodes to PNG. The other two platforms exchange images as base64
     * PNG regardless of what was copied, so a JPEG straight off the clipboard
     * would arrive as bytes the receiver labels PNG and can still decode - but
     * would then re-hash differently on every hop. Normalising here keeps the
     * echo-suppression hash stable across devices. Null when [bytes] don't
     * decode as an image at all, or make one too big to travel inline: over
     * [MAX_INLINE_IMAGE_EDGE] on a side - measured before anything is
     * decoded, as iOS limits it - or a PNG over [MAX_INLINE_IMAGE_BYTES].
     */
    private fun toPng(bytes: ByteArray): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        if (maxOf(bounds.outWidth, bounds.outHeight) > MAX_INLINE_IMAGE_EDGE) return null
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return out.toByteArray().takeIf { it.size <= MAX_INLINE_IMAGE_BYTES }
    }

    /** Writes a received entry onto the system clipboard. */
    fun apply(entry: ClipboardEntry): Boolean {
        return try {
            when (entry.type) {
                ClipboardEntry.TYPE_TEXT -> {
                    lastKnownHash = FileStore.hashOf(entry.content.toByteArray(Charsets.UTF_8))
                    manager.setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, entry.content))
                    true
                }

                ClipboardEntry.TYPE_IMAGE -> {
                    val bytes = B64.decodeOrNull(entry.content) ?: return false
                    val hash = FileStore.hashOf(bytes)
                    lastKnownHash = hash
                    // Images travel inline in the entry, but the clipboard
                    // needs a URI - so the bytes get parked in the blob cache
                    // purely to have something FileProvider can hand out.
                    if (!fileStore.exists(hash)) fileStore.write(hash, bytes)
                    manager.setPrimaryClip(uriClip(fileStore.path(hash), "$hash.png", "image/png"))
                    true
                }

                ClipboardEntry.TYPE_FILE -> {
                    val payload = FilePayload.parse(entry.content) ?: return false
                    if (!fileStore.exists(payload.fileHash)) return false
                    lastKnownHash = payload.fileHash
                    manager.setPrimaryClip(
                        uriClip(
                            fileStore.path(payload.fileHash),
                            payload.fileName,
                            guessMimeType(payload.fileName),
                        ),
                    )
                    true
                }

                else -> false
            }
        } catch (e: Exception) {
            false
        }
    }

    fun noteLocalHash(hash: String) {
        lastKnownHash = hash
    }

    /**
     * Copies the blob to a human-named file first. A blob is stored under its
     * hash, and handing another app `a3f9…` as a filename is useless in a
     * share sheet or a Downloads folder.
     *
     * [displayName] is usually a peer's FileName, so it is only ever used
     * through [FileNames.safe]: a received ".." or "../../shared_prefs/x"
     * must name a file inside sharedDir, never sharedDir or its parents.
     *
     * One copy per blob (see [sharedCopyOf]); the length check only repairs a
     * copy that was cut short.
     */
    fun contentUriFor(sourceFile: File, displayName: String): Uri {
        val target = sharedCopyOf(fileStore.sharedDir, sourceFile, displayName)
        target.parentFile?.apply {
            if (isFile) delete() // an older build's copy, named like a hash
            mkdirs()
        }
        if (!target.exists() || target.length() != sourceFile.length()) {
            sourceFile.copyTo(target, overwrite = true)
        }
        return FileProvider.getUriForFile(context, fileProviderAuthority(context), target)
    }

    private fun uriClip(sourceFile: File, displayName: String, mimeType: String): ClipData {
        val uri = contentUriFor(sourceFile, displayName)
        return ClipData(
            ClipDescription(CLIP_LABEL, arrayOf(mimeType)),
            ClipData.Item(uri),
        )
    }

    companion object {
        /** What every clip this app writes is labelled - see [capture]. */
        const val CLIP_LABEL = "ClipLink"
        private const val LAST_HASH_KEY = "last_known_hash"

        /** The most a copied image may be to travel inline as a PNG, before and after - iOS's limit. */
        private const val MAX_INLINE_IMAGE_BYTES = 24 * 1024 * 1024

        /** The longest side a copied image may have to be decoded and travel inline - iOS's limit. */
        private const val MAX_INLINE_IMAGE_EDGE = 4096

        /** The FileProvider's authority, as the manifest declares it: `${applicationId}.files`. */
        fun fileProviderAuthority(context: Context): String = "${context.packageName}.files"

        fun guessMimeType(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "pdf" -> "application/pdf"
            "txt", "md", "log" -> "text/plain"
            "json" -> "application/json"
            "zip" -> "application/zip"
            "mp4" -> "video/mp4"
            "mp3" -> "audio/mpeg"
            else -> "application/octet-stream"
        }
    }
}

/**
 * Where [blob]'s human-named copy goes: `<sharedDir>/<its hash>/<safe name>`.
 * A folder per blob, so a later file with the same name - and maybe the same
 * length - gets a copy of its own rather than the earlier file's bytes.
 */
internal fun sharedCopyOf(sharedDir: File, blob: File, displayName: String): File =
    File(File(sharedDir, blob.name), FileNames.safe(displayName, "file"))
