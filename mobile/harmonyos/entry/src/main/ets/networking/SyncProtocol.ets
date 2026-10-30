// Sync v2, the plain parts: what goes on the wire for the handshake's
// Protocol field, the v2 history_head, history_request and delete, and the
// rules that decide what to ask a peer for. No sockets, files or preferences in
// here, so entry/src/test can run all of it; HistorySync.ets puts it to work.
// Mirrors the "Sync v2" section of docs/protocol.md and the other platforms'
// own copies of these rules.
//
// A connection speaks v2 only when BOTH sides sent Protocol >= 2 in their
// handshake. Otherwise it speaks v1: the old history_head (Newest + Keys) and
// the whole history_batch, exactly as before.

import { ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';

// What this build sends as the handshake's Protocol.
export const PROTOCOL_VERSION: number = 2;
// A history_request or delete carries at most this many keys; more are ignored.
export const MAX_REQUEST_KEYS: number = 100;
// A key longer than this is not one.
export const MAX_KEY_LENGTH: number = 2048;
// A v2 head lists at most this many entries (the history cap) ...
export const MAX_HEAD_KEYS_V2: number = 25;
// ... and this many tombstones, the most recently deleted first.
export const MAX_HEAD_DELETED: number = 500;
// A history_request not answered within this long is given up on.
export const REQUEST_TIMEOUT_MS: number = 90000;
// Two syncs that each bring a convenience item (the one that goes on the
// clipboard) within this long of each other put only one on the clipboard.
export const CONVENIENCE_WINDOW_MS: number = 90000;

// What the peer's handshake says its protocol is: 1 when the field is absent,
// null, not a number or below 2 (every build before v2), else the number.
export function peerProtocolOf(value: Object | null | undefined): number {
  if (typeof value !== 'number' || !isFinite(value) || value < 2) return 1;
  return Math.floor(value);
}

// The protocol a connection speaks: the newest one both sides know.
export function negotiatedProtocol(peerProtocol: number): number {
  return Math.min(PROTOCOL_VERSION, peerProtocol);
}

const TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?(Z|[+-]\d{2}:\d{2})?$/;

// A timestamp (the .NET round-trip text every entry carries, see Signing.ets)
// as Unix milliseconds in UTC, for a head's Times; 0 for text that is not one.
// Done by hand on the text, not with Date.parse, for the same reason Signing
// never parses a Timestamp into a Date: the fraction has 7 digits.
export function unixMillis(timestamp: string): number {
  const match = TIMESTAMP.exec(timestamp);
  if (match === null) return 0;
  const fraction: string = ((match[7] ?? '') + '000').slice(0, 3);
  let millis: number = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
    Number(match[4]), Number(match[5]), Number(match[6])) + Number(fraction);
  const zone: string = match[8] ?? 'Z';
  if (zone !== 'Z') {
    const offsetMinutes: number = Number(zone.slice(1, 3)) * 60 + Number(zone.slice(4, 6));
    millis -= (zone.charAt(0) === '-' ? -1 : 1) * offsetMinutes * 60000;
  }
  return millis;
}

// Newest first by timestamp (canonical form, which sorts as text). Of equal
// timestamps the one listed first stays first.
export function newestFirst(entries: ClipboardEntry[]): ClipboardEntry[] {
  return entries.slice().sort((a: ClipboardEntry, b: ClipboardEntry) => {
    const at: string = canonicalTimestamp(a.Timestamp);
    const bt: string = canonicalTimestamp(b.Timestamp);
    return at < bt ? 1 : (at > bt ? -1 : 0);
  });
}

// A key is a non-empty string of at most MAX_KEY_LENGTH characters.
function isKey(value: Object | null | undefined): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= MAX_KEY_LENGTH;
}

// ---- history_head, v2 form --------------------------------------------------

interface HeadV2Wire {
  Keys: string[];
  Times: number[];
  Deleted: string[];
}

// The payload of a v2 head: the key of every entry of `history` newest first
// (at most MAX_HEAD_KEYS_V2) with its time, and the tombstones `deleted`
// (most recently deleted first). There is no Newest: the peer may have that
// item already, and a big one would be sent for nothing. Always sent, even for
// a history of 0 or 1: the key list and the tombstones matter on their own.
export function buildHeadV2Payload(history: ClipboardEntry[], keyOf: (entry: ClipboardEntry) => string, deleted: string[]): string {
  const sorted: ClipboardEntry[] = newestFirst(history).slice(0, MAX_HEAD_KEYS_V2);
  const head: HeadV2Wire = {
    Keys: sorted.map((entry: ClipboardEntry) => keyOf(entry)),
    Times: sorted.map((entry: ClipboardEntry) => unixMillis(canonicalTimestamp(entry.Timestamp))),
    Deleted: deleted.slice(0, MAX_HEAD_DELETED),
  };
  return JSON.stringify(head);
}

