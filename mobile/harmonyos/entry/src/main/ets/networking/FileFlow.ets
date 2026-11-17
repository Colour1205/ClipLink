// Flow control for file streams, the plain parts: the handshake capability
// that turns it on, the file_ack message, and the window a sender keeps. No
// sockets or files in here, so entry/src/test can run all of it; SyncManager
// puts it to work. Mirrors the "Files" section of docs/protocol.md.
//
// Why it exists: the socket API on this phone cannot pause a sender, so a PC
// that sends a big file faster than the phone takes it in fills the phone's
// memory with lines it has not read yet. A 290 MB file from a PC that sent all
// of it in 6 s killed the app (shared heap out of memory) at 58%. With flow
// control the receiver says which chunks it has written, and the sender keeps
// only a few chunks ahead of that.
//
// It is only used when both sides know it. Each new build lists "file-ack" in
// its handshake's Caps. A receiver acknowledges chunks only to a sender that
// listed it, and a sender waits for acknowledgements only from a receiver that
// listed it. A peer that lists nothing (every older build) gets exactly the
// behaviour it had before, both ways: no file_ack is sent to it, and nothing is
// waited for from it. Like DeviceName and Protocol, Caps is not signed: a man
// in the middle who strips it only turns the pacing off, which is how every
// older build talks anyway, and an ack only paces sending: it never changes
// what is stored.

// What this build lists in its handshake's Caps.
export const FILE_ACK_CAP: string = 'file-ack';
export const OWN_CAPS: string[] = [FILE_ACK_CAP];
// A handshake's Caps is read up to this many items, each up to this long: the
// handshake comes before anything is trusted, so a stranger's list is cut down
// rather than kept whole.
export const MAX_CAPS: number = 32;
export const MAX_CAP_LENGTH: number = 64;

// The envelope Type of an acknowledgement.
export const FILE_ACK_TYPE: string = 'file_ack';

// How many chunks a sender may have sent and not had acknowledged: 8 chunks of
// 256 KiB, 2 MiB of file (about 3.7 MB of lines on the wire). That is little
// for the phone to hold, and still enough to keep a fast link busy: at the
// phone's own pace (about 18 MB/s) 2 MiB lasts about 110 ms, longer than a
// round trip on a home network, so the next acknowledgement is back before
// the sender runs dry.
export const ACK_WINDOW: number = 8;
// A sender whose window is full and that hears no acknowledgement for this
// long gives the stream up. The receiver asks for the file again when it needs
// it, as it does after any stream that comes to nothing.
export const ACK_TIMEOUT_MS: number = 30000;
// A receiver that has written everything a pacing sender sent, and then gets
// no chunk of that stream for this long, takes the sender to have given up
// (its own ACK_TIMEOUT_MS ran out while this side was held up) and asks for
// the file again, instead of keeping a stream open that will never finish.
// Longer than ACK_TIMEOUT_MS, so a sender that is only waiting is never
// mistaken for one that gave up.
export const STALLED_STREAM_MS: number = ACK_TIMEOUT_MS + 15000;

// The capabilities a peer's handshake lists: its Caps, or none when the field
// is missing or not a list (every older build). Items that are not strings,
// are empty or are too long are skipped.
export function peerCapsOf(value: Object | null | undefined): string[] {
  if (!Array.isArray(value)) return [];
  const raw: Object[] = value as Object[];
  const caps: string[] = [];
  for (let i = 0; i < raw.length && caps.length < MAX_CAPS; i++) {
    const item: Object = raw[i];
    if (typeof item !== 'string') continue;
    const cap: string = item as string;
    if (cap.length > 0 && cap.length <= MAX_CAP_LENGTH) caps.push(cap);
  }
  return caps;
}

// Whether a peer that listed `caps` paces file streams with file_ack.
export function acksFiles(caps: string[]): boolean {
  return caps.includes(FILE_ACK_CAP);
}

// One acknowledgement: the chunk `ChunkIndex` of the stream of `FileHash` has
// been dealt with by the receiver (written and hashed, or set aside unwritten).
// FileHash is spelt exactly as the chunk spelt it.
export interface FileAck {
  FileHash: string;
  ChunkIndex: number;
}

// The payload of a file_ack.
export function buildFileAckPayload(fileHash: string, chunkIndex: number): string {
  const ack: FileAck = { FileHash: fileHash, ChunkIndex: chunkIndex };
  return JSON.stringify(ack);
}

