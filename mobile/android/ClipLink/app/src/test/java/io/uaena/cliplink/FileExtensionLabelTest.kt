package io.uaena.cliplink

import io.uaena.cliplink.ui.fileExtensionLabel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The kind a file card's footer shows at its far end - the same rule on every phone app. */
class FileExtensionLabelTest {

    @Test
    fun `the extension is upper-case and without the dot`() {
        assertEquals("PDF", fileExtensionLabel("report.pdf"))
        assertEquals("JPG", fileExtensionLabel("IMG_0042.jpg"))
        assertEquals("M3U", fileExtensionLabel("Road Trip.m3u"))
        // Only the last one counts.
        assertEquals("GZ", fileExtensionLabel("backup.tar.gz"))
    }

    @Test
    fun `eight characters is the longest that counts as a kind`() {
        assertEquals("TORRENTS", fileExtensionLabel("set.torrents"))
        assertNull(fileExtensionLabel("notes.withaname"))
    }

    @Test
    fun `only letters and digits count as a kind`() {
        assertNull(fileExtensionLabel("v1.2 beta"))
        assertNull(fileExtensionLabel("photo.jp-g"))
        // A name that is all extension still has one.
        assertEquals("BASHRC", fileExtensionLabel(".bashrc"))
    }

    @Test
    fun `no name or no extension shows nothing`() {
        assertNull(fileExtensionLabel(null))
        assertNull(fileExtensionLabel(""))
        assertNull(fileExtensionLabel("README"))
        assertNull(fileExtensionLabel("draft."))
    }
}
