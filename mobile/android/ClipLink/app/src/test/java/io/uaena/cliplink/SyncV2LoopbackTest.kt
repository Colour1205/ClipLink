package io.uaena.cliplink

import io.uaena.cliplink.net.Protocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Two devices, each the real SyncManager on real stores, joined by a pair of links that hand each other
 * what they send: a v2 pair moves only what the other lacks, and what was deleted stays deleted.
 */
class SyncV2LoopbackTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var scope: CoroutineScope
    private lateinit var alice: V2Peer
    private lateinit var bob: V2Peer

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        alice = V2Peer("alice", temp.root, scope)
        bob = V2Peer("bob", temp.root, scope)
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    /** Joins the two; the links are named for the device each one leads to. */
    private fun connect(protocolOfBob: Int = 2, protocolOfAlice: Int = 2): Pair<WireLink, WireLink> {
        val toBob = WireLink(bob.id, protocolOfBob)
        val toAlice = WireLink(alice.id, protocolOfAlice)
        toBob.other = toAlice
        toAlice.other = toBob
        alice.connectTo(toBob)
        bob.connectTo(toAlice)
        return toBob to toAlice
    }

    private val items = (1..5).map { entryOf("e$it", it, "alice") }

    @Test
    fun `a v2 pair moves only the items the other device lacks`() {
        // Bob has the two oldest already.
        alice.history.addAll(items)
        bob.history.addAll(items.take(2))

        val (toBob, toAlice) = connect()
        eventually("bob has everything") { bob.history.all().size == 5 }
        Thread.sleep(300)

        // What alice sent: a head, and then exactly the three bob lacked - the newest alone, then the rest.
        assertEquals(listOf(Protocol.TYPE_HISTORY_HEAD), toBob.sent.map(Wire::type).filter { it != Protocol.TYPE_HISTORY_BATCH })
        assertEquals(listOf(listOf("e5"), listOf("e4", "e3")), toBob.sentOfType(Protocol.TYPE_HISTORY_BATCH).map(Wire::contentsOf))
        // Bob asked for nothing alice lacked: no history_request from alice, and no batch from bob.
        assertTrue(toAlice.sentOfType(Protocol.TYPE_HISTORY_REQUEST).size == 2)
        assertTrue(toBob.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())
        assertTrue(toAlice.sentOfType(Protocol.TYPE_HISTORY_BATCH).isEmpty())

        // The clipboard got the newest missing item, once; the stack is e5 in front of e4 and e3.
        assertEquals(listOf("e5"), bob.applied.map { it.content })
        assertTrue(alice.applied.isEmpty())
        assertEquals(listOf("e5", "e4", "e3", "e2", "e1"), bob.view())
        eventually("settled") { bob.tagOf(items[4])?.expectedSize == 0 }
        assertEquals(bob.tagOf(items[4])!!.id, bob.tagOf(items[2])!!.id)
        assertEquals(null, bob.tagOf(items[0]))
    }

    @Test
    fun `an item older than the device's own newest is the one that reaches the clipboard`() {
        val mine = entryOf("mine", 90, "bob")
        bob.history.addAll(listOf(mine))
        alice.history.addAll(items)
        connect()
        eventually("bob has everything") { bob.history.all().size == 6 }
        Thread.sleep(200)
        // Older than bob's own item, and still on top of the list and on the clipboard.
        assertEquals(listOf("e5"), bob.applied.map { it.content })
        assertEquals(listOf("e5", "e4", "e3", "e2", "e1", "mine"), bob.view())
        // Alice learns bob's one item the same way.
        eventually("alice has it") { alice.history.all().size == 6 }
        assertEquals(listOf("mine"), alice.applied.map { it.content })
    }

    @Test
    fun `devices that already have the same history exchange only heads`() {
        alice.history.addAll(items)
        bob.history.addAll(items)
        val (toBob, toAlice) = connect()
        eventually("both heads") { toBob.sent.isNotEmpty() && toAlice.sent.isNotEmpty() }
        Thread.sleep(300)
        assertEquals(listOf(Protocol.TYPE_HISTORY_HEAD), toBob.sent.map(Wire::type))
        assertEquals(listOf(Protocol.TYPE_HISTORY_HEAD), toAlice.sent.map(Wire::type))
        assertTrue(alice.applied.isEmpty() && bob.applied.isEmpty())
    }

    @Test
    fun `a delete on one device deletes the item on the other and it does not return`() {
        alice.history.addAll(items)
        bob.history.addAll(items)
        val (toBob, _) = connect()
        eventually("both heads") { toBob.sent.isNotEmpty() }
        Thread.sleep(200)

        alice.sync.deleteEntry(items[3])

        eventually("bob lost it") { bob.history.all().size == 4 }
        assertFalse(bob.contents().contains("e4"))
        assertTrue(bob.tomb.contains(items[3].dk))
        assertTrue(bob.applied.isEmpty())
        // Bob does not tell alice back.
        assertEquals(1, toBob.sentOfType(Protocol.TYPE_DELETE).size)

        // Reconnecting changes nothing: heads carry the tombstones, nothing is asked for.
        toBob.close("reconnect")
        val (again, backAgain) = connect()
        eventually("heads") { again.sent.isNotEmpty() && backAgain.sent.isNotEmpty() }
        Thread.sleep(300)
        assertTrue(again.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())
        assertTrue(backAgain.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())
        assertEquals(4, alice.history.all().size)
        assertEquals(4, bob.history.all().size)
    }

    @Test
    fun `a delete made while the other device was away reaches it in its next head`() {
        alice.history.addAll(items)
        bob.history.addAll(items)
        alice.sync.deleteEntry(items[1])
        alice.sync.deleteEntry(items[4])

        val (_, toAlice) = connect()
        eventually("bob dropped both") { bob.history.all().size == 3 }
        Thread.sleep(200)
        assertEquals(setOf("e1", "e3", "e4"), bob.contents())
        assertTrue(bob.applied.isEmpty())
        assertTrue(toAlice.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())
    }

    @Test
    fun `clearing the history on one device clears the other`() {
        alice.history.addAll(items)
        bob.history.addAll(items)
        val (toBob, _) = connect()
        eventually("heads") { toBob.sent.isNotEmpty() }
        Thread.sleep(200)

        alice.sync.clearHistory()

        eventually("bob cleared") { bob.history.all().isEmpty() }
        assertEquals(items.map { it.dk }.toSet(), items.filter { bob.tomb.contains(it.dk) }.map { it.dk }.toSet())
    }

    @Test
    fun `a v2 device with an older one gets the old behavior both ways`() {
        alice.history.addAll(items)
        // Bob is an older build: its link says protocol 1 to alice, alice's says 1 to bob.
        val (toBob, toAlice) = connect(protocolOfBob = 1, protocolOfAlice = 1)
        eventually("bob has everything") { bob.history.all().size == 5 }
        Thread.sleep(200)

        assertEquals(
            listOf(Protocol.TYPE_HISTORY_HEAD, Protocol.TYPE_HISTORY_BATCH),
            toBob.sent.map(Wire::type),
        )
        assertEquals(5, Wire.contentsOf(toBob.sentOfType(Protocol.TYPE_HISTORY_BATCH).single()).size)
        assertEquals(listOf("e5"), bob.applied.map { it.content })
        assertTrue(toBob.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())
        assertTrue(toAlice.sentOfType(Protocol.TYPE_HISTORY_REQUEST).isEmpty())

        // A delete is not sent to it.
        alice.sync.deleteEntry(items[0])
        Thread.sleep(200)
        assertTrue(toBob.sentOfType(Protocol.TYPE_DELETE).isEmpty())
        assertEquals(5, bob.history.all().size)
    }
}
