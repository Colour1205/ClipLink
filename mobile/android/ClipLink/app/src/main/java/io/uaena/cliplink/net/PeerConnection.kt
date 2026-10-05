package io.uaena.cliplink.net

import io.uaena.cliplink.core.AesGcm
import io.uaena.cliplink.core.B64
import io.uaena.cliplink.core.DeviceIdentity
import io.uaena.cliplink.core.toHex
import io.uaena.cliplink.store.PassphraseKeyStore
import io.uaena.cliplink.store.TrustStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.Socket
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * One authenticated, encrypted link to a peer.
 *
 * The handshake is symmetric: both sides write their own handshake line
 * first, then read the other's. There is no client/server role, so the same
 * code path runs whether this device dialled out or was dialled.
 *
 * Framing is newline-delimited UTF-8 for the whole connection's life,
 * handshake and session alike. The Windows daemon writes `\r\n` and the other
 * two write `\n`; every reader tolerates both.
 */
class PeerConnection private constructor(
    private val socket: Socket,
    private val reader: BufferedReader,
    private val writer: BufferedWriter,
    private val sessionKey: ByteArray,
    val peerDeviceId: String,
    /** What the peer's handshake says it's called - null from builds that don't send one. */
    val peerName: String?,
    /**
     * False means this peer was not in the trust store when the handshake
     * ran, and the connection exists only because pairing mode was open. The
     * caller MUST surface an explicit accept/reject prompt rather than hand
     * it to the sync manager like an ordinary trusted link.
     */
    val wasAlreadyTrusted: Boolean,
    /**
     * True only when trust was established by THIS handshake's passphrase
     * proof verifying - the caller's signal to actually persist trust.
     */
    val newlyTrustedViaPassphrase: Boolean,
) {

    private val writeLock = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lastActivityAt = AtomicLong(System.currentTimeMillis())
    private val closed = AtomicBoolean(false)
    private val disconnectFired = AtomicBoolean(false)
    private val sessionProven = AtomicBoolean(false)
    private val echoGuard = EchoGuard()

    var onMessage: ((String) -> Unit)? = null
    var onDisconnected: (() -> Unit)? = null

    /**
     * Fires once, on the read loop, the first time a line decrypts with the
     * session key - a message or a heartbeat - that isn't one of our own
     * coming back (see [EchoGuard]). Only that proves the peer holds the
     * identity it claimed: the handshake signature covers just the ephemeral
     * key, so a recorded handshake replays under any DeviceName, but a
     * replayer can never produce a line that decrypts. Keep it quick.
     */
    var onSessionProven: (() -> Unit)? = null

    /** Whether [onSessionProven] has fired - for a caller whose own setup may have lost the race. */
    val isSessionProven: Boolean get() = sessionProven.get()

    val remoteAddress: String? get() = socket.inetAddress?.hostAddress

    /**
     * A connection can die between the handshake returning and the caller
     * registering it - at which point onDisconnected was still null and will
     * never fire, leaving a dead link registered as live forever. Callers
     * check this after wiring their callbacks.
     */
    val isClosed: Boolean get() = closed.get()

    suspend fun send(message: String) = withContext(Dispatchers.IO) {
        val packed = AesGcm.encryptPacked(sessionKey, message)
        // Before the write, so its echo can't arrive ahead of it.
        if (!sessionProven.get()) echoGuard.sent(packed)
        writeLine(B64.encode(packed))
    }

    /**
     * Serialised because the heartbeat writes on its own schedule and can
     * otherwise interleave with a real message mid-stream. The Windows side
     * carries the identical lock for the identical reason.
     */
    private suspend fun writeLine(line: String) = writeLock.withLock {
        writer.write(line)
        writer.write("\n")
        writer.flush()
    }

    /** Starts the read loop and the heartbeat. A connection isn't live for either until this. */
    fun listen() {
        scope.launch { readLoop() }
        scope.launch { heartbeatLoop() }
    }

    private suspend fun readLoop() = withContext(Dispatchers.IO) {
        try {
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) continue
                // Decoded once, and checked as bytes: the decoder skips
                // whatever isn't base64, so one line has endless spellings.
                val packed = B64.decode(line)
                // Only this loop sets sessionProven, so it can't flip in between.
                if (!sessionProven.get() && echoGuard.isEcho(packed)) error("our own line came back")
                val decrypted = AesGcm.decryptPacked(sessionKey, packed)
                lastActivityAt.set(System.currentTimeMillis())
                // Before the ping check: a heartbeat proves the key just as well.
                if (sessionProven.compareAndSet(false, true)) {
                    echoGuard.clear()
                    onSessionProven?.invoke()
                }
                if (decrypted == PING_SENTINEL) continue // heartbeat, never real data
                onMessage?.invoke(decrypted)
            }
        } catch (e: Exception) {
            // Clean close, abrupt disconnect, or a corrupt/forged line that
            // failed to decrypt - or one of our own echoed back. All of them
            // end the connection, same as the single catch-all on the other
            // two platforms.
        } finally {
            finish()
        }
    }

    private suspend fun heartbeatLoop() {
        while (scope.coroutineContext.isActive) {
            delay(HEARTBEAT_INTERVAL_MS)
            if (closed.get()) return
            try {
                send(PING_SENTINEL)
            } catch (e: Exception) {
                // A dead write also surfaces via the read loop ending.
            }
            if (System.currentTimeMillis() - lastActivityAt.get() > HEARTBEAT_TIMEOUT_MS) {
                // Nothing at all for the timeout window: the peer is gone even
                // though TCP hasn't noticed. Closing here is what actually makes
                // the UI's connected count reflect reality in seconds rather than
                // whenever the OS eventually gives up, which can be hours -
                // Android exposes no per-socket keepalive interval either.
                close()
                return
            }
        }
    }

    fun close() = finish()

    /**
     * Idempotent and safe from either side of the race - the read loop's
     * `finally` and an explicit [close] routinely both land here. Firing
     * onDisconnected twice would make the sync manager evict a connection it
     * has already replaced, which is precisely the reconnect loop this
     * protocol had to be fixed for once already.
     */
    private fun finish() {
        if (!closed.getAndSet(true)) {
            try {
                socket.close()
            } catch (e: Exception) {
                // already closed - fine
            }
        }
        if (disconnectFired.getAndSet(true)) return
        scope.coroutineContext[Job]?.cancel()
        onDisconnected?.invoke()
    }

    companion object {
        private const val PING_SENTINEL = "__ping__"

        /**
         * Deliberately tighter than the Windows daemon's 5000/15000. What has
         * to hold is that EACH side pings faster than the OTHER side's
         * timeout, and both directions satisfy that: this pings every 3s
         * against the daemon's 15s timeout, the daemon pings every 5s against
         * this 9s timeout.
         */
        private const val HEARTBEAT_INTERVAL_MS = 3000L
        private const val HEARTBEAT_TIMEOUT_MS = 9000L

        private const val HANDSHAKE_TIMEOUT_MS = 10_000

        /**
         * Runs the handshake and returns a live connection, or null for any
         * failure at all - a malformed peer, a bad signature, or an untrusted
         * one that is neither pairing-eligible nor passphrase-verified. Never
         * throws, matching CreateAsync's contract on the Windows side.
         *
         * [pairingModeOpen] must be a live "I am at the pairing screen right
         * now" signal, not a setting. With it false, an untrusted peer is
         * refused before this even spends effort verifying their signature.
         * With it true, the handshake completes so the caller can show an
         * accept/reject prompt. A verifying passphrase proof is a second,
         * independent way in, exactly as the LAN beacon's passive auto-trust
         * already is.
         *
         * [ownName] is this device's display name as it should go out in the
         * handshake, or null to leave the field off.
         */
        suspend fun create(
            socket: Socket,
            identity: DeviceIdentity,
            trustStore: TrustStore,
            passphraseKeyStore: PassphraseKeyStore,
            pairingModeOpen: Boolean,
            ownName: String?,
        ): PeerConnection? = withContext(Dispatchers.IO) {
            val connection = try {
                handshake(socket, identity, trustStore, passphraseKeyStore, pairingModeOpen, ownName)
            } catch (e: Exception) {
                null
            }
            if (connection == null) {
                // Every failure path closes the socket here rather than
                // leaving it to each caller - a half-open socket per refused
                // handshake adds up fast when a stranger's beacon arrives
                // every two seconds.
                try {
                    socket.close()
                } catch (ignored: Exception) {
                    // already closed - fine
                }
            }
            connection
        }

        private fun handshake(
            socket: Socket,
            identity: DeviceIdentity,
            trustStore: TrustStore,
            passphraseKeyStore: PassphraseKeyStore,
            pairingModeOpen: Boolean,
            ownName: String?,
        ): PeerConnection? {
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.tcpNoDelay = true
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))

            val ephemeral = KeyPairGenerator.getInstance("EC").run {
                initialize(ECGenParameterSpec("secp256r1"))
                generateKeyPair()
            }
            val ephemeralPublicBytes = ephemeral.public.encoded
            val myIdentityPublicKey = identity.publicKeyBase64()
            val myKey = passphraseKeyStore.key()

            val mine = HandshakeMessage(
                ephemeralPublicKey = B64.encode(ephemeralPublicBytes),
                identityPublicKey = myIdentityPublicKey,
                signature = B64.encode(identity.sign(ephemeralPublicBytes)),
                passphraseProof = myKey?.let {
                    passphraseKeyStore.computeProof(it, myIdentityPublicKey)
                },
                deviceName = ownName,
            )
            writer.write(mine.toJson())
            writer.write("\n")
            writer.flush()

            val theirs = HandshakeMessage.parse(reader.readLine() ?: return null) ?: return null
            // Our own handshake sent back - never a real peer. Two of our own
            // connections cross-wired that way derive one key, so each would
            // take the other's lines as proof, out of sight of the per-link
            // EchoGuard - and our own passcode proof would even vouch for it.
            if (theirs.identityPublicKey == myIdentityPublicKey) return null
            // Our own key spelt some other way is still us. B64 skips
            // anything that isn't base64, so a space or a dot slipped into
            // our id gets past the text check above and still decodes to our
            // key - and verifies our signature. So compare the keys, as
            // Windows does.
            if (DeviceIdentity.isSameKey(theirs.identityPublicKey, myIdentityPublicKey)) return null

            val alreadyTrusted = trustStore.isTrusted(theirs.identityPublicKey)
            val passphraseVerified = !alreadyTrusted && myKey != null &&
                passphraseKeyStore.verifyProof(
                    myKey,
                    theirs.identityPublicKey,
                    theirs.passphraseProof,
                )
            val effectivelyTrusted = alreadyTrusted || passphraseVerified
            if (!effectivelyTrusted && !pairingModeOpen) {
                // Not someone we trust or can auto-trust, and we aren't
                // expecting to pair - refuse before doing any more work.
                return null
            }

            val theirEphemeralBytes = B64.decodeOrNull(theirs.ephemeralPublicKey) ?: return null
            val theirSignature = B64.decodeOrNull(theirs.signature) ?: return null
            if (!DeviceIdentity.verifyRawSignature(
                    theirs.identityPublicKey,
                    theirEphemeralBytes,
                    theirSignature,
                )
            ) {
                return null
            }

            val theirEphemeralPublic = KeyFactory.getInstance("EC")
                .generatePublic(X509EncodedKeySpec(theirEphemeralBytes))
            val agreement = KeyAgreement.getInstance("ECDH").apply {
                init(ephemeral.private)
                doPhase(theirEphemeralPublic, true)
            }
            // Matches .NET's DeriveKeyFromHash(theirPublicKey, SHA256) with no
            // prepend/append - that is plain SHA256(rawSharedSecret), NOT
            // HKDF. Adding a salt or info here would derive a different key
            // and every message on the session would fail to decrypt.
            val sessionKey = MessageDigest.getInstance("SHA-256")
                .digest(agreement.generateSecret())

            // The handshake timeout must not outlive the handshake: the
            // session read loop parks in readLine() indefinitely by design,
            // and leaving a 10s SO_TIMEOUT on would tear down a perfectly
            // healthy idle connection every 10 seconds.
            socket.soTimeout = 0

            return PeerConnection(
                socket = socket,
                reader = reader,
                writer = writer,
                sessionKey = sessionKey,
                peerDeviceId = theirs.identityPublicKey,
                peerName = theirs.deviceName,
                wasAlreadyTrusted = effectivelyTrusted,
                newlyTrustedViaPassphrase = passphraseVerified,
            )
        }
    }
}

