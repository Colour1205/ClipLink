using System.Buffers;
using System.Buffers.Text;
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
    private static ReadOnlySpan<byte> PingSentinelUtf8 => "__ping__"u8;
    private const int HeartbeatIntervalMs = 5000;
    private const int HeartbeatTimeoutMs = 15000;

    private readonly TcpClient client;
    private readonly LineReader reader;
    // Lines are written straight to the stream (see Send) - the handshake's
    // StreamWriter flushes every write, so it never holds anything back.
    private readonly Stream stream;
    // One cipher per direction for the connection's life, rather than a new
    // one per line. AesGcm isn't safe to share between threads: Send runs
    // on many (the heartbeat timer, the chunk loop, the read loop's
    // answers), so encrypting takes encryptGate, while only the read loop
    // ever decrypts.
    private readonly AesGcm encryptor;
    private readonly AesGcm decryptor;
    private readonly object encryptGate = new();
    private DateTime lastActivityAt = DateTime.UtcNow;
    private System.Threading.Timer? heartbeatTimer;
    // Writes aren't safe for concurrent calls - without this, the
    // heartbeat timer's own Send(ping) can race a real Send() from, say,
    // StreamFileToPeer's chunk loop (different threads entirely): two
    // lines interleave on the wire, or (back when lines went through a
    // StreamWriter) its internal state broke - an
    // ArgumentOutOfRangeException out of WriteLineAsync. This serializes
    // every Send() so only one write is ever in flight.
    private readonly SemaphoreSlim writeLock = new(1, 1);

    // Known the moment the connection is created — verified during the
    // handshake, not inferred later from message content.
    public string PeerDeviceId { get; }

    // False means this peer wasn't in the trust store when the handshake
    // ran and its passcode proof (if any) didn't verify: the connection only
    // exists so the user can be asked (see CreateAsync). Callers MUST treat
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

    // The protocol the peer's handshake said it speaks (1 when it said nothing,
    // or less than 2) and the one this connection speaks: 2 only when both sides
    // do (see HandshakeMessage.Protocol). Read from the handshake, which is
    // not signed: a man in the middle can only make it 1.
    public int PeerProtocol { get; }
    public int Protocol => Math.Min(ownProtocol, PeerProtocol);
    private readonly int ownProtocol;

    // What the peer's handshake said it can do (see HandshakeMessage.Caps),
    // empty when it said nothing. Not signed either: a man in the middle can
    // only take a name away, which turns that feature off.
    public IReadOnlyList<string> PeerCaps { get; }
    private readonly IReadOnlyList<string> ownCaps;

    // Whether file streams on this connection are paced by acks (see
    // FileFlow): only when both sides announced "file-ack". Otherwise neither
    // side sends file_ack or waits for one, as before.
    public bool FileAck => HandshakeMessage.Has(ownCaps, HandshakeMessage.FileAckCap) && HandshakeMessage.Has(PeerCaps, HandshakeMessage.FileAckCap);

    // Cancelled once the connection has closed (its read loop has ended, or
    // Close was called): what a file stream waiting for an ack gives up on.
    public CancellationToken Closed => closed.Token;
    private readonly CancellationTokenSource closed = new();

    // The address this connection runs over, read when it was created (the
    // socket may be closed by the time anyone asks): what the Devices list
    // shows for a connected device. Null if it couldn't be read.
    public string? RemoteAddress { get; }

    // Each decrypted message, as text. For whoever only wants strings (the
    // tests' scripted peers); the engine uses MessageHandler.
    public event Action<string>? MessageReceived;
    public event Action? Disconnected;

    // Raised with each heartbeat (every HeartbeatIntervalMs) while the
    // connection is open, on a timer thread: for checks that only need to
    // run now and then, such as a file stream that stopped coming. Handlers
    // must be quick and mustn't throw.
    public event Action? Tick;

    // Each decrypted message as its UTF-8 bytes, awaited by the read loop
    // before it reads the next line - which is what lets a file chunk wait
    // for room in its file's write queue without the socket being read any
    // faster than the disk keeps up. The bytes are only good until the
    // returned task completes (the next line is decoded in the same buffer):
    // a handler copies what it keeps. Set once, before Listen.
    public Func<ReadOnlyMemory<byte>, ValueTask>? MessageHandler { get; set; }

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
    private volatile bool sessionProven; // only Listen's read loop sets it
    // The peer has answered: a line from it decrypted, which it only sends once it
    // accepted this device. Before that the peer may still be asking its user.
    public bool IsSessionProven => sessionProven;

    // The nonces of the lines this side sent before the session was proven.
    // One key serves both directions, so a replayer could otherwise echo
    // this side's own history batch or heartbeat back and have it decrypt;
    // Decrypt refuses those, which ends the connection like a forged line.
    // A genuine peer's random nonces never match, and changing an echoed
    // line's nonce breaks its tag. Dropped once the session is proven, so it
    // only grows until then (or until the heartbeat times the link out).
    private HashSet<string>? sentNonces = new();
    private readonly object sentNoncesGate = new(); // Send runs off the read loop

    private PeerConnection(TcpClient client, LineReader reader, Stream stream, byte[] sessionKey, string peerDeviceId, bool wasAlreadyTrusted, bool newlyTrustedViaPassphrase, string? peerDeviceName, int peerProtocol, int ownProtocol, IReadOnlyList<string>? peerCaps, IReadOnlyList<string> ownCaps)
    {
        this.client = client;
        this.reader = reader;
        this.stream = stream;
        encryptor = new AesGcm(sessionKey, TagSize);
        decryptor = new AesGcm(sessionKey, TagSize);
        PeerDeviceId = peerDeviceId;
        WasAlreadyTrusted = wasAlreadyTrusted;
        NewlyTrustedViaPassphrase = newlyTrustedViaPassphrase;
        PeerDeviceName = peerDeviceName;
        PeerProtocol = peerProtocol;
        this.ownProtocol = ownProtocol;
        PeerCaps = peerCaps ?? Array.Empty<string>();
        this.ownCaps = ownCaps;
        try
        {
            RemoteAddress = (client.Client.RemoteEndPoint as System.Net.IPEndPoint)?.Address.ToString();
        }
        catch (Exception)
        {
            // already closed or disposed - no address to show
        }
    }

    // Performs the authenticated ECDH handshake described in HandshakeMessage.cs.
    // Returns null (never throws for a bad peer) if the handshake fails, the
    // signature doesn't verify, or the peer is blocked — callers should just
    // close the socket and move on.
    //
    // An untrusted peer's handshake completes once its signature verifies, so
    // the user can be asked, as a dialog or a notification, whether to trust
    // it: the caller who gets back WasAlreadyTrusted=false is responsible for
    // that Trust/Ignore prompt before writing trust, and nothing is trusted
    // by the connection merely existing. A handshake whose passcode proof
    // verifies against passphraseKeyStore (NewlyTrustedViaPassphrase) is
    // trusted without a question, the same as the LAN beacon's passive
    // auto-trust.
    //
    // isBlocked is asked about the peer's claimed key as soon as it is read,
    // before trust, the passcode proof or anything else: a blocked device
    // gets nothing, however it got here. (It has already been sent this
    // side's handshake line, an acceptor writes first - only a public key
    // and a signature.)
    //
    // myDeviceName is this device's display name, sent in the handshake's
    // DeviceName (the caller reads it fresh, so a rename applies to the next
    // connection).
    //
    // A handshake carrying this device's own identity is always refused
    // (null); answeredAsSelf, if given, is called first, so a caller that
    // dialled an address can tell "that's this device" from a refusal.
    //
    // protocol is the sync protocol this side sends and speaks (see
    // HandshakeMessage.Protocol): always the current one, except in tests and
    // tools that stand in for an older build. caps is what this side says
    // it can do (see HandshakeMessage.Caps): null for the current build's,
    // empty for a stand-in for a build from before them.
    //
    // cancellationToken ends the handshake (the caller's timeout): its read
    // or write then throws OperationCanceledException, to the caller. Merely
    // giving up on the task (WaitAsync) left it running until the caller
    // closed the socket, and that failure was then nobody's - logged as an
    // unobserved task error, stack and all, on every redial of a peer that
    // accepts TCP and never answers.
    public static async Task<PeerConnection?> CreateAsync(TcpClient client, DeviceIdentity myIdentity, TrustStore trustStore, PassphraseKeyStore passphraseKeyStore, string? myDeviceName = null, Action? answeredAsSelf = null, Func<string, bool>? isBlocked = null, int protocol = HandshakeMessage.CurrentProtocol, CancellationToken cancellationToken = default, IReadOnlyList<string>? caps = null)
    {
        caps ??= HandshakeMessage.CurrentCaps;
        Stream stream = client.GetStream();
        // Bytes, not a StreamReader, from the first line on: whatever the
        // peer sends straight after its handshake is already in this
        // reader's buffer, and Listen goes on from there.
        var reader = new LineReader(stream);
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
            DeviceNameStore.Normalize(myDeviceName),
            protocol,
            caps.Count > 0 ? caps : null);
        await writer.WriteLineAsync(JsonSerializer.Serialize(myHandshake).AsMemory(), cancellationToken);

        string? theirHandshakeJson = await ReadHandshakeLineAsync(reader, MaxHandshakeChars, cancellationToken);
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

        // Before trust, the passcode proof and anything else: a blocked device
        // is never let in by any of them.
        if (isBlocked != null && isBlocked(theirHandshake.IdentityPublicKey)) return null;

        bool alreadyTrusted = trustStore.IsTrusted(theirHandshake.IdentityPublicKey);
        bool passphraseVerified = false;
        if (!alreadyTrusted && myKey != null && theirHandshake.PassphraseProof != null)
        {
            passphraseVerified = PassphraseAuth.VerifyProof(myKey, theirHandshake.IdentityPublicKey, theirHandshake.PassphraseProof);
        }
        // Not a device we trust or can auto-trust is no longer refused here:
        // it becomes a pairing request (WasAlreadyTrusted = false) that the
        // user answers. Its signature still has to verify below.
        bool effectivelyTrusted = alreadyTrusted || passphraseVerified;

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

        return new PeerConnection(client, reader, stream, sessionKey, theirHandshake.IdentityPublicKey, effectivelyTrusted, passphraseVerified, DeviceNameStore.Normalize(theirHandshake.DeviceName),
            HandshakeMessage.Normalize(theirHandshake.Protocol), protocol, theirHandshake.Caps, caps);
    }

    // The longest handshake line read (bytes, UTF-8). A real one is a few
    // hundred: two keys, a signature, a proof and a name.
    public const int MaxHandshakeChars = 16 * 1024;

    // The peer's handshake line, or null if the stream ends first or the
    // line runs past maxBytes. Anyone on the network can connect and send
    // this before proving anything, and ReadLineAsync kept everything until
    // a newline - a host streaming bytes without one made this buffer
    // gigabytes. Reads through reader, so whatever it has buffered beyond the
    // line is still there for Listen. A line ends at "\n" (every build ends
    // its lines with "\n" or "\r\n"); a "\r" is dropped. UTF-8, without the
    // byte order mark the StreamReader this replaced would have skipped.
    public static async Task<string?> ReadHandshakeLineAsync(LineReader reader, int maxBytes = MaxHandshakeChars, CancellationToken cancellationToken = default)
    {
        byte[]? line = await reader.ReadHandshakeLineAsync(maxBytes, cancellationToken);
        if (line == null) return null;
        var text = line.AsSpan();
        if (text.StartsWith(Encoding.UTF8.Preamble)) text = text[Encoding.UTF8.Preamble.Length..];
        return Encoding.UTF8.GetString(text);
    }

    public Task Send(string message) => Send(Encoding.UTF8.GetBytes(message));

    // One message, already UTF-8 (see Wire.Envelope): sealed into one buffer
    // and written as one Base64 line - the same bytes as ever, with the
    // "\r\n" StreamWriter.WriteLine ended it with - but without the copies a
    // picture used to make on the way: its UTF-8, the ciphertext, the packed
    // bytes and a Base64 string twice their size, for every peer.
    public async Task Send(ReadOnlyMemory<byte> message)
    {
        int packedLength = NonceSize + TagSize + message.Length;
        byte[] packed = ArrayPool<byte>.Shared.Rent(packedLength);
        byte[]? line = null;
        try
        {
            Encrypt(message.Span, packed.AsSpan(0, packedLength));
            line = ArrayPool<byte>.Shared.Rent(Base64.GetMaxEncodedToUtf8Length(packedLength) + 2);
            Base64.EncodeToUtf8(packed.AsSpan(0, packedLength), line, out _, out int written);
            line[written++] = (byte)'\r';
            line[written++] = (byte)'\n';
            await writeLock.WaitAsync();
            try
            {
                await stream.WriteAsync(line.AsMemory(0, written));
            }
            finally
            {
                writeLock.Release();
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(packed);
            if (line != null) ArrayPool<byte>.Shared.Return(line);
        }
    }

    public async Task Listen()
    {
        StartHeartbeat();
        try
        {
            while (true)
            {
                if (await reader.ReadLineAsync() is not { } line) break; // peer closed cleanly
                lastActivityAt = DateTime.UtcNow;
                // The line's bytes decoded into a buffer of their own, and
                // decrypted where they are: no string of the line, and no
                // string of the message unless someone asks for one.
                byte[] packed = ByteBuffers.Rent(Base64.GetMaxDecodedFromUtf8Length(line.Length));
                try
                {
                    var decrypted = Decrypt(line.Span, ref packed);
                    if (!sessionProven)
                    {
                        // Before the ping check: a heartbeat proves the key just as well.
                        sessionProven = true;
                        lock (sentNoncesGate) sentNonces = null;
                        SessionProven?.Invoke();
                    }
                    if (decrypted.Span.SequenceEqual(PingSentinelUtf8)) continue; // heartbeat only, not real data
                    if (MessageHandler is { } handler) await handler(decrypted);
                    MessageReceived?.Invoke(Encoding.UTF8.GetString(decrypted.Span));
                }
                finally
                {
                    ByteBuffers.Return(packed);
                }
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
            CancelClosed();
            decryptor.Dispose(); // only ever used by this loop
            reader.Dispose();    // and so is this
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
                return;
            }
            try
            {
                Tick?.Invoke();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[conn] a heartbeat check for {DeviceLabel.ShortId(PeerDeviceId)} failed: {ex.GetType().Name}: {ex.Message}");
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
        CancelClosed();
    }

    private void CancelClosed()
    {
        try
        {
            closed.Cancel();
        }
        catch (AggregateException ex)
        {
            // A handler of Closed that threw - never the connection's to fail over.
            Console.WriteLine($"[conn] a handler of a closed connection failed: {ex.GetBaseException().Message}");
        }
    }

    private const int NonceSize = 12; // AES-GCM standard nonce size
    private const int TagSize = 16;

    // plaintext sealed into packed, laid out as the wire has it - nonce, tag,
    // ciphertext - with nothing copied on the way.
    private void Encrypt(ReadOnlySpan<byte> plaintext, Span<byte> packed)
    {
        Span<byte> nonce = packed[..NonceSize];
        RandomNumberGenerator.Fill(nonce);
        lock (sentNoncesGate) sentNonces?.Add(Convert.ToBase64String(nonce));
        lock (encryptGate)
        {
            encryptor.Encrypt(nonce, plaintext, packed[(NonceSize + TagSize)..], packed[NonceSize..(NonceSize + TagSize)]);
        }
    }

    // A line's Base64 decoded into packed (from ByteBuffers, and replaced
    // by a bigger one if it has to be) and decrypted in place there; returns
    // the plaintext, inside packed. Base64 that the fast decoder won't take
    // goes through Convert.FromBase64String, which the line reader this
    // replaced always used: whatever it accepted is still accepted, and what
    // it refused still ends the connection (its FormatException, caught in
    // Listen).
    private ReadOnlyMemory<byte> Decrypt(ReadOnlySpan<byte> line, ref byte[] packed)
    {
        var status = Base64.DecodeFromUtf8(line, packed, out int consumed, out int length);
        if (status != OperationStatus.Done || consumed != line.Length)
        {
            byte[] decoded = Convert.FromBase64String(Encoding.UTF8.GetString(line));
            if (decoded.Length > packed.Length)
            {
                ByteBuffers.Return(packed);
                packed = ByteBuffers.Rent(decoded.Length);
            }
            decoded.CopyTo(packed, 0);
            length = decoded.Length;
        }
        if (length < NonceSize + TagSize) throw new CryptographicException("line too short"); // caught in Listen()
        ReadOnlySpan<byte> nonce = packed.AsSpan(0, NonceSize);
        ReadOnlySpan<byte> tag = packed.AsSpan(NonceSize, TagSize);
        Span<byte> cipher = packed.AsSpan(NonceSize + TagSize, length - NonceSize - TagSize);
        lock (sentNoncesGate)
        {
            if (sentNonces != null && sentNonces.Contains(Convert.ToBase64String(nonce)))
            {
                throw new CryptographicException("reflected line - one of ours, echoed back"); // caught in Listen()
            }
        }

        decryptor.Decrypt(nonce, cipher, tag, cipher); // throws if tampered — caught in Listen()
        return packed.AsMemory(NonceSize + TagSize, length - NonceSize - TagSize);
    }
}
