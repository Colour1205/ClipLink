// Step 8/10 of the build order in ../../../../README.md: full sync + file
// transfer. Mirrors Program.cs's HandleMessage/SendHistoryBatch/
// ClipboardChanged/HandleFileChunk/HandleFileRequest/StreamFileToPeer. What is
// done with the history messages (head, batch, request, delete) is in
// HistorySync.ets; this class gives it the history, the clipboard and the files.

import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { PeerConnection } from './PeerConnection';
import { BatchApplied, HeadApplied, HistorySync, SyncApplied, SyncLink } from './HistorySync';
import { ChunkPlace, placeChunk } from './ChunkOrder';
import { FileChunkMessage } from './FileChunkMessage';
import { FileRequestMessage } from './FileRequestMessage';
import { TrustStore } from '../identity/TrustStore';
import { shortDeviceId } from '../identity/DeviceName';
import { HistoryAccess } from '../storage/HistoryAccess';
import { FileStore, isEmptyFile, isValidFileHash, removeIfThere, sha256File } from '../storage/FileStore';
import { FilePayload } from '../storage/FilePayload';
import { entryKey } from '../storage/DeletedEntries';
import { ClipboardEntry, verifiedEntry } from '../crypto/Signing';
import { applyEntryToClipboard, ApplyResult } from '../clipboard/ClipboardApply';

const base64Helper = new util.Base64Helper();
const CHUNK_SIZE = 256 * 1024;
// See requestAgain. Same as Android's SyncManager.MAX_RETRIES.
const MAX_RETRIES = 3;
interface Envelope {
  Type: string;
  Payload: string;
}

// One file's bytes arriving over one connection (see handleFileChunk),
// written to a temp file of its own until IsLast.
interface IncomingTransfer {
  fileHash: string;
  conn: PeerConnection;
  fd: number;
  tempPath: string;
  nextIndex: number;
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
  private fileStoredCallback: ((fileHash: string) => void) | null = null;
  private logCallback: ((message: string) => void) | null = null;
  private connectionsChangedCallback: ((count: number) => void) | null = null;
  private unpairedCallback: ((deviceId: string) => void) | null = null;