// A v2 head as received. times: the time of each key (same order), or null
// when there are none or they do not match the keys one to one.
export interface HeadV2 {
  keys: string[];
  times: number[] | null;
  deleted: string[];
}

// A received v2 head, or null if the payload is not a JSON object. Missing
// lists are empty, unknown keys (a v1.5 head's Newest, say) are ignored, keys
// that are not strings or are too long are skipped, and more than
// MAX_HEAD_KEYS_V2 keys or MAX_HEAD_DELETED tombstones are cut to the first.
export function parseHeadV2(payload: string): HeadV2 | null {
  let wire: HeadV2Wire;
  try {
    wire = JSON.parse(payload) as HeadV2Wire;
  } catch (e) {
    return null;
  }
  if (wire === null || wire === undefined || typeof wire !== 'object' || Array.isArray(wire)) return null;
  const rawKeys: string[] = Array.isArray(wire.Keys) ? wire.Keys : [];
  const rawTimes: number[] | null = Array.isArray(wire.Times) ? wire.Times : null;
  let matched: boolean = rawTimes !== null && rawTimes.length === rawKeys.length;
  if (matched && rawTimes !== null) {
    for (const time of rawTimes) {
      if (typeof time !== 'number' || !isFinite(time)) matched = false;
    }
  }
  const keys: string[] = [];
  const times: number[] = [];
  for (let i = 0; i < rawKeys.length && keys.length < MAX_HEAD_KEYS_V2; i++) {
    if (!isKey(rawKeys[i])) continue;
    keys.push(rawKeys[i]);
    if (matched && rawTimes !== null) times.push(rawTimes[i]);
  }
  const deleted: string[] = [];
  const rawDeleted: string[] = Array.isArray(wire.Deleted) ? wire.Deleted : [];
  for (let i = 0; i < rawDeleted.length && deleted.length < MAX_HEAD_DELETED; i++) {
    if (isKey(rawDeleted[i])) deleted.push(rawDeleted[i]);
  }
  return { keys: keys, times: matched ? times : null, deleted: deleted };
}

// ---- history_request and delete ----------------------------------------------

interface KeysWire {
  Keys: string[];
}

// The payload of a history_request or a delete: `{"Keys":[...]}`.
export function buildKeysPayload(keys: string[]): string {
  const wire: KeysWire = { Keys: keys };
  return JSON.stringify(wire);
}

// The keys of a received history_request or delete, or null if the payload is
// not a JSON object. Keys that are not strings or are too long are skipped, and
// only the first MAX_REQUEST_KEYS are read.
export function parseKeysPayload(payload: string): string[] | null {
  let wire: KeysWire;
  try {
    wire = JSON.parse(payload) as KeysWire;
  } catch (e) {
    return null;
  }
  if (wire === null || wire === undefined || typeof wire !== 'object' || Array.isArray(wire)) return null;
  const raw: string[] = Array.isArray(wire.Keys) ? wire.Keys : [];
  const keys: string[] = [];
  for (let i = 0; i < raw.length && keys.length < MAX_REQUEST_KEYS; i++) {
    if (isKey(raw[i])) keys.push(raw[i]);
  }
  return keys;
}

// `keys` in pieces of at most MAX_REQUEST_KEYS, for a delete that names more.
export function splitKeys(keys: string[]): string[][] {
  const pieces: string[][] = [];
  for (let i = 0; i < keys.length; i += MAX_REQUEST_KEYS) {
    pieces.push(keys.slice(i, i + MAX_REQUEST_KEYS));
  }
  return pieces;
}

// What a history_request is answered with: the entries of `history` whose key
// is asked for, newest first. A key this device no longer has is skipped.
export function answerFor(history: ClipboardEntry[], keys: string[], keyOf: (entry: ClipboardEntry) => string): ClipboardEntry[] {
  const asked: Set<string> = new Set<string>(keys);
  return newestFirst(history.filter((entry: ClipboardEntry) => asked.has(keyOf(entry))));
}

// ---- what to ask for ---------------------------------------------------------

