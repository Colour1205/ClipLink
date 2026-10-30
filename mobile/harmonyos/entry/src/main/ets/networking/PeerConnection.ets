// Step 6/7 of the build order in ../../../../README.md: handshake +
// session encryption, then trust store integration. Mirrors
// windows/ClipLink/Engine/Networking/PeerConnection.cs's authenticated ECDH
// handshake, AES-256-GCM session transport, and trust enforcement - refuse
// the connection outright if the peer's claimed identity isn't trusted,
// checked at the same point in the flow Windows checks it (right after
// parsing their handshake message, before spending effort verifying the
// signature or deriving a session key for a peer we'd refuse anyway).

import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { DeviceIdentity, verifyRawSignature } from '../identity/DeviceIdentity';
import { TrustStore } from '../identity/TrustStore';
import { PassphraseKeyStore } from '../identity/PassphraseKeyStore';
import { deviceFingerprint, normalizeDeviceName } from '../identity/DeviceName';
import * as AesGcm from '../crypto/AesGcm';
import { LineFramer } from './LineFramer';
import { PROTOCOL_VERSION, negotiatedProtocol, peerProtocolOf } from './SyncProtocol';

const base64Helper = new util.Base64Helper();
const decoder = util.TextDecoder.create('utf-8');
const CARRIAGE_RETURN = 13;

export interface HandshakeMessage {
  EphemeralPublicKey: string;
  IdentityPublicKey: string;
  Signature: string;
  // Optional - HMAC-SHA256(sharedPassphraseKey, own IdentityPublicKey),
  // same computation as the LAN beacon's own proof (PassphraseAuth.cs).
  // Lets two devices with the same passcode auto-accept a pairing over a
  // direct connection (e.g. Tailscale, via Pair by Address) the same way
  // they already auto-trust from a LAN beacon - no beacon needed, since
  // this rides along on the handshake itself instead.
  PassphraseProof?: string;
  // Optional - the sender's display name (see DeviceName.ets), sent whenever
  // it's known. Older builds neither send nor read it.
  DeviceName?: string;
  // Optional - the sync protocol the sender speaks (see SyncProtocol.ets).
  // Absent means 1: every build before sync v2. A connection speaks v2 only
  // when both sides send 2 or more. Like DeviceName, an older build's parser
  // just skips it. It is not signed (the signature covers only the ephemeral
  // key): a man in the middle who strips it only forces v1, the safe fallback.
  Protocol?: number;
}

// The handshake is the one plaintext line this side writes, and DeviceName is
// the first thing in it that can be non-ASCII. Escaping every non-ASCII UTF-16
// unit as \uXXXX (what Windows' System.Text.Json writes) keeps the line pure
// ASCII, so it can't depend on how the socket layer encodes a string; every
// peer's JSON parser reads the escapes back as the same text.
function asciiJson(json: string): string {
  let out = '';
  for (let i = 0; i < json.length; i++) {
    const code = json.charCodeAt(i);
    out += code < 0x80 ? json.charAt(i) : `\\u${code.toString(16).padStart(4, '0')}`;
  }
  return out;
}

// The line this side writes as its half of the handshake.
export function handshakeLine(handshake: HandshakeMessage): string {
  return asciiJson(JSON.stringify(handshake));
}

// What the other side did right after a completed handshake - see
// PeerConnection.waitForPeerVerdict.
export type PeerVerdict = 'accepted' | 'closed' | 'quiet';

// Optional out-parameter for PeerConnection.create, for callers that need to
// tell a peer that never answered apart from one that hung up.
export class HandshakeReport {
  // The connection stayed open but no handshake arrived within
  // HANDSHAKE_TIMEOUT_MS.
  timedOut: boolean = false;
}

// How long to wait for the peer's half of the handshake. Without a limit, a
// peer that accepts the TCP connection but never answers (a wedged daemon,
// or not ClipLink at all) left the dial - and the Pairing screen's
// "Connecting..." - hanging forever. Generous for a cold Tailscale relay.
// Handshake only; nothing to do with the heartbeat below.
const HANDSHAKE_TIMEOUT_MS = 10000;

