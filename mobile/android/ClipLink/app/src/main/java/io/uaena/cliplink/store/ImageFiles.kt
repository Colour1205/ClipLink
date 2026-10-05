package io.uaena.cliplink.store

import java.io.File

/**
 * Which file entries are pictures - a photo shared in from a phone's
 * gallery, say, which arrives as a file rather than as an inline image and
 * still deserves a preview. By its name first, then by its first bytes for
 * one whose name says nothing ("1234", "file"). Only ever a guess: the
 * decode that follows is what really decides.
 */
object ImageFiles {

    private val EXTENSIONS = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp")

    /** The HEIF brands a phone's photo carries - "mif1" and "msf1" are the generic ones. */
    private val HEIF_BRANDS = setOf("heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1")

    /** The size a BMP's second header says it is, for every version of that header. */
    private val BMP_HEADER_SIZES = setOf(12, 40, 52, 56, 64, 108, 124)

    private const val HEADER_BYTES = 32

    fun isImageName(name: String?): Boolean =
        name != null && name.substringAfterLast('.', "").lowercase() in EXTENSIONS

    /** Whether [header] - a file's first bytes - starts like one of the formats [isImageName] knows. */
    fun isImageHeader(header: ByteArray): Boolean {
        fun ascii(offset: Int, text: String) = header.size >= offset + text.length &&
            text.indices.all { header[offset + it] == text[it].code.toByte() }

        fun byte(offset: Int) = header[offset].toInt() and 0xFF

        return when {
            header.size >= 8 && byte(0) == 0x89 && ascii(1, "PNG\r\n") && byte(6) == 0x1A && byte(7) == 0x0A -> true
            header.size >= 3 && byte(0) == 0xFF && byte(1) == 0xD8 && byte(2) == 0xFF -> true
            ascii(0, "GIF87a") || ascii(0, "GIF89a") -> true
            ascii(0, "RIFF") && ascii(8, "WEBP") -> true
            // "BM" alone starts plenty of text files; the size of the header
            // that follows it is one of a handful of values.
            ascii(0, "BM") && header.size >= 18 && byte(14) in BMP_HEADER_SIZES &&
                byte(15) == 0 && byte(16) == 0 && byte(17) == 0 -> true
            ascii(4, "ftyp") && header.size >= 12 &&
                String(header, 8, 4, Charsets.US_ASCII) in HEIF_BRANDS -> true
            else -> false
        }
    }

    /** [isImageName], else [isImageHeader] of [file]'s first bytes. Reads the disk - off the main thread. */
    fun looksLikeImage(name: String?, file: File): Boolean {
        if (isImageName(name)) return true
        val header = ByteArray(HEADER_BYTES)
        var read = 0
        try {
            file.inputStream().use { stream ->
                while (read < header.size) {
                    val n = stream.read(header, read, header.size - read)
                    if (n < 0) break
                    read += n
                }
            }
        } catch (e: Exception) {
            return false
        }
        return isImageHeader(header.copyOf(read))
    }
}
