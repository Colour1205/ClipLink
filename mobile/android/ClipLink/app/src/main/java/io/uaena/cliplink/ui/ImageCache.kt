package io.uaena.cliplink.ui

import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.engine.SyncedItem
import io.uaena.cliplink.store.ImageFiles
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Decoded bitmaps, kept behind a size-bounded cache.
 *
 * Image entries carry their PNG inline as base64, so a list of them would
 * otherwise re-decode several megabytes on every recomposition and every
 * scroll. The cache is measured in bytes rather than entries because one
 * screenshot can outweigh twenty small images.
 */
object ImageCache {

    private val cache = object : LruCache<String, ImageBitmap>(BUDGET_BYTES) {
        override fun sizeOf(key: String, value: ImageBitmap): Int =
            value.width * value.height * 4
    }

    fun fromBase64(key: String, base64: String, maxDimension: Int): ImageBitmap? {
        val cacheKey = "$key@$maxDimension"
        cache.get(cacheKey)?.let { return it }
        val bytes = B64.decodeOrNull(base64) ?: return null
        val decoded = decode({ options -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }, maxDimension)
            ?: return null
        cache.put(cacheKey, decoded)
        return decoded
    }

    /**
     * Where [fromFile] runs for a list: a screenful of photos decodes two at
     * a time rather than all at once, so memory stays at a couple of decodes.
     */
    val fileDecoding: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(2)

    /** What [fromFile] has already decoded, without touching the disk - for a first frame with no flash. */
    fun cached(file: File, maxDimension: Int): ImageBitmap? = cache.get(fileKey(file, maxDimension))

    /**
     * An image file, at most [maxDimension] on its longer side and the right
     * way up: ImageDecoder rather than BitmapFactory, because a phone's photo
     * is usually stored sideways with an EXIF rotation, which only it
     * applies. Null for anything it can't decode. Blocking - off the main
     * thread.
     */
    fun fromFile(file: File, maxDimension: Int): ImageBitmap? {
        val cacheKey = fileKey(file, maxDimension)
        cache.get(cacheKey)?.let { return it }
        if (!file.exists()) return null
        val decoded = try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                val longest = maxOf(info.size.width, info.size.height)
                if (longest > maxDimension) {
                    // Decoded straight to this size - never whole first.
                    val scale = maxDimension.toDouble() / longest
                    decoder.setTargetSize(
                        (info.size.width * scale).toInt().coerceAtLeast(1),
                        (info.size.height * scale).toInt().coerceAtLeast(1),
                    )
                }
                // Heap memory, like every other bitmap here, so the budget
                // below is what it really costs.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }.asImageBitmap()
        } catch (e: Throwable) {
            // Not an image after all, a truncated one - or, as in decode(),
            // an OutOfMemoryError.
            null
        } ?: return null
        cache.put(cacheKey, decoded)
        return decoded
    }

    private fun fileKey(file: File, maxDimension: Int) = "${file.absolutePath}@$maxDimension"

    /**
     * Two passes: the first measures without allocating, the second decodes
     * subsampled. Decoding a full-resolution screenshot to draw it at thumbnail
     * size is the quickest way to an OutOfMemoryError in a list.
     */
    private fun decode(
        decoder: (BitmapFactory.Options) -> android.graphics.Bitmap?,
        maxDimension: Int,
    ): ImageBitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            decoder(bounds)
            val width = bounds.outWidth
            val height = bounds.outHeight
            if (width <= 0 || height <= 0) return null
            var sample = 1
            while (width / sample > maxDimension || height / sample > maxDimension) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            decoder(options)?.asImageBitmap()
        } catch (e: Throwable) {
            // OutOfMemoryError is an Error, not an Exception - a 40-megapixel
            // screenshot from a desktop peer is exactly the case that would
            // otherwise take the process down rather than show a placeholder.
            null
        }
    }

    private const val BUDGET_BYTES = 24 * 1024 * 1024
}

/**
 * The picture of an image file entry - a photo shared in from a phone, say -
 * once its bytes are here, at most [maxDimension] on its longer side and
 * decoded off the main thread. Null until then, and for a file that isn't an
 * image or doesn't decode: the caller shows its file card instead.
 */
@Composable
fun rememberFileThumbnail(item: SyncedItem, maxDimension: Int): ImageBitmap? {
    val file = item.file
    val name = item.filePayload?.fileName
    val thumbnail by produceState(file?.let { ImageCache.cached(it, maxDimension) }, file, maxDimension) {
        if (file == null) {
            value = null
            return@produceState
        }
        value = withContext(ImageCache.fileDecoding) {
            if (ImageFiles.looksLikeImage(name, file)) ImageCache.fromFile(file, maxDimension) else null
        }
    }
    return thumbnail
}
