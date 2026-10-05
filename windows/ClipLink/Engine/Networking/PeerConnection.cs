using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Engine;

namespace ClipboardDaemon.Networking;

public class PeerConnection
{
    // Sent (encrypted, like anything else on this channel) as a heartbeat
    // and filtered out in Listen() before reaching MessageReceived - normal
    // message handling never sees these. TCP keepalive alone (see
    // ClipLinkEngine's EnableKeepAlive) isn't enough by itself to catch a
    // silently dead peer in reasonable time - depending on OS/network
    // conditions it can still take much longer than feels "live". This
    // application-level ping/watchdog is what actually makes a connection
    // list reflect reality within seconds of a peer actually going away.
    private const string PingSentinel = "__ping__";
    private const int HeartbeatIntervalMs = 5000;
    private const int HeartbeatTimeoutMs = 15000;

    private readonly TcpClient client;
    private readonly StreamReader reader;
    private readonly StreamWriter writer;
    private readonly byte[] sessionKey;
    private DateTime lastActivityAt = DateTime.UtcNow;
    private System.Threading.Timer? heartbeatTimer;
    // StreamWriter isn't safe for concurrent calls - without this, the
    // heartbeat timer's own Send(ping) can race a real Send() from, say,
    // StreamFileToPeer's chunk loop (different threads entirely) and
    // corrupt the writer's internal state. That's what an
    // ArgumentOutOfRangeException out of WriteLineAsync actually was -
    // this serializes every Send() so only one write is ever in flight.
    private readonly SemaphoreSlim writeLock = new(1, 1);

    // Known the moment the connection is created — verified during the
    // handshake, not inferred later from message content.
    public string PeerDeviceId { get; }

    // False means this peer wasn't in the trust store when the handshake
    // ran, and the connection only exists at all because pairingModeOpen
    // was true (see CreateAsync's relaxed gate below). Callers MUST treat
    // this as a live pairing candidate — show an explicit accept/reject
    // prompt fed by this already signature-verified PeerDeviceId — rather
    // than handing it straight to normal message processing.
    public bool WasAlreadyTrusted { get; }

    // True only when WasAlreadyTrusted became true because THIS handshake's
    // passphrase proof verified (not because the peer was already in the
    // trust store) - the caller's signal to actually WRITE trust for this
    // peer before treating the connection as normal, same as the LAN
    // beacon's own auto-trust path already does.
    public bool NewlyTrustedViaPassphrase { get; }

    // The display name the peer's handshake carried (already normalized -
    // see DeviceNameStore.Normalize), or null if it didn't send one (an
    // older build). Self-asserted, unlike PeerDeviceId, and not covered by
    // the handshake's signature: shown right away, but only stored once
    // SessionProven fires.
    public string? PeerDeviceName { get; }

    public event Action<string>? MessageReceived;
    public event Action? Disconnected;

    // Raised once, on the read loop, the first time a line from the peer
    // decrypts with the session key - a message or a heartbeat - and isn't
    // one of this side's own lines echoed back. Only that proves the peer
    // holds the identity it claimed: the handshake signature covers just the
    // ephemeral key, so a captured handshake can be replayed under any
    // DeviceName, but a replayer can't derive the key, so the only lines it
    // has that decrypt are the ones this side sent it (see sentNonces).
    // Handlers must be quick (the read loop waits for them) and mustn't
    // throw.
    public event Action? SessionProven;
    private bool sessionProven; // only Listen's read loop touches it

    // The nonces of the lines this side sent before the session was proven.
    // One key serves both directions, so a replayer could otherwise echo
    // this side's own history batch or heartbeat back and have it decrypt;
    // Decrypt refuses those, which ends the connection like a forged line.
    // A genuine peer's random nonces never match, and changing an echoed
    // line's nonce breaks its tag. Dropped once the session is proven, so it
    // only grows until then (or until the heartbeat times the link out).
    private HashSet<string>? sentNonces = new();
    private readonly object sentNoncesGate = new(); // Send runs off the read loop

    private PeerConnection(TcpClient client, StreamReader reader, StreamWriter writer, byte[] sessionKey, string peerDeviceId, bool wasAlreadyTrusted, bool newlyTrustedViaPassphrase, string? peerDeviceName)
    {
        this.client = client;
        this.reader = reader;
        this.writer = writer;
        this.sessionKey = sessionKey;
        PeerDeviceId = peerDeviceId;
        WasAlreadyTrusted = wasAlreadyTrusted;
        NewlyTrustedViaPassphrase = newlyTrustedViaPassphrase;
        PeerDeviceName = peerDeviceName;
    }

