package io.uaena.cliplink

import io.uaena.cliplink.core.LineReader
import io.uaena.cliplink.core.jsonNestsDeeperThan
import io.uaena.cliplink.core.untrusted
import io.uaena.cliplink.net.ConnectionGate
import io.uaena.cliplink.net.Envelope
import io.uaena.cliplink.net.FileChunkMessage
import io.uaena.cliplink.net.FilePayload
import io.uaena.cliplink.net.FileRequestMessage
import io.uaena.cliplink.net.HandshakeMessage
import io.uaena.cliplink.net.Limits
import io.uaena.cliplink.net.Liveness
import io.uaena.cliplink.net.PairingInfo
import io.uaena.cliplink.net.PeerConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.SocketTimeoutException

/**
 * What a stranger on port 49000 can and can't do with the first line they
 * send, before anything is trusted: no unbounded line, no document that
 * overflows the parser's stack, and no Error getting out to kill the app.
 */
class PeerFramingTest {

    private fun lineReader(text: String) = LineReader(ByteArrayInputStream(text.toByteArray(Charsets.UTF_8)))

    /** `{"a":{"a":{"a":...1...}}}` - [depth] levels deep. */
    private fun nested(depth: Int): String = "{\"a\":".repeat(depth) + "1" + "}".repeat(depth)

    private val realHandshake = """{"EphemeralPublicKey":"${"E".repeat(124)}","IdentityPublicKey":"${"I".repeat(124)}",""" +
        """"Signature":"${"S".repeat(88)}","PassphraseProof":"${"P".repeat(44)}","DeviceName":"Colour's Laptop"}"""

    // ---- the handshake line -------------------------------------------------

    @Test
    fun `a real handshake is far under the cap and reads`() {
        assertTrue(realHandshake.length < 1500)
        val handshake = PeerConnection.readHandshake(lineReader(realHandshake + "\r\n"))
        assertNotNull(handshake)
        assertEquals("Colour's Laptop", handshake!!.deviceName)
    }

    @Test
    fun `a handshake line over the cap is refused without being parsed`() {
        // The ~25 KB of nesting that overflowed org.json's stack in a review.
        val hostile = nested(5000)
        assertTrue(hostile.length > 25_000)
        assertTrue(hostile.length > Limits.MAX_HANDSHAKE_BYTES)
        assertNull(PeerConnection.readHandshake(lineReader(hostile + "\n")))
    }

    @Test
    fun `endless data with no newline gets no handshake`() {
        assertNull(PeerConnection.readHandshake(lineReader("{".repeat(1_000_000))))
    }

    @Test
    fun `an empty or missing handshake is nothing`() {
        assertNull(PeerConnection.readHandshake(lineReader("")))
        assertNull(PeerConnection.readHandshake(lineReader("\n")))
        assertNull(PeerConnection.readHandshake(lineReader("not json\n")))
    }

    @Test
    fun `a peer that drips its handshake out is stopped by the deadline`() {
        // One byte per read: the slowest sender there is.
        val reader = LineReader(ByteArrayInputStream((realHandshake + "\n").toByteArray(Charsets.UTF_8)), bufferSize = 1)
        var now = 0L
        val deadline = 10_000L
        reader.beforeRead = {
            now += 4_000 // each byte takes four seconds to arrive
            if (now > deadline) throw SocketTimeoutException("handshake took too long")
        }
        try {
            PeerConnection.readHandshake(reader)
            fail("the slow handshake should have timed out")
        } catch (e: SocketTimeoutException) {
            // create() turns this into a refused handshake and closes the socket
        }
    }

    // ---- hostile documents never throw ---------------------------------------

    @Test
    fun `a handshake nested a few levels deep is refused before org json recurses`() {
        assertNull(HandshakeMessage.parse(nested(50)))
        assertNull(HandshakeMessage.parse(nested(100_000)))
        // Still a handshake when it merely holds a short string with brackets in it.
        val bracketed = """{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"{{{{{{{{{{{{{{"}"""
        assertNotNull(HandshakeMessage.parse(bracketed))
    }

    @Test
    fun `parsers catch a stack overflow instead of letting it kill the process`() {
        val tooDeep = nested(200_000)
        // These go through org.json, which recurses: a StackOverflowError on
        // the test JVM's stack, caught and turned into "not a message".
        assertNull(Envelope.parse(tooDeep))
        assertNull(FilePayload.parse(tooDeep))
        assertNull(FileChunkMessage.parse(tooDeep))
        assertNull(FileRequestMessage.parse(tooDeep))
        assertNull(PairingInfo.parse(tooDeep))
        assertNull(untrusted<String> { throw StackOverflowError() })
        assertNull(untrusted<String> { throw OutOfMemoryError() })
    }

