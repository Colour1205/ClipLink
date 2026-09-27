// Step 8/10 of the build order in ../../../../README.md: full sync + file
// transfer. Mirrors Program.cs's HandleMessage/SendHistoryBatch/
// ClipboardChanged/HandleFileChunk/HandleFileRequest/StreamFileToPeer.

import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PeerConnection } from './PeerConnection';
import { FileChunkMessage } from './FileChunkMessage';
import { FileRequestMessage } from './FileRequestMessage';
import { TrustStore } from '../identity/TrustStore';
import { HistoryAccess } from '../storage/HistoryAccess';
import { FileStore } from '../storage/FileStore';
import { FilePayload } from '../storage/FilePayload';
import { ClipboardEntry, verifiedEntry } from '../crypto/Signing';
import { applyEntryToClipboard, ApplyResult } from '../clipboard/ClipboardApply';

const base64Helper = new util.Base64Helper();
const CHUNK_SIZE = 256 * 1024;

interface Envelope {
  Type: string;
  Payload: string;
}

async function hashFile(path: string): Promise<string> {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  const md = cryptoFramework.createMd('SHA256');
  try {
    const buffer = new ArrayBuffer(CHUNK_SIZE);
    let bytesRead = fs.readSync(file.fd, buffer);
    while (bytesRead > 0) {
      await md.update({ data: new Uint8Array(buffer.slice(0, bytesRead)) });
      bytesRead = fs.readSync(file.fd, buffer);
    }
  } finally {
    fs.closeSync(file);
  }
  const digest = (await md.digest()).data;
  let out = '';
  for (let i = 0; i < digest.length; i++) {
    out += digest[i].toString(16).padStart(2, '0');
  }
  return out;
}