// Both socket.TCPSocket (outbound, from connectTcp) and
// socket.TCPSocketConnection (inbound, from TcpServer.onConnection) expose
// this same shape - captured explicitly here rather than relying on
// implicit structural compatibility between two separate SDK types, so
// PeerConnection.create() works identically for whichever side initiated
// the TCP connection (matches PeerConnection.cs: the handshake itself has
// no notion of "client" vs "server" role, both sides just write-then-read).
interface TcpLike {
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void;
  onClose(callback: () => void): void;
  send(options: socket.TCPSendOptions): Promise<void>;
  close(): Promise<void>;
}

// Holds a socket's 'message' and 'close' events until the channel asks for
// them. A TCPSocket drops what arrives while it has no 'message' listener
// (checked on a device: a handshake sent 1.5 s before the listener was
// registered never came, the lines after it did), and the device at the
// other end of a dial writes its handshake the moment it accepts - before
// connect() has even resolved here, let alone the setExtraOptions round
// trip and the main thread's turn that came between it and the channel
// registering its listener. Lost, the handshake left the dial reading the
// peer's history batch as its handshake, which failed, and the peer was
// redialled: on a cold start, or when the main thread was busy, a trusted
// device this side dials took one or more 2 s beacons (or the dial
// fallback's next 30 s) longer to connect. So each adapter registers both
// listeners as soon as it is made - before connect() - and replays here.
export class MessageRelay {
  private messageCallback: ((info: socket.SocketMessageInfo) => void) | null = null;
  private closeCallback: (() => void) | null = null;
  private held: socket.SocketMessageInfo[] = [];
  private closed: boolean = false;

  // From the socket's 'message' event.
  message(info: socket.SocketMessageInfo): void {
    if (this.messageCallback !== null) {
      this.messageCallback(info);
    } else {
      this.held.push(info);
    }
  }

  // From the socket's 'close' event.
  close(): void {
    this.closed = true;
    this.closeCallback?.();
  }

  // What was held is delivered now, in order, then everything as it comes.
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.messageCallback = callback;
    const held: socket.SocketMessageInfo[] = this.held;
    this.held = [];
    for (const info of held) callback(info);
  }

  onClose(callback: () => void): void {
    this.closeCallback = callback;
    if (this.closed) callback();
  }
}

// ArkTS has no structural typing (arkts-no-structural-typing) - a
// socket.TCPSocket or socket.TCPSocketConnection can't be passed where
// TcpLike is expected just because their shapes match; they need an
// explicit adapter. Thin wrappers, one per concrete SDK type, each
// listening from the moment it is made (see MessageRelay). Make one before
// connect() for a dial, and before anything is awaited for an accepted
// connection.
export class TcpSocketAdapter implements TcpLike {
  private inner: socket.TCPSocket;
  private relay: MessageRelay = new MessageRelay();
  constructor(inner: socket.TCPSocket) {
    this.inner = inner;
    this.inner.on('message', (info: socket.SocketMessageInfo) => { this.relay.message(info); });
    this.inner.on('close', () => { this.relay.close(); });
  }
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.relay.onMessage(callback);
  }
  onClose(callback: () => void): void {
    this.relay.onClose(callback);
  }
  send(options: socket.TCPSendOptions): Promise<void> {
    return this.inner.send(options);
  }
  close(): Promise<void> {
    return this.inner.close();
  }
}

export class TcpSocketConnectionAdapter implements TcpLike {
  private inner: socket.TCPSocketConnection;
  private relay: MessageRelay = new MessageRelay();
  constructor(inner: socket.TCPSocketConnection) {
    this.inner = inner;
    this.inner.on('message', (info: socket.SocketMessageInfo) => { this.relay.message(info); });
    this.inner.on('close', () => { this.relay.close(); });
  }
  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.relay.onMessage(callback);
  }
  onClose(callback: () => void): void {
    this.relay.onClose(callback);
  }
  send(options: socket.TCPSendOptions): Promise<void> {
    return this.inner.send(options);
  }
  close(): Promise<void> {
    return this.inner.close();
  }
}

// The bytes a Base64 IdentityPublicKey decodes to - by the same decoder
// verifyRawSignature reads it with - or null if it isn't Base64 at all.
function decodedKey(base64: string): Uint8Array | null {
  try {
    return base64Helper.decodeSync(base64);
  } catch (e) {
    return null;
  }
}

