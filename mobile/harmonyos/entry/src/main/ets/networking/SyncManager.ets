// Step 8/10 of the build order in ../../../../README.md: full sync + file
// transfer. Mirrors Program.cs's HandleMessage/SendHistoryBatch/
// ClipboardChanged/HandleFileChunk/HandleFileRequest/StreamFileToPeer. What is
// done with the history messages (head, batch, request, delete) is in
// HistorySync.ets; this class gives it the history, the clipboard and the files.

import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PeerConnection, exactBuffer } from './PeerConnection';
import { ProgressThrottle, TransferPhase, TransferUpdate } from './TransferProgress';
import { BatchApplied, HeadApplied, HistorySync, SyncApplied, SyncLink } from './HistorySync';
import { ChunkPlace, placeChunk } from './ChunkOrder';
import { joinFileChunk } from './ChunkSplit';
import { decodeBase64 } from '../crypto/Base64Bytes';
import { releaseBuffer } from './FreeOnWorker';
import { FileChunkMessage } from './FileChunkMessage';
import { FileRequestMessage } from './FileRequestMessage';
import {
  ACK_TIMEOUT_MS, AckWindow, ChunkSender, FILE_ACK_TYPE, FileAck, HandedChunk, PumpEnd, StallVerdict, fileAckFor, parseFileAck, pumpChunks,
  stallVerdict
} from './FileFlow';
import { TrustStore } from '../identity/TrustStore';
import { shortDeviceId } from '../identity/DeviceName';
import { HistoryAccess } from '../storage/HistoryAccess';
import { MergeResult } from '../storage/HistoryBatch';
import { EMPTY_FILE_HASH, FileStore, hexString, isEmptyFile, isValidFileHash, removeIfThere, sha256File } from '../storage/FileStore';
import { FilePayload } from '../storage/FilePayload';
import { entryKey } from '../storage/DeletedEntries';
import { contentKey, primeContentKeys } from '../storage/ContentPrint';
import { ClipboardEntry, verifiedEntry } from '../crypto/Signing';
import { ApplyResult, ClipboardWrite, writeEntryToClipboard } from '../clipboard/ClipboardApply';
import { pasteboardChangeCount } from '../clipboard/ClipboardWatcher';
import { pendingFileMayApply } from './PendingFiles';

const base64Helper = new util.Base64Helper();
const CHUNK_SIZE = 256 * 1024;
// See requestAgain. Same as Android's SyncManager.MAX_RETRIES.
const MAX_RETRIES = 3;
// How many of a file's chunks streamFileToPeer has on their way at once:
// while one is written to the socket, the next is read, encoded and
// encrypted. One at a time, the radio sat idle while each chunk was made
// (the socket's send buffer, 256 KB, is smaller than one 466 KB line).
const SEND_WINDOW = 3;
// How many of an incoming stream's chunks may be decoding or waiting to be
// written before the connection's reading is held (see handleFileChunk).
const CHUNK_BACKLOG = 4;
// How many times a connection may be closed for its queue (see
// PeerConnection's SESSION_QUEUE_MAX_BYTES) while it streams the same file
// before that file is no longer asked for on this run. Its sender starts
// over at chunk 0 and sends just as fast each time, so the queue fills at
// the same point again: asking on every reconnect only tore the session
// down over and over and never brought the file.
const MAX_QUEUE_CLOSURES = 2;

// What asking for a file again came to (see requestAgain): asked, no device
// to ask, stopped (retries used up, or too big to take in, with devices
// still connected), or not needed (stored, arriving from someone, or no
// longer wanted).
type RequestOutcome = 'asked' | 'noDevice' | 'stopped' | 'notNeeded';

// A chunk's bytes: already decoded when its line was opened (see
// LineOpener), or, for a chunk that arrived whole as text (an older sender's
// spelling, see ChunkSplit), decoded from its Base64 now, on a worker (see
// Base64Bytes.ets). Never throws: a chunk that is not Base64 - or has no
// DataBase64 at all, or a number or object there - comes back as a rejected
// promise, so its transfer fails and is asked for again.
async function decodeChunk(data: string | Uint8Array): Promise<Uint8Array> {
  if (data instanceof Uint8Array) return data;
  if (typeof data !== 'string') throw new Error('file chunk has no DataBase64');
  // An empty file's only chunk is empty (see streamFileToPeer).
  if (data.length === 0) return new Uint8Array(0);
  return decodeBase64(data);
}
interface Envelope {
  Type: string;
  Payload: string;
}

// A send nobody waits on. Its failure is caught (it was an unhandled
// rejection) and dropped: a socket that closes mid-send is routine, and the
// read loop ending is what reports the link gone.
function sendQuietly(conn: PeerConnection, json: string): void {
  conn.send(json).catch(() => { /* the read loop reports the link gone */ });
}

// What JSON.parse gave is an object, not null, a number or a string - what a
// peer's envelope and entry must be before anything reads their fields.
function isObject(value: Object | null | undefined): boolean {
  return value !== null && value !== undefined && typeof value === 'object';
}

// A file entry's hash, as it spells it, or null if its description does not
// hold a real one.
function fileHashOf(entry: ClipboardEntry): string | null {
  try {
    const payload: FilePayload = JSON.parse(entry.Content) as FilePayload;
    return isObject(payload) && isValidFileHash(payload.FileHash) ? payload.FileHash : null;
  } catch (e) {
    return null;
  }
}

// A file entry that goes on the clipboard once its bytes are here: when it
// was set to (armedAt, ms since the epoch), and the pasteboard's change count
// then (generation). The bytes landing much later, or after anything else
// went on the clipboard, only store them (see tryFulfillPendingEntry).
interface PendingFile {
  entry: ClipboardEntry;
  // As the entry spells it: what is asked for (an older peer may only find
  // its blob under that spelling).
  fileHash: string;
  armedAt: number;
  generation: number;
}

// What the page does around a clipboard write (see setClipboardHooks).
export interface ClipboardHooks {
  // Whether the clipboard holds this entry's content already, as far as
  // ClipLink knows (it wrote it, or sent it, last): it is not written again,
  // and nobody is told.
  holds: (entry: ClipboardEntry) => boolean;
  // A write of a received entry succeeded, with the prints of what is on the
  // clipboard now: the change is ClipLink's own.
  wrote: (entry: ClipboardEntry, prints: string[]) => void;
  // Before an automatic write: a copy made here and not dealt with yet goes
  // out first, so the write does not bury it unsent. Runs inside the
  // clipboard lock (see withClipboard), so it must not take it again.
  beforeWrite: () => Promise<void>;
}

// One file's bytes arriving over one connection (see handleFileChunk),
// written to a temp file of its own until IsLast.
interface IncomingTransfer {
  fileHash: string;
  conn: PeerConnection;
  fd: number;
  tempPath: string;
  // The next chunk this stream takes, counted as chunks arrive (before they
  // are decoded and written).
  nextIndex: number;
  // The chunks taken and not yet written, each one's write step, oldest
  // first. They are written one after another, in the order they came.
  pending: Promise<void>[];
  // Where the next chunk's write joins the queue: after the last one's.
  tail: Promise<void>;
  // Bytes written so far.
  received: number;
  // The SHA-256 of what has been written, kept up chunk by chunk, so the
  // file is not read back whole at the end. null if the digest failed on
  // the way: then the file is read once more, as it used to be.
  md: cryptoFramework.Md | null;
  // Given up on (see abortTransfer): its chunks still queued are dropped.
  aborted: boolean;
  // Given up on because one of its own chunks could not be decoded or
  // written (see failTransfer), as opposed to a restart or its connection
  // closing.
  failed: boolean;
  throttle: ProgressThrottle;
  startedAt: number;
  // When the stream's last chunk was taken, for a sender that paces its
  // streams and may have given this one up (see checkStalledStreams).
  lastChunkAt: number;
}

// One file this side is sending to a receiver that acknowledges chunks (see
// FileFlow.ets), so that its file_acks find the stream's window.
interface OutgoingStream {
  conn: PeerConnection;
  acks: AckWindow;
}

// One file's chunks read from disk and sent to one peer, for pumpChunks (see
// streamFileToPeer). One buffer for the whole file: each chunk is encoded
// before the next read overwrites it.
class FileChunkSender implements ChunkSender {
  private readonly conn: PeerConnection;
  private readonly file: fs.File;
  private readonly fileHash: string;
  private readonly totalSize: number;
  private readonly buffer: ArrayBuffer = new ArrayBuffer(CHUNK_SIZE);
  private sentBytes: number = 0;
  // A send failed (the peer gone): the ones still on their way fail the same
  // way and are only waited out.
  private failed: boolean = false;

  constructor(conn: PeerConnection, file: fs.File, fileHash: string, totalSize: number) {
    this.conn = conn;
    this.file = file;
    this.fileHash = fileHash;
    this.totalSize = totalSize;
  }

  more(): boolean {
    return this.sentBytes < this.totalSize && !this.failed && !this.conn.isClosed;
  }