export class SyncManager {
  private connections: Map<string, PeerConnection> = new Map();
  private history: HistoryAccess;
  private trustStore: TrustStore;
  private context: common.UIAbilityContext;
  private fileStore: FileStore;
  private entryAppliedCallback: ((entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => void) | null = null;
  private logCallback: ((message: string) => void) | null = null;
  private connectionsChangedCallback: ((count: number) => void) | null = null;

  // In-progress incoming chunk writes, keyed by file hash - the fd stays
  // open across every "file_chunk" message for that hash until IsLast.
  private inProgressFds: Map<string, number> = new Map();
  // Entries that arrived (and verified) before their bytes finished
  // streaming in, keyed by the file hash they're waiting on.
  private pendingEntries: Map<string, ClipboardEntry> = new Map();
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

  constructor(fileStore: FileStore, trustStore: TrustStore, context: common.UIAbilityContext) {
    this.history = new HistoryAccess(fileStore);
    this.trustStore = trustStore;
    this.context = context;
    this.fileStore = fileStore;
  }

  onEntryApplied(callback: (entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => void): void {
    this.entryAppliedCallback = callback;
  }

  onLog(callback: (message: string) => void): void {
    this.logCallback = callback;
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

  // pendingEntries is cleared too: otherwise a file whose bytes finish
  // arriving after this would still fire entryAppliedCallback and the
  // cleared item would pop back into the list. A peer's history_batch on
  // its next reconnect can still re-add entries it has, same as Android.
  getHistory(): Promise<ClipboardEntry[]> {
    return this.history.getHistory(this.context);
  }

  async clearHistory(): Promise<void> {
    this.pendingEntries.clear();
    await this.history.clearHistory(this.context);
  }

  get connectionCount(): number {
    return this.connections.size;
  }

  isConnected(deviceId: string): boolean {
    return this.connections.has(deviceId);
  }

  // Wires up a freshly-handshaken connection into ongoing sync: registers
  // it, starts listening, and sends our current history - same sequence
  // Program.cs runs right after both the accept loop and ConnectToPeer
  // complete a handshake.
  registerConnection(conn: PeerConnection): void {
    const previous = this.connections.get(conn.peerDeviceId);
    this.connections.set(conn.peerDeviceId, conn);
    this.connectionsChangedCallback?.(this.connections.size);
    conn.onMessage((msg: string) => { void this.handleMessage(msg, conn); });
    conn.onDisconnected(() => {
      // Only evict if the map still points at THIS connection. Removing by
      // peerDeviceId alone meant a stale link's teardown deleted the newer,
      // live connection that had replaced it - after which isConnected()
      // said false, so the next 2-second discovery beacon dialled again,
      // and the whole thing looped forever without clipboard ever flowing.
      // The Windows daemon carries the identical guard (Program.cs's
      // Disconnected handler); both ends need it or the other end's churn
      // keeps the loop alive.
      if (this.connections.get(conn.peerDeviceId) !== conn) return;
      this.connections.delete(conn.peerDeviceId);
      this.connectionsChangedCallback?.(this.connections.size);
      this.logCallback?.(`peer disconnected: ${conn.peerDeviceId.slice(0, 20)}...`);
    });
    conn.listen();
    void this.sendHistoryBatch(conn);
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

  private async sendHistoryBatch(conn: PeerConnection): Promise<void> {
    const history = await this.history.getHistory(this.context);
    const envelope: Envelope = { Type: 'history_batch', Payload: JSON.stringify(history) };
    await conn.send(JSON.stringify(envelope));
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
    let payload: FilePayload;
    try {
      payload = JSON.parse(entry.Content) as FilePayload;
    } catch (e) {
      this.logCallback?.('received malformed file entry from peer');
      return;
    }
    if (this.fileStore.exists(payload.FileHash)) {
      void this.applyFileEntry(entry);
      return;
    }
    this.pendingEntries.set(payload.FileHash, entry);
    this.broadcastFileRequest(payload.FileHash);
  }

  // Bytes are still fetched and cached when autoApply is off (handleIncomingFileEntry
  // requests them regardless), so Share/Save work on the item later.
  private async applyFileEntry(entry: ClipboardEntry): Promise<void> {
    const result: ApplyResult = this.autoApply ? await applyEntryToClipboard(entry, this.fileStore) : 'skipped';
    this.entryAppliedCallback?.(entry, result, true);
  }

  private broadcastFileRequest(fileHash: string): void {
    const request: FileRequestMessage = { FileHash: fileHash };
    const envelope: Envelope = { Type: 'file_request', Payload: JSON.stringify(request) };
    const json = JSON.stringify(envelope);
    for (const conn of this.connections.values()) {
      void conn.send(json);
    }
  }

  private handleFileRequest(payloadJson: string, requestingConn: PeerConnection): void {
    let request: FileRequestMessage;
    try {
      request = JSON.parse(payloadJson) as FileRequestMessage;
    } catch (e) {
      return;
    }
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

  private async handleFileChunk(payloadJson: string): Promise<void> {
    let chunk: FileChunkMessage;
    try {
      chunk = JSON.parse(payloadJson) as FileChunkMessage;
    } catch (e) {
      return;
    }
    let chunkBytes: Uint8Array;
    try {
      chunkBytes = base64Helper.decodeSync(chunk.DataBase64);
    } catch (e) {
      return;
    }

    let fd = this.inProgressFds.get(chunk.FileHash);
    if (fd === undefined) {
      const file = fs.openSync(
        this.fileStore.getTempPath(chunk.FileHash),
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC,
      );
      fd = file.fd;
      this.inProgressFds.set(chunk.FileHash, fd);
    }

    try {
      const ab = chunkBytes.buffer.slice(chunkBytes.byteOffset, chunkBytes.byteOffset + chunkBytes.byteLength) as ArrayBuffer;
      fs.writeSync(fd, ab);
    } catch (e) {
      this.logCallback?.(`failed writing file chunk (${e}) - abandoning this transfer`);
      this.inProgressFds.delete(chunk.FileHash);
      fs.closeSync(fd);
      return;
    }

    if (!chunk.IsLast) return;

    fs.closeSync(fd);
    this.inProgressFds.delete(chunk.FileHash);

    const tempPath = this.fileStore.getTempPath(chunk.FileHash);
    const actualHash = await hashFile(tempPath);
    if (actualHash.toLowerCase() !== chunk.FileHash.toLowerCase()) {
      // corrupted in transit, or tampered - the signed entry's hash is
      // what we trust, not whatever bytes actually showed up
      this.logCallback?.('file transfer failed hash verification - discarding');
      fs.unlinkSync(tempPath);
      this.pendingEntries.delete(chunk.FileHash);
      return;
    }

    fs.renameSync(tempPath, this.fileStore.getPath(chunk.FileHash));
    await this.tryFulfillPendingEntry(chunk.FileHash);
  }

  // FileStore can gain a blob through more than one path - chunk-stream
  // completion (above), but also this device's own local capture of a
  // file (see Index.ets's onPasteButtonClick). Whichever way a hash
  // becomes available, a pending entry waiting on exactly that hash
  // should get applied.
  private async tryFulfillPendingEntry(fileHash: string): Promise<void> {
    const entry = this.pendingEntries.get(fileHash);
    if (entry === undefined) return;
    this.pendingEntries.delete(fileHash);
    await this.applyFileEntry(entry);
  }

  private async handleMessage(msg: string, conn: PeerConnection): Promise<void> {
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
        this.logCallback?.(`dropped ${received.Type} entry from ${received.DeviceId.slice(0, 12)}... - failed signature/trust check`);
        return;
      }
      await this.applyAndReport(entry);
      await this.history.addToHistory(this.context, entry);
    } else if (envelope.Type === 'history_batch') {
      let entries: ClipboardEntry[];
      try {
        entries = JSON.parse(envelope.Payload) as ClipboardEntry[];
      } catch (e) {
        this.logCallback?.('received invalid message from peer (bad history_batch JSON)');
        return;
      }
      for (const received of entries) {
        const entry = await this.verifiedAndTrusted(received);
        if (entry === null) {
          continue; // skip just this bad entry, keep processing the rest of the batch
        }
        const isNew = await this.history.addToHistory(this.context, entry);
        if (isNew) {
          await this.applyAndReport(entry);
        }
      }
    } else if (envelope.Type === 'file_chunk') {
      await this.handleFileChunk(envelope.Payload);
    } else if (envelope.Type === 'file_request') {
      this.handleFileRequest(envelope.Payload, conn);
    } else {
      this.logCallback?.(`received message with unknown type from peer: ${envelope.Type}`);
    }
  }
}