    @Test
    fun `untrusted still lets a cancellation through`() {
        try {
            untrusted<String> { throw kotlinx.coroutines.CancellationException("cancelled") }
            fail("a cancellation must propagate")
        } catch (e: kotlinx.coroutines.CancellationException) {
            // right
        }
    }

    @Test
    fun `nesting is counted outside strings only`() {
        assertFalse(jsonNestsDeeperThan("""{"a":[1,{"b":2}]}""", 3))
        assertTrue(jsonNestsDeeperThan("""{"a":[1,{"b":2}]}""", 2))
        // Brackets and escaped quotes inside a string are text.
        assertFalse(jsonNestsDeeperThan("""{"a":"[[[[[[[[[[ \" {{{{{{{{{{"}""", 1))
        assertTrue(jsonNestsDeeperThan(nested(10), 9))
        assertFalse(jsonNestsDeeperThan(nested(10), 10))
    }

    // ---- liveness: the dead-peer check ----------------------------------------

    private class FakeClock(var now: Long = 1_000_000L) {
        fun advance(ms: Long) {
            now += ms
        }
    }

    private val timeout = 9_000L
    private val grace = 120_000L

    @Test
    fun `a peer silent past the timeout is dead and any bytes bring it back`() {
        val clock = FakeClock()
        val liveness = Liveness(clock = { clock.now })
        clock.advance(timeout)
        assertFalse(liveness.isDead(timeout, grace)) // exactly at the limit is not past it
        clock.advance(1)
        assertTrue(liveness.isDead(timeout, grace))
        // Bytes - not whole messages: the read loop reports them as they come.
        liveness.heard()
        assertFalse(liveness.isDead(timeout, grace))
    }

    @Test
    fun `a read loop waiting on its handler doesn't count the peer's silence`() {
        val clock = FakeClock()
        val liveness = Liveness(clock = { clock.now })
        // The handler is hashing a big file, and the inbox is full: nothing is
        // being read, so a peer that is perfectly alive looks silent.
        liveness.readerBlocked()
        clock.advance(60_000)
        assertFalse(liveness.isDead(timeout, grace))
        // It resumes: silence counts from now, not from before the wait.
        liveness.readerResumed()
        assertFalse(liveness.isDead(timeout, grace))
        clock.advance(timeout + 1)
        assertTrue(liveness.isDead(timeout, grace))
    }

    @Test
    fun `a handler that never comes back can't hide a dead peer for ever`() {
        val clock = FakeClock()
        val liveness = Liveness(clock = { clock.now })
        liveness.readerBlocked()
        clock.advance(grace)
        assertFalse(liveness.isDead(timeout, grace))
        clock.advance(1)
        assertTrue(liveness.isDead(timeout, grace))
    }

    // ---- the gate in front of the handshake -----------------------------------

    @Test
    fun `only a few unauthenticated handshakes run at once`() {
        val clock = FakeClock()
        val gate = ConnectionGate(maxPending = 3, perSourceLimit = 100, clock = { clock.now })
        assertTrue(gate.tryEnter("10.0.0.1"))
        assertTrue(gate.tryEnter("10.0.0.2"))
        assertTrue(gate.tryEnter("10.0.0.3"))
        // The rest are dropped on the spot...
        assertFalse(gate.tryEnter("10.0.0.4"))
        assertEquals(3, gate.pendingCount)
        // ...until one finishes.
        gate.leave()
        assertTrue(gate.tryEnter("10.0.0.4"))
    }

    @Test
    fun `one address can't open connections faster than the limit`() {
        val clock = FakeClock()
        val gate = ConnectionGate(maxPending = 100, perSourceLimit = 3, windowMs = 10_000, clock = { clock.now })
        repeat(3) { assertTrue(gate.tryEnter("10.0.0.9")); gate.leave() }
        assertFalse(gate.tryEnter("10.0.0.9"))
        // Another address is unaffected.
        assertTrue(gate.tryEnter("10.0.0.10"))
        gate.leave()
        // The window passes.
        clock.advance(10_001)
        assertTrue(gate.tryEnter("10.0.0.9"))
    }

    @Test
    fun `forged source addresses can't grow the gate without bound`() {
        val clock = FakeClock()
        val gate = ConnectionGate(maxPending = 1_000_000, perSourceLimit = 5, maxSources = 100, clock = { clock.now })
        repeat(10_000) { i ->
            assertTrue(gate.tryEnter("198.51.${i / 250}.${i % 250}"))
            gate.leave()
        }
        // The map of sources was cut back along the way (it isn't exposed, but
        // this finished), and a stranger is still let in afterwards.
        assertTrue(gate.tryEnter("203.0.113.1"))
    }
}