// Whether two keys' bytes are one key. No bytes at all (an empty key, or
// one the decoder refused) is nobody's key, so it never matches.
export function sameKeyBytes(a: Uint8Array | null, b: Uint8Array | null): boolean {
  if (a === null || b === null || a.length === 0 || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

// Whether two IdentityPublicKeys are one key: compared as the bytes they
// decode to, not just as text, so our own key spelt some other way the
// decoder still takes (whitespace in it, say) is still ours. The same as
// comparing canonical re-encodings (one Base64 spelling per byte string),
// which is how Windows' CreateAsync compares the key it re-exports.
export function sameIdentityKey(a: string, b: string): boolean {
  return (a.length > 0 && a === b) || sameKeyBytes(decodedKey(a), decodedKey(b));
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data });
  return (await md.digest()).data;
}

// Reassembles newline-delimited lines out of a TCPSocket's raw message
// chunks, and supports async pull (readLine) - matches the semantics of
// .NET's StreamReader.ReadLineAsync() (returns null on clean close) closely
// enough for this protocol's purposes. Used for the whole connection
// lifetime, handshake and session phase alike, same as the Windows side
// reuses one StreamReader/StreamWriter throughout.
//
// Lines come out as bytes, not text. Only the handshake line is read as
// text; every session line is Base64, which Base64Helper decodes straight
// from the bytes. Decoding a line to a string first cost a pass over it on
// the UI thread - measured at about 90 ms for a 16 MB history batch - for
// nothing. (A line that long is ordinary: an image item is its PNG in
// Base64, and a history batch carries 25 items.)
class TcpLineChannel {
  private client: TcpLike;
  // Splits the socket's bytes into lines - bounded, and linear in what
  // arrives (see LineFramer).
  private framer: LineFramer = new LineFramer();
  private pendingLines: Uint8Array[] = [];
  private waiters: Array<(line: Uint8Array | null) => void> = [];
  // Notified whenever a line arrives or the socket closes - see
  // waitForActivity.
  private activityListeners: Array<() => void> = [];
  private closed = false;
  // Chains every writeLine onto the previous one so only one client.send()
  // is ever in flight at a time - without this, the heartbeat's own
  // writeLine (see PeerConnection's heartbeat) can overlap a real one from
  // SyncManager/file streaming, and there's no guarantee the underlying
  // socket API handles two concurrent send() calls as cleanly-ordered,
  // un-corrupted writes. Mirrors the same fix on the Windows side
  // (PeerConnection.cs's writeLock), same reasoning.
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(client: TcpLike) {
    this.client = client;
    client.onMessage((info: socket.SocketMessageInfo) => {
      this.handleChunk(info.message);
    });
    client.onClose(() => {
      this.closed = true;
      this.flushWaiters(null);
      this.notifyActivity();
    });
  }

  private handleChunk(chunk: ArrayBuffer): void {
    const lines: Uint8Array[] | null = this.framer.push(new Uint8Array(chunk));
    if (lines === null) {
      // Over the cap before a handshake even arrived - not a ClipLink peer,
      // or one trying to fill this device's memory. Closed here and now,
      // whether or not the socket reports its own close.
      this.closed = true;
      this.flushWaiters(null);
      this.notifyActivity();
      this.close();
      return;
    }
    for (const lineBytes of lines) {
      // A peer that ends its lines with "\r\n": the '\r' is not part of the line.
      const end: number = lineBytes.length > 0 && lineBytes[lineBytes.length - 1] === CARRIAGE_RETURN
        ? lineBytes.length - 1 : lineBytes.length;
      this.deliverLine(end === lineBytes.length ? lineBytes : lineBytes.subarray(0, end));
    }
    // For waitForActivity, a partial line is already proof the peer is
    // talking (a big first message can take seconds to arrive in full over
    // a relayed connection).
    this.notifyActivity();
  }

