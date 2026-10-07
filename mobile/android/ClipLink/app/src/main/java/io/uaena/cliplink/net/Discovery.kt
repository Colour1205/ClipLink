package io.uaena.cliplink.net

import io.uaena.cliplink.core.Ipv4
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.util.Base64

/**
 * LAN peer discovery. Mirrors Discovery.cs and Discovery.ets exactly: same
 * port, same 2-second cadence, same beacon format
 * `{tcpPort}:{deviceId}:{proof}:{address}:{pairing}:{name}` with "-" for an
 * absent field. Device IDs and names are base64, which never contains ":", so
 * splitting on it is safe.
 */
class Discovery {

    data class Beacon(
        val tcpPort: Int,
        val deviceId: String,
        val proof: String?,
        val address: String?,
        /** True only while the sender's own pairing screen is open. */
        val pairing: Boolean,
        /** The sender's display name - null from older builds, or when it didn't decode. */
        val name: String?,
        val senderIp: String,
    )

    private var socket: DatagramSocket? = null
    private var scope: CoroutineScope? = null

    var onPeer: ((Beacon) -> Unit)? = null
    var onError: ((String, Throwable) -> Unit)? = null

    val isRunning: Boolean get() = socket?.isClosed == false

    /**
     * [proof], [ownAddress], [pairingOpen] and [ownName] are read fresh on
     * every beacon, not captured once. Each can change while running - a
     * passcode set later, a Tailscale IP typed in, the pairing screen
     * opening, the device renamed - and must take effect without a restart.
     */
    suspend fun start(
        deviceId: String,
        tcpPort: Int,
        proof: () -> String?,
        ownAddress: () -> String?,
        pairingOpen: () -> Boolean,
        ownName: () -> String?,
    ) = withContext(Dispatchers.IO) {
        stop()

        val udp = DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            bind(InetSocketAddress("0.0.0.0", Protocol.UDP_PORT))
        }
        socket = udp
        // An unexpected throw in either loop is reported, not fatal: the loops
        // catch what they expect, and this is for what they don't.
        val discoveryScope = CoroutineScope(
            SupervisorJob() + Dispatchers.IO +
                CoroutineExceptionHandler { _, error -> onError?.invoke("loop", error) },
        )
        scope = discoveryScope

