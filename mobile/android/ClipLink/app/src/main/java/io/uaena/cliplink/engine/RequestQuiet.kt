package io.uaena.cliplink.engine

import io.uaena.cliplink.store.sameDeviceId

/**
 * Devices whose pairing requests are held back for a while.
 *
 * A device this one does not trust still gets here whenever the other end
 * trusts this one and dials it: the other end redials for as long as it keeps
 * its trust record, and each connection used to raise a new pairing request. So a
 * request that was ignored (or never answered), or a device that was removed,
 * came back again and again - the same device, a prompt every few minutes, for ever.
 *
 * The cure is in two parts. Removing a device (or tapping Ignore on its request)
 * sends it an "unpair" message, so the other end drops its trust record and stops
 * redialling (SyncManager.onUnpaired). And this: a device whose request was ignored
 * or expired, or that was removed, is quiet for a while - its connection is closed
 * without a prompt - which covers a peer that was offline when the message went, or
 * is a build that ignores it. A device that was removed is told again whenever it
 * connects while it is quiet. Blocking is the permanent version ([io.uaena.cliplink.store.BlockStore]).
 *
 * Lifted early by what asks for it: opening the pairing screen, pairing by address
 * or QR code, trusting the device. In memory only: a restart starts fresh. The same
 * rule is in every platform's engine (ClipLinkEngine.cs, Index.ets, SyncEngine.swift):
 * change them together.
 */
class RequestQuiet(
    private val now: () -> Long = System::currentTimeMillis,
    /** Whether two ids name the same device (a key can be spelt more than one way). */
    private val same: (String, String) -> Boolean = { a, b -> sameDeviceId(a, b) },
) {

    private class Entry(val id: String, val untilMs: Long, val removed: Boolean)

    private val entries = ArrayList<Entry>()

    /** [id] is quiet for [spanMs]; [removed] says why (removed, as against ignored). */
    @Synchronized
    fun quiet(id: String, spanMs: Long, removed: Boolean = false) {
        if (id.isEmpty()) return
        entries.removeAll { same(it.id, id) }
        entries.add(Entry(id, now() + spanMs, removed))
    }

    /** Whether [id] is quiet, and if so whether it was removed (as against ignored). */
    @Synchronized
    fun state(id: String): State {
        entries.removeAll { it.untilMs <= now() } // over
        val entry = entries.firstOrNull { same(it.id, id) } ?: return State.NotQuiet
        return if (entry.removed) State.Removed else State.Ignored
    }

    @Synchronized
    fun release(id: String) {
        entries.removeAll { same(it.id, id) }
    }

    @Synchronized
    fun clear() {
        entries.clear()
    }

    enum class State { NotQuiet, Ignored, Removed }

    companion object {
        /** After an ignored request, or one nobody answered. */
        const val AFTER_IGNORED_MS = 30L * 60 * 1000

        /** After the user removed the device: it is not coming back on its own. */
        const val AFTER_REMOVED_MS = 6L * 60 * 60 * 1000
    }
}