  // In-progress incoming chunk streams, keyed `${peerDeviceId}:${fileHash}`
  // like streamingInFlight - the fd stays open across every "file_chunk"
  // message for that hash from that peer until IsLast. Keyed by hash alone,
  // two peers answering one file_request (it goes to every peer) were
  // written into one file, which then failed verification; now each stream
  // has its own file, and whichever finishes first is kept.
  private incoming: Map<string, IncomingTransfer> = new Map();
  // Entries that arrived (and verified) before their bytes finished
  // streaming in, keyed by the file hash they're waiting on.
  private pendingEntries: Map<string, ClipboardEntry> = new Map();
  // File hashes whose waiting entry was deleted or cleared before the bytes
  // finished arriving - see handleFileChunk.
  private abandonedHashes: Set<string> = new Set();
  // How often each file (lowercase hash) has been asked for again after a
  // transfer of it came to nothing - see requestAgain.
  private retries: Map<string, number> = new Map();
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
    this.trustStore = trustStore;
    this.context = context;
    this.fileStore = fileStore;
    this.sync = new HistorySync({
      verified: (entry: ClipboardEntry) => this.verifiedAndTrusted(entry),
      getHistory: () => this.history.getHistory(this.context),
      deletedKeys: (limit: number) => this.history.recentDeleted(this.context, limit),
      goneKeys: (keys: string[]) => this.history.goneKeys(this.context, keys),
      isDeleted: (entry: ClipboardEntry) => this.history.isDeleted(this.context, entry),
      addBatch: (candidates: ClipboardEntry[], newFront: boolean, frontOk: (entry: ClipboardEntry) => boolean) =>
        this.history.addBatch(this.context, candidates, newFront, frontOk),
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

  // A file's bytes arrived that no newly received entry was waiting on - an
  // older item's, asked for again (see requestMissingFiles). Its card can
  // show what it now has (an image's preview, say). Android's onFileStored.
  onFileStored(callback: (fileHash: string) => void): void {
    this.fileStoredCallback = callback;
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
    this.pendingEntries.forEach((entry: ClipboardEntry, fileHash: string) => {
      keys.push(entryKey(entry));
      this.abandonedHashes.add(fileHash);
    });
    this.pendingEntries.clear();
    const cleared: string[] = await this.history.clearHistory(this.context, keys);
    this.sync.broadcastDelete(cleared);
  }

  // One item, by entryKey - same rules as clearHistory.
  async deleteEntry(key: string): Promise<void> {
    await this.dropEntries([key]);
    this.sync.broadcastDelete([key]);
  }

  // Deletes these items (by entryKey) from this device: tombstoned, out of the
  // history, their files gone unless another entry uses them. A file entry
  // still waiting for its bytes is dropped too, so their arrival can't re-list
  // it. Used for the user's own delete and for a peer's.
  private async dropEntries(keys: string[]): Promise<void> {
    const gone: Set<string> = new Set<string>(keys);
    const waiting: string[] = [];
    this.pendingEntries.forEach((entry: ClipboardEntry, fileHash: string) => {
      if (gone.has(entryKey(entry))) waiting.push(fileHash);
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
    conn.onMessage((msg: string) => { void this.handleMessage(msg, conn, link); });
    conn.onTick(() => { this.sync.expire(link); });
    conn.onDisconnected(() => {
      // Whatever it still owed, and a stack that waited for it.
      this.sync.close(link);
      // Its streams are dead whether or not it was replaced - see
      // dropTransfersFrom.
      const cutOff: string[] = this.dropTransfersFrom(conn);
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
        void this.requestAgain(fileHash, others);
      }
    });
    conn.listen();
    void this.sync.announce(link);
    void this.requestMissingFiles(conn);
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
      void conn.send(json);
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
          void this.streamFileToPeer(conn, this.fileStore.getPath(payload.FileHash), payload.FileHash);
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
      this.handleIncomingFileEntry(entry);
      return;
    }
    const result: ApplyResult = this.autoApply ? await applyEntryToClipboard(entry, this.fileStore) : 'skipped';
    this.entryAppliedCallback?.(entry, result, true);
  }

  // Mirrors Program.cs's HandleIncomingFileEntry: apply right away if we
  // already have these exact bytes (e.g. this device sent them originally,
  // or already received them via another peer); otherwise remember to
  // apply once file_chunk messages for this hash finish arriving and
  // verifying, and ask every connected peer (not just whoever handed us
  // this entry) whether they have it.
  private handleIncomingFileEntry(entry: ClipboardEntry): void {
    if (this.prepareFileEntry(entry, true)) void this.applyFileEntry(entry);
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
    if (applyWhenStored) this.pendingEntries.set(payload.FileHash, entry);
    // Already arriving (its sender streams a new file right after its entry,
    // and that can overtake the entry's checks here): more peers sending it
    // too would only be wasted.
    if (!this.isReceiving(payload.FileHash)) this.broadcastFileRequest(payload.FileHash);
    return false;
  }

  // Bytes are still fetched and cached when autoApply is off (handleIncomingFileEntry
  // requests them regardless), so Share/Save work on the item later.
  private async applyFileEntry(entry: ClipboardEntry): Promise<void> {
    // Deleted while its bytes were on their way - a relay of the same entry
    // can have queued it again after deleteEntry dropped it.
    if (await this.history.isDeleted(this.context, entry)) return;
    const result: ApplyResult = this.autoApply ? await applyEntryToClipboard(entry, this.fileStore) : 'skipped';
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
      void conn.send(json);
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
    for (const fileHash of this.pendingEntries.keys()) {
      wanted.set(fileHash.toLowerCase(), fileHash);
    }
    try {
      (await this.missingFiles()).forEach((fileHash: string, key: string) => {
        if (!wanted.has(key)) wanted.set(key, fileHash);
      });
    } catch (e) {
      // history unreadable - the entries waiting here are still asked for
    }
    wanted.forEach((fileHash: string) => {
      if (!this.fileStore.exists(fileHash) && !this.isReceiving(fileHash)) {
        void conn.send(this.fileRequestJson(fileHash));
      }
    });
  }

  // Asks `from` for a file again after a transfer of it came to nothing -
  // failed its hash check, had a gap, or went by unused - while an item
  // still wants it and nobody is sending it. Only MAX_RETRIES times between
  // successes: a sender whose copy is bad would otherwise be asked forever.
  // A peer connecting asks once more anyway (see requestMissingFiles). The
  // same rule as Android's requestAgain.
  private async requestAgain(fileHash: string, from: PeerConnection[]): Promise<void> {
    if (this.fileStore.exists(fileHash) || this.isReceiving(fileHash)) return;
    // A new item's (see pendingEntries), or an older one's.
    let wanted: boolean = this.pendingEntries.has(fileHash);
    if (!wanted) {
      try {
        wanted = (await this.missingFiles()).has(fileHash.toLowerCase());
      } catch (e) {
        // history unreadable - nothing known to want it
      }
    }
    // Checked again after reading the history: a stream may have started.
    if (!wanted || this.fileStore.exists(fileHash) || this.isReceiving(fileHash)) return;
    const live: PeerConnection[] = from.filter((c: PeerConnection) => !c.isClosed);
    if (live.length === 0) return;
    const key: string = fileHash.toLowerCase();
    const tries: number = (this.retries.get(key) ?? 0) + 1;
    this.retries.set(key, tries);
    if (tries > MAX_RETRIES) {
      if (tries === MAX_RETRIES + 1) this.logCallback?.('giving up on a file until a device reconnects');
      return;
    }
    const json: string = this.fileRequestJson(fileHash);
    for (const c of live) {
      void c.send(json);
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
      void this.streamFileToPeer(requestingConn, this.fileStore.getPath(request.FileHash), request.FileHash);
    }
    // if we don't have it either, just don't respond - the requester
    // already broadcast to everyone else too; someone else might have it
  }

  // Reads a file incrementally and sends it as a sequence of file_chunk
  // envelopes - bounded memory (one chunk at a time) regardless of the
  // file's total size, matching Program.cs's StreamFileToPeer.
  async streamFileToPeer(conn: PeerConnection, filePath: string, fileHash: string): Promise<void> {
    const key = `${conn.peerDeviceId}:${fileHash}`;
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
      try {
        let sent = 0;
        let chunkIndex = 0;
        while (sent < totalSize) {
          const buffer = new ArrayBuffer(CHUNK_SIZE);
          const bytesRead = fs.readSync(file.fd, buffer);
          if (bytesRead <= 0) break;
          sent += bytesRead;
          const chunkBytes = new Uint8Array(buffer.slice(0, bytesRead));
          const chunkMsg: FileChunkMessage = {
            FileHash: fileHash,
            ChunkIndex: chunkIndex,
            IsLast: sent >= totalSize,
            DataBase64: base64Helper.encodeToStringSync(chunkBytes),
          };
          const envelope: Envelope = { Type: 'file_chunk', Payload: JSON.stringify(chunkMsg) };
          await conn.send(JSON.stringify(envelope));
          chunkIndex++;
        }
      } catch (e) {
        // peer disconnected mid-transfer - nothing further to do
      } finally {
        fs.closeSync(file);
      }
    } finally {
      this.streamingInFlight.delete(key);
    }
  }

  // One stream per peer per file, each into a temp file of its own (see
  // incoming), taken in order: a stream starts at chunk 0, so the middle of
  // one this side never saw start (cut off, or begun before this run) is
  // ignored, and a sender that starts over at 0 gets a fresh file. Bytes
  // already stored aren't written again - a second peer's stream of a file
  // stops as soon as the first one's is stored. A file whose stream comes to
  // nothing (a gap, a hash mismatch) is asked for again, a few times - see
  // requestAgain.
  private async handleFileChunk(payloadJson: string, conn: PeerConnection): Promise<void> {
    let chunk: FileChunkMessage;
    try {
      chunk = JSON.parse(payloadJson) as FileChunkMessage;
    } catch (e) {
      return;
    }
    // The hash names the file these bytes are written to.
    if (!isValidFileHash(chunk.FileHash)) return;

    const key = `${conn.peerDeviceId}:${chunk.FileHash}`;
    let transfer: IncomingTransfer | undefined = this.incoming.get(key);
    const place: ChunkPlace =
      placeChunk(transfer !== undefined, transfer?.conn === conn, transfer?.nextIndex ?? 0, chunk.ChunkIndex);
    if (place === 'ignore') {
      // The end of a stream this side couldn't use - one it gave up on, say.
      // With nobody else sending the file now, its sender may as well start
      // over.
      if (chunk.IsLast) await this.requestAgain(chunk.FileHash, [conn]);
      return;
    }
    if (transfer !== undefined && place === 'abandon') {
      this.logCallback?.('file chunk out of order - abandoning this transfer');
      this.abortTransfer(key, transfer);
      await this.requestAgain(chunk.FileHash, this.connectionsExcept(null));
      return;
    }
    if (transfer !== undefined && place === 'restart') {
      // Its sender started over (or its new connection did): so does this
      // side, from an empty file.
      this.abortTransfer(key, transfer);
      transfer = undefined;
    }
    // Stored already - by another peer's stream that got here first, or this
    // device copying the same file itself meanwhile, in which case an entry
    // may still be waiting on them.
    if (transfer !== undefined && this.fileStore.exists(chunk.FileHash)) {
      this.abortTransfer(key, transfer);
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
        transfer = { fileHash: chunk.FileHash, conn: conn, fd: file.fd, tempPath: tempPath, nextIndex: 0 };
      } catch (e) {
        this.logCallback?.(`failed writing file chunk (${e}) - abandoning this transfer`);
        return;
      }
      this.incoming.set(key, transfer);
    }

    // Decoded only once it's known to be written: the rest of a second
    // peer's stream of a file that's stored already is ignored unread.
    let chunkBytes: Uint8Array;
    try {
      // An empty file's only chunk is empty (see streamFileToPeer).
      chunkBytes = chunk.DataBase64 === '' ? new Uint8Array(0) : base64Helper.decodeSync(chunk.DataBase64);
    } catch (e) {
      this.logCallback?.('file chunk is not Base64 - abandoning this transfer');
      this.abortTransfer(key, transfer);
      return;
    }
    try {
      if (chunkBytes.byteLength > 0) {
        const ab = chunkBytes.buffer.slice(chunkBytes.byteOffset, chunkBytes.byteOffset + chunkBytes.byteLength) as ArrayBuffer;
        fs.writeSync(transfer.fd, ab);
      }
    } catch (e) {
      this.logCallback?.(`failed writing file chunk (${e}) - abandoning this transfer`);
      this.abortTransfer(key, transfer);
      return;
    }
    transfer.nextIndex++;

    if (!chunk.IsLast) return;

    // Off the map before anything awaits: another stream of this file (its
    // sender answering a file_request once this one's done, say) writes a
    // file of its own meanwhile, and can't truncate or delete this one.
    this.incoming.delete(key);
    const tempPath = transfer.tempPath;
    let actualHash = '';
    try {
      fs.closeSync(transfer.fd);
      actualHash = await sha256File(tempPath);
    } catch (e) {
      // unreadable - fails the check below
    }
    if (actualHash.toLowerCase() !== chunk.FileHash.toLowerCase()) {
      // corrupted in transit, or tampered - the signed entry's hash is
      // what we trust, not whatever bytes actually showed up
      this.logCallback?.('file transfer failed hash verification - discarding');
      removeIfThere(tempPath);
      // The entry still waits: another peer's copy, or this one's next
      // stream, may be intact.
      await this.requestAgain(chunk.FileHash, this.connectionsExcept(null));
      return;
    }

    try {
      fs.renameSync(tempPath, this.fileStore.getPath(chunk.FileHash));
    } catch (e) {
      this.logCallback?.(`could not store a received file (${e})`);
      removeIfThere(tempPath);
      return;
    }
    this.retries.delete(chunk.FileHash.toLowerCase());
    // Its item was deleted or cleared while these bytes were on their way,
    // and nothing is waiting on them now: kept, they'd be an orphan.
    if (this.abandonedHashes.delete(chunk.FileHash) && !this.pendingEntries.has(chunk.FileHash)) {
      await this.history.deleteFileIfUnused(this.context, chunk.FileHash);
      return;
    }
    if (!(await this.tryFulfillPendingEntry(chunk.FileHash))) this.fileStoredCallback?.(chunk.FileHash);
  }