// The keys of a peer's head worth downloading, in the order the peer listed
// them (newest first). `missing` are the head's keys that are not `known`
// (in the history, or deleted here) and not `pending` (already being asked for);
// a key listed twice counts once. With the head's `times`, only the missing
// keys that would stay in a history of `cap` items are wanted: the `cap`
// newest by time of the local entries (`localTimes`) and the missing ones
// together. The first missing key is wanted whatever its time: it is the item
// that goes on the clipboard. Without times every missing key is wanted, up to
// `cap`. Never more than `cap` keys come back, even when the times are not in
// the order of the keys and the first key is not one of the `cap` newest.
export function wantedKeys(keys: string[], times: number[] | null, known: (key: string) => boolean,
  pending: (key: string) => boolean, localTimes: number[], cap: number): string[] {
  const missing: string[] = [];
  const missingTimes: number[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < keys.length; i++) {
    if (seen.has(keys[i])) continue;
    seen.add(keys[i]);
    if (known(keys[i]) || pending(keys[i])) continue;
    missing.push(keys[i]);
    missingTimes.push(times !== null ? times[i] : 0);
  }
  if (missing.length === 0) return [];
  if (times === null) return missing.slice(0, cap);

  // Local entries first, then the missing ones, so of equal times a local
  // entry keeps its place and the peer's listing order decides between the rest.
  const rank: number[] = [];
  const time: number[] = [];
  for (const t of localTimes) {
    rank.push(rank.length);
    time.push(t);
  }
  for (const t of missingTimes) {
    rank.push(rank.length);
    time.push(t);
  }
  rank.sort((a: number, b: number) => (time[a] !== time[b] ? time[b] - time[a] : a - b));
  const kept: Set<number> = new Set<number>(rank.slice(0, cap));
  const wanted: string[] = [];
  for (let i = 0; i < missing.length; i++) {
    if (i === 0 || kept.has(localTimes.length + i)) wanted.push(missing[i]);
  }
  return wanted.slice(0, cap);
}

// ---- one clipboard change when two peers answer at once ----------------------

// The last convenience item that went on the clipboard (its timestamp in
// canonical form, which sorts as text, and when), kept in memory for the whole
// engine, not per connection. When two peers each answer a convenience request,
// the second item goes on the clipboard only if it is newer than the first or
// the first went there CONVENIENCE_WINDOW_MS ago or more.
export class ConvenienceMemory {
  private stamp: string = '';
  private at: number = 0;
  private known: boolean = false;

  // Whether a convenience item with this timestamp may go on the clipboard at
  // `now` (ms since the epoch). A clock that went back (now before the time
  // recorded) is outside the window: nothing is held back for ever.
  allows(stamp: string, now: number): boolean {
    if (!this.known) return true;
    const inWindow: boolean = now >= this.at && now - this.at < CONVENIENCE_WINDOW_MS;
    return !(inWindow && stamp <= this.stamp);
  }

  // This item went on the clipboard at `now`.
  record(stamp: string, now: number): void {
    this.stamp = stamp;
    this.at = now;
    this.known = true;
  }
}

// ---- requests in flight --------------------------------------------------------

// One history_request this side sent on a connection and has not had the
// answer to. The answers come back in the order the requests went out, so the
// connection keeps these in a queue (SyncLink.queue). convenience: the one for
// the item that goes on the clipboard. groupSize: how many items the whole
// sync asked for, which the stack counts from (only the convenience request
// carries it, see HistorySync).
export class SentRequest {
  keys: string[];
  convenience: boolean;
  sentAt: number;
  groupSize: number;

  constructor(keys: string[], convenience: boolean, sentAt: number, groupSize: number) {
    this.keys = keys;
    this.convenience = convenience;
    this.sentAt = sentAt;
    this.groupSize = groupSize;
  }
}

// The keys asked for and not answered yet, and the connection each was asked
// on (by SyncLink.id): a key asked for on one connection is not asked on
// another.
export class PendingKeys {
  private owner: Map<string, string> = new Map<string, string>();

  has(key: string): boolean {
    return this.owner.has(key);
  }

  claim(linkId: string, keys: string[]): void {
    for (const key of keys) this.owner.set(key, linkId);
  }

  // These keys, if they are the connection's: it was answered, or gave up.
  release(linkId: string, keys: string[]): void {
    for (const key of keys) {
      if (this.owner.get(key) === linkId) this.owner.delete(key);
    }
  }

  // Everything the connection was asked for, when it closes. Returns how many.
  releaseLink(linkId: string): number {
    const mine: string[] = [];
    this.owner.forEach((id: string, key: string) => {
      if (id === linkId) mine.push(key);
    });
    for (const key of mine) this.owner.delete(key);
    return mine.length;
  }
}
