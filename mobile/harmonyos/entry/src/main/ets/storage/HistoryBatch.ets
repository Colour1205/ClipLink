// What a peer's history_batch does to this device's history, as plain list
// work (no files, no preferences, no network) so it can be tested on its own.
// HistoryAccess.addBatch and SyncManager.handleHistoryBatch call it. Mirrors
// windows/ClipLink/Engine/Storage/HistoryBatch.cs and the docs' "Sharing
// history".

import { ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';

// One batch that adds at least this many new entries is shown as one stack on
// the Synced tab; fewer is just normal cards. (Every platform uses the same
// number.)
export const GROUP_MIN_ITEMS: number = 2;

// What merging a batch into a history did. added: the entries that are new
// and are still in the history afterwards, in the order the batch listed
// them. evicted: everything the cap pushed out (old entries, or new ones that
// were older than all the rest). duplicates: already in the history (or twice
// in the batch). deleted: the user deleted them here earlier. front: the
// newest of `added` when the merge was asked to protect it (see mergeBatch),
// else null.
export interface MergeResult {
  added: ClipboardEntry[];
  evicted: ClipboardEntry[];
  duplicates: number;
  deleted: number;
  front: ClipboardEntry | null;
}

function neverKept(entry: ClipboardEntry): boolean {
  return false;
}

function alwaysOk(entry: ClipboardEntry): boolean {
  return true;
}

// Oldest-first eviction (by timestamp, in canonical form, which is
// fixed-width so text order is time order) down to maxItems. Changes
// `history` in place and returns what went. Of equal timestamps the one
// listed first goes first. An entry `isKept` says yes to is never the one
// that goes: the oldest of the others does instead, so the history still ends
// up at maxItems.
export function trimOldest(history: ClipboardEntry[], maxItems: number, isKept: (entry: ClipboardEntry) => boolean = neverKept): ClipboardEntry[] {
  const evicted: ClipboardEntry[] = [];
  while (history.length > maxItems) {
    let oldestIndex = -1;
    for (let i = 0; i < history.length; i++) {
      if (isKept(history[i])) continue;
      if (oldestIndex === -1 || canonicalTimestamp(history[i].Timestamp) < canonicalTimestamp(history[oldestIndex].Timestamp)) {
        oldestIndex = i;
      }
    }
    if (oldestIndex === -1) break;
    evicted.push(history.splice(oldestIndex, 1)[0]);
  }
  return evicted;
}

// Adds every new, not deleted entry of `incoming` to `history`, then trims
// once. Changes `history` in place. Nothing is saved or announced here: that
// is one step for the whole batch, done by the caller.
//
// The trim spares one entry, so that the item a sync puts on the clipboard (and
// on top of the list) is not the first to go just because it is old: with
// `newFront` the newest of the entries this call adds (the result's `front`),
// else the entry `isKept` says yes to (the one an earlier call spared).
// `frontOk` is asked once, with the newest entry really added, before the trim:
// with `newFront`, that entry is the front (and spared) only if it says yes.
export function mergeBatch(history: ClipboardEntry[], incoming: ClipboardEntry[],
  isSame: (a: ClipboardEntry, b: ClipboardEntry) => boolean, isDeleted: (entry: ClipboardEntry) => boolean,
  maxItems: number, newFront: boolean = false, isKept: (entry: ClipboardEntry) => boolean = neverKept,
  frontOk: (entry: ClipboardEntry) => boolean = alwaysOk): MergeResult {
  let added: ClipboardEntry[] = [];
  let duplicates = 0;
  let deleted = 0;
  for (const entry of incoming) {
    if (history.some((known: ClipboardEntry) => isSame(known, entry))) {
      duplicates++;
    } else if (isDeleted(entry)) {
      deleted++;
    } else {
      history.push(entry);
      added.push(entry);
    }
  }
  const newest: ClipboardEntry | null = newFront ? newestOf(added) : null;
  const front: ClipboardEntry | null = newest !== null && frontOk(newest) ? newest : null;
  const evicted: ClipboardEntry[] = trimOldest(history, maxItems,
    front !== null ? (entry: ClipboardEntry): boolean => entry === front : isKept);
  if (evicted.length > 0) {
    // A new entry older than the whole history is added and trimmed in the
    // same step: it never was in the history, so it is not "added".
    added = added.filter((entry: ClipboardEntry) => !evicted.includes(entry));
  }
  return { added: added, evicted: evicted, duplicates: duplicates, deleted: deleted, front: front };
}

// What applyBatch did, in numbers and in entries. rejected: a bad signature
// or a maker this device does not trust.
export interface BatchOutcome {
  added: ClipboardEntry[];
  rejected: number;
  duplicates: number;
  deleted: number;
}

// A whole history_batch as one unit: each entry is checked (`verify`: the
// signature and the trusted maker, giving the entry as its signer signed it,
// or null; `isDeleted`: the user deleted it here), all the survivors are
// added in one step (`add`), and `announce` is called ONCE with what was
// added, if anything was - never once per entry.
export async function applyBatch(entries: ClipboardEntry[],
  verify: (entry: ClipboardEntry) => Promise<ClipboardEntry | null>,
  isDeleted: (entry: ClipboardEntry) => Promise<boolean>,
  add: (candidates: ClipboardEntry[]) => Promise<MergeResult>,
  announce: (added: ClipboardEntry[]) => Promise<void>): Promise<BatchOutcome> {
  const candidates: ClipboardEntry[] = [];
  let rejected = 0;
  let deletedEarly = 0;
  for (const received of entries) {
    const entry: ClipboardEntry | null = await verify(received);
    if (entry === null) {
      rejected++; // skip just this one, keep the rest of the batch
    } else if (await isDeleted(entry)) {
      deletedEarly++; // peers keep resending what was deleted here
    } else {
      candidates.push(entry);
    }
  }
  const merged: MergeResult = await add(candidates);
  if (merged.added.length > 0) {
    await announce(merged.added);
  }
  return { added: merged.added, rejected: rejected, duplicates: merged.duplicates, deleted: merged.deleted + deletedEarly };
}

// The newest of these by timestamp, or null for none. Of equal timestamps the
// first listed wins, so the result does not depend on how a sort breaks a tie.
export function newestOf(entries: ClipboardEntry[]): ClipboardEntry | null {
  let newest: ClipboardEntry | null = null;
  for (const entry of entries) {
    if (newest === null || canonicalTimestamp(entry.Timestamp) > canonicalTimestamp(newest.Timestamp)) {
      newest = entry;
    }
  }
  return newest;
}

// ---- history_head ----------------------------------------------------------
//
// A history_batch is big (tens of MB with pictures), so the sender first sends
// a head: the newest entry on its own and the keys of the batch that follows,
// newest first. The receiver can show the newest item and how many items are
// coming long before the batch has arrived. The batch that follows is
// unchanged (it holds the newest entry again), so a build that has never
// heard of the head just ignores it. A head belongs to the next history_batch
// on the same connection; nothing is stored or sent about it.

// More keys than this is not a history anyone sends: the head is ignored.
export const MAX_HEAD_KEYS: number = 1000;

export interface HistoryHead {
  Newest: ClipboardEntry;
  Keys: string[];
}

// The payload of a head for `history`, or null when there is no point in one
// (fewer than 2 entries: the batch is as quick as the head would be).
// keyOf: the entry's key, as the other side computes it (its Signature).
export function buildHeadPayload(history: ClipboardEntry[], keyOf: (entry: ClipboardEntry) => string): string | null {
  if (history.length < 2) return null;
  const sorted: ClipboardEntry[] = history.slice().sort((a: ClipboardEntry, b: ClipboardEntry) => {
    const at: string = canonicalTimestamp(a.Timestamp);
    const bt: string = canonicalTimestamp(b.Timestamp);
    return at < bt ? 1 : (at > bt ? -1 : 0);
  });
  const head: HistoryHead = { Newest: sorted[0], Keys: sorted.map((entry: ClipboardEntry) => keyOf(entry)) };
  return JSON.stringify(head);
}

// A received head's payload, or null if it is not one.
export function parseHead(payload: string): HistoryHead | null {
  try {
    const head: HistoryHead = JSON.parse(payload) as HistoryHead;
    if (head === null || head === undefined || !Array.isArray(head.Keys) || head.Keys.length > MAX_HEAD_KEYS) return null;
    const newest: ClipboardEntry = head.Newest;
    if (newest === null || newest === undefined || typeof newest.Content !== 'string' || typeof newest.Type !== 'string' ||
      typeof newest.DeviceId !== 'string' || typeof newest.Timestamp !== 'string') return null;
    for (const key of head.Keys) {
      if (typeof key !== 'string') return null;
    }
    return head;
  } catch (e) {
    return null;
  }
}

// What applyHead did: newest is the head's newest entry if it was new and is
// in the history now, else null; expectedNew is how many of the batch's
// entries are new to this device (capped at maxNew).
export interface HeadOutcome {
  newest: ClipboardEntry | null;
  expectedNew: number;
}

// A head as ONE small unit: its newest entry is checked like any live entry
// (`verify`), counted against the keys that are not here yet (`goneKeys`:
// which of these keys are already in the history or were deleted here), and
// added in one step (`add`); `announce` is called ONCE if it was new. A head
// whose newest entry does not verify is ignored completely (null): the batch
// then works as it did without one.
export async function applyHead(head: HistoryHead,
  verify: (entry: ClipboardEntry) => Promise<ClipboardEntry | null>,
  goneKeys: (keys: string[]) => Promise<Set<string>>,
  add: (candidates: ClipboardEntry[]) => Promise<MergeResult>,
  announce: (newest: ClipboardEntry, expectedNew: number) => Promise<void>,
  maxNew: number): Promise<HeadOutcome | null> {
  const newest: ClipboardEntry | null = await verify(head.Newest);
  if (newest === null) return null;
  const keys: string[] = Array.from(new Set<string>(head.Keys));
  const gone: Set<string> = await goneKeys(keys);
  const expectedNew: number = Math.min(maxNew, keys.filter((key: string) => !gone.has(key)).length);
  const merged: MergeResult = await add([newest]);
  if (merged.added.length === 0) return { newest: null, expectedNew: expectedNew };
  await announce(merged.added[0], expectedNew);
  return { newest: merged.added[0], expectedNew: expectedNew };
}