  // Ends one incoming stream early: off the map, its fd closed and its
  // half-written file deleted.
  private abortTransfer(key: string, transfer: IncomingTransfer): void {
    this.incoming.delete(key);
    try {
      fs.closeSync(transfer.fd);
    } catch (e) {
      // closed already
    }
    removeIfThere(transfer.tempPath);
  }

  private isReceiving(fileHash: string): boolean {
    for (const transfer of this.incoming.values()) {
      if (transfer.fileHash === fileHash) return true;
    }
    return false;
  }

  // A closed connection's streams never resume - every sender starts over
  // at chunk 0 - so each one's half-written file goes, rather than its fd
  // staying open for good. Returns the hashes that were cut off.
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
  // becomes available, a pending entry waiting on exactly that hash
  // should get applied. False if none was waiting.
  private async tryFulfillPendingEntry(fileHash: string): Promise<boolean> {
    const entry = this.pendingEntries.get(fileHash);
    if (entry === undefined) return false;
    this.pendingEntries.delete(fileHash);
    await this.applyFileEntry(entry);
    return true;
  }

  private applyToClipboard(entry: ClipboardEntry): Promise<ApplyResult> {
    return this.autoApply ? applyEntryToClipboard(entry, this.fileStore) : Promise.resolve<ApplyResult>('skipped');
  }

  private async handleMessage(msg: string, conn: PeerConnection, link: SyncLink): Promise<void> {
    let envelope: Envelope;
    try {
      envelope = JSON.parse(msg) as Envelope;
    } catch (e) {
      this.logCallback?.('received invalid message from peer (bad JSON)');
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
      // Deleted here before - neither re-listed nor put on the clipboard.
      if (await this.history.isDeleted(this.context, entry)) return;
      await this.applyAndReport(entry);
      await this.history.addToHistory(this.context, entry);
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
      await this.handleFileChunk(envelope.Payload, conn);
    } else if (envelope.Type === 'file_request') {
      this.handleFileRequest(envelope.Payload, conn);
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
