// Devices whose pairing requests are held back for a while.
//
// A device this one does not trust still gets here whenever the other end
// trusts this one and dials it: the other end redials for as long as it keeps
// its trust record, and each connection used to raise a new pairing request. So a
// request that was ignored (or never answered), or a device that was removed,
// came back again and again - the same device, a prompt every few minutes, for ever.
//
// The cure is in two parts. Removing a device (or tapping Ignore on its request)
// sends it an "unpair" message, so the other end drops its trust record and stops
// redialling (SyncManager.onUnpaired). And this: a device whose request was ignored
// or expired, or that was removed, is quiet for a while - its connection is closed
// without a prompt - which covers a peer that was offline when the message went, or
// is a build that ignores it. A device that was removed is told again whenever it
// connects while it is quiet. Blocking is the permanent version (BlockStore).
//
// Lifted early by what asks for it: opening the pairing screen, pairing by address
// or QR code, trusting the device. In memory only: a restart starts fresh. The same
// rule is in every platform's engine (ClipLinkEngine.cs, ClipLinkEngine.kt,
// SyncEngine.swift): change them together.

import { sameIdentityKey } from './PeerConnection';

// After an ignored request, or one nobody answered.
export const QUIET_AFTER_IGNORED_MS: number = 30 * 60 * 1000;
// After the user removed the device: it is not coming back on its own.
export const QUIET_AFTER_REMOVED_MS: number = 6 * 60 * 60 * 1000;

export type QuietState = 'none' | 'ignored' | 'removed';

class QuietEntry {
  id: string;
  untilMs: number;
  removed: boolean;

  constructor(id: string, untilMs: number, removed: boolean) {
    this.id = id;
    this.untilMs = untilMs;
    this.removed = removed;
  }
}

export class RequestQuiet {
  private entries: QuietEntry[] = [];

  // id is quiet for spanMs; removed says why (removed, as against ignored).
  quiet(id: string, spanMs: number, removed: boolean = false, nowMs: number = Date.now()): void {
    if (id.length === 0) return;
    this.entries = this.entries.filter((e: QuietEntry) => !sameIdentityKey(e.id, id));
    this.entries.push(new QuietEntry(id, nowMs + spanMs, removed));
  }

  // Whether id is quiet, and if so whether it was removed (as against ignored).
  state(id: string, nowMs: number = Date.now()): QuietState {
    this.entries = this.entries.filter((e: QuietEntry) => e.untilMs > nowMs); // over
    const entry: QuietEntry | undefined = this.entries.find((e: QuietEntry) => sameIdentityKey(e.id, id));
    if (entry === undefined) return 'none';
    return entry.removed ? 'removed' : 'ignored';
  }

  release(id: string): void {
    this.entries = this.entries.filter((e: QuietEntry) => !sameIdentityKey(e.id, id));
  }

  clear(): void {
    this.entries = [];
  }
}
