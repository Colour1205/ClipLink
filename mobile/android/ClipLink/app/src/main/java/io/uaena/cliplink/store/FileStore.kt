package io.uaena.cliplink.store

import android.content.Context
import io.uaena.cliplink.core.toHex
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/**
 * Content-addressed blob cache, keyed by SHA-256 hex exactly as the entry
 * spells it (this device writes lowercase; Windows and iOS send uppercase).
 * Mirrors FileStore.cs / FileStore.ets.
 *
 * Descriptor-only by design: entry payloads carry a name/hash/size, never
 * bytes. The bytes arrive separately as chunk messages and land here.
 *
 * A hash almost always comes from another device - a file entry, a
 * file_request or a file_chunk - and every method here turns it into a path.
 * Only a real SHA-256 in hex is one (see [isValidHash]): anything else,
 * "../shared_prefs/cliplink_trust.xml" say, would let a peer read, overwrite
 * or delete this app's own files. [path] and [tempPath] throw for it;
 * [exists] is false and [delete] does nothing.
 */
class FileStore internal constructor(
    private val baseDir: File,
    /** Human-named copies for share sheets - a blob's own filename is its hash. */
    val sharedDir: File,
) {

    constructor(context: Context) : this(
        File(context.applicationContext.filesDir, SUBDIR),
        File(context.applicationContext.cacheDir, "shared"),
    )

    /**
     * Every hash this process has turned into a path so far - stored,
     * checked for, or being received - which [sweepUnreferenced] must leave
     * alone: a share's blob is nobody's until its entry is signed and
     * recorded a moment after the import, and a .tmp may be a live
     * transfer's. Null once the sweep has run; it runs once.
     */
    private var touched: MutableSet<String>? = HashSet()
    private val sweepLock = Any()

    init {
        baseDir.mkdirs()
        sharedDir.mkdirs()
        // Imports a killed process never finished. Nothing else can be
        // writing one yet: this store is built once, when the process starts.
        baseDir.listFiles { file -> file.name.startsWith(IMPORT_PREFIX) }?.forEach { it.delete() }
    }

    private fun touch(hash: String): String {
        synchronized(sweepLock) { touched?.add(hash) }
        return hash
    }

    fun path(hash: String): File = File(baseDir, touch(checked(hash)))

    fun tempPath(hash: String): File = File(baseDir, "${touch(checked(hash))}$TEMP_SUFFIX")

    fun exists(hash: String): Boolean = isValidHash(hash) && path(hash).exists()

    fun delete(hash: String) {
        if (!isValidHash(hash)) return
        path(hash).delete()
    }

    fun write(hash: String, bytes: ByteArray) {
        path(hash).writeBytes(bytes)
    }

    /**
     * Stores a 0-byte file's blob, which no peer ever has to send: most
     * builds stream no chunk at all for an empty file, so waiting for one
     * would wait forever. [hash] must be [EMPTY_FILE_HASH], in whichever
     * case the entry spells it.
     */
    fun storeEmpty(hash: String) {
        require(hash.equals(EMPTY_FILE_HASH, ignoreCase = true)) { "Not the empty file's hash." }
        val file = path(hash)
        if (!file.exists()) file.writeBytes(ByteArray(0))
    }

    /**
     * Deletes every blob, and every .tmp a killed process left, whose hash
     * isn't in [referenced] - bytes no history entry points at any more,
     * whatever left them behind: an entry deleted or evicted while its bytes
     * were still arriving, a process killed between the two. Anything this
     * process has already touched is spared (see [touched]). For startup,
     * before any peer connects; runs once, later calls do nothing. Returns
     * how many files went.
     */
    fun sweepUnreferenced(referenced: Set<String>): Int = synchronized(sweepLock) {
        val spared = touched ?: return 0
        touched = null
        val files = baseDir.listFiles() ?: return 0
        files.count { file ->
            val hash = file.name.removeSuffix(TEMP_SUFFIX)
            isValidHash(hash) && hash !in referenced && hash !in spared && file.isFile && file.delete()
        }
    }

    /** A blob [importStream] put in the store. */
    data class Stored(val hash: String, val size: Long)

    /**
     * Streams [input] into the store - copied and hashed in one pass, never
     * held in memory, then renamed to its hash. Null, and nothing kept, when
     * it is bigger than [maxBytes]. Throws IOException when it can't be read
     * or written.
     */
    fun importStream(input: InputStream, maxBytes: Long): Stored? {
        val temp = File.createTempFile(IMPORT_PREFIX, ".part", baseDir)
        try {
            val stored = temp.outputStream().use { copyHashed(input, it, maxBytes) } ?: return null
            val target = path(stored.hash)
            // Already here means these exact bytes are already here.
            if (!target.exists() && !temp.renameTo(target)) throw IOException("couldn't store ${stored.hash}")
            return stored
        } finally {
            temp.delete() // a no-op once renamed
        }
    }

    companion object {
        private const val SUBDIR = "cliplink_files"
        private const val BUFFER = 256 * 1024
        private const val IMPORT_PREFIX = "import_"
        private const val TEMP_SUFFIX = ".tmp"

        /** SHA-256 of no bytes at all - a 0-byte file's hash, on every platform. */
        const val EMPTY_FILE_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

        /**
         * A SHA-256 in hex: 64 hex digits. Either case - Windows sends upper
         * case, the phones lower - which the file system here keeps apart,
         * but every device only ever names a blob the way it received it.
         */
        fun isValidHash(hash: String?): Boolean =
            hash != null && hash.length == 64 && hash.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

        private fun checked(hash: String): String {
            require(isValidHash(hash)) { "Not a file hash (64 hex digits)." }
            return hash
        }

        fun hashOf(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

        /** Streams the file rather than reading it whole - these can be large. */
        fun hashOf(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { stream ->
                val buffer = ByteArray(BUFFER)
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().toHex()
        }

        /**
         * Copies [input] to [output] while hashing it. Stops reading, and
         * returns null, as soon as more than [maxBytes] have come through - a
         * provider's reported size is only a claim.
         */
        internal fun copyHashed(input: InputStream, output: OutputStream, maxBytes: Long): Stored? {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(BUFFER)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > maxBytes) return null
                digest.update(buffer, 0, read)
                output.write(buffer, 0, read)
            }
            return Stored(digest.digest().toHex(), total)
        }
    }
}
