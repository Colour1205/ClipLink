package io.uaena.cliplink

import io.uaena.cliplink.engine.DialFallback
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** When a trusted device that should have dialled this one is dialled from here instead. */
class DialFallbackTest {

    private var clock = 1_000L
    private val fallback = DialFallback { clock }

    @Test
    fun `a device is given time to dial first`() {
        assertFalse(fallback.due("A")) // first seen not connected
        clock += DialFallback.WAIT_MS - 1
        assertFalse(fallback.due("A"))
        clock += 1
        assertTrue(fallback.due("A"))
    }

    @Test
    fun `after a dial it is left alone for a while, then tried again`() {
        fallback.due("A")
        clock += DialFallback.WAIT_MS
        assertTrue(fallback.due("A"))
        clock += DialFallback.EVERY_MS - 1
        assertFalse(fallback.due("A"))
        clock += 1
        assertTrue(fallback.due("A"))
    }

    @Test
    fun `connecting starts the count again, and devices are counted separately`() {
        fallback.due("A")
        fallback.due("B")
        clock += DialFallback.WAIT_MS
        assertTrue(fallback.due("A"))
        fallback.connected("A") // it connected, then went away
        assertFalse(fallback.due("A")) // given time to dial first again
        assertTrue(fallback.due("B"))
    }
}
