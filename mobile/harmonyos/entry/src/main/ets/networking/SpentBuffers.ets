// Buffers a file stream is done with, handed to a TaskPool worker to be freed
// there instead of on the UI thread.
//
// Why: every chunk of a file passes through about 2 MB of buffers (the
// socket's messages, the line, its decoded and decrypted bytes, the file's
// bytes), and on this thread they are freed only when the collector runs.
// It runs when the JS heap grows, which these hardly make it do, and for the
// app's first 8 seconds it does not run at all ("SmartGC: app cold start"
// in the log): a 290 MB file asked for the moment the app connected took the
// native heap past 1.2 GB before anything was freed (measured on a phone).
// Handed over by transfer, nothing is copied: the buffer's memory moves to
// the worker, which frees it soon after - a worker is not held back at
// start-up, and collects as buffers pile up there. In the app's first
// seconds, 400 buffers of 357 KB handed over this way left this side's native
// heap where it was, where 400 of 466 KB kept here added 230 MB to it.
//
// Only a buffer nothing will ever touch again may be released: it is
// detached here, and reading it after that throws. Nothing in here touches
// a socket or a worker, so it can be checked on its own (see
// test/SpentBuffers.test.ets); the worker is FreeOnWorker's.

// Handed over once this much is waiting, or this many buffers, or after
// FLUSH_MS; until then they are only held here. A batch takes one trip, about
// a millisecond however many buffers are in it.
const BATCH_BYTES = 8 * 1024 * 1024;
const BATCH_COUNT = 64;
const FLUSH_MS = 50;
// Smaller ones are not worth the trip: a ping or a clipboard entry is a few
// hundred bytes, and the collector catches up with those soon enough.
export const MIN_SPENT_BYTES = 16 * 1024;

export class SpentBuffers {
  private readonly hand: (buffers: ArrayBuffer[]) => void;
  private batch: ArrayBuffer[] = [];
  private batchBytes: number = 0;
  private timer: number = -1;

  // hand: takes a batch away (and never gives it back).
  constructor(hand: (buffers: ArrayBuffer[]) => void) {
    this.hand = hand;
  }

  // This buffer will not be used again. One released twice, already handed
  // away (detached) or small is left where it is.
  release(buffer: ArrayBuffer): void {
    let size: number = 0;
    try {
      size = buffer.byteLength;
    } catch (e) {
      return; // detached: handed away already
    }
    if (size < MIN_SPENT_BYTES || this.batch.indexOf(buffer) !== -1) return;
    this.batch.push(buffer);
    this.batchBytes += size;
    if (this.batchBytes >= BATCH_BYTES || this.batch.length >= BATCH_COUNT) {
      this.flush();
    } else if (this.timer === -1) {
      this.timer = setTimeout(() => {
        this.timer = -1;
        this.flush();
      }, FLUSH_MS);
    }
  }

  // The bytes waiting to be handed over.
  get waitingBytes(): number {
    return this.batchBytes;
  }

  // Hands over whatever is waiting, now.
  flush(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.batch.length === 0) return;
    const buffers: ArrayBuffer[] = this.batch;
    this.batch = [];
    this.batchBytes = 0;
    try {
      this.hand(buffers);
    } catch (e) {
      // not handed over: left to this thread's collector, as before
    }
  }
}