// The file_ack payload a receiver sends once a chunk of `fileHash` numbered
// `chunkIndex` has been dealt with, or null when it sends none: always null
// for a sender that did not list file-ack (an older build is sent nothing
// new), and null for a chunk with no usable index (the sender takes an
// acknowledgement to cover every chunk before it, so the next one does).
// (chunkIndex is whatever the peer's JSON held, whatever its type says.)
export function fileAckFor(senderAcksFiles: boolean, fileHash: string, chunkIndex: number): string | null {
  if (!senderAcksFiles) return null;
  if (typeof chunkIndex !== 'number' || !Number.isInteger(chunkIndex) || chunkIndex < 0) return null;
  return buildFileAckPayload(fileHash, chunkIndex);
}

// A received file_ack, or null when it is not one: not a JSON object, no hash
// that is a string, or a ChunkIndex that is not a whole number of 0 or more.
// Whether the hash names a stream under way is the sender's business.
export function parseFileAck(payload: string): FileAck | null {
  let wire: FileAck;
  try {
    wire = JSON.parse(payload) as FileAck;
  } catch (e) {
    return null;
  }
  if (wire === null || wire === undefined || typeof wire !== 'object' || Array.isArray(wire)) return null;
  if (typeof wire.FileHash !== 'string' || wire.FileHash.length === 0) return null;
  const index: number = wire.ChunkIndex;
  if (typeof index !== 'number' || !Number.isInteger(index) || index < 0) return null;
  const ack: FileAck = { FileHash: wire.FileHash, ChunkIndex: index };
  return ack;
}

// The clock an AckWindow waits on: setTimeout and clearTimeout in the app,
// a hand-driven one in the tests.
export interface AckTimers {
  start(callback: () => void, ms: number): number;
  stop(id: number): void;
}

class SystemTimers implements AckTimers {
  start(callback: () => void, ms: number): number {
    return setTimeout(callback, ms);
  }

  stop(id: number): void {
    clearTimeout(id);
  }
}

// What a sender keeps for one stream it sends to a receiver that acknowledges
// chunks: how many it has sent, how far the receiver has acknowledged, and the
// one wait for room in between. Chunks go in order and a receiver deals with
// them in order, so an acknowledgement of chunk n stands for every chunk up
// to n.
export class AckWindow {
  private readonly size: number;
  private readonly timeoutMs: number;
  private readonly timers: AckTimers;
  // The index of the next chunk to be sent (so, how many have been sent).
  private nextIndex: number = 0;
  // The highest chunk acknowledged, or -1 for none.
  private ackedThrough: number = -1;
  private waiter: ((room: boolean) => void) | null = null;
  private timerId: number = -1;
  private cancelled: boolean = false;
  // The last wait ran out with no acknowledgement.
  timedOut: boolean = false;

  constructor(size: number = ACK_WINDOW, timeoutMs: number = ACK_TIMEOUT_MS, timers: AckTimers = new SystemTimers()) {
    this.size = size;
    this.timeoutMs = timeoutMs;
    this.timers = timers;
  }

  // Chunks sent and not acknowledged yet.
  get unacked(): number {
    return this.nextIndex - 1 - this.ackedThrough;
  }

  // Whether another chunk may be sent now.
  get hasRoom(): boolean {
    return !this.cancelled && this.unacked < this.size;
  }

  // Chunk `index` has been handed to the connection. Chunk 0 starts the window
  // again from empty: a stream that starts over owes nothing from before.
  sent(index: number): void {
    if (index === 0) this.ackedThrough = -1;
    this.nextIndex = index + 1;
  }

  // The receiver acknowledged chunk `index`. One for a chunk not sent yet in
  // this stream (a late one from a stream that started over), or for one
  // already covered, changes nothing. Returns whether it moved the window.
  //
  // An acknowledgement names no stream, only the file, so a late one from a
  // stream that started over on the same connection, for a chunk below
  // nextIndex, is counted for the new stream. That only loosens the pacing
  // for a moment (at most about twice ACK_WINDOW chunks on their way instead
  // of ACK_WINDOW), and an acknowledgement never changes what is stored, so
  // it is left at that.
  ack(index: number): boolean {
    if (index >= this.nextIndex || index <= this.ackedThrough) return false;
    this.ackedThrough = index;
    if (this.waiter !== null && this.hasRoom) this.settle(true);
    return true;
  }

