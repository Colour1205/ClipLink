package io.uaena.cliplink.ui

import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
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
 * Decoded bitmaps, kept behind size-bounded caches.
 *
 * Image entries carry their PNG inline as base64, so a list of them would
 * otherwise re-decode several megabytes on every recomposition and every
 * scroll. The caches are measured in bytes rather than entries because one
 * screenshot can outweigh twenty small images.
 *
 * EVERY DECODE HERE IS BLOCKING and belongs off the main thread: callers go
 * through [rememberInlineImage] / [rememberFileThumbnail], which run them on
 * [decoding]. (A base64 decode of several megabytes plus two BitmapFactory
 * passes per card, run during composition, froze the list on every scroll.)
 *
 * Two caches, so that opening one picture full size - up to a 23 MB bitmap -
 * cannot evict every thumbnail in the list: coming back from the detail view
 * used to re-decode all of them.
 */
object ImageCache {

    private val thumbnails = bitmapCache(THUMBNAIL_BUDGET_BYTES)
    private val detail = bitmapCache(DETAIL_BUDGET_BYTES)

    /**
     * What definitely did not decode - not an image after all, or truncated -
     * so that a card scrolling into view again doesn't decode it again to
     * find out the same. An out-of-memory failure is NOT recorded: that one
     * may well work later.
     */
    private val failures = LruCache<String, Boolean>(MAX_REMEMBERED_FAILURES)

    private fun cacheFor(maxDimension: Int) = if (maxDimension > THUMBNAIL_MAX_EDGE) detail else thumbnails

    private fun bitmapCache(budget: Int) = object : LruCache<String, ImageBitmap>(budget) {
        override fun sizeOf(key: String, value: ImageBitmap): Int = value.width * value.height * 4
    }

    /**
     * Where decodes run for a list: a screenful of pictures decodes two at a
     * time rather than all at once, so memory stays at a couple of decodes.
     */
    val decoding: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(2)

    /** What [fromBase64] has already decoded, without decoding anything - for a first frame with no flash. */
    fun cachedBase64(key: String, maxDimension: Int): ImageBitmap? =
        cacheFor(maxDimension).get(base64Key(key, maxDimension))

    /** An inline image, at most [maxDimension] on its longer side. Null if it won't decode. Blocking. */
    fun fromBase64(key: String, base64: String, maxDimension: Int): ImageBitmap? {
        val cacheKey = base64Key(key, maxDimension)
        val cache = cacheFor(maxDimension)
        cache.get(cacheKey)?.let { return it }
        if (failures.get(cacheKey) != null) return null
        val decoded = try {
            B64.decodeOrNull(base64)?.let { bytes ->
                decode({ options -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }, maxDimension)
            }
        } catch (e: OutOfMemoryError) {
            // A 40-megapixel screenshot from a desktop peer is exactly what
            // would otherwise take the process down rather than show a
            // placeholder. Not remembered: memory may be there next time.
            return null
        }
        if (decoded == null) {
            failures.put(cacheKey, true)
            return null
        }
        cache.put(cacheKey, decoded)
        return decoded
    }

    /** What [fromFile] has already decoded, without touching the disk - for a first frame with no flash. */
    fun cached(file: File, maxDimension: Int): ImageBitmap? = cacheFor(maxDimension).get(fileKey(file, maxDimension))

    /**
     * An image file, at most [maxDimension] on its longer side and the right
     * way up: ImageDecoder rather than BitmapFactory, because a phone's photo
     * is usually stored sideways with an EXIF rotation, which only it
     * applies. Null for anything it can't decode. Blocking - off the main
     * thread.
     */
    fun fromFile(file: File, maxDimension: Int): ImageBitmap? {
        val cacheKey = fileKey(file, maxDimension)
        val cache = cacheFor(maxDimension)
        cache.get(cacheKey)?.let { return it }
        if (failures.get(cacheKey) != null) return null
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
        } catch (e: OutOfMemoryError) {
            return null // transient - see [failures]
        } catch (e: Exception) {
            // Not an image after all, or a truncated one.
            failures.put(cacheKey, true)
            return null
        }
        cache.put(cacheKey, decoded)
        return decoded
    }

    private fun base64Key(key: String, maxDimension: Int) = "$key@$maxDimension"

    private fun fileKey(file: File, maxDimension: Int) = "${file.absolutePath}@$maxDimension"

    /**
     * Two passes: the first measures without allocating, the second decodes
     * subsampled. Decoding a full-resolution screenshot to draw it at thumbnail
     * size is the quickest way to an OutOfMemoryError in a list - which is
     * left to the caller to catch, as it isn't a verdict on the image.
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
        } catch (e: Exception) {
            null
        }
    }

    /** Past this, a decode is for the full-size view and goes in its own cache. */
    private const val THUMBNAIL_MAX_EDGE = 1024
    private const val THUMBNAIL_BUDGET_BYTES = 24 * 1024 * 1024

    /** Room for the biggest single decode (2400 px square, ~23 MB) - and no other picture to lose. */
    private const val DETAIL_BUDGET_BYTES = 26 * 1024 * 1024
    private const val MAX_REMEMBERED_FAILURES = 256
}

/** Where an image that is being decoded off the main thread has got to. */
@Immutable
sealed interface ImageState {
    data object Loading : ImageState
    data object Failed : ImageState
    data class Ready(val bitmap: ImageBitmap) : ImageState
}

/**
 * An inline image entry's picture, at most [maxDimension] on its longer side,
 * decoded off the main thread - [ImageState.Loading] until it is. Cached
 * under [key] (the item's unique list key, see [keyedItems]), and a picture
 * that doesn't decode stays [ImageState.Failed] without decoding again.
 */
@Composable
fun rememberInlineImage(key: String, base64: String, maxDimension: Int): ImageState {
    val state by produceState<ImageState>(initialValue = inlineImageStateOf(key, maxDimension), key, maxDimension) {
        value = inlineImageStateOf(key, maxDimension)
        if (value is ImageState.Ready) return@produceState
        val decoded = withContext(ImageCache.decoding) { ImageCache.fromBase64(key, base64, maxDimension) }
        value = if (decoded != null) ImageState.Ready(decoded) else ImageState.Failed
    }
    return state
}

private fun inlineImageStateOf(key: String, maxDimension: Int): ImageState =
    ImageCache.cachedBase64(key, maxDimension)?.let { ImageState.Ready(it) } ?: ImageState.Loading

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
        value = ImageCache.cached(file, maxDimension)
        if (value != null) return@produceState
        value = withContext(ImageCache.decoding) {
            if (ImageFiles.looksLikeImage(name, file)) ImageCache.fromFile(file, maxDimension) else null
        }
    }
    return thumbnail
}
