package io.uaena.cliplink

import io.uaena.cliplink.ui.DeleteWording
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The delete dialogs tell the truth now that a delete reaches the paired devices. */
class DeleteWordingTest {

    private val all = listOf(DeleteWording.ITEM_BODY, DeleteWording.CLEAR_ROW, DeleteWording.CLEAR_BODY)

    @Test
    fun `every text says the paired devices lose the item too`() {
        all.forEach { assertTrue(it, it.contains("paired devices")) }
    }

    @Test
    fun `no text says the other devices keep their copies`() {
        all.forEach {
            assertFalse(it, it.contains("They keep", ignoreCase = true))
            assertFalse(it, it.contains("keep theirs", ignoreCase = true))
            assertFalse(it, it.contains("other devices", ignoreCase = true))
        }
    }

    @Test
    fun `the dialogs say that an older ClipLink keeps its copy`() {
        assertTrue(DeleteWording.ITEM_BODY.contains("older ClipLink"))
        assertTrue(DeleteWording.CLEAR_BODY.contains("older ClipLink"))
    }
}