  // Resolves true as soon as another chunk may be sent: at once when there is
  // room, otherwise when an acknowledgement makes some. Resolves false when
  // no acknowledgement comes for timeoutMs (timedOut is then set), or when the
  // window is cancelled. One wait at a time: one sender loop owns a window.
  waitForRoom(): Promise<boolean> {
    if (this.cancelled) return Promise.resolve(false);
    if (this.hasRoom) return Promise.resolve(true);
    if (this.waiter !== null) this.settle(false);
    return new Promise<boolean>((resolve: (room: boolean) => void) => {
      this.waiter = resolve;
      this.timerId = this.timers.start(() => {
        this.timerId = -1;
        this.timedOut = true;
        this.settle(false);
      }, this.timeoutMs);
    });
  }

  // The stream is over (its connection closed, say): a wait still running
  // ends now with false, and so does every later one.
  cancel(): void {
    this.cancelled = true;
    if (this.waiter !== null) this.settle(false);
  }

  private settle(room: boolean): void {
    if (this.timerId !== -1) {
      this.timers.stop(this.timerId);
      this.timerId = -1;
    }
    const waiter: ((room: boolean) => void) | null = this.waiter;
    this.waiter = null;
    waiter?.(room);
  }
}

// What a sender asks before each chunk: true to send it, false to stop the
// stream. With no window (a receiver that does not acknowledge chunks, so an
// older build) the answer is always yes at once: the stream goes as fast as it
// always did.
export function mayProceed(acks: AckWindow | null): Promise<boolean> {
  return acks === null ? Promise.resolve(true) : acks.waitForRoom();
}

// A chunk handed to the connection: `written` resolves once it is written to
// the socket, and never rejects (a failed send makes ChunkSender.more false
// instead). Wrapped, because a promise returned from an async function is
// waited for, not handed back.
export interface HandedChunk {
  written: Promise<void>;
}

// What pumpChunks drives: one file's chunks, read and handed to the
// connection one at a time.
export interface ChunkSender {
  // Whether there are chunks left to send and the stream may go on (no send
  // has failed, the connection is open).
  more(): boolean;
  // Reads chunk `index` and hands it to the connection; resolves as soon as
  // it is handed over, not once it is written. Resolves null when the file
  // turned out to have no more (it shrank while being sent), and rejects when
  // the chunk could not be read or encoded.
  send(index: number): Promise<HandedChunk | null>;
}

// How a pumpChunks run ended: everything sent (or the stream stopped, its
// connection gone), or the receiver acknowledged nothing for ACK_TIMEOUT_MS.
export type PumpEnd = 'ended' | 'timed-out';

// A file's chunks, sent in order: at most `sendWindow` handed to the
// connection and not yet written, and with a window (a receiver that
// acknowledges chunks) at most its size sent and not acknowledged. Without
// one (an older receiver) nothing is waited for but the socket, as before.
// Returns once every send it started has settled, or rejects as
// sender.send does.
export async function pumpChunks(sender: ChunkSender, acks: AckWindow | null, sendWindow: number): Promise<PumpEnd> {
  // The chunks handed over and not yet written, oldest first.
  const inFlight: Promise<void>[] = [];
  try {
    let index: number = 0;
    while (sender.more()) {
      if (acks !== null && !acks.hasRoom) {
        // The window's timeout is for the receiver, so it starts only once
        // this side's own chunks are written: one still in this side's write
        // queue (behind a big history batch on a slow link, say) can't have
        // been acknowledged yet. Nothing more could be sent meanwhile anyway.
        await Promise.all(inFlight.splice(0));
        if (!sender.more()) break;
      }
      // Before the chunk is read, so a receiver that is behind costs this
      // side no memory either.
      if (!(await mayProceed(acks))) return acks !== null && acks.timedOut ? 'timed-out' : 'ended';
      const handed: HandedChunk | null = await sender.send(index);
      if (handed === null) break;
      inFlight.push(handed.written);
      acks?.sent(index);
      index++;
      if (inFlight.length >= sendWindow) await inFlight.shift();
    }
    return 'ended';
  } finally {
    await Promise.all(inFlight);
  }
}

// What a receiver does with one stream from a sender that paces its streams,
// on each heartbeat tick (see STALLED_STREAM_MS): 'wait' while chunks it took
// are still being written (the sender is waiting on this side), 'touch' while
// something from the sender is still on its way through (a big line on a slow
// link holds up every chunk behind it, so the quiet is not the sender's),
// 'drop' once it has been quiet for STALLED_STREAM_MS since its last chunk,
// and 'wait' before that.
export type StallVerdict = 'wait' | 'touch' | 'drop';

export function stallVerdict(writesWaiting: number, receiving: boolean, lastChunkAt: number, now: number): StallVerdict {
  if (writesWaiting > 0) return 'wait';
  if (receiving) return 'touch';
  return now - lastChunkAt >= STALLED_STREAM_MS ? 'drop' : 'wait';
}