  async send(index: number): Promise<HandedChunk | null> {
    const bytesRead = fs.readSync(this.file.fd, this.buffer);
    if (bytesRead <= 0) return null;
    this.sentBytes += bytesRead;
    // The last, short chunk is copied out: the encoder is handed exactly its
    // bytes, never the rest of the buffer.
    const chunkBytes = bytesRead === CHUNK_SIZE ? new Uint8Array(this.buffer) : new Uint8Array(this.buffer.slice(0, bytesRead));
    // The same bytes as the envelope JSON.stringify makes, without the
    // Base64 ever being a string (see ChunkSplit.joinFileChunk).
    const data: Uint8Array = await base64Helper.encode(chunkBytes);
    const message: Uint8Array = joinFileChunk(this.fileHash, index, this.sentBytes >= this.totalSize, data);
    // Copied into the message, which sendBytes frees once encrypted (see
    // SpentBuffers).
    releaseBuffer(data.buffer as ArrayBuffer);
    const handed: HandedChunk = { written: this.conn.sendBytes(message).catch(() => { this.failed = true; }) };
    return handed;
  }
}

export class SyncManager {
  private connections: Map<string, PeerConnection> = new Map();
  private history: HistoryAccess;
  private trustStore: TrustStore;
  private context: common.UIAbilityContext;
  private fileStore: FileStore;
  private entryAppliedCallback: ((entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => void) | null = null;
  private batchAppliedCallback: ((batch: BatchApplied) => void) | null = null;
  private headAppliedCallback: ((head: HeadApplied) => void) | null = null;
  private syncAppliedCallback: ((sync: SyncApplied) => void) | null = null;
  private headSettledCallback: ((from: string) => void) | null = null;
  private entriesDeletedCallback: ((keys: string[]) => void) | null = null;
  private entriesEvictedCallback: ((keys: string[]) => void) | null = null;
  private fileStoredCallback: ((fileHash: string) => void) | null = null;
  private entryWaitingCallback: ((entry: ClipboardEntry) => void) | null = null;
  private transferProgressCallback: ((update: TransferUpdate) => void) | null = null;
  private logCallback: ((message: string) => void) | null = null;
  private connectionsChangedCallback: ((count: number) => void) | null = null;
  private unpairedCallback: ((deviceId: string) => void) | null = null;

  // In-progress incoming chunk streams, keyed `${peerDeviceId}:${fileHash}`
  // like streamingInFlight - the fd stays open across every "file_chunk"
  // message for that hash from that peer until IsLast. Keyed by hash alone,
  // two peers answering one file_request (it goes to every peer) were
  // written into one file, which then failed verification. Each stream has
  // its own file, and only the first sender's stream of a file is taken
  // (see placeChunk's otherSender); a sender that starts over on a newer
  // connection still replaces its own older stream.
  private incoming: Map<string, IncomingTransfer> = new Map();
  // Streams whose last chunk has arrived and that are being written out,
  // checked and stored, by lowercase hash (a count). Off `incoming` already
  // (see handleFileChunk), but still arriving as far as anyone asking is
  // concerned (see isReceiving).
  private finishing: Map<string, number> = new Map();
  // Entries that arrived (and verified) before their bytes finished
  // streaming in, keyed by the file hash they're waiting on, in lowercase:
  // senders differ in case (iOS sends uppercase), and bytes stored under
  // either spelling fulfil the entry.
  private pendingEntries: Map<string, PendingFile> = new Map();
  // File hashes (lowercase) whose waiting entry was deleted or cleared before
  // the bytes finished arriving - see handleFileChunk.
  private abandonedHashes: Set<string> = new Set();
  // Reading and writing the clipboard happen one at a time: the page's capture
  // (from the read to the record of what was read) and every write of a
  // received entry (from the write to the record of what was written). A
  // capture could otherwise read a received item in the moment between its
  // write and that record, and send it back as a copy of this device's own.
  private clipboardChain: Promise<void> = Promise.resolve();
  private clipboardHooks: ClipboardHooks | null = null;
  // Live entries are dealt with one at a time, in the order they came: a
  // picture takes far longer to check and write than text, and a copy made
  // a second after it otherwise got there first and was buried by it.
  private liveWork: Promise<void> = Promise.resolve();
  // How often each file (lowercase hash) has been asked for again after a
  // transfer of it came to nothing - see requestAgain.
  private retries: Map<string, number> = new Map();
  // How often a connection was closed for its queue while it streamed each
  // file (lowercase hash) - see MAX_QUEUE_CLOSURES. Kept for the run.
  private queueClosures: Map<string, number> = new Map();
  // Guards against streaming the same file to the same peer twice at once
  // (key: `${peerDeviceId}:${fileHash}`) - broadcastEntry proactively
  // streams a freshly-captured file right after sending its entry, but the
  // receiving side (handleIncomingFileEntry) ALSO unconditionally
  // broadcasts a file_request the moment it sees an entry it doesn't have
  // bytes for yet, regardless of whether the sender is already streaming.
  // Without this guard, that redundant request makes the sender start a
  // SECOND concurrent stream of the same file over the same connection,
  // and the two chunk sequences interleave on the wire - which is what
  // "file transfer failed hash verification" actually was.
  private streamingInFlight: Set<string> = new Set();
  // The streams under way to receivers that acknowledge chunks, keyed
  // `${peerDeviceId}:${fileHash}` with the hash in lowercase (a receiver
  // echoes the hash as it got it, and another build may write it in
  // capitals). A file_ack that names no stream here is ignored.
  private outgoing: Map<string, OutgoingStream> = new Map();
  // "Copy received items automatically" (DeviceSettings.getAutoApply). Off,
  // a received entry is still verified, recorded and reported to the UI -
  // only the write to the system pasteboard is skipped.
  private autoApply: boolean = true;
  // What is done with the history messages (heads, batches, requests, deletes).
  private sync: HistorySync;
  // Numbers the connections (SyncLink.id).
  private linkSerial: number = 0;

  constructor(fileStore: FileStore, trustStore: TrustStore, context: common.UIAbilityContext) {
    this.history = new HistoryAccess(fileStore);
    this.history.onEvicted((keys: string[]) => { this.entriesEvictedCallback?.(keys); });
    this.history.onSaveFailed((message: string) => { this.logCallback?.(message); });
    this.trustStore = trustStore;
    this.context = context;
    this.fileStore = fileStore;
    this.sync = new HistorySync({
      verified: (entry: ClipboardEntry) => this.verifiedAndTrusted(entry),
      getHistory: () => this.history.getHistory(this.context),
      deletedKeys: (limit: number) => this.history.recentDeleted(this.context, limit),
      goneKeys: (keys: string[]) => this.history.goneKeys(this.context, keys),
      isDeleted: (entry: ClipboardEntry) => this.history.isDeleted(this.context, entry),
      // The pictures' keys first, off the UI thread (see primeContentKeys):
      // the list asks for them as it makes the cards.
      addBatch: async (candidates: ClipboardEntry[], newFront: boolean,
        frontOk: (entry: ClipboardEntry, localNewest: string | null) => boolean): Promise<MergeResult> => {
        await primeContentKeys(candidates);
        return this.history.addBatch(this.context, candidates, newFront, frontOk);
      },
      deleteKeys: (keys: string[]) => this.dropEntries(keys),
      applyToClipboard: (entry: ClipboardEntry) => this.applyToClipboard(entry),
      prepareFile: (entry: ClipboardEntry, applyWhenStored: boolean) => this.prepareFileEntry(entry, applyWhenStored),
      wait: (ms: number) => new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); }),
      now: () => Date.now(),
      log: (message: string) => { this.logCallback?.(message); },
      headApplied: (head: HeadApplied) => { this.headAppliedCallback?.(head); },
      batchApplied: (batch: BatchApplied) => { this.batchAppliedCallback?.(batch); },
      syncApplied: (sync: SyncApplied) => { this.syncAppliedCallback?.(sync); },
      settled: (link: string) => { this.headSettledCallback?.(link); },
      deleted: (keys: string[]) => { this.entriesDeletedCallback?.(keys); },
    });
  }

  onEntryApplied(callback: (entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => void): void {
    this.entryAppliedCallback = callback;
  }

  // A peer's history_batch has been dealt with, as ONE unit: called once for
  // the whole batch (not at all for a batch that added nothing), after all of
  // its entries are in the history. Not called for a live entry - that is
  // onEntryApplied.
  onBatchApplied(callback: (batch: BatchApplied) => void): void {
    this.batchAppliedCallback = callback;
  }

  // A peer's history_head (of the old kind, from a device that does not speak
  // sync v2) has been dealt with: its newest item is in the history and the UI
  // is told, once, with the number of items to expect. Only called when that
  // item was new.
  onHeadApplied(callback: (head: HeadApplied) => void): void {
    this.headAppliedCallback = callback;
  }

  // The answer to one of this device's history_requests (sync v2) has been
  // dealt with, as ONE unit like a batch: called once, after its entries are in
  // the history, and not at all when it added nothing.
  onSyncApplied(callback: (sync: SyncApplied) => void): void {
    this.syncAppliedCallback = callback;
  }

  // What the UI showed in expectation of more items is final now: the
  // history_batch a head announced is over - it added nothing new, or the
  // connection closed before it came - or a v2 sync's last request was
  // answered with nothing, or given up on, or its connection closed. The
  // argument is the connection's id, as in the events above. (Not called when
  // the last batch or answer added items: that is onBatchApplied or
  // onSyncApplied.)
  onHeadSettled(callback: (from: string) => void): void {
    this.headSettledCallback = callback;
  }

  // A peer deleted these items (a delete message, or the tombstones in its
  // head): they are gone from the history, and the list is to drop them.
  onEntriesDeleted(callback: (keys: string[]) => void): void {
    this.entriesDeletedCallback = callback;
  }

  // The history's cap pushed these items (by entryKey) out: the list drops
  // them too, so it never shows more than the history holds.
  onEntriesEvicted(callback: (keys: string[]) => void): void {
    this.entriesEvictedCallback = callback;
  }

  setClipboardHooks(hooks: ClipboardHooks): void {
    this.clipboardHooks = hooks;
  }

  // Runs `work` with the clipboard to itself (see clipboardChain). For the
  // page's capture; the writes of received entries take it themselves.
  withClipboard<T>(work: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.clipboardChain.then(work);
    this.clipboardChain = result.then(() => {}, () => {});
    return result;
  }

  // A file's bytes arrived that no newly received entry was waiting on - an
  // older item's, asked for again (see requestMissingFiles). Its card can
  // show what it now has (an image's preview, say). Android's onFileStored.
  onFileStored(callback: (fileHash: string) => void): void {
    this.fileStoredCallback = callback;
  }

  // A live file entry whose bytes are not here yet and are being fetched: the
  // page lists it now, as a file that is arriving, instead of only once the
  // last byte is stored (it had no card at all until then, and none ever if
  // the stream never finished). It is reported again through onEntryApplied
  // when its bytes are stored.
  onEntryWaiting(callback: (entry: ClipboardEntry) => void): void {
    this.entryWaitingCallback = callback;
  }

  // How a file's bytes are getting on (see TransferProgress.ets): at a
  // stream's start, at most every PROGRESS_INTERVAL_MS while it runs, at its
  // last chunk, when it is stored, and when it fails. Never from the history
  // or the list: the page keeps this apart from them.
  onTransferProgress(callback: (update: TransferUpdate) => void): void {
    this.transferProgressCallback = callback;
  }

  onLog(callback: (message: string) => void): void {
    this.logCallback = callback;
  }

  // A trusted peer said it no longer trusts this device (it was removed there, or
  // its request was ignored there). The argument is the peer's id: Index drops its
  // trust record here too, so the peer stops being redialled and stops asking.
  onUnpaired(callback: (deviceId: string) => void): void {
    this.unpairedCallback = callback;
  }

  // The connections Map lives entirely inside this class - a plain
  // JS Map's mutations aren't observable by ArkUI's @State reactivity, so
  // without this callback the UI's connected-device count never updates
  // even though connectionCount itself was always correct if you happened
  // to re-read it. Fired on every add (registerConnection) and remove
  // (peer disconnect).
  onConnectionsChanged(callback: (count: number) => void): void {
    this.connectionsChangedCallback = callback;
  }

  setAutoApply(value: boolean): void {
    this.autoApply = value;
  }

  getHistory(): Promise<ClipboardEntry[]> {
    return this.history.getHistory(this.context);
  }

  // Once, at startup: FileStore's blobs that no history entry points at any
  // more go (see HistoryAccess.deleteUnreferencedFiles) - left by items
  // deleted or evicted while their bytes were on the way, bytes streamed for
  // an entry this device dropped, and transfers the app was killed in the
  // middle of. A transfer running meanwhile is never touched.
  async deleteUnreferencedFiles(): Promise<void> {
    try {
      const deleted: number = await this.history.deleteUnreferencedFiles(this.context);
      if (deleted > 0) this.logCallback?.(`deleted ${deleted} unused file(s) from storage`);
    } catch (e) {
      this.logCallback?.(`could not tidy file storage (${e})`);
    }
  }

  // pendingEntries is cleared too: otherwise a file whose bytes finish
  // arriving after this would still fire entryAppliedCallback and the
  // cleared item would pop back into the list. Everything cleared is
  // tombstoned (listedKeys: what the UI still shows beyond the capped
  // history), so a peer's history_batch on its next reconnect can't re-add
  // it. The clipboard isn't touched. Peers that speak sync v2 are told to
  // delete the items too; the others keep theirs.
  async clearHistory(listedKeys: string[]): Promise<void> {
    const keys: string[] = listedKeys.slice();
    this.pendingEntries.forEach((pending: PendingFile, fileHash: string) => {
      keys.push(entryKey(pending.entry));
      this.abandonedHashes.add(fileHash);
    });
    this.pendingEntries.clear();
    const cleared: string[] = await this.history.clearHistory(this.context, keys);
    this.sync.broadcastDelete(cleared);
  }

  // One item, by entryKey - same rules as clearHistory.
  async deleteEntry(key: string): Promise<void> {
    await this.deleteEntries([key]);
  }

  // Several items at once (a card and its twins, see twinKeys): one delete
  // message with every key goes to v2 peers.
  async deleteEntries(keys: string[]): Promise<void> {
    await this.dropEntries(keys);
    this.sync.broadcastDelete(keys);
  }

  // The keys of every history entry with the same content as `key`'s (see
  // storage/ContentPrint.ets), `key` included: a card stands for all of them
  // (the list shows one card per content), so deleting it deletes them all.
  async twinKeys(key: string): Promise<string[]> {
    const history: ClipboardEntry[] = await this.history.getHistory(this.context);
    const entry: ClipboardEntry | undefined = history.find((e: ClipboardEntry) => entryKey(e) === key);
    const print: string | null = entry !== undefined ? contentKey(entry) : null;
    if (print === null) return [key];
    const keys: string[] = history.filter((e: ClipboardEntry) => contentKey(e) === print).map((e: ClipboardEntry) => entryKey(e));
    return keys.includes(key) ? keys : [key, ...keys];
  }

  // Deletes these items (by entryKey) from this device: tombstoned, out of the
  // history, their files gone unless another entry uses them. A file entry
  // still waiting for its bytes is dropped too, so their arrival can't re-list
  // it. Used for the user's own delete and for a peer's.
  private async dropEntries(keys: string[]): Promise<void> {
    const gone: Set<string> = new Set<string>(keys);
    const waiting: string[] = [];
    this.pendingEntries.forEach((pending: PendingFile, fileHash: string) => {
      if (gone.has(entryKey(pending.entry))) waiting.push(fileHash);
    });
    for (const fileHash of waiting) {
      this.pendingEntries.delete(fileHash);
      this.abandonedHashes.add(fileHash);
    }
    await this.history.deleteEntries(this.context, keys);
  }

  get connectionCount(): number {
    return this.connections.size;
  }

  isConnected(deviceId: string): boolean {
    return this.connections.has(deviceId);
  }

  // Linked and answered: the peer accepted this device (its first line decrypted). A
  // device that is trusted here and was dialled may be linked without that - the peer
  // may still be asking its user - and is not "connected" for the Devices tab.
  isProven(deviceId: string): boolean {
    const conn: PeerConnection | undefined = this.connections.get(deviceId);
    return conn !== undefined && conn.isSessionProven;
  }

  get provenCount(): number {
    let count: number = 0;
    this.connections.forEach((conn: PeerConnection) => { if (conn.isSessionProven) count++; });
    return count;
  }

  // Wires up a freshly-handshaken connection into ongoing sync: registers
  // it, starts listening, and tells the peer what we have - same sequence
  // Program.cs runs right after both the accept loop and ConnectToPeer
  // complete a handshake. With a peer that speaks sync v2 that is a head and
  // nothing else; the peer asks for what it is missing (see HistorySync).
  registerConnection(conn: PeerConnection): void {
    const previous = this.connections.get(conn.peerDeviceId);
    this.connections.set(conn.peerDeviceId, conn);
    this.connectionsChangedCallback?.(this.connections.size);
    this.linkSerial++;
    const link: SyncLink = new SyncLink(`link-${this.linkSerial}`, shortDeviceId(conn.peerDeviceId), conn.protocol,
      (json: string) => conn.send(json));
    this.sync.open(link);
    // The peer answering changes what the Devices tab shows (waiting -> connected).
    conn.onSessionProven(() => { this.connectionsChangedCallback?.(this.connections.size); });
    // Caught here: anything that throws in handling a message (a history
    // that won't save, a payload that isn't what it says) was an unhandled
    // rejection that never reached the activity log.
    conn.onMessage((msg: string, data: Uint8Array | null) => {
      this.handleMessage(msg, conn, link, data).catch((e: Error) => {
        this.logCallback?.(`could not deal with a message from ${shortDeviceId(conn.peerDeviceId)} (${e})`);
      });
    });
    conn.onTick(() => {
      this.sync.expire(link);
      this.checkStalledStreams(conn);
    });
    conn.onDisconnected(() => {
      // Whatever it still owed, and a stack that waited for it.
      this.sync.close(link);
      // A stream to it that waits for an acknowledgement stops now, instead
      // of holding its place (see streamingInFlight) for the whole timeout:
      // the peer's next connection asks for the file again, and that request
      // would otherwise be ignored as a stream already under way.
      this.outgoing.forEach((stream: OutgoingStream) => {
        if (stream.conn === conn) stream.acks.cancel();
      });
      // Its streams are dead whether or not it was replaced - see
      // dropTransfersFrom.
      const cutOff: string[] = this.dropTransfersFrom(conn);
      // Closed because its sender was far ahead of this side: counted per
      // file, so one that cannot be taken in at its sender's pace is not
      // asked for forever (see MAX_QUEUE_CLOSURES).
      if (conn.queueOverflowed) {
        for (const fileHash of cutOff) this.noteQueueClosure(fileHash);
      }
      // Only evict if the map still points at THIS connection. Removing by
      // peerDeviceId alone meant a stale link's teardown deleted the newer,
      // live connection that had replaced it - after which isConnected()
      // said false, so the next 2-second discovery beacon dialled again,
      // and the whole thing looped forever without clipboard ever flowing.
      // The Windows daemon carries the identical guard (Program.cs's
      // Disconnected handler); both ends need it or the other end's churn
      // keeps the loop alive.
      if (this.connections.get(conn.peerDeviceId) === conn) {
        this.connections.delete(conn.peerDeviceId);
        this.connectionsChangedCallback?.(this.connections.size);
        this.logCallback?.(`peer disconnected: ${shortDeviceId(conn.peerDeviceId)}`);
      }
      // Nobody resumes a broken stream on their own, so a file still wanted
      // is asked for again - here from whoever's left, and from the next
      // connection to come up (see requestMissingFiles) if that's nobody.
      const others: PeerConnection[] = this.connectionsExcept(conn);
      for (const fileHash of cutOff) {
        this.retryFile(fileHash, others).catch((e: Error) => { this.logCallback?.(`could not ask for a file again (${e})`); });
      }
    });
    conn.listen();
    this.sync.announce(link).catch((e: Error) => {
      this.logCallback?.(`could not tell ${shortDeviceId(conn.peerDeviceId)} what this device has (${e})`);
    });
    this.requestMissingFiles(conn).catch((e: Error) => { this.logCallback?.(`could not ask for missing files (${e})`); });
    if (previous !== undefined && previous !== conn) {
      // A second connection to this same peer just replaced the first one
      // in the map (duplicate connections happen when a beacon-triggered
      // dial races one already in flight - see the connectingTo guards in
      // Index.ets). Without this, `previous` was left alive as an orphan:
      // its own read loop and heartbeat kept running even though nothing
      // sent on it anymore, and this device's own map already pointed at
      // the new connection - but the PEER on the other end of that orphaned
      // socket has no idea it's been superseded, and may still consider IT
      // the canonical connection. That split-brain (each side treating a
      // different one of the duplicate sockets as "the" connection) is what
      // actually produced "Devices tab shows not connected, but sync still
      // works" (the orphan was still relaying data) and connections
      // appearing to drop later (whichever side's orphan eventually noticed
      // the other end had stopped using it). Closing it here immediately -
      // instead of waiting for its own heartbeat to eventually notice -
      // means there is only ever one live socket per peer, on both ends.
      previous.close();
    }
  }

  // Closes the connection to a device that's just been removed (see Index's
  // untrustDevice), as Windows' UntrustDevice does - left open, the
  // heartbeat kept it up, and it went on receiving everything this device
  // sent and could still ask for any stored file. Off the map first, so the
  // count updates now and its teardown (onDisconnected) leaves the map be.
  disconnect(deviceId: string): void {
    const conn: PeerConnection | undefined = this.connections.get(deviceId);
    if (conn === undefined) return;
    this.connections.delete(deviceId);
    this.connectionsChangedCallback?.(this.connections.size);
    conn.close();
  }

  // disconnect for a device that has just been removed, which tells it first that
  // it is no longer trusted here: it drops this device too and stops redialling
  // (its onUnpaired). Best effort - a peer that is gone, or a build that does not
  // know the message, is left to Index's RequestQuiet.
  unpair(deviceId: string): void {
    const conn: PeerConnection | undefined = this.connections.get(deviceId);
    if (conn === undefined) return;
    this.connections.delete(deviceId);
    this.connectionsChangedCallback?.(this.connections.size);
    void this.unpairAndClose(conn);
  }

  // unpair for a link that is not registered, such as a pairing request that is
  // being ignored.
  async unpairAndClose(conn: PeerConnection): Promise<void> {
    const envelope: Envelope = { Type: 'unpair', Payload: '{}' };
    try {
      await conn.send(JSON.stringify(envelope));
      // Let it leave before the socket goes.
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
    } catch (e) {
      this.logCallback?.(`could not tell ${shortDeviceId(conn.peerDeviceId)} it was removed`);
    }
    conn.close();
  }

  // Signs, broadcasts to every connected peer, and records locally - same
  // sequence as Program.cs's ClipboardChanged handler. For file entries,
  // the caller (Index.ets) is responsible for caching the bytes into
  // FileStore under fileHash BEFORE calling this, then this proactively
  // streams them to every currently-connected peer right after the entry
  // itself goes out - matching Program.cs's ClipboardChanged file handling,
  // which doesn't wait for peers to ask via file_request.
  async broadcastEntry(entry: ClipboardEntry): Promise<void> {
    const envelope: Envelope = { Type: 'entry', Payload: JSON.stringify(entry) };
    const json = JSON.stringify(envelope);
    for (const conn of this.connections.values()) {
      sendQuietly(conn, json);
    }
    await this.history.addToHistory(this.context, entry);

    if (entry.Type === 'file') {
      let payload: FilePayload;
      try {
        payload = JSON.parse(entry.Content) as FilePayload;
      } catch (e) {
        return; // malformed descriptor - nothing to stream
      }
      if (this.fileStore.exists(payload.FileHash)) {
        for (const conn of this.connections.values()) {
          this.streamFileToPeer(conn, this.fileStore.getPath(payload.FileHash), payload.FileHash)
            .catch((e: Error) => { this.logCallback?.(`could not send a file (${e})`); });
        }
      }
    }
  }

  // The entry as its signer signed it, or null if the signature or trust
  // check fails. Store and apply what this returns, not what arrived - see
  // verifiedEntry().
  private async verifiedAndTrusted(entry: ClipboardEntry): Promise<ClipboardEntry | null> {
    const verified = await verifiedEntry(entry);
    if (verified === null) return null;
    return (await this.trustStore.isTrusted(this.context, verified.DeviceId)) ? verified : null;
  }

  private async applyAndReport(entry: ClipboardEntry): Promise<void> {
    if (entry.Type === 'file') {
      await this.handleIncomingFileEntry(entry);
      return;
    }
    const result: ApplyResult = await this.applyToClipboard(entry);
    this.entryAppliedCallback?.(entry, result, true);
  }

  // Mirrors Program.cs's HandleIncomingFileEntry: apply right away if we
  // already have these exact bytes (e.g. this device sent them originally,
  // or already received them via another peer); otherwise remember to
  // apply once file_chunk messages for this hash finish arriving and
  // verifying, and ask every connected peer (not just whoever handed us
  // this entry) whether they have it.
  private async handleIncomingFileEntry(entry: ClipboardEntry): Promise<void> {
    if (this.prepareFileEntry(entry, true)) {
      await this.applyFileEntry(entry);
      return;
    }
    // Waiting for its bytes (see onEntryWaiting); not for an entry that is
    // no good, which prepareFileEntry did not keep.
    const fileHash: string | null = fileHashOf(entry);
    if (fileHash !== null && this.pendingEntries.has(fileHash.toLowerCase())) this.entryWaitingCallback?.(entry);
  }

  // The first half of handleIncomingFileEntry: true if the entry's bytes are
  // here, so it can be applied at once. If they are not, they are asked for
  // from every peer, and with applyWhenStored the entry waits to be applied
  // when they arrive (a batch's older files do not: only its newest item goes
  // on the clipboard, but every file's bytes are wanted all the same). False
  // as well for an entry that is no good.
  private prepareFileEntry(entry: ClipboardEntry, applyWhenStored: boolean): boolean {
    let payload: FilePayload;
    try {
      payload = JSON.parse(entry.Content) as FilePayload;
    } catch (e) {
      this.logCallback?.('received malformed file entry from peer');
      return false;
    }
    // Asked for by hash, then written and read under it - so only a real
    // one (see FileStore's isValidFileHash).
    if (!isValidFileHash(payload.FileHash)) {
      this.logCallback?.('received malformed file entry from peer');
      return false;
    }
    if (this.fileStore.exists(payload.FileHash)) {
      return true;
    }
    // An empty file might never finish arriving: an older sender has no
    // chunk to stream for one (see streamFileToPeer), so a file_request
    // could wait forever. Its bytes are known, so they're stored here
    // instead - no request goes out, whatever build the sender runs.
    if (isEmptyFile(payload)) {
      if (!this.fileStore.write(payload.FileHash, new Uint8Array(0))) {
        this.logCallback?.('could not store a received empty file');
        return false;
      }
      return true;
    }
    if (applyWhenStored) {
      this.pendingEntries.set(payload.FileHash.toLowerCase(), {
        entry: entry, fileHash: payload.FileHash, armedAt: Date.now(), generation: pasteboardChangeCount()
      });
    }
    // Already arriving (its sender streams a new file right after its entry,
    // and that can overtake the entry's checks here): more peers sending it
    // too would only be wasted.
    if (!this.isReceiving(payload.FileHash)) this.broadcastFileRequest(payload.FileHash);
    return false;
  }

  // Bytes are still fetched and cached when autoApply is off (handleIncomingFileEntry
  // requests them regardless), so Share/Save work on the item later. `pending`:
  // the entry waited for its bytes, and goes on the clipboard only if
  // pendingFileMayApply says so - nothing else went there meanwhile, and not
  // too long ago. Otherwise it is only listed ('held').
  private async applyFileEntry(entry: ClipboardEntry, pending: PendingFile | null = null): Promise<void> {
    // Deleted while its bytes were on their way - a relay of the same entry
    // can have queued it again after deleteEntry dropped it.
    if (await this.history.isDeleted(this.context, entry)) return;
    const stale: boolean = pending !== null &&
      !pendingFileMayApply(pending.armedAt, pending.generation, Date.now(), pasteboardChangeCount());
    const result: ApplyResult = stale ? 'held' : await this.applyToClipboard(entry);
    this.entryAppliedCallback?.(entry, result, true);
  }

  private fileRequestJson(fileHash: string): string {
    const request: FileRequestMessage = { FileHash: fileHash };
    const envelope: Envelope = { Type: 'file_request', Payload: JSON.stringify(request) };
    return JSON.stringify(envelope);
  }

  private broadcastFileRequest(fileHash: string): void {
    const json = this.fileRequestJson(fileHash);
    for (const conn of this.connections.values()) {
      sendQuietly(conn, json);
    }
  }

  private connectionsExcept(conn: PeerConnection | null): PeerConnection[] {
    const out: PeerConnection[] = [];
    for (const c of this.connections.values()) {
      if (c !== conn) out.push(c);
    }
    return out;
  }

  // The files history entries point at whose bytes aren't here, keyed by
  // lowercase hash, each spelt as its entry spells it (the blob is stored,
  // and looked for, under that). An empty file is never missing: its bytes
  // are known (see handleIncomingFileEntry).
  private async missingFiles(): Promise<Map<string, string>> {
    const missing: Map<string, string> = new Map<string, string>();
    for (const entry of await this.history.getHistory(this.context)) {
      if (entry.Type !== 'file') continue;
      let payload: FilePayload;
      try {
        payload = JSON.parse(entry.Content) as FilePayload;
      } catch (e) {
        continue;
      }
      if (!isValidFileHash(payload.FileHash) || isEmptyFile(payload) || this.fileStore.exists(payload.FileHash)) continue;
      missing.set(payload.FileHash.toLowerCase(), payload.FileHash);
    }
    return missing;
  }

  // Asks a peer that just connected for every file this device is still
  // missing: a new item's whose stream was cut off or failed - a phone loses
  // every connection whenever it goes to the background - and any older
  // item's whose bytes never came (the app killed mid-transfer, say).
  // Nothing else would ask again: an entry is no longer new when its
  // sender's history batch brings it back. Android's requestMissingFiles and
  // iOS's requestMissingBlobs do the same.
  private async requestMissingFiles(conn: PeerConnection): Promise<void> {
    const wanted: Map<string, string> = new Map<string, string>();
    try {
      await this.dropPendingNotInHistory();
      (await this.missingFiles()).forEach((fileHash: string, key: string) => {
        if (!wanted.has(key)) wanted.set(key, fileHash);
      });
    } catch (e) {
      // history unreadable - the entries waiting here are still asked for
    }
    this.pendingEntries.forEach((pending: PendingFile, key: string) => {
      if (!wanted.has(key)) wanted.set(key, pending.fileHash);
    });
    wanted.forEach((fileHash: string) => {
      if (!this.fileStore.exists(fileHash) && !this.isReceiving(fileHash) && !this.tooBigToTake(fileHash)) {
        sendQuietly(conn, this.fileRequestJson(fileHash));
      }
    });
  }

  // A connection was closed for its queue while it streamed this file.
  private noteQueueClosure(fileHash: string): void {
    const key: string = fileHash.toLowerCase();
    const closures: number = (this.queueClosures.get(key) ?? 0) + 1;
    this.queueClosures.set(key, closures);
    if (closures === MAX_QUEUE_CLOSURES) {
      this.logCallback?.('a file came in faster than this device could take it in, ' +
        `${closures} times - not asking for it again on this run`);
    }
  }

  // The file's sender has outrun this side MAX_QUEUE_CLOSURES times: it is not
  // asked for again until the app starts again.
  private tooBigToTake(fileHash: string): boolean {
    return (this.queueClosures.get(fileHash.toLowerCase()) ?? 0) >= MAX_QUEUE_CLOSURES;
  }

  // An entry waiting for its bytes that the history no longer holds (the cap
  // pushed it out) waits no more: its bytes are not asked for again, and if
  // they come they are not applied.
  private async dropPendingNotInHistory(): Promise<void> {
    if (this.pendingEntries.size === 0) return;
    const held: Set<string> = new Set<string>((await this.history.getHistory(this.context)).map((e: ClipboardEntry) => entryKey(e)));
    const gone: string[] = [];
    this.pendingEntries.forEach((pending: PendingFile, key: string) => {
      if (!held.has(entryKey(pending.entry))) gone.push(key);
    });
    for (const key of gone) {
      this.pendingEntries.delete(key);
      this.abandonedHashes.add(key);
    }
  }

  // Asks `from` for a file again after a transfer of it came to nothing -
  // failed its hash check, had a gap, or went by unused - while an item
  // still wants it and nobody is sending it. Only MAX_RETRIES times between
  // successes: a sender whose copy is bad would otherwise be asked forever.
  // A peer connecting asks once more anyway (see requestMissingFiles). The
  // same rule as Android's requestAgain.
  private async requestAgain(fileHash: string, from: PeerConnection[]): Promise<RequestOutcome> {
    if (this.fileStore.exists(fileHash) || this.isReceiving(fileHash)) return 'notNeeded';
    // A new item's (see pendingEntries), or an older one's.
    let wanted: boolean = this.pendingEntries.has(fileHash.toLowerCase());
    if (!wanted) {
      try {
        wanted = (await this.missingFiles()).has(fileHash.toLowerCase());
      } catch (e) {
        // history unreadable - nothing known to want it
      }
    }
    // Checked again after reading the history: a stream may have started.
    if (!wanted || this.fileStore.exists(fileHash) || this.isReceiving(fileHash)) return 'notNeeded';
    if (this.tooBigToTake(fileHash)) return 'stopped';
    const live: PeerConnection[] = from.filter((c: PeerConnection) => !c.isClosed);
    if (live.length === 0) return 'noDevice';
    const key: string = fileHash.toLowerCase();
    const tries: number = (this.retries.get(key) ?? 0) + 1;
    this.retries.set(key, tries);
    if (tries > MAX_RETRIES) {
      if (tries === MAX_RETRIES + 1) this.logCallback?.('giving up on a file until a device reconnects');
      return 'stopped';
    }
    const json: string = this.fileRequestJson(fileHash);
    for (const c of live) {
      sendQuietly(c, json);
    }
    return 'asked';
  }

  // requestAgain after a stream of the file came to nothing, with the card
  // told what came of it: asked again ("Trying again"), nobody left to ask
  // ("Waiting for a device"), or not asked any more although devices are
  // connected ("Couldn't receive"). Not needed, the card is told that too,
  // unless another stream of the file is under way and reports for itself:
  // its bar would otherwise be left on the last numbers for good.
  private async retryFile(fileHash: string, from: PeerConnection[]): Promise<void> {
    const outcome: RequestOutcome = await this.requestAgain(fileHash, from);
    if (outcome === 'asked') {
      this.emitProgress(fileHash, 'retrying', 0);
    } else if (outcome === 'noDevice') {
      this.emitProgress(fileHash, 'waiting', 0);
    } else if (outcome === 'stopped') {
      this.emitProgress(fileHash, 'stopped', 0);
    } else if (this.fileStore.exists(fileHash)) {
      this.emitProgress(fileHash, 'done', 0);
    } else if (!this.isReceiving(fileHash)) {
      // No longer wanted (its item deleted, say): the page drops a bar whose
      // card is gone, and stops looking at one that stays.
      this.emitProgress(fileHash, 'waiting', 0);
    }
  }

  private emitProgress(fileHash: string, phase: TransferPhase, received: number): void {
    const update: TransferUpdate = { fileHash: fileHash.toLowerCase(), phase: phase, received: received };
    try {
      this.transferProgressCallback?.(update);
    } catch (e) {
      // the page's trouble must never stop a transfer
    }
  }

  private handleFileRequest(payloadJson: string, requestingConn: PeerConnection): void {
    let request: FileRequestMessage;
    try {
      request = JSON.parse(payloadJson) as FileRequestMessage;
    } catch (e) {
      return;
    }
    // Only ever a hash of something in FileStore - never a path to whatever
    // file a peer names (see FileStore's isValidFileHash).
    if (!isValidFileHash(request.FileHash)) return;
    if (this.fileStore.exists(request.FileHash)) {
      this.streamFileToPeer(requestingConn, this.fileStore.getPath(request.FileHash), request.FileHash)
        .catch((e: Error) => { this.logCallback?.(`could not send a file (${e})`); });
    }
    // if we don't have it either, just don't respond - the requester
    // already broadcast to everyone else too; someone else might have it
  }

  // Reads a file incrementally and sends it as a sequence of file_chunk
  // envelopes - bounded memory (SEND_WINDOW chunks at a time) regardless of
  // the file's total size, matching Program.cs's StreamFileToPeer. The
  // chunks are the same 256 KiB file_chunk messages, in the same order, as
  // every version sends: only the work behind them overlaps. While chunk N
  // is being encrypted and written to the socket, chunk N+1 is read and
  // encoded (on a worker), so the radio is not left idle between chunks.
  async streamFileToPeer(conn: PeerConnection, filePath: string, fileHash: string): Promise<void> {
    // Lowercase, like outgoing's keys: the same file asked for in two
    // spellings is still one stream, not two that interleave.
    const key = `${conn.peerDeviceId}:${fileHash.toLowerCase()}`;
    if (this.streamingInFlight.has(key)) {
      // Already streaming this exact file to this exact peer - see the
      // streamingInFlight field comment for why this happens (proactive
      // send + the receiver's own redundant file_request both trying to
      // start a stream).
      return;
    }
    this.streamingInFlight.add(key);
    try {
      let totalSize: number;
      try {
        totalSize = fs.statSync(filePath).size;
      } catch (e) {
        return; // source file vanished - nothing to stream
      }
      if (totalSize === 0) {
        // Still one chunk - empty, and the last - as every other platform
        // sends: an older receiver only finishes an empty file on it.
        const emptyChunk: FileChunkMessage = { FileHash: fileHash, ChunkIndex: 0, IsLast: true, DataBase64: '' };
        const envelope: Envelope = { Type: 'file_chunk', Payload: JSON.stringify(emptyChunk) };
        try {
          await conn.send(JSON.stringify(envelope));
        } catch (e) {
          // peer disconnected - nothing further to do
        }
        return;
      }
      let file: fs.File;
      try {
        file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      } catch (e) {
        return;
      }
      // A receiver that acknowledges chunks (see FileFlow.ets) is never sent
      // more than ACK_WINDOW chunks ahead of what it has written. One that
      // does not (an older build) is sent the file as fast as before.
      const acks: AckWindow | null = conn.peerAcksFiles ? new AckWindow() : null;
      if (acks !== null) this.outgoing.set(key, { conn: conn, acks: acks });
      try {
        const end: PumpEnd = await pumpChunks(new FileChunkSender(conn, file, fileHash, totalSize), acks, SEND_WINDOW);
        if (end === 'timed-out') {
          this.logCallback?.(`${shortDeviceId(conn.peerDeviceId)} acknowledged nothing for ${ACK_TIMEOUT_MS / 1000} s - ` +
            'stopped sending it a file (it asks again when it needs it)');
        }
      } catch (e) {
        // the file could not be read, or a chunk not encoded - the receiver
        // sees the stream stop, and asks again
      } finally {
        if (acks !== null) {
          // Acknowledgements still on their way find no stream, and are ignored.
          acks.cancel();
          if (this.outgoing.get(key)?.acks === acks) this.outgoing.delete(key);
        }
        fs.closeSync(file);
      }
    } finally {
      this.streamingInFlight.delete(key);
    }
  }

  // One stream per file, from the first peer whose chunk 0 arrives (see
  // placeChunk), into a temp file of its own (see incoming), taken in order:
  // a stream starts at chunk 0, so the middle of one this side never saw
  // start (cut off, or begun before this run) is ignored, and a sender that
  // starts over at 0 gets a fresh file. Bytes already stored aren't written
  // again. A file whose stream comes to nothing (a gap, a hash mismatch) is
  // asked for again, a few times - see requestAgain.
  //
  // Where a chunk goes is settled the moment it arrives, before anything is
  // awaited; its bytes are then decoded on a worker and written in a queue of
  // its own (see writeChunk), so the next chunks can be decoded while this
  // one waits its turn, and they still land in the order they came. Before,
  // the order held only because nothing was awaited before the write, and so
  // the decoding ran on the UI thread, a chunk at a time.
  // data: the chunk's bytes, decoded, when its line came apart that way (see
  // PeerConnection.onMessage); its DataBase64 is then empty.
  private async handleFileChunk(payloadJson: string, conn: PeerConnection, data: Uint8Array | null): Promise<void> {
    let parsed: FileChunkMessage | null = null;
    try {
      parsed = JSON.parse(payloadJson) as FileChunkMessage;
    } catch (e) {
      parsed = null;
    }
    // The hash names the file these bytes are written to.
    if (parsed === null || !isObject(parsed) || !isValidFileHash(parsed.FileHash)) {
      // Not a chunk this side can use: its bytes, if they came decoded, are
      // freed now rather than left to the collector (see SpentBuffers).
      if (data !== null) releaseBuffer(data.buffer as ArrayBuffer);
      return;
    }
    const chunk: FileChunkMessage = parsed;
    try {
      await this.takeFileChunk(chunk, conn, data !== null && chunk.DataBase64 === '' ? data : chunk.DataBase64);
    } finally {
      // Written and freed by now (see writeChunk), unless the chunk was set
      // aside: then freed here. Freeing twice does nothing.
      if (data !== null) releaseBuffer(data.buffer as ArrayBuffer);
      // Whatever came of the chunk - written and hashed, or set aside - it is
      // no longer waiting here, so a sender that paces its streams may send
      // another. Only to a sender that said it does (see FileFlow.ets): an
      // older build is sent nothing new.
      this.sendFileAck(conn, chunk);
    }
  }

  // handleFileChunk once the chunk is known to be one: where it goes, and
  // its bytes decoded and written there. Returns once the chunk is written
  // (and, for the last one, the file checked and stored), or set aside.
  // content: its Base64, or its bytes already decoded (see decodeChunk).
  private async takeFileChunk(chunk: FileChunkMessage, conn: PeerConnection, content: string | Uint8Array): Promise<void> {
    const key = `${conn.peerDeviceId}:${chunk.FileHash}`;
    let transfer: IncomingTransfer | undefined = this.incoming.get(key);
    const place: ChunkPlace = placeChunk(transfer !== undefined, transfer?.conn === conn, transfer?.nextIndex ?? 0,
      chunk.ChunkIndex, transfer === undefined && this.isReceiving(chunk.FileHash));
    if (place === 'ignore') {
      // The end of a stream this side couldn't use - one it gave up on, or a
      // second sender's. With nobody else sending the file now, its sender
      // may as well start over.
      if (chunk.IsLast) await this.retryFile(chunk.FileHash, [conn]);
      return;
    }
    if (transfer !== undefined && place === 'abandon') {
      this.logCallback?.('file chunk out of order - abandoning this transfer');
      this.abortTransfer(key, transfer);
      await this.retryFile(chunk.FileHash, this.connectionsExcept(null));
      return;
    }
    if (transfer !== undefined && place === 'restart') {
      // Its sender started over (or its new connection did): so does this
      // side, from an empty file.
      this.abortTransfer(key, transfer);
      transfer = undefined;
    }
    // Stored already - this device copying the same file itself meanwhile,
    // say, in which case an entry may still be waiting on them.
    if (transfer !== undefined && this.fileStore.exists(chunk.FileHash)) {
      this.abortTransfer(key, transfer);
      this.emitProgress(chunk.FileHash, 'done', 0);
      await this.tryFulfillPendingEntry(chunk.FileHash);
      return;
    }
    if (transfer === undefined) {
      // 'start', or 'restart' - chunk 0 either way.
      if (this.fileStore.exists(chunk.FileHash)) {
        await this.tryFulfillPendingEntry(chunk.FileHash);
        return;
      }
      const tempPath = this.fileStore.newTempPath(chunk.FileHash);
      try {
        const file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        transfer = this.newTransfer(chunk.FileHash, conn, file.fd, tempPath);
      } catch (e) {
        this.logCallback?.(`failed writing file chunk (${e}) - abandoning this transfer`);
        return;
      }
      this.incoming.set(key, transfer);
      this.emitProgress(chunk.FileHash, 'receiving', 0);
    }

    // Taken: the next chunk of this stream is expected now, whatever its
    // bytes turn out to be. Decoded only once it's known to be written: a
    // stream that is ignored is never decoded.
    const current: IncomingTransfer = transfer;
    current.nextIndex++;
    current.lastChunkAt = Date.now();
    const decoding: Promise<Uint8Array> = decodeChunk(content);
    decoding.catch(() => { /* reported by writeChunk */ });
    const isLast: boolean = chunk.IsLast === true;
    if (isLast) {
      // Off the map before anything awaits: another stream of this file (its
      // sender answering a file_request once this one's done, say) writes a
      // file of its own meanwhile, and can't truncate or delete this one.
      // It still counts as arriving until it is stored or thrown away.
      this.incoming.delete(key);
      this.startFinishing(current.fileHash);
    }
    const step: Promise<void> = current.tail.then(() => this.writeChunk(key, current, decoding, isLast));
    const settled: Promise<void> = step.catch((e: Error) => {
      this.logCallback?.(`could not write a file chunk (${e})`);
    });
    current.tail = settled;
    current.pending.push(settled);
    // Decoding runs ahead of writing; past a few chunks the connection stops
    // reading until the oldest is written (see PeerConnection.holdReadsUntil).
    if (current.pending.length > CHUNK_BACKLOG) conn.holdReadsUntil(current.pending[0]);
    await settled;
  }

  private newTransfer(fileHash: string, conn: PeerConnection, fd: number, tempPath: string): IncomingTransfer {
    let md: cryptoFramework.Md | null = null;
    try {
      md = cryptoFramework.createMd('SHA256');
    } catch (e) {
      // read back at the end instead (see digestOf)
    }
    const transfer: IncomingTransfer = {
      fileHash: fileHash, conn: conn, fd: fd, tempPath: tempPath, nextIndex: 0, pending: [], tail: Promise.resolve(),
      received: 0, md: md, aborted: false, failed: false, throttle: new ProgressThrottle(), startedAt: Date.now(),
      lastChunkAt: Date.now(),
    };
    return transfer;
  }

  // Tells a sender that paces its streams that this chunk has been dealt
  // with (see FileFlow.ets). The hash goes back spelt as the chunk spelt it.
  // Nothing goes to a sender that did not list file-ack (see fileAckFor).
  private sendFileAck(conn: PeerConnection, chunk: FileChunkMessage): void {
    const payload: string | null = fileAckFor(conn.peerAcksFiles, chunk.FileHash, chunk.ChunkIndex);
    if (payload === null) return;
    const envelope: Envelope = { Type: FILE_ACK_TYPE, Payload: payload };
    sendQuietly(conn, JSON.stringify(envelope));
  }

  // A file_ack from a receiver this side is sending a file to: the stream's
  // window moves on. One for a stream that is not under way (finished, given
  // up, or never sent), or that came over another connection, is ignored.
  private handleFileAck(payloadJson: string, conn: PeerConnection): void {
    const ack: FileAck | null = parseFileAck(payloadJson);
    if (ack === null) return;
    const stream: OutgoingStream | undefined = this.outgoing.get(`${conn.peerDeviceId}:${ack.FileHash.toLowerCase()}`);
    if (stream === undefined || stream.conn !== conn) return;
    stream.acks.ack(ack.ChunkIndex);
  }

  // A sender that paces its streams gives one up when this side acknowledges
  // nothing for its timeout - this side held up (a slow write, say) while the
  // connection stayed up. Its last acknowledgements then arrive too late, no
  // more chunks come, and the stream would stay open here for good, so the
  // file would never be asked for again. So a stream from such a sender that
  // has everything it took written, and no new chunk for STALLED_STREAM_MS,
  // is given up here too and the file asked for again (see stallVerdict:
  // while anything from the sender is still on its way through, a big line
  // on a slow link say, the quiet is not counted). An older sender never
  // stops part-way on a live connection, so its streams are left as before.
  // Checked with the connection's heartbeat tick.
  private checkStalledStreams(conn: PeerConnection): void {
    if (!conn.peerAcksFiles) return;
    const now: number = Date.now();
    const receiving: boolean = conn.isReceiving;
    const stalled: string[] = [];
    this.incoming.forEach((transfer: IncomingTransfer, key: string) => {
      if (transfer.conn !== conn) return;
      const verdict: StallVerdict = stallVerdict(transfer.pending.length, receiving, transfer.lastChunkAt, now);
      if (verdict === 'touch') {
        transfer.lastChunkAt = now;
      } else if (verdict === 'drop') {
        stalled.push(key);
      }
    });
    for (const key of stalled) {
      const transfer: IncomingTransfer | undefined = this.incoming.get(key);
      if (transfer === undefined) continue;
      this.logCallback?.('a file stopped arriving part-way - asking for it again');
      this.abortTransfer(key, transfer);
      this.retryFile(transfer.fileHash, this.connectionsExcept(null))
        .catch((e: Error) => { this.logCallback?.(`could not ask for a file again (${e})`); });
    }
  }

  // One chunk's turn in its stream's queue: its decoded bytes written to the
  // stream's file and added to its hash, and for the last chunk the file
  // checked and stored. Nothing between the check that the stream is still
  // wanted and the write is awaited, so a stream given up on meanwhile is
  // never written to.
  private async writeChunk(key: string, transfer: IncomingTransfer, decoding: Promise<Uint8Array>,
    isLast: boolean): Promise<void> {
    let bytes: Uint8Array | null = null;
    try {
      bytes = await decoding;
    } catch (e) {
      bytes = null;
    }
    transfer.pending.shift();
    // Given up on meanwhile: a restart, a gap, its connection closing, or an
    // earlier chunk failing.
    if (transfer.aborted) {
      if (!isLast) return;
      this.endFinishing(transfer.fileHash);
      // An earlier chunk of this stream failed after this one, the last, was
      // already taken: that chunk's retry found the file still arriving (this
      // chunk was what made it count as arriving) and asked nobody. Only now
      // that it no longer counts can the file be asked for again. A stream
      // taken off the map before its last chunk came never gets here: that
      // chunk then goes nowhere (see placeChunk).
      if (transfer.failed) await this.retryFile(transfer.fileHash, this.connectionsExcept(null));
      return;
    }
    if (bytes === null) {
      this.logCallback?.('file chunk is not Base64 - abandoning this transfer');
      this.failTransfer(key, transfer, isLast);
      await this.retryFile(transfer.fileHash, this.connectionsExcept(null));
      return;
    }
    // The decoded bytes' own buffer when they fill it (they normally do), so
    // neither the write nor the hash needs a copy of them.
    const whole: ArrayBuffer = exactBuffer(bytes);
    try {
      if (whole.byteLength > 0) fs.writeSync(transfer.fd, whole);
    } catch (e) {
      this.logCallback?.(`failed writing file chunk (${e}) - abandoning this transfer`);
      this.failTransfer(key, transfer, isLast);
      await this.retryFile(transfer.fileHash, this.connectionsExcept(null));
      return;
    }
    if (transfer.md !== null && bytes.byteLength > 0) {
      try {
        transfer.md.updateSync({ data: new Uint8Array(whole) });
      } catch (e) {
        transfer.md = null;
      }
    }
    transfer.received += bytes.byteLength;
    // Written and hashed: the decoded bytes are not needed again (see
    // SpentBuffers).
    if (whole !== bytes.buffer) releaseBuffer(whole);
    releaseBuffer(bytes.buffer as ArrayBuffer);
    if (!isLast) {
      if (transfer.throttle.due(Date.now())) this.emitProgress(transfer.fileHash, 'receiving', transfer.received);
      return;
    }
    // The bar full while the file is checked and stored.
    this.emitProgress(transfer.fileHash, 'receiving', transfer.received);
    await this.finishTransfer(transfer);
  }

  // A stream's last chunk is written: its hash is checked against the one
  // it was asked for, and it is stored under it.
  private async finishTransfer(transfer: IncomingTransfer): Promise<void> {
    const fileHash: string = transfer.fileHash;
    const tempPath = transfer.tempPath;
    let actualHash = '';
    try {
      fs.closeSync(transfer.fd);
      actualHash = await this.digestOf(transfer);
    } catch (e) {
      // unreadable - fails the check below
    }
    this.endFinishing(fileHash);
    const seconds: number = Math.max(0.001, (Date.now() - transfer.startedAt) / 1000);
    const megabytes: number = transfer.received / 1048576;
    const queueHigh: number = transfer.conn.takeQueueHigh() / 1048576;
    this.logCallback?.(`received a file: ${megabytes.toFixed(1)} MB in ${seconds.toFixed(1)} s ` +
      `(${(megabytes / seconds).toFixed(1)} MB/s, queue high ${queueHigh.toFixed(0)} MB)`);
    if (actualHash.toLowerCase() !== fileHash.toLowerCase()) {
      // corrupted in transit, or tampered - the signed entry's hash is
      // what we trust, not whatever bytes actually showed up
      this.logCallback?.('file transfer failed hash verification - discarding');
      removeIfThere(tempPath);
      // The entry still waits: another peer's copy, or this one's next
      // stream, may be intact.
      await this.retryFile(fileHash, this.connectionsExcept(null));
      return;
    }

    try {
      fs.renameSync(tempPath, this.fileStore.getPath(fileHash));
    } catch (e) {
      this.logCallback?.(`could not store a received file (${e})`);
      removeIfThere(tempPath);
      // Not asked for again until a device reconnects (see requestMissingFiles).
      this.emitProgress(fileHash, 'stopped', 0);
      return;
    }
    this.retries.delete(fileHash.toLowerCase());
    this.emitProgress(fileHash, 'done', transfer.received);
    // Its item was deleted or cleared while these bytes were on their way,
    // and nothing is waiting on them now: kept, they'd be an orphan.
    if (this.abandonedHashes.delete(fileHash.toLowerCase()) && !this.pendingEntries.has(fileHash.toLowerCase())) {
      await this.history.deleteFileIfUnused(this.context, fileHash);
      return;
    }
    if (!(await this.tryFulfillPendingEntry(fileHash))) this.fileStoredCallback?.(fileHash);
  }

  // The SHA-256 of what a stream wrote, in lowercase hex: kept up as it was
  // written (see IncomingTransfer.md), or read back from the file if that
  // failed on the way. An empty file's is the known constant.
  private async digestOf(transfer: IncomingTransfer): Promise<string> {
    if (transfer.received === 0) return EMPTY_FILE_HASH;
    if (transfer.md !== null) {
      try {
        return hexString(transfer.md.digestSync().data);
      } catch (e) {
        // read back below
      }
    }
    return sha256File(transfer.tempPath);
  }

  // A chunk of a stream could not be decoded or written: the stream is given
  // up (and its last chunk, if this was it, no longer counts as arriving).
  private failTransfer(key: string, transfer: IncomingTransfer, isLast: boolean): void {
    transfer.failed = true;
    this.abortTransfer(key, transfer);
    if (isLast) this.endFinishing(transfer.fileHash);
  }

  // Ends one incoming stream early: off the map (if it is still there), its
  // fd closed and its half-written file deleted. Its chunks still queued are
  // dropped (see writeChunk).
  private abortTransfer(key: string, transfer: IncomingTransfer): void {
    if (this.incoming.get(key) === transfer) this.incoming.delete(key);
    if (transfer.aborted) return;
    transfer.aborted = true;
    try {
      fs.closeSync(transfer.fd);
    } catch (e) {
      // closed already
    }
    removeIfThere(transfer.tempPath);
  }

  private startFinishing(fileHash: string): void {
    const key: string = fileHash.toLowerCase();
    this.finishing.set(key, (this.finishing.get(key) ?? 0) + 1);
  }

  private endFinishing(fileHash: string): void {
    const key: string = fileHash.toLowerCase();
    const left: number = (this.finishing.get(key) ?? 0) - 1;
    if (left > 0) {
      this.finishing.set(key, left);
    } else {
      this.finishing.delete(key);
    }
  }

  // A stream of this file is under way from some peer, or its last chunk is
  // in and it is being checked and stored.
  private isReceiving(fileHash: string): boolean {
    const key: string = fileHash.toLowerCase();
    if (this.finishing.has(key)) return true;
    for (const transfer of this.incoming.values()) {
      if (transfer.fileHash.toLowerCase() === key) return true;
    }
    return false;
  }

  // A closed connection's streams never resume - every sender starts over
  // at chunk 0 - so each one's half-written file goes, rather than its fd
  // staying open for good. Returns the hashes that were cut off. A stream
  // whose last chunk is already in is not one of them: its bytes are all
  // here, and it finishes on its own.
  private dropTransfersFrom(conn: PeerConnection): string[] {
    const keys: string[] = [];
    this.incoming.forEach((transfer: IncomingTransfer, key: string) => {
      if (transfer.conn === conn) keys.push(key);
    });
    const cutOff: string[] = [];
    for (const key of keys) {
      const transfer: IncomingTransfer | undefined = this.incoming.get(key);
      if (transfer === undefined) continue;
      this.abortTransfer(key, transfer);
      cutOff.push(transfer.fileHash);
    }
    return cutOff;
  }

  // FileStore can gain a blob through more than one path - chunk-stream
  // completion (above), but also this device's own local capture of a
  // file (see Index.ets's onPasteButtonClick). Whichever way a hash
  // becomes available, a pending entry waiting on that hash (in any case)
  // is applied - if it still may be, see applyFileEntry. False if none was
  // waiting.
  private async tryFulfillPendingEntry(fileHash: string): Promise<boolean> {
    const key: string = fileHash.toLowerCase();
    const pending: PendingFile | undefined = this.pendingEntries.get(key);
    if (pending === undefined) return false;
    this.pendingEntries.delete(key);
    // Pushed out of the history while its bytes were on their way: they are
    // stored, but nothing is applied or listed.
    const held: ClipboardEntry[] = await this.history.getHistory(this.context);
    if (!held.some((e: ClipboardEntry) => entryKey(e) === entryKey(pending.entry))) {
      await this.history.deleteFileIfUnused(this.context, fileHash);
      return true;
    }
    await this.applyFileEntry(pending.entry, pending);
    return true;
  }

  // Every write of a received entry to the clipboard: one at a time with the
  // page's capture (see clipboardChain). Content the clipboard holds already
  // is not written again ('already', no notice: an older peer echoing back
  // what this device sent, say); a copy made here and not dealt with yet goes
  // out first (ClipboardHooks.beforeWrite); and what was written is recorded.
  private applyToClipboard(entry: ClipboardEntry): Promise<ApplyResult> {
    return this.withClipboard(async (): Promise<ApplyResult> => {
      const hooks: ClipboardHooks | null = this.clipboardHooks;
      if (hooks !== null && hooks.holds(entry)) return 'already';
      if (!this.autoApply) return 'skipped';
      if (hooks !== null) {
        try {
          await hooks.beforeWrite();
        } catch (e) {
          this.logCallback?.(`could not send the copy made here first (${e})`);
        }
      }
      const write: ClipboardWrite = await writeEntryToClipboard(entry, this.fileStore);
      if (write.result === 'applied') hooks?.wrote(entry, write.prints);
      return write.result;
    });
  }

  // A live entry: checked, then added to the history FIRST, and applied and
  // listed only if the history took it - new, not deleted here, and not
  // trimmed away at once for being older than everything it keeps. Before,
  // it was applied and listed first: a card stayed for an item the history
  // had refused, and a file waited for bytes nothing kept.
  private async handleLiveEntry(received: ClipboardEntry): Promise<void> {
    const entry = await this.verifiedAndTrusted(received);
    if (entry === null) {
      // Was silent (a routine consequence of trust mismatches during
      // normal pairing setup) - re-enabled while chasing the image/file
      // sync bug, since a silent drop here is indistinguishable from
      // "nothing arrived at all" and was hiding where the failure
      // actually happens. type/deviceId included since this is the
      // first concrete data point telling us whether it's even getting
      // this far.
      this.logCallback?.(`dropped ${received.Type} entry from ${shortDeviceId(received.DeviceId)} - failed signature/trust check`);
      return;
    }
    // Deleted here before, a repeat, or too old to keep: neither listed nor
    // put on the clipboard.
    if (!(await this.history.addToHistory(this.context, entry))) return;
    await primeContentKeys([entry]);
    await this.applyAndReport(entry);
  }

  private async handleMessage(msg: string, conn: PeerConnection, link: SyncLink, data: Uint8Array | null): Promise<void> {
    let envelope: Envelope;
    try {
      envelope = JSON.parse(msg) as Envelope;
    } catch (e) {
      this.logCallback?.('received invalid message from peer (bad JSON)');
      return;
    }
    // JSON, but not an envelope at all ("null", say): reading its Type threw.
    if (!isObject(envelope)) {
      this.logCallback?.('received invalid message from peer (not an envelope)');
      return;
    }

    if (envelope.Type === 'entry') {
      let received: ClipboardEntry;
      try {
        received = JSON.parse(envelope.Payload) as ClipboardEntry;
      } catch (e) {
        this.logCallback?.('received invalid message from peer (bad entry JSON)');
        return;
      }
      if (!isObject(received)) {
        this.logCallback?.('received invalid message from peer (bad entry JSON)');
        return;
      }
      // Its place in the queue is taken now, before anything is awaited.
      const work: Promise<void> = this.liveWork.then(() => this.handleLiveEntry(received));
      this.liveWork = work.catch((e: Error) => { this.logCallback?.(`could not deal with an entry (${e})`); });
      await this.liveWork;
    } else if (envelope.Type === 'history_head') {
      await this.sync.onHead(link, envelope.Payload);
    } else if (envelope.Type === 'history_batch') {
      // Nothing is awaited before this call: a batch that answers a request
      // takes its place in the connection's queue in the order it came (see
      // HistorySync.onBatch).
      await this.sync.onBatch(link, envelope.Payload);
    } else if (envelope.Type === 'history_request') {
      this.sync.onRequest(link, envelope.Payload);
    } else if (envelope.Type === 'delete') {
      await this.sync.onDelete(link, envelope.Payload);
    } else if (envelope.Type === 'file_chunk') {
      await this.handleFileChunk(envelope.Payload, conn, data);
    } else if (envelope.Type === 'file_request') {
      this.handleFileRequest(envelope.Payload, conn);
    } else if (envelope.Type === FILE_ACK_TYPE) {
      this.handleFileAck(envelope.Payload, conn);
    } else if (envelope.Type === 'unpair') {
      // The peer removed this device, or ignored its request: it no longer trusts
      // it. Dropping it here too ends its redialling - trust on one side only never
      // became a pairing, and only ever produced a request at the other end. Only
      // a peer can say this about itself: the message came over its proven
      // session, and all it changes is whether this device trusts it.
      this.unpairedCallback?.(conn.peerDeviceId);
      this.disconnect(conn.peerDeviceId);
    } else {
      this.logCallback?.(`received message with unknown type from peer: ${envelope.Type}`);
    }
  }
}
