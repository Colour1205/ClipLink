package io.uaena.cliplink.net

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
        val discoveryScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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
            } catch (e: Exception) {
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
            } catch (e: Exception) {
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

        /**
         * Always writes all six fields, the pairing one included even when
         * it's "-": the name is only findable because it is always at index 5.
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
            append(deviceId).append(':')
            append(proof ?: "-").append(':')
            append(address ?: "-").append(':')
            append(if (pairing) "1" else "-").append(':')
            append(encodeName(name))
        }

        fun parse(text: String, senderIp: String): Beacon? {
            val parts = text.split(':')
            if (parts.size < 3) return null // malformed or older-format beacon
            val port = parts[0].toIntOrNull() ?: return null
            if (parts[1].isEmpty()) return null
            return Beacon(
                tcpPort = port,
                deviceId = parts[1],
                proof = parts[2].takeIf { it != "-" && it.isNotEmpty() },
                address = parts.getOrNull(3)?.takeIf { it != "-" && it.isNotEmpty() },
                pairing = parts.getOrNull(4) == "1",
                name = decodeName(parts.getOrNull(5)),
                senderIp = senderIp,
            )
        }

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