        discoveryScope.launch { receiveLoop(udp) }
        discoveryScope.launch { sendLoop(udp, deviceId, tcpPort, proof, ownAddress, pairingOpen, ownName) }
    }

    private suspend fun receiveLoop(udp: DatagramSocket) {
        val buffer = ByteArray(2048)
        while (currentCoroutineContext().isActive) {
            try {
                val packet = DatagramPacket(buffer, buffer.size)
                udp.receive(packet)
                val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                parse(text, packet.address?.hostAddress ?: "")?.let { onPeer?.invoke(it) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (udp.isClosed) return
                // A transient receive error must not kill discovery for the
                // rest of the session. That exact failure mode - one throw,
                // socket never restarted, sync silently dead with nothing in
                // the log - is what the HarmonyOS port had to be fixed for.
                onError?.invoke("receive", e)
                delay(500)
            }
        }
    }

    private suspend fun sendLoop(
        udp: DatagramSocket,
        deviceId: String,
        tcpPort: Int,
        proof: () -> String?,
        ownAddress: () -> String?,
        pairingOpen: () -> Boolean,
        ownName: () -> String?,
    ) {
        val broadcast = InetAddress.getByName(BROADCAST_ADDRESS)
        var alreadyReported = false
        while (currentCoroutineContext().isActive) {
            try {
                val message = build(tcpPort, deviceId, proof(), ownAddress(), pairingOpen(), ownName())
                val bytes = message.toByteArray(Charsets.UTF_8)
                udp.send(DatagramPacket(bytes, bytes.size, broadcast, Protocol.UDP_PORT))
                alreadyReported = false
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (udp.isClosed) return
                // On targetSdk 37 an EPERM here almost always means
                // ACCESS_LOCAL_NETWORK was denied, not that the network is
                // down. Reported once per failure streak so the log doesn't
                // fill with one line every two seconds.
                if (!alreadyReported) {
                    alreadyReported = true
                    onError?.invoke("send", e)
                }
            }
            delay(SEND_INTERVAL_MS)
        }
    }

    /**
     * Fully awaits the socket close AND the loops' cancellation. A caller
     * that stops and immediately restarts (which is what foregrounding does)
     * would otherwise race the release and get EADDRINUSE binding the same
     * fixed port again - and a failed rebind means no peer is discovered for
     * the rest of the session.
     */
    suspend fun stop() {
        val runningScope = scope
        scope = null
        val udp = socket
        socket = null
        udp?.close() // unblocks the receive() the loop is parked in
        runningScope?.coroutineContext?.get(Job)?.cancelAndJoin()
    }

    companion object {
        private const val BROADCAST_ADDRESS = "255.255.255.255"
        private const val SEND_INTERVAL_MS = 2000L

        /** Longest a device id, a proof and an address may be in a beacon - the real ones are 124, 44 and 15 characters. */
        const val MAX_ID_LENGTH = 256
        const val MAX_PROOF_LENGTH = 128
        const val MAX_ADDRESS_LENGTH = 64

        /**
         * Always writes all six fields, the pairing one included even when
         * it's "-": the name is only findable because it is always at index 5.
         *
         * Every field is made safe for the format first: a ':' in any of them
         * would shift every field after it, and every receiver would then
         * read the pairing flag and the name from the wrong place. So none
         * may contain one (or whitespace or a control character), and each
         * has a cap. The address goes out only if it is an IPv4 address
         * ([Ipv4]) - anything else is "-" - and the name is base64, which has
         * no colon to begin with.
         */
        fun build(
            tcpPort: Int,
            deviceId: String,
            proof: String?,
            address: String?,
            pairing: Boolean,
            name: String?,
        ): String = buildString {
            append(tcpPort).append(':')
            append(field(deviceId, MAX_ID_LENGTH) ?: "-").append(':')
            append(field(proof, MAX_PROOF_LENGTH) ?: "-").append(':')
            append(Ipv4.normalize(address) ?: "-").append(':')
            append(if (pairing) "1" else "-").append(':')
            append(encodeName(name))
        }

        /** [value] with whatever would break a beacon field removed, cut to [max]; null when nothing is left. */
        private fun field(value: String?, max: Int): String? =
            value?.filter { it != ':' && !it.isWhitespace() && !it.isISOControl() }?.take(max)?.takeIf { it.isNotEmpty() }

        fun parse(text: String, senderIp: String): Beacon? {
            val parts = text.split(':')
            if (parts.size < 3) return null // malformed or older-format beacon
            val port = parts[0].toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            if (parts[1].isEmpty() || parts[1].length > MAX_ID_LENGTH) return null
            return Beacon(
                tcpPort = port,
                deviceId = parts[1],
                proof = parts[2].takeIf { it != "-" && it.isNotEmpty() && it.length <= MAX_PROOF_LENGTH },
                address = parts.getOrNull(3)?.takeIf { it != "-" && isPlausibleAddress(it) },
                pairing = parts.getOrNull(4) == "1",
                name = decodeName(parts.getOrNull(5)),
                senderIp = senderIp,
            )
        }

        /**
         * A beacon's address ends up dialled and stored for a trusted device,
         * and it came from anyone on the network. Whatever platform sent it,
         * it is an IPv4 address or, from a build that allows one, a host name:
         * letters, digits, '.', '-' and '_', and not long. (IPv6 can't be in a
         * colon-separated beacon at all.)
         */
        internal fun isPlausibleAddress(text: String): Boolean =
            text.isNotEmpty() && text.length <= MAX_ADDRESS_LENGTH &&
                text.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '.' || it == '-' || it == '_' }

        /**
         * Standard padded base64 of the UTF-8 name - a name can contain ":"
         * itself, and base64 can't. java.util.Base64 rather than B64 (which
         * wraps android.util.Base64) only so this stays testable on the plain
         * JVM; both write the identical padded standard alphabet.
         */
        fun encodeName(name: String?): String {
            val normalized = Protocol.normalizeDeviceName(name) ?: return "-"
            return Base64.getEncoder().encodeToString(normalized.toByteArray(Charsets.UTF_8))
        }

        /**
         * Null for "-", empty, bad base64 or bad UTF-8. A name is only ever a
         * label, so a field that doesn't decode costs the name, never the
         * beacon - dropping the beacon would drop the peer.
         */
        fun decodeName(field: String?): String? {
            val trimmed = field?.trim()
            if (trimmed.isNullOrEmpty() || trimmed == "-") return null
            return try {
                val bytes = Base64.getDecoder().decode(trimmed)
                // newDecoder() REPORTS malformed input instead of silently
                // substituting U+FFFD the way String(bytes, UTF_8) would.
                val text = Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
                Protocol.normalizeDeviceName(text)
            } catch (e: Exception) {
                null
            }
        }
    }
}
