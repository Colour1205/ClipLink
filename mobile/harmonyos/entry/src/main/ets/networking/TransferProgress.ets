// What the card of a file that is still arriving shows: one thin bar, the
// speed above its left end and the percentage (or, in the opened item, "124 of
// 290 MB") above its right end. SyncManager says how many bytes have arrived;
// this works out the rest. Nothing in here touches a socket, a file or the UI,
// so it can be checked on its own (see test/TransferProgress.test.ets).
//
// The total is the FileSize the signed entry gives, so a sender of any version
// needs to do nothing for it: the receiver counts the bytes itself.

// SyncManager tells the page at most this often while bytes arrive (and
// always at a stream's start and end), so the page redraws the bar about 4
// times a second, whatever the speed.
export const PROGRESS_INTERVAL_MS: number = 250;
// The speed is the bytes of about the last 2 seconds over their time, so it
// does not jump with every chunk.
export const SPEED_WINDOW_MS: number = 2000;
// Nothing is shown as a speed for the first moments of a stream: a number made
// of one or two chunks is noise.
export const SPEED_HIDDEN_MS: number = 750;
// After this long with no new bytes the speed gives way to a word saying the
// transfer is waiting.
export const STALLED_AFTER_MS: number = 3000;

// Where one file's transfer is, as SyncManager reports it:
//   'receiving' - a stream is under way (or, for an entry listed early, about
//                 to be asked for);
//   'retrying'  - a stream failed (a gap, a wrong hash, a write error, the
//                 connection closing) and the file was asked for again;
//   'waiting'   - nobody is sending it because no device is connected to ask;
//   'stopped'   - devices are connected but it is not asked for any more on
//                 this run (retries used up, or too big to take in at the
//                 sender's pace) until a device reconnects;
//   'done'      - the bytes are stored.
export type TransferPhase = 'receiving' | 'retrying' | 'waiting' | 'stopped' | 'done';

// One report from SyncManager. fileHash is lowercase; received is the bytes of
// the current stream so far (a new stream starts again from 0).
export interface TransferUpdate {
  fileHash: string;
  phase: TransferPhase;
  received: number;
}

const KIB: number = 1024;
const MIB: number = 1024 * 1024;
const GIB: number = 1024 * 1024 * 1024;

// At most one report per PROGRESS_INTERVAL_MS. The check runs when a chunk is
// written, so nothing ticks while no bytes come.
export class ProgressThrottle {
  private last: number = Number.NEGATIVE_INFINITY;

  // Whether a report is due now; if it is, the next one is due an interval on.
  due(now: number): boolean {
    if (now - this.last < PROGRESS_INTERVAL_MS) return false;
    this.last = now;
    return true;
  }
}

interface Sample {
  at: number;
  bytes: number;
}

// The bytes of one stream over time, for its speed and for noticing that it
// stopped. received is always the stream's running total, not a step.
export class SpeedMeter {
  private samples: Sample[] = [];
  private startedAt: number = -1;
  private lastGrowthAt: number = -1;
  private lastBytes: number = 0;

  // A new stream (or the first report): everything before it is forgotten.
  // A sender that starts over sends from 0 again, so fewer bytes than last
  // time means a new stream too, and so does a report of 0: SyncManager sends
  // one when a stream starts, and the card may have been listed (with a 0 of
  // its own) seconds before that, which would otherwise count as the stream's
  // start and spread its first bytes over the wait.
  add(received: number, now: number): void {
    if (this.startedAt < 0 || received < this.lastBytes || received === 0) {
      this.samples = [];
      this.startedAt = now;
      this.lastGrowthAt = now;
      this.lastBytes = 0;
    }
    if (received > this.lastBytes) this.lastGrowthAt = now;
    this.lastBytes = received;
    this.samples.push({ at: now, bytes: received });
    // The oldest sample kept is the last one at or before the window's start,
    // so the window is always covered from its beginning.
    while (this.samples.length > 2 && this.samples[1].at <= now - SPEED_WINDOW_MS) {
      this.samples.shift();
    }
  }

  // Forgets the stream: the next add starts a new one.
  reset(): void {
    this.samples = [];
    this.startedAt = -1;
    this.lastGrowthAt = -1;
    this.lastBytes = 0;
  }

  // No new bytes for STALLED_AFTER_MS.
  stalled(now: number): boolean {
    return this.startedAt >= 0 && now - this.lastGrowthAt >= STALLED_AFTER_MS;
  }

  // Bytes per second over about the last SPEED_WINDOW_MS, or -1 while there is
  // nothing worth showing: too early in the stream, stalled, or too few
  // samples to measure.
  bytesPerSecond(now: number): number {
    if (this.startedAt < 0 || now - this.startedAt < SPEED_HIDDEN_MS || this.stalled(now)) return -1;
    if (this.samples.length < 2) return -1;
    const first: Sample = this.samples[0];
    const last: Sample = this.samples[this.samples.length - 1];
    const span: number = last.at - first.at;
    if (span < PROGRESS_INTERVAL_MS / 2) return -1;
    return (last.bytes - first.bytes) * 1000 / span;
  }
}