/**
 * Spots our own lines coming back before a session is proven. The session
 * key is one hash of the ECDH secret, the same both ways, so a line we sent
 * decrypts just as well when it's echoed to us - and a replayer, which can't
 * make a line of its own, could pass for proven by echoing ours (the history
 * batch and heartbeats go out unprompted). Kept by nonce, the first 12 of a
 * line's `nonce(12) || tag(16) || ciphertext` bytes - the decoded bytes, as
 * Windows keeps them, never the text: B64 skips anything that isn't base64,
 * so an echo with a space in front would miss a text match and still decrypt.
 * A plain class so it can be tested off-device.
 */
internal class EchoGuard {
    private val sentNonces: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** [packed] is a line as AesGcm packs it: its bytes, not their base64. */
    fun sent(packed: ByteArray) {
        nonceOf(packed)?.let(sentNonces::add)
    }

    fun isEcho(packed: ByteArray): Boolean = nonceOf(packed)?.let { it in sentNonces } == true

    /** Once the session is proven there's nothing left to guard. */
    fun clear() = sentNonces.clear()

    // Too short for a nonce is too short to decrypt, too.
    private fun nonceOf(packed: ByteArray) =
        if (packed.size >= NONCE_SIZE) packed.copyOf(NONCE_SIZE).toHex() else null

    private companion object {
        const val NONCE_SIZE = 12
    }
}