  private deliverLine(line: Uint8Array): void {
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter(line);
    } else {
      this.pendingLines.push(line);
    }
    this.notifyActivity();
  }

  private flushWaiters(value: Uint8Array | null): void {
    while (this.waiters.length > 0) {
      this.waiters.shift()?.(value);
    }
  }

  private notifyActivity(): void {
    const listeners = this.activityListeners;
    this.activityListeners = [];
    for (const listener of listeners) listener();
  }

  async readLine(): Promise<Uint8Array | null> {
    if (this.pendingLines.length > 0) {
      return this.pendingLines.shift()!;
    }
    if (this.closed) return null;
    return new Promise<Uint8Array | null>((resolve) => {
      this.waiters.push(resolve);
    });
  }

  // readLine with a deadline: null on close OR on timeout. The timed-out
  // waiter is removed so it can't swallow a line that arrives later.
  async readLineWithin(timeoutMs: number): Promise<Uint8Array | null> {
    if (this.pendingLines.length > 0) {
      return this.pendingLines.shift()!;
    }
    if (this.closed) return null;
    return new Promise<Uint8Array | null>((resolve) => {
      let timerId = -1;
      const waiter = (line: Uint8Array | null): void => {
        clearTimeout(timerId);
        resolve(line);
      };
      timerId = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i !== -1) this.waiters.splice(i, 1);
        resolve(null);
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  get isClosed(): boolean {
    return this.closed;
  }

  // Without consuming anything: 'accepted' once any data has arrived (whole
  // lines stay queued for readLine), 'closed' if the socket closes first,
  // 'quiet' if neither happens within timeoutMs. Only meaningful before
  // anything reads the channel (i.e. before PeerConnection.listen).
  waitForActivity(timeoutMs: number): Promise<PeerVerdict> {
    return new Promise<PeerVerdict>((resolve) => {
      let timerId = -1;
      const settled = (): boolean => {
        if (this.pendingLines.length > 0 || this.framer.bufferedBytes > 0) {
          resolve('accepted');
          return true;
        }
        if (this.closed) {
          resolve('closed');
          return true;
        }
        return false;
      };
      if (settled()) return;
      const onActivity = (): void => {
        if (settled()) {
          clearTimeout(timerId);
        } else {
          this.activityListeners.push(onActivity);
        }
      };
      this.activityListeners.push(onActivity);
      timerId = setTimeout(() => {
        const i = this.activityListeners.indexOf(onActivity);
        if (i !== -1) this.activityListeners.splice(i, 1);
        resolve('quiet');
      }, timeoutMs);
    });
  }

  async writeLine(line: string): Promise<void> {
    const previous = this.writeQueue;
    const current = previous.then(() => this.client.send({ data: line + '\n' }));
    // Swallow rejection in the queue itself - a failed send shouldn't wedge
    // every write after it. The actual error still reaches THIS call's own
    // caller via the awaited `current` below.
    this.writeQueue = current.catch(() => {});
    await current;
  }

  // Never throws - listenLoop's teardown calls it before telling SyncManager
  // the link is gone. Ends the channel here and now rather than waiting for
  // the socket's own 'close' event: a readLine() still waiting gets null, so
  // the read loop ends and the link leaves SyncManager's map even if that
  // event never comes (a socket the OS already tore down while the app was
  // frozen, say). Left in the map, the link counted as connected, so no
  // beacon ever redialled its peer and the dial fallback never came due.
  close(): void {
    this.closed = true;
    this.flushWaiters(null);
    this.notifyActivity();
    try {
      this.client.close().catch(() => { /* already closed - fine */ });
    } catch (e) {
      // already closed - fine
    }
  }
}

// Sent (encrypted, like anything else on this channel) as a heartbeat and
// filtered out in listenLoop before reaching messageCallback - SyncManager
// never sees these. TCP keepalive alone isn't enough to catch a silently
// dead peer in reasonable time: HarmonyOS's socket API only exposes an
// on/off keepAlive flag, no interval tuning, so it falls back to whatever
// the kernel's own default is (can be hours). This application-level
// ping/watchdog is what actually makes "connected" reflect reality within
// seconds instead of however long the OS takes to notice.
const PING_SENTINEL = '__ping__';
// Deliberately tighter than the Windows daemon's 5000/15000. What
// actually has to hold is that EACH side pings faster than the OTHER
// side's timeout, and both directions satisfy that: this pings every 3s
// against the daemon's 15s timeout, the daemon pings every 5s against
// this 9s timeout. Tightening only this end is therefore safe, and it
// cuts how long the UI can show a stale "Connected" for a silently-dead
// peer from ~15-20s to ~9-12s.
//
// (A 25s timeout was tried here and reverted - it fixed nothing for the
// "connection still drops after a while" symptom, which has a different
// root cause elsewhere, and it made the ORIGINAL stale-"Connected" problem
// this heartbeat exists to fix noticeably worse. Leave these values alone
// unless you've root-caused a problem to this specific number.)
const HEARTBEAT_INTERVAL_MS = 3000;
const HEARTBEAT_TIMEOUT_MS = 9000;

// What sentNonces keeps a line by: its nonce - the first AesGcm.NONCE_SIZE
// of its packed nonce || tag || ciphertext bytes - in hex. The decoded
// bytes, as Windows and Android keep them, never the line's text: a decoder
// may take more than one spelling of the same bytes (whitespace in them, or
// a character outside the alphabet read as some other), so an echo of one
// of our lines spelt another way would miss a text match and still decrypt.
// null for bytes too short to hold a nonce, which decryptPacked refuses.
export function nonceKey(packed: Uint8Array): string | null {
  if (packed.length < AesGcm.NONCE_SIZE) return null;
  let key = '';
  for (let i = 0; i < AesGcm.NONCE_SIZE; i++) {
    key += packed[i].toString(16).padStart(2, '0');
  }
  return key;
}

export class PeerConnection {
  private messageCallback: ((message: string) => void) | null = null;
  private disconnectedCallback: (() => void) | null = null;
  private tickCallback: (() => void) | null = null;
  private channel: TcpLineChannel;
  private sessionKey: Uint8Array;
  private lastActivityAt: number = Date.now();
  private heartbeatTimerId: number = -1;
  public readonly peerDeviceId: string;
  // False means: this peer wasn't in the trust store when the handshake
  // ran and its passcode proof (if any) didn't verify: the connection only
  // exists so the user can be asked (see create()). The caller MUST treat
  // this as a live pairing candidate - show an explicit Trust/Ignore prompt
  // fed by this already signature-verified peerDeviceId - rather than handing
  // it straight to SyncManager like an ordinary already-trusted connection.
  public readonly wasAlreadyTrusted: boolean;
  // True only when wasAlreadyTrusted became true because THIS handshake's
  // passphrase proof verified (not because the peer was already in the
  // trust store) - the caller's signal to actually WRITE trust for this
  // peer before treating the connection as normal, same as the LAN beacon's
  // own auto-trust path already does.
  public readonly newlyTrustedViaPassphrase: boolean;
  // What the peer's handshake says it's called, or null if it sent no
  // (usable) DeviceName - e.g. an older build. Fine to show right away, but
  // not to store until onSessionProven.
  public readonly peerName: string | null;
  // The sync protocol the peer's handshake says it speaks: 1 when it says
  // nothing (an older build), see SyncProtocol.peerProtocolOf.
  public readonly peerProtocol: number;
  // Set by the first line that decrypts - see onSessionProven.
  private sessionProven: boolean = false;
  private sessionProvenCallbacks: Array<() => void> = [];

  // The peer has answered: a line from it decrypted, which it only sends once it
  // accepted this device. Before that the peer may still be asking its user.
  get isSessionProven(): boolean {
    return this.sessionProven;
  }
  // The nonce of every envelope this side sends until the session is
  // proven, then null. Both directions share one key with no AAD, so an
  // envelope of ours echoed back would decrypt too - a replayed handshake's
  // sender could "prove" the session with this side's own history batch or
  // ping. listenLoop refuses such a line instead. Keyed by nonceKey.
  private sentNonces: Set<string> | null = new Set<string>();

  private constructor(channel: TcpLineChannel, sessionKey: Uint8Array, peerDeviceId: string, wasAlreadyTrusted: boolean, newlyTrustedViaPassphrase: boolean, peerName: string | null, peerProtocol: number) {
    this.channel = channel;
    this.sessionKey = sessionKey;
    this.peerDeviceId = peerDeviceId;
    this.wasAlreadyTrusted = wasAlreadyTrusted;
    this.newlyTrustedViaPassphrase = newlyTrustedViaPassphrase;
    this.peerName = peerName;
    this.peerProtocol = peerProtocol;
  }

  // The protocol this connection speaks: 2 only if both sides sent 2 or more.
  get protocol(): number {
    return negotiatedProtocol(this.peerProtocol);
  }

  // An untrusted peer's handshake completes once its signature verifies, so
  // the user can be asked, as a dialog or a notification, whether to trust
  // it: the caller who gets back wasAlreadyTrusted=false is responsible for
  // that Trust/Ignore prompt before writing trust, and nothing is trusted by
  // the connection merely existing. (This used to need the Pairing screen
  // open; a request now reaches this device whenever the app is running.) A
  // handshake whose passcode proof verifies against passphraseKeyStore
  // (see newlyTrustedViaPassphrase) is trusted without a question, the same
  // as the LAN beacon's passive auto-trust.
  //
  // isBlocked is asked about the peer's claimed key as soon as it is read,
  // before trust, the passcode proof or anything else: a blocked device gets
  // nothing, however it got here. (It has already been sent this side's
  // handshake line - an acceptor writes first - only a public key and a
  // signature.) A function rather than the store itself: the store compares
  // keys with sameIdentityKey, from this file.
  //
  // ownName: this device's display name to send as DeviceName, or null to
  // leave it out.
  //
  // Returns null (never throws for a bad/malformed peer) on any handshake
  // failure, or for a blocked one - same contract as PeerConnection.cs's
  // CreateAsync.
  static async create(client: TcpLike, myIdentity: DeviceIdentity, trustStore: TrustStore, context: common.UIAbilityContext, isBlocked: (deviceId: string) => Promise<boolean>, passphraseKeyStore: PassphraseKeyStore, ownName: string | null, report?: HandshakeReport): Promise<PeerConnection | null> {
    const channel = new TcpLineChannel(client);

    try {
      const ephemeralKeyGen = cryptoFramework.createAsyKeyGenerator('ECC256');
      const ephemeralKeyPair = await ephemeralKeyGen.generateKeyPair();
      const ephemeralPubBytes = ephemeralKeyPair.pubKey.getEncoded().data;
      const mySignature = await myIdentity.sign(ephemeralPubBytes);
      const myIdentityPublicKey = await myIdentity.getPublicKeyBase64();

      const myKey = await passphraseKeyStore.getKey(context);
      const myProof = myKey !== null ? await passphraseKeyStore.computeProof(myKey, myIdentityPublicKey) : undefined;

      const myHandshake: HandshakeMessage = {
        EphemeralPublicKey: base64Helper.encodeToStringSync(ephemeralPubBytes),
        IdentityPublicKey: myIdentityPublicKey,
        Signature: base64Helper.encodeToStringSync(mySignature),
        PassphraseProof: myProof,
        DeviceName: ownName !== null ? (normalizeDeviceName(ownName) ?? undefined) : undefined,
        Protocol: PROTOCOL_VERSION,
      };
      await channel.writeLine(handshakeLine(myHandshake));

      const theirLineBytes = await channel.readLineWithin(HANDSHAKE_TIMEOUT_MS);
      if (theirLineBytes === null) {
        if (report !== undefined && !channel.isClosed) report.timedOut = true;
        return null;
      }

      let theirHandshake: HandshakeMessage;
      try {
        theirHandshake = JSON.parse(decoder.decodeToString(theirLineBytes)) as HandshakeMessage;
      } catch (e) {
        return null;
      }
      if (!theirHandshake.EphemeralPublicKey || !theirHandshake.IdentityPublicKey || !theirHandshake.Signature) {
        return null;
      }
      // Our own handshake sent back - never a real peer, whichever side
      // dialled. Two of our own connections cross-wired that way derive one
      // key, so each would take the other's lines as proof, out of sight of
      // the per-link sentNonces - and our own passcode proof would even
      // vouch for it. Same check as Android's PeerConnection.handshake, on
      // the key's bytes rather than its text (see sameIdentityKey).
      if (sameIdentityKey(theirHandshake.IdentityPublicKey, myIdentityPublicKey)) {
        return null;
      }

      // Before trust, the passcode proof and anything else: a blocked device
      // is never let in by any of them.
      if (await isBlocked(theirHandshake.IdentityPublicKey)) {
        return null;
      }

      const alreadyTrusted = await trustStore.isTrusted(context, theirHandshake.IdentityPublicKey);
      let passphraseVerified = false;
      if (!alreadyTrusted && myKey !== null && theirHandshake.PassphraseProof) {
        passphraseVerified = await passphraseKeyStore.verifyProof(myKey, theirHandshake.IdentityPublicKey, theirHandshake.PassphraseProof);
      }
      // Not a device we trust or can auto-trust is no longer refused here: it
      // becomes a pairing request (wasAlreadyTrusted = false) that the user
      // answers. Its signature still has to verify below.
      const effectivelyTrusted = alreadyTrusted || passphraseVerified;

      let theirEphemeralPubBytes: Uint8Array;
      let theirSignature: Uint8Array;
      try {
        theirEphemeralPubBytes = base64Helper.decodeSync(theirHandshake.EphemeralPublicKey);
        theirSignature = base64Helper.decodeSync(theirHandshake.Signature);
      } catch (e) {
        return null;
      }

      const verified = await verifyRawSignature(theirHandshake.IdentityPublicKey, theirEphemeralPubBytes, theirSignature);
      if (!verified) return null;

      const theirEphemeralKeyGen = cryptoFramework.createAsyKeyGenerator('ECC256');
      const theirEphemeralKeyPair = await theirEphemeralKeyGen.convertKey({ data: theirEphemeralPubBytes }, null);
      const keyAgreement = cryptoFramework.createKeyAgreement('ECC256');
      const sharedSecret = await keyAgreement.generateSecret(ephemeralKeyPair.priKey, theirEphemeralKeyPair.pubKey);
      // Matches .NET's ecdh.DeriveKeyFromHash(theirPublicKey, SHA256) with
      // no secretPrepend/secretAppend - that's just SHA256(rawSharedSecret).
      const sessionKey = await sha256(sharedSecret.data);

      // Absent, null, empty or not a string: unknown.
      const sentName: string | undefined = theirHandshake.DeviceName;
      const theirName: string | null = typeof sentName === 'string' ? normalizeDeviceName(sentName) : null;
      return new PeerConnection(channel, sessionKey, theirHandshake.IdentityPublicKey, effectivelyTrusted, passphraseVerified, theirName,
        peerProtocolOf(theirHandshake.Protocol));
    } catch (e) {
      return null;
    }
  }

  // The Base64 is made off the UI thread (Base64Helper's promise form runs
  // on a worker), as the read loop's decoding is: a history batch of images
  // is tens of MB of it.
  async send(message: string): Promise<void> {
    const packed: Uint8Array = await AesGcm.encryptPacked(this.sessionKey, message);
    // Before the write, so its echo can't arrive ahead of it.
    const nonce: string | null = nonceKey(packed);
    if (this.sentNonces !== null && nonce !== null) this.sentNonces.add(nonce);
    await this.channel.writeLine(await base64Helper.encodeToString(packed));
  }

  onMessage(callback: (message: string) => void): void {
    this.messageCallback = callback;
  }

  onDisconnected(callback: () => void): void {
    this.disconnectedCallback = callback;
  }

  // Called with every heartbeat tick (every HEARTBEAT_INTERVAL_MS while the
  // connection is up), for checks that need a clock but not a timer of their
  // own - SyncManager's request timeouts.
  onTick(callback: () => void): void {
    this.tickCallback = callback;
  }

  // Called once, when the first envelope on this connection (data or
  // heartbeat) decrypts with the session key - right away if one already
  // has. The handshake's signature covers only the ephemeral key, so a
  // captured handshake can be replayed with any DeviceName; only the real
  // peer can then produce a line that decrypts (one of this side's own
  // echoed back doesn't count - see sentNonces). Whatever the handshake
  // claims that gets written to disk (its name) waits for this.
  onSessionProven(callback: () => void): void {
    this.sessionProvenCallbacks.push(callback);
    if (this.sessionProven) callback();
  }

  // Call BEFORE listen(), after dialling someone to pair. Both sides send
  // their half of the handshake before deciding whether to accept the
  // other, so a peer that refuses this device still completes the
  // handshake from here - its refusal only shows up as the socket closing
  // just after. Every client sends its history the moment it accepts a
  // link, so: 'accepted' = a line arrived, 'closed' = refused, 'quiet' =
  // it's holding the connection as a pairing request awaiting Accept.
  waitForPeerVerdict(timeoutMs: number): Promise<PeerVerdict> {
    return this.channel.waitForActivity(timeoutMs);
  }

  // The socket has closed - e.g. a held pairing request whose other side
  // rejected or gave up while this side's Accept prompt was still showing.
  get isClosed(): boolean {
    return this.channel.isClosed;
  }

  // Starts the read loop - fire-and-forget, matches PeerConnection.cs's
  // Listen() being kicked off without awaiting it. ANY failure (clean
  // close, corrupt/forged line that fails to decrypt) ends the whole
  // connection, same as the Windows side's single catch-all. Also starts
  // the heartbeat - both begin together since a connection isn't "live"
  // for either purpose until this point.
  listen(): void {
    void this.listenLoop();
    this.startHeartbeat();
  }

  private async listenLoop(): Promise<void> {
    let failed = false;
    try {
      while (true) {
        const line = await this.channel.readLine();
        if (line === null) break;
        // Decoded once: the nonce checked is the one decrypted with (see
        // nonceKey). Checked before decrypting: an echo of this side's own
        // envelope would decrypt (see sentNonces), and must neither prove
        // the session nor count as activity for the heartbeat watchdog.
        // Decoded from the line's bytes, on a worker (the promise form):
        // decodeSync held the UI thread for 0.4 s on a 16 MB history
        // batch, right as the peer was about to count as connected.
        const packed: Uint8Array = await base64Helper.decode(line);
        const nonce: string | null = nonceKey(packed);
        if (this.sentNonces !== null && nonce !== null && this.sentNonces.has(nonce)) {
          throw new Error('reflected line');
        }
        const decrypted = await AesGcm.decryptPacked(this.sessionKey, packed);
        this.lastActivityAt = Date.now();
        if (!this.sessionProven) this.markSessionProven();
        if (decrypted === PING_SENTINEL) continue; // heartbeat only, not real data
        this.messageCallback?.(decrypted);
      }
    } catch (e) {
      // abrupt disconnect, a corrupt/forged line that failed to decrypt,
      // or an unproven session's own envelope echoed back
      failed = true;
    } finally {
      const idleMs: number = Date.now() - this.lastActivityAt;
      // Stops the heartbeat and closes the socket: a loop that ended on a
      // reflected or undecryptable line would otherwise leave the peer an
      // open, silent connection. Closing one that's already closed is
      // harmless (see TcpLineChannel.close).
      this.close();
      this.disconnectedCallback?.();
      // Logged after the teardown, so logging can never stop it. idleMs
      // over HEARTBEAT_TIMEOUT_MS means this side's own watchdog closed the
      // link; a small idleMs means the peer (or a superseding connection,
      // see SyncManager.registerConnection) closed it.
      hilog.info(0x0001, 'ClipLinkNet', '%{public}s',
        `conn closed: peer=${deviceFingerprint(this.peerDeviceId)} idleMs=${idleMs} failed=${failed}`);
    }
  }

  private markSessionProven(): void {
    this.sessionProven = true;
    this.sentNonces = null; // the peer holds the key - nothing left to tell apart
    for (const callback of this.sessionProvenCallbacks) {
      try {
        callback();
      } catch (e) {
        // a listener's failure must never end the read loop
      }
    }
  }

  // The first ping goes at once, ahead of the history batch that follows
  // listen() (see SyncManager.registerConnection): the peer counts this
  // device as connected on the first line that decrypts, and a ping is a
  // few dozen bytes where the batch can be tens of MB and seconds in
  // transit. Every build filters pings out, so an early one costs nothing.
  private startHeartbeat(): void {
    void this.send(PING_SENTINEL).catch(() => { /* as below */ });
    this.heartbeatTimerId = setInterval(() => {
      void this.send(PING_SENTINEL).catch(() => { /* a send failure will also surface via the read loop dying */ });
      try {
        this.tickCallback?.();
      } catch (e) {
        // a listener's failure must never stop the heartbeat
      }
      if (Date.now() - this.lastActivityAt > HEARTBEAT_TIMEOUT_MS) {
        // Nothing at all (ping or real data) for HEARTBEAT_TIMEOUT_MS -
        // the peer is gone even though TCP itself hasn't noticed yet.
        // Closing here is what actually makes isConnected()/connectedCount
        // reflect reality, instead of a connection nothing will ever mark
        // dead until some much longer OS-level timeout eventually does.
        this.close();
      }
    }, HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimerId !== -1) {
      clearInterval(this.heartbeatTimerId);
      this.heartbeatTimerId = -1;
    }
  }

  close(): void {
    this.stopHeartbeat();
    this.channel.close();
  }
}