// "8.3 MB/s": one decimal under 100 MB/s, none above it, and KB/s under 1 MB/s.
// Units of 1024, as the card's own size (Index's formatFileSize).
export function speedLabel(bytesPerSecond: number): string {
  if (bytesPerSecond < 0) return '';
  if (bytesPerSecond < MIB) return `${Math.max(1, Math.round(bytesPerSecond / KIB))} KB/s`;
  const mb: number = bytesPerSecond / MIB;
  return mb < 100 ? `${mb.toFixed(1)} MB/s` : `${Math.round(mb)} MB/s`;
}

// How much of the file is here, 0 to 1, or -1 when the total is not known.
export function progressFraction(received: number, total: number): number {
  if (total <= 0) return -1;
  return Math.min(1, Math.max(0, received / total));
}

// "43%", rounded down, and never 100% before the last byte: a bar that says
// 100% and then sits there for the last chunk looks stuck. '' with no total.
export function percentLabel(received: number, total: number): string {
  if (total <= 0) return '';
  let percent: number = Math.floor(Math.max(0, received) * 100 / total);
  if (received < total) percent = Math.min(percent, 99);
  return `${Math.min(100, percent)}%`;
}

// The parts of "124 of 290 MB": both numbers in the total's unit, the part
// that is here rounded down so it never reads as the whole before it is.
export interface AmountParts {
  done: string;
  total: string;
  unit: string;
}

function floorTo(value: number, decimals: number): string {
  const scale: number = Math.pow(10, decimals);
  return (Math.floor(value * scale + 1e-9) / scale).toFixed(decimals);
}

export function amountParts(received: number, total: number): AmountParts {
  const done: number = Math.min(Math.max(0, received), Math.max(0, total));
  let unit: string = 'B';
  let size: number = 1;
  let decimals: number = 0;
  if (total >= GIB) {
    unit = 'GB';
    size = GIB;
    decimals = 1;
  } else if (total >= MIB) {
    unit = 'MB';
    size = MIB;
    // A small file would read "1 of 3 MB" for a long while: one decimal.
    decimals = total < 10 * MIB ? 1 : 0;
  } else if (total >= KIB) {
    unit = 'KB';
    size = KIB;
  }
  const parts: AmountParts = {
    done: floorTo(done / size, decimals),
    total: (total / size).toFixed(decimals),
    unit: unit,
  };
  return parts;
}

// "12.4 MB": what has arrived, for a file whose size is not known.
export function receivedLabel(received: number): string {
  if (received < KIB) return `${Math.max(0, received)} B`;
  if (received < MIB) return `${Math.floor(received / KIB)} KB`;
  if (received < GIB) return `${(received / MIB).toFixed(1)} MB`;
  return `${(received / GIB).toFixed(2)} GB`;
}

// What, instead of the numbers, the bar's left end says:
//   'none'     - nothing: the speed (or nothing, early on) shows;
//   'stalled'  - no bytes for STALLED_AFTER_MS ("Waiting");
//   'retrying' - the stream failed and the file was asked for again;
//   'waiting'  - nobody is sending it now: no device to ask;
//   'stopped'  - it is not asked for again until a device reconnects.
export type TransferStatus = 'none' | 'stalled' | 'retrying' | 'waiting' | 'stopped';

// Everything the bar shows, worked out at one moment.
export interface TransferView {
  // 0 to 1, or -1 for a file whose size is not known.
  fraction: number;
  // '' while hidden (early, stalled, failed).
  speed: string;
  // The right end on a card: "43%", or what has arrived when the size is
  // not known. '' when a status replaces the numbers.
  cardRight: string;
  // The right end in the opened item: "124 of 290 MB" in parts, or (size not
  // known) received holds "12.4 MB" and the parts are ''.
  amount: AmountParts;
  received: string;
  status: TransferStatus;
  done: boolean;
}

const NO_AMOUNT: AmountParts = { done: '', total: '', unit: '' };

// The view of one transfer now. total is the entry's FileSize (0 or less: not
// known).
export function transferView(phase: TransferPhase, received: number, total: number, meter: SpeedMeter,
  now: number): TransferView {
  if (phase === 'retrying' || phase === 'waiting' || phase === 'stopped') {
    const failed: TransferView = {
      fraction: total > 0 ? 0 : -1, speed: '', cardRight: '', amount: NO_AMOUNT, received: '',
      status: phase, done: false,
    };
    return failed;
  }
  const done: boolean = phase === 'done';
  const shown: number = done && total > 0 ? total : received;
  const stalled: boolean = !done && meter.stalled(now);
  const knownTotal: boolean = total > 0;
  const view: TransferView = {
    fraction: done ? 1 : progressFraction(shown, total),
    speed: done || stalled ? '' : speedLabel(meter.bytesPerSecond(now)),
    cardRight: knownTotal ? percentLabel(shown, total) : receivedLabel(shown),
    amount: knownTotal ? amountParts(shown, total) : NO_AMOUNT,
    received: knownTotal ? '' : receivedLabel(shown),
    status: stalled ? 'stalled' : 'none',
    done: done,
  };
  return view;
}
