package io.uaena.cliplink

import io.uaena.cliplink.engine.RequestQuiet
import org.junit.Assert.assertEquals
import org.junit.Test

/** Which devices' pairing requests are held back, for how long, and what lifts it. */
class RequestQuietTest {

    private var clock = 1_000L
    private val quiet = RequestQuiet(now = { clock }, same = { a, b -> a == b })

    @Test
    fun `an unknown device is not quiet`() {
        assertEquals(RequestQuiet.State.NotQuiet, quiet.state("A"))
    }

    @Test
    fun `an ignored device is quiet for a while, then not`() {
        quiet.quiet("A", RequestQuiet.AFTER_IGNORED_MS)
        assertEquals(RequestQuiet.State.Ignored, quiet.state("A"))
        assertEquals(RequestQuiet.State.NotQuiet, quiet.state("B"))
        clock += RequestQuiet.AFTER_IGNORED_MS - 1
        assertEquals(RequestQuiet.State.Ignored, quiet.state("A"))
        clock += 1
        assertEquals(RequestQuiet.State.NotQuiet, quiet.state("A"))
    }

    @Test
    fun `a removed device is quiet longer, and says it was removed`() {
        quiet.quiet("A", RequestQuiet.AFTER_REMOVED_MS, removed = true)
        clock += RequestQuiet.AFTER_IGNORED_MS + 1
        assertEquals(RequestQuiet.State.Removed, quiet.state("A"))
        clock += RequestQuiet.AFTER_REMOVED_MS
        assertEquals(RequestQuiet.State.NotQuiet, quiet.state("A"))
    }

    @Test
    fun `a later reason replaces the earlier one`() {
        quiet.quiet("A", RequestQuiet.AFTER_IGNORED_MS)
        quiet.quiet("A", RequestQuiet.AFTER_REMOVED_MS, removed = true)
        assertEquals(RequestQuiet.State.Removed, quiet.state("A"))
    }

    @Test
    fun `release lifts one device, clear lifts all`() {
        quiet.quiet("A", RequestQuiet.AFTER_IGNORED_MS)
        quiet.quiet("B", RequestQuiet.AFTER_IGNORED_MS)
        quiet.release("A")
        assertEquals(RequestQuiet.State.NotQuiet, quiet.state("A"))
        assertEquals(RequestQuiet.State.Ignored, quiet.state("B"))
        quiet.clear()
        assertEquals(RequestQuiet.State.NotQuiet, quiet.state("B"))
    }
}
