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
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream

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

    /** Too big to remember by identity: a file over 1 GB, which a repeat tap would otherwise stream and hash again. */
    private var tooLargeMemo: Pair<String, Capture.TooLarge>? = null

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
            // The same clip as last time: another app's file left on the
            // clipboard is still there on every resume, and reading it means
            // streaming up to 1 GB into the store and hashing it, only for the
            // engine to find the hash equal to lastKnownHash afterwards - so
            // it is recognised first, by what is cheap to compare.
            val identity = clipIdentity(uri, description)
            unchangedUriClip(identity)?.let { return it }
            readUri(uri)?.let {
                rememberUriClip(identity, it)
                return it
            }
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
            if (mime.startsWith("image/")) inlineImage(uri)?.let { return it }
            resolver.openInputStream(uri)?.use { store(uri, it) }
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        }
    }

    /**
     * The PNG of a copied image small enough to travel inline, else null - and
     * then the image goes as the file it is. Null, rather than a failure, for
     * an image that is too big in bytes (judged by its declared size first, so
     * a huge one isn't read twice), too wide, not decodable, or that there is
     * no memory to decode: all four are files.
     */
    private fun inlineImage(uri: Uri): Capture.Image? = try {
        val declared = declaredSize(uri)
        if (declared > MAX_INLINE_IMAGE_BYTES) {
            null
        } else {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val head = input.readAtMost(MAX_INLINE_IMAGE_BYTES + 1)
                if (head.size > MAX_INLINE_IMAGE_BYTES) null else toPng(head)?.let { Capture.Image(it) }
            }
        }
    } catch (e: Exception) {
        null
    } catch (e: OutOfMemoryError) {
        null
    }

    /** What the provider says the content is long, or -1 when it doesn't say. */
    private fun declaredSize(uri: Uri): Long = try {
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
    } catch (e: Exception) {
        -1L
    }

    // ---- recognising a clip that hasn't changed ---------------------------

    /**
     * What identifies a clip without reading it: its URI and when it was put
     * there. The timestamp is what tells "the same URI copied again" - which
     * may be a different file behind the same address - from the clip that
     * never moved.
     */
    private fun clipIdentity(uri: Uri, description: ClipDescription?): String =
        "$uri|${description?.timestamp ?: 0L}"

    /**
     * [Capture.Ours] - already synced - when [identity] is the clip captured
     * last time AND that capture did go out: the hash it produced is the one
     * lastKnownHash holds, and the engine notes it only once it has gone on to
     * broadcast. A capture the engine gave up on (still starting, say) is not
     * recognised, so a second tap tries again. Null when it has to be read.
     */
    private fun unchangedUriClip(identity: String): Capture? {
        tooLargeMemo?.takeIf { it.first == identity }?.let { return it.second }
        val hash = prefs.getString(URI_CLIP_HASH_KEY, null) ?: return null
        if (prefs.getString(URI_CLIP_KEY, null) != identity) return null
        return if (hash == lastKnownHash) Capture.Ours else null
    }

    private fun rememberUriClip(identity: String, capture: Capture) {
        val hash = when (capture) {
            is Capture.Payload -> capture.hash
            is Capture.Image -> FileStore.hashOf(capture.pngBytes)
            is Capture.TooLarge -> {
                tooLargeMemo = identity to capture
                return
            }

            else -> return
        }
        // Persisted: the clipboard outlives this process, and without it the
        // first resume after every restart read the same file in again.
        prefs.edit().putString(URI_CLIP_KEY, identity).putString(URI_CLIP_HASH_KEY, hash).apply()
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
     * decoded, as iOS limits it - or a PNG over [MAX_INLINE_IMAGE_BYTES]. Also
     * null when there is no memory for it (a 4096 px square is 64 MB decoded,
     * and the PNG is built beside it): the image then goes as a file instead
     * of the process going down.
     */
    private fun toPng(bytes: ByteArray): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        if (maxOf(bounds.outWidth, bounds.outHeight) > MAX_INLINE_IMAGE_EDGE) return null
        val bitmap = try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (e: OutOfMemoryError) {
            null
        } ?: return null
        try {
            val out = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) return null
            return out.toByteArray().takeIf { it.size <= MAX_INLINE_IMAGE_BYTES }
        } catch (e: OutOfMemoryError) {
            return null
        } finally {
            // Freed as soon as the PNG exists, not whenever the GC gets to it.
            bitmap.recycle()
        }
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
        } catch (e: OutOfMemoryError) {
            false // an image's base64 and bytes at once, for one
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
     *
     * BLOCKING, and it can fail: a blob can be a gigabyte, the disk can be
     * full, the blob can have been evicted meanwhile, and FileProvider throws
     * for a path it doesn't cover. Never call it on the main thread, and
     * expect an IOException or IllegalArgumentException (see [prepareShare]).
     */
    fun contentUriFor(sourceFile: File, displayName: String): Uri {
        val target = sharedCopyOf(fileStore.sharedDir, sourceFile, displayName)
        target.parentFile?.apply {
            if (isFile) delete() // an older build's copy, named like a hash
            mkdirs()
        }
        if (!target.exists() || target.length() != sourceFile.length()) {
            placeCopy(sourceFile, target)
        }
        // The folder's age is what [pruneSharedCopies] goes by: stamped on every
        // use, so a copy made long ago and handed out again now isn't pruned.
        target.parentFile?.setLastModified(System.currentTimeMillis())
        return FileProvider.getUriForFile(context, fileProviderAuthority(context), target)
    }

    /**
     * What a share of one history item hands to the share sheet - see
     * [prepareShare].
     */
    sealed interface SharePayload {
        data class Text(val text: String) : SharePayload
        data class Stream(val uri: Uri, val mimeType: String) : SharePayload

        /** Nothing to share; [message] says why, for a toast. */
        data class Unavailable(val message: String) : SharePayload
    }

    /**
     * Gets one history item ready for the share sheet. BLOCKING - for the IO
     * dispatcher: a file is copied into [FileStore.sharedDir] under its own
     * name (up to a gigabyte, hence the dispatcher), an image is decoded from
     * its base64 and parked in the store.
     *
     * NEVER THROWS. Sharing was unguarded while Copy never was: a full disk, a
     * blob evicted a moment ago, FileProvider rejecting a path or no memory for
     * a big image crashed the app. Each is an [SharePayload.Unavailable] with
     * a message instead. A text too long for an Intent extra (a ~1 MB Binder
     * limit shared by everything in flight - half a million characters threw
     * TransactionTooLargeException, wrapped as a RuntimeException) is shared
     * as a .txt file; nothing is cut off.
     */
    fun prepareShare(entry: ClipboardEntry): SharePayload = try {
        pruneSharedCopies()
        when (entry.type) {
            ClipboardEntry.TYPE_TEXT -> shareText(entry.content)

            ClipboardEntry.TYPE_IMAGE -> {
                val bytes = B64.decodeOrNull(entry.content)
                if (bytes == null) {
                    SharePayload.Unavailable("Couldn't read that image.")
                } else {
                    val hash = FileStore.hashOf(bytes)
                    if (!fileStore.exists(hash)) fileStore.write(hash, bytes)
                    SharePayload.Stream(contentUriFor(fileStore.path(hash), "$hash.png"), "image/png")
                }
            }

            ClipboardEntry.TYPE_FILE -> {
                val payload = FilePayload.parse(entry.content)
                when {
                    payload == null -> SharePayload.Unavailable("Couldn't read that file's details.")
                    !fileStore.exists(payload.fileHash) ->
                        SharePayload.Unavailable("That file hasn't finished transferring yet.")

                    else -> SharePayload.Stream(
                        contentUriFor(fileStore.path(payload.fileHash), payload.fileName),
                        guessMimeType(payload.fileName),
                    )
                }
            }

            else -> SharePayload.Unavailable("That kind of item can't be shared.")
        }
    } catch (e: OutOfMemoryError) {
        SharePayload.Unavailable("Not enough memory to share that item.")
    } catch (e: IOException) {
        SharePayload.Unavailable("Couldn't get that ready to share - is the phone's storage full?")
    } catch (e: Exception) {
        SharePayload.Unavailable("Couldn't get that ready to share.")
    }

    private fun shareText(text: String): SharePayload {
        if (text.length <= MAX_SHARE_TEXT_CHARS) return SharePayload.Text(text)
        val bytes = text.toByteArray(Charsets.UTF_8)
        val blob = fileStore.sharedDir.resolve(FileStore.hashOf(bytes)).apply { mkdirs() }
        val target = File(blob, "ClipLink text.txt")
        if (!target.exists() || target.length() != bytes.size.toLong()) {
            val temp = File.createTempFile("text_", ".part", blob)
            try {
                temp.writeBytes(bytes)
                target.delete()
                if (!temp.renameTo(target)) throw IOException("couldn't place the text file")
            } finally {
                temp.delete()
            }
        }
        blob.setLastModified(System.currentTimeMillis())
        return SharePayload.Stream(
            FileProvider.getUriForFile(context, fileProviderAuthority(context), target),
            "text/plain",
        )
    }

    /**
     * Deletes the human-named copies in [FileStore.sharedDir] that haven't
     * been handed out for a day. They were never deleted: each doubles a
     * blob's storage for good. A day is long enough for any app that was
     * given one to have read it; the clip this app put on the clipboard last
     * is spared, as it may be pasted much later. Blocking; never throws.
     */
    fun pruneSharedCopies(): Int = try {
        pruneSharedDir(fileStore.sharedDir, System.currentTimeMillis(), SHARED_COPY_MAX_AGE_MS, lastKnownHash)
    } catch (e: Exception) {
        0
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

        /** The last foreign file/image clip captured (see [capture]), and the hash it produced. */
        private const val URI_CLIP_KEY = "last_uri_clip"
        private const val URI_CLIP_HASH_KEY = "last_uri_clip_hash"

        /**
         * The longest text put in an Intent extra when sharing. UTF-16 on the
         * wire, inside a Binder transaction whose ~1 MB budget everything in
         * flight shares - and the share sheet carries the intent twice.
         */
        internal const val MAX_SHARE_TEXT_CHARS = 50_000

        /** How long a human-named copy in the share folder is kept after it was last handed out. */
        internal const val SHARED_COPY_MAX_AGE_MS = 24L * 60 * 60 * 1000

        /**
         * The most a copied image may be to travel inline as a PNG, before and
         * after: 6 MB, which is 8 MB once base64-encoded - and that is encoded
         * again with the signature and the encryption around it, so the
         * sender holds several copies at once (it used to be iOS's 24 MB:
         * ~100 MB of buffers on a phone). A bigger image goes as the file it
         * is, which is streamed rather than held.
         */
        internal const val MAX_INLINE_IMAGE_BYTES = 6 * 1024 * 1024

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

/**
 * Copies [source] to [target], never leaving a half-written [target] behind:
 * the copy is made beside it and renamed into place, so a disk that fills up
 * half way, or a process killed meanwhile, leaves nothing a share could hand
 * out. Throws IOException on a full disk or a vanished source. (A hard link
 * would save the copy, but this app's sandbox refused one when tried on an
 * emulator, so it isn't relied on.)
 */
internal fun placeCopy(source: File, target: File) {
    target.delete() // a copy that was cut short by an older build
    val temp = File.createTempFile("copy_", ".part", target.parentFile)
    try {
        source.inputStream().use { input -> temp.outputStream().use { output -> input.copyTo(output) } }
        if (!temp.renameTo(target)) throw IOException("couldn't place ${target.name}")
    } finally {
        temp.delete() // a no-op once renamed
    }
}

/**
 * Deletes what is directly under [sharedDir] - a folder per blob, or a stray
 * file - that was last modified [maxAgeMs] or more before [now], except the
 * one named [keepName]. Returns how many went.
 */
internal fun pruneSharedDir(sharedDir: File, now: Long, maxAgeMs: Long, keepName: String?): Int {
    val entries = sharedDir.listFiles() ?: return 0
    return entries.count { entry ->
        entry.name != keepName && now - entry.lastModified() >= maxAgeMs && entry.deleteRecursively()
    }
}