    // Performs the authenticated ECDH handshake described in HandshakeMessage.cs.
    // Returns null (never throws for a bad peer, or an untrusted one that's
    // neither pairing-mode-eligible nor passphrase-verified) if the
    // handshake fails or the signature doesn't verify — callers should just
    // close the socket and move on.
    //
    // pairingModeOpen: true only while the local app's pairing screen is
    // open (mirrors HarmonyOS's Index.ets pairingOpen) — a live, explicit
    // "I'm expecting to pair right now" signal. Without it, an untrusted
    // peer is refused exactly as before (same early-bail, no wasted
    // signature verification) UNLESS their handshake carries a passphrase
    // proof that verifies against passphraseKeyStore (see
    // NewlyTrustedViaPassphrase) - a second, independent way in, same as
    // the LAN beacon's passive auto-trust already is regardless of pairing
    // mode. With pairingModeOpen true, the handshake completes fully for a
    // live accept/reject prompt instead - both sides need this true on
    // their OWN behalf for a NEW pairing to succeed that way, since each
    // independently runs this same check over the same connection; the
    // caller who gets back WasAlreadyTrusted=false is responsible for a
    // local accept/reject prompt before writing trust.
    //
    // myDeviceName is this device's display name, sent in the handshake's
    // DeviceName (the caller reads it fresh, so a rename applies to the next
    // connection).
    //
    // A handshake carrying this device's own identity is always refused
    // (null); answeredAsSelf, if given, is called first, so a caller that
    // dialled an address can tell "that's this device" from a refusal.
    public static async Task<PeerConnection?> CreateAsync(TcpClient client, DeviceIdentity myIdentity, TrustStore trustStore, bool pairingModeOpen, PassphraseKeyStore passphraseKeyStore, string? myDeviceName = null, Action? answeredAsSelf = null)
    {
        Stream stream = client.GetStream();
        var reader = new StreamReader(stream);
        var writer = new StreamWriter(stream) { AutoFlush = true };

        using var ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        byte[] myEphemeralPublicKey = ecdh.PublicKey.ExportSubjectPublicKeyInfo();
        byte[] mySignature = myIdentity.SignData(myEphemeralPublicKey);

        string myIdentityPublicKey = myIdentity.GetPublicKey();
        byte[]? myKey = passphraseKeyStore.GetKey();
        string? myProof = myKey != null ? PassphraseAuth.ComputeProof(myKey, myIdentityPublicKey) : null;

        var myHandshake = new HandshakeMessage(
            Convert.ToBase64String(myEphemeralPublicKey),
            myIdentityPublicKey,
            Convert.ToBase64String(mySignature),
            myProof,
            DeviceNameStore.Normalize(myDeviceName));
        await writer.WriteLineAsync(JsonSerializer.Serialize(myHandshake));

        string? theirHandshakeJson = await reader.ReadLineAsync();
        if (theirHandshakeJson == null) return null;

        HandshakeMessage? theirHandshake;
        try
        {
            theirHandshake = JsonSerializer.Deserialize<HandshakeMessage>(theirHandshakeJson);
        }
        catch (JsonException) { return null; }
        if (theirHandshake == null) return null;

        // Our own handshake sent back - never a real peer (this device's own
        // address, or something relaying our dial into our own listener).
        // Two of our own connections cross-wired that way derive one session
        // key, so each would take the other's lines as proof, out of sight of
        // the per-connection sentNonces check - and our own passcode proof
        // would even vouch for our own id. So before anything else, trust
        // and pairing included. Our own key written some other way (Base64
        // with a space in it, say) is still us, so it's the keys that are
        // compared, not just the text (see DeviceIdentity.IsSameKey).
        if (DeviceIdentity.IsSameKey(theirHandshake.IdentityPublicKey, myIdentityPublicKey))
        {
            answeredAsSelf?.Invoke();
            return null;
        }

        bool alreadyTrusted = trustStore.IsTrusted(theirHandshake.IdentityPublicKey);
        bool passphraseVerified = false;
        if (!alreadyTrusted && myKey != null && theirHandshake.PassphraseProof != null)
        {
            passphraseVerified = PassphraseAuth.VerifyProof(myKey, theirHandshake.IdentityPublicKey, theirHandshake.PassphraseProof);
        }
        bool effectivelyTrusted = alreadyTrusted || passphraseVerified;
        if (!effectivelyTrusted && !pairingModeOpen)
        {
            return null; // not a device we trust or can auto-trust, and not expecting to pair right now — refuse outright
        }

        byte[] theirEphemeralPublicKeyBytes;
        byte[] theirSignature;
        try
        {
            theirEphemeralPublicKeyBytes = Convert.FromBase64String(theirHandshake.EphemeralPublicKey);
            theirSignature = Convert.FromBase64String(theirHandshake.Signature);
        }
        catch (FormatException) { return null; }

        using var verifyEcdsa = ECDsa.Create();
        try
        {
            verifyEcdsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(theirHandshake.IdentityPublicKey), out _);
        }
        catch (CryptographicException) { return null; }

        if (!verifyEcdsa.VerifyData(theirEphemeralPublicKeyBytes, theirSignature, HashAlgorithmName.SHA256))
        {
            return null; // ephemeral key doesn't match the claimed identity's signature — tampered or spoofed
        }

