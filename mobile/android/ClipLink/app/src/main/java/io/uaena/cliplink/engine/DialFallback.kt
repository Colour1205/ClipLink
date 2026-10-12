package io.uaena.cliplink.engine

/**
 * Trusting a device is one-sided: it only decides whether THIS device accepts it. To keep two
 * devices that hear each other from opening two connections, only one of them dials - the one
 * whose key sorts after the other's. When both trust each other that is fine. But when only one
 * does - the user just tapped Trust here, and the other device has not been asked yet - and
 * the other's key is the larger, nobody dials: the other never trusts this device, so it does not
 * dial, and this one waits for it to. The pairing request never reaches the other device.
 *
 * So a trusted device that should have dialled this one, but has not connected after a few
 * seconds, is dialled by this one after all (and again every half minute while it stays
 * unconnected). If it does trust this device it has long since connected and this never fires; if
 * it does not, the dial is what raises the pairing request there. The same rule is in every
 * platform's engine: change them together.
 */
class DialFallback(private val now: () -> Long = System::currentTimeMillis) {

    private val since = HashMap<String, Long>()
    private val lastDial = HashMap<String, Long>()

    /**
     * True when a trusted device that should have dialled this one has waited long
     * enough, and was not dialled in the last [EVERY_MS]. Counts the call as the dial.
     */
    @Synchronized
    fun due(id: String): Boolean {
        val t = now()
        val first = since.getOrPut(id) { t }
        if (t - first < WAIT_MS) return false
        val last = lastDial[id]
        if (last != null && t - last < EVERY_MS) return false
        lastDial[id] = t
        return true
    }

    /** It is connected (or gone): start counting again next time. */
    @Synchronized
    fun connected(id: String) {
        since.remove(id)
        lastDial.remove(id)
    }

    companion object {
        /** How long a trusted device that should dial this one is given to do so. */
        const val WAIT_MS = 8_000L

        /** How often it is dialled after that while it stays unconnected. */
        const val EVERY_MS = 30_000L
    }
}
