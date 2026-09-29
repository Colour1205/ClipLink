package io.uaena.cliplink.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.ClipboardEntry
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.store.FileNames
import io.uaena.cliplink.store.FileStore
import java.io.ByteArrayOutputStream
import java.io.File

/** Something captured locally, on its way to becoming a signed entry. */
sealed interface Capture {
    data class Text(val text: String) : Capture
    data class Image(val pngBytes: ByteArray) : Capture {
        override fun equals(other: Any?) = this === other
        override fun hashCode() = System.identityHashCode(this)
    }

    data class Payload(val fileName: String, val bytes: ByteArray) : Capture {
        override fun equals(other: Any?) = this === other
        override fun hashCode() = System.identityHashCode(this)
    }

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
        item.uri?.let { uri -> readUri(uri)?.let { return it } }

        val text = item.coerceToText(context)?.toString()
        if (!text.isNullOrEmpty()) return Capture.Text(text)
        return null
    }

    private fun readUri(uri: Uri): Capture? = try {
        val mime = context.contentResolver.getType(uri) ?: ""
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        when {
            bytes == null -> null
            mime.startsWith("image/") -> Capture.Image(toPng(bytes))
            else -> Capture.Payload(displayName(uri), bytes)
        }
    } catch (e: Exception) {
        null
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
     * echo-suppression hash stable across devices.
     */
    private fun toPng(bytes: ByteArray): ByteArray {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return bytes
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
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
     */
    fun contentUriFor(sourceFile: File, displayName: String): Uri {
        val target = File(fileStore.sharedDir, FileNames.safe(displayName, "file"))
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