        using var theirEcdh = ECDiffieHellman.Create();
        theirEcdh.ImportSubjectPublicKeyInfo(theirEphemeralPublicKeyBytes, out _);

        byte[] sessionKey = ecdh.DeriveKeyFromHash(theirEcdh.PublicKey, HashAlgorithmName.SHA256);

        return new PeerConnection(client, reader, writer, sessionKey, theirHandshake.IdentityPublicKey, effectivelyTrusted, passphraseVerified, DeviceNameStore.Normalize(theirHandshake.DeviceName));
    }

    public async Task Send(string message)
    {
        string encrypted = Encrypt(message);
        await writeLock.WaitAsync();
        try
        {
            await writer.WriteLineAsync(encrypted);
        }
        finally
        {
            writeLock.Release();
        }
    }

    public async Task Listen()
    {
        StartHeartbeat();
        try
        {
            while (true)
            {
                string? line = await reader.ReadLineAsync();
                if (line == null) break; // peer closed cleanly
                lastActivityAt = DateTime.UtcNow;
                string decrypted = Decrypt(line);
                if (!sessionProven)
                {
                    // Before the ping check: a heartbeat proves the key just as well.
                    sessionProven = true;
                    lock (sentNoncesGate) sentNonces = null;
                    SessionProven?.Invoke();
                }
                if (decrypted == PingSentinel) continue; // heartbeat only, not real data
                MessageReceived?.Invoke(decrypted);
            }
        }
        catch (Exception ex)
        {
            // Abrupt disconnect, or a corrupt/forged line that failed to
            // decrypt. Logged so a connection that ends for a reason other
            // than the peer going away doesn't just silently vanish.
            Console.WriteLine($"[conn] read loop for {DeviceLabel.ShortId(PeerDeviceId)} ended: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            StopHeartbeat();
            Disconnected?.Invoke();
        }
    }

    private void StartHeartbeat()
    {
        heartbeatTimer = new System.Threading.Timer(_ =>
        {
            _ = Send(PingSentinel); // fire-and-forget - a send failure also surfaces via Listen()'s read loop dying
            if ((DateTime.UtcNow - lastActivityAt).TotalMilliseconds > HeartbeatTimeoutMs)
            {
                // Nothing at all (ping or real data) for HeartbeatTimeoutMs -
                // the peer is gone even though TCP itself hasn't noticed
                // yet. Closing here is what actually makes the connections
                // list reflect reality, instead of relying on some much
                // longer OS-level timeout to eventually notice.
                Close();
            }
        }, null, HeartbeatIntervalMs, HeartbeatIntervalMs);
    }

    private void StopHeartbeat()
    {
        heartbeatTimer?.Dispose();
        heartbeatTimer = null;
    }

    // Actively tears down the connection — used when a device gets untrusted
    // while still connected.
    public void Close()
    {
        StopHeartbeat();
        client.Close();
    }

    private const int NonceSize = 12; // AES-GCM standard nonce size
    private const int TagSize = 16;

    private string Encrypt(string plaintext)
    {
        byte[] nonce = RandomNumberGenerator.GetBytes(NonceSize);
        lock (sentNoncesGate) sentNonces?.Add(Convert.ToBase64String(nonce));
        byte[] plainBytes = Encoding.UTF8.GetBytes(plaintext);
        byte[] cipherBytes = new byte[plainBytes.Length];
        byte[] tag = new byte[TagSize];

        using var aesGcm = new AesGcm(sessionKey, TagSize);
        aesGcm.Encrypt(nonce, plainBytes, cipherBytes, tag);

        byte[] packed = new byte[NonceSize + TagSize + cipherBytes.Length];
        Buffer.BlockCopy(nonce, 0, packed, 0, NonceSize);
        Buffer.BlockCopy(tag, 0, packed, NonceSize, TagSize);
        Buffer.BlockCopy(cipherBytes, 0, packed, NonceSize + TagSize, cipherBytes.Length);
        return Convert.ToBase64String(packed);
    }

    private string Decrypt(string packedBase64)
    {
        byte[] packed = Convert.FromBase64String(packedBase64);
        byte[] nonce = packed[0..NonceSize];
        byte[] tag = packed[NonceSize..(NonceSize + TagSize)];
        byte[] cipherBytes = packed[(NonceSize + TagSize)..];
        byte[] plainBytes = new byte[cipherBytes.Length];
        lock (sentNoncesGate)
        {
            if (sentNonces != null && sentNonces.Contains(Convert.ToBase64String(nonce)))
            {
                throw new CryptographicException("reflected line - one of ours, echoed back"); // caught in Listen()
            }
        }

        using var aesGcm = new AesGcm(sessionKey, TagSize);
        aesGcm.Decrypt(nonce, cipherBytes, tag, plainBytes); // throws if tampered — caught in Listen()
        return Encoding.UTF8.GetString(plainBytes);
    }
}
