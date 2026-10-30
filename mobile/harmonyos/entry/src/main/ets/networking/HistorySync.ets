// What this device does with the history messages: history_head, history_batch,
// and, between two devices that speak sync v2, history_request and delete.
// Mirrors windows/ClipLink/Engine/ClipLinkEngine.cs and the docs' "Sharing
// history". It is plain code behind a SyncHost (the history, the clipboard and
// the UI as functions it is given), so entry/src/test can run two of them
// against each other; SyncManager gives it the real ones.
//
// Between two v2 devices (both sent Protocol 2 in the handshake) a connection
// starts with a head only: the keys of the sender's history with their times,
// and its tombstones. The receiver deletes what the tombstones name, works out
// which items it is missing and wants (SyncProtocol.wantedKeys), and asks for
// them with history_request: the newest one alone first (it goes on the
// clipboard), then the rest in a second request. Each request is answered with
// one history_batch, in order, so the connection keeps the requests it is
// waiting on in a queue (SyncLink.queue). With an older peer (v1) nothing
// changes: a head with Newest and Keys when there are two or more entries, then
// the whole batch, and a received batch is applied as one unit.
//
// ArkTS runs all of this on one thread, but every await is a place where
// another message gets its turn. So what must happen in the order the
// messages came in (taking an answer's place in the queue) is done before the
// first await of the handler, and the rest of the work for the history runs
// one piece at a time (enqueue).

import { ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';
import { ApplyResult } from '../clipboard/ClipboardApply';
import { entryKey } from '../storage/DeletedEntries';
import { MAX_HISTORY_ITEMS } from '../storage/HistoryAccess';
import { GROUP_MIN_ITEMS, MergeResult, applyBatch, applyHead, buildHeadPayload, newestOf, parseHead } from '../storage/HistoryBatch';
import {
  ConvenienceMemory, MAX_HEAD_DELETED, PROTOCOL_VERSION, PendingKeys, REQUEST_TIMEOUT_MS, SentRequest, answerFor, buildHeadV2Payload, buildKeysPayload,
  parseHeadV2, parseKeysPayload, splitKeys, unixMillis, wantedKeys
} from './SyncProtocol';

// How long a stack that has just come in on screen is left alone, before the
// big message behind it is parsed on the UI thread.
const STACK_SETTLE_MS = 450;

interface Envelope {
  Type: string;
  Payload: string;
}

function envelopeJson(type: string, payload: string): string {
  const envelope: Envelope = { Type: type, Payload: payload };
  return JSON.stringify(envelope);
}

// For an add whose newest new entry goes on the clipboard without a check.
function anyEntry(entry: ClipboardEntry): boolean {
  return true;
}

// What a history_batch did, told to the UI once, whatever the number of entries
// (see HistorySync.announceBatch). added: the entries that were new and are
// still in the history after the cap, in the order the batch listed them.
// newest: the latest of them. applied: what putting `newest` on the clipboard
// came to, or null if that has not happened (a file whose bytes are still on
// their way: it is put there when they arrive, and reported then as a single
// entry, see SyncManager.onEntryApplied). from: the connection (SyncLink.id).
export interface BatchApplied {
  from: string;
  added: ClipboardEntry[];
  newest: ClipboardEntry;
  applied: ApplyResult | null;
  // The peer's history_head came first and already put its newest item on the
  // clipboard and told the user: the batch does neither again.
  headDone: boolean;
}

// What a history_head of the old form did, told to the UI once: the peer's
// newest item, which was new and is in the history now, and how many items the
// batch that follows is going to bring (that one included). applied: as in
// BatchApplied.
export interface HeadApplied {
  from: string;
  newest: ClipboardEntry;
  expectedNew: number;
  applied: ApplyResult | null;
}

// What the answer to a history_request did, told to the UI once (v2 only).
// added: the new entries that are in the history now. front: the newest of
// them when the request was the convenience one (see SentRequest), which is on
// the clipboard (applied: as in BatchApplied), else null. expectedTotal: with
// a front, how many items the sync asked for in all. last: no request of this
// connection is still waiting. from: the connection (SyncLink.id).
// superseded: the front is not on the clipboard, and the user is not told of
// it, because another sync's convenience item went there a moment ago and is
// not older (it still leads its stack). quiet: the answer to a request given
// up on, stored without a stack, the clipboard or a notice.
export interface SyncApplied {
  from: string;
  added: ClipboardEntry[];
  front: ClipboardEntry | null;
  applied: ApplyResult | null;
  expectedTotal: number;
  last: boolean;
  superseded: boolean;
  quiet: boolean;
}

// One connection, as sync sees it. id is made by SyncManager and is the key
// the UI keeps a sync's stack under.
export class SyncLink {
  readonly id: string;
  // How the peer is named in the log.
  readonly label: string;
  // 2 or 1: the protocol both sides speak.
  readonly protocol: number;
  private sender: (json: string) => Promise<void>;
  // The requests sent on this connection and not answered yet, oldest first.
  queue: SentRequest[] = [];
  // The requests given up on (REQUEST_TIMEOUT_MS) whose answers have not come,
  // oldest first: the markers of the request queue. The peer answers in the
  // order it was asked, so their answers still come before those of the queue:
  // each answer takes its marker, and is stored quietly (see onBatch). A marker
  // leaves only with its answer or with the connection, and it is not a
  // request that is waiting: it counts for no timeout and no stack.
  expired: SentRequest[] = [];
  // Answers taken from the queue and not dealt with yet. A late answer (taken
  // from expired) is not counted: it belongs to no stack, so it must not
  // change when another sync's stack is final.
  answering: number = 0;
  // The last v2 head this connection sent, to ask again from (see
  // HistorySync.close).
  lastKeys: string[] | null = null;
  lastTimes: number[] | null = null;
  // The convenience request was sent on this connection already.
  askedFront: boolean = false;
  // This connection's sync put an item on the clipboard.
  frontServed: boolean = false;
  // A v2 stack made on this connection is still waiting for answers.
  waiting: boolean = false;
  // A v1 head put an item into the history and its batch has not been dealt
  // with yet, since headAt (ms since the epoch).
  headPending: boolean = false;
  headAt: number = 0;
  closed: boolean = false;
  // Answers to the requests of the peer, one at a time, in the order they came.
  replies: Promise<void> = Promise.resolve();

  constructor(id: string, label: string, protocol: number, sender: (json: string) => Promise<void>) {
    this.id = id;
    this.label = label;
    this.protocol = protocol;
    this.sender = sender;
  }

  send(json: string): Promise<void> {
    return this.sender(json);
  }
}

// What HistorySync needs from the rest of the app.
export interface SyncHost {
  // The entry as its signer signed it, or null if its signature or its
  // signer's trust fails.
  verified: (entry: ClipboardEntry) => Promise<ClipboardEntry | null>;
  getHistory: () => Promise<ClipboardEntry[]>;
  // The keys of the tombstones, most recently deleted first, at most `limit`.
  deletedKeys: (limit: number) => Promise<string[]>;
  // Which of these keys are in the history or deleted here.
  goneKeys: (keys: string[]) => Promise<Set<string>>;
  isDeleted: (entry: ClipboardEntry) => Promise<boolean>;
  // Adds the candidates in one step; newFront: the newest new one is the item
  // that goes on the clipboard, which the trim spares, if frontOk (asked once,
  // with that entry, before the trim) says yes. The result's front is that entry
  // or null.
  addBatch: (candidates: ClipboardEntry[], newFront: boolean, frontOk: (entry: ClipboardEntry) => boolean) => Promise<MergeResult>;
  // Tombstones these keys and removes the entries (and their files, and any
  // entry still waiting for its bytes) from this device.
  deleteKeys: (keys: string[]) => Promise<void>;
  applyToClipboard: (entry: ClipboardEntry) => Promise<ApplyResult>;
  // A file entry's first half: true if its bytes are here; if not they are
  // asked for from every peer (see SyncManager.prepareFileEntry).
  prepareFile: (entry: ClipboardEntry, applyWhenStored: boolean) => boolean;
  wait: (ms: number) => Promise<void>;
  now: () => number;
  log: (message: string) => void;
  headApplied: (head: HeadApplied) => void;
  batchApplied: (batch: BatchApplied) => void;
  syncApplied: (sync: SyncApplied) => void;
  // A stack made for connection `link` will not be added to any more.
  settled: (link: string) => void;
  // These keys were deleted by a peer: the list drops them.
  deleted: (keys: string[]) => void;
}

export class HistorySync {
  private host: SyncHost;
  private links: Map<string, SyncLink> = new Map<string, SyncLink>();
  private pending: PendingKeys = new PendingKeys();
  // Heads, answers, batches and deletes are dealt with one at a time, in the
  // order they arrived, whatever the time each takes.
  private work: Promise<void> = Promise.resolve();
  // Until then (ms since the epoch) the UI is still showing a stack come in:
  // the next big message waits before it is parsed.
  private quietUntil: number = 0;
  // The last convenience item that went on the clipboard, for all connections.
  private convenience: ConvenienceMemory = new ConvenienceMemory();

  constructor(host: SyncHost) {
    this.host = host;
  }

  private enqueue(work: () => Promise<void>): Promise<void> {
    const result: Promise<void> = this.work.then(work).catch((e: Error) => {
      this.host.log(`could not deal with a history message (${e})`);
    });
    this.work = result;
    return result;
  }

  // A connection is up: it is known to this, and what it may need from us is
  // announced (see announce).
  open(link: SyncLink): void {
    this.links.set(link.id, link);
  }

  // The connection is ready: tells the peer what this device has. On v2 that is
  // a head and nothing else (the peer asks for what it is missing); on v1 the
  // head of the old form when there are 2 or more entries, then the whole
  // history.
  async announce(link: SyncLink): Promise<void> {
    const history: ClipboardEntry[] = await this.host.getHistory();
    if (link.protocol >= PROTOCOL_VERSION) {
      const deleted: string[] = await this.host.deletedKeys(MAX_HEAD_DELETED);
      await link.send(envelopeJson('history_head', buildHeadV2Payload(history, (entry: ClipboardEntry) => entryKey(entry), deleted)));
      return;
    }
    // The head first: the newest entry and the keys of the batch behind it,
    // a few KB where the batch can be tens of MB. Not for a history of 0 or 1.
    const headPayload: string | null = buildHeadPayload(history, (entry: ClipboardEntry) => entryKey(entry));
    if (headPayload !== null) {
      await link.send(envelopeJson('history_head', headPayload));
    }
    await link.send(envelopeJson('history_batch', JSON.stringify(history)));
  }

  // ---- what the user deleted here -------------------------------------------

  // Tells every v2 peer that these items were deleted on this device (single
  // delete, clear all), at most MAX_REQUEST_KEYS keys to a message. A peer that
  // does not speak v2 is not told (it would not know the message) and keeps its
  // copy; the tombstone here keeps it out of the history even when it sends it
  // again. Not for deletions a peer told us about: the heads carry those to
  // devices that were offline.
  broadcastDelete(keys: string[]): void {
    const unique: string[] = Array.from(new Set<string>(keys));
    for (const piece of splitKeys(unique)) {
      const json: string = envelopeJson('delete', buildKeysPayload(piece));
      this.links.forEach((link: SyncLink) => {
        if (link.protocol >= PROTOCOL_VERSION && !link.closed) {
          link.send(json).catch((e: Error) => { /* a send failure also ends the link */ });
        }
      });
    }
  }

  // ---- history_head --------------------------------------------------------

  onHead(link: SyncLink, payload: string): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (link.protocol >= PROTOCOL_VERSION) {
        await this.handleHeadV2(link, payload);
      } else {
        await this.handleHeadV1(link, payload);
      }
    });
  }

  // A v2 head: first its tombstones, then what to ask for. Its Newest, if it
  // has one, is ignored: it would only be a big item the peer may have sent for
  // nothing.
  private async handleHeadV2(link: SyncLink, payload: string): Promise<void> {
    const head = parseHeadV2(payload);
    if (head === null) {
      this.host.log('received invalid message from peer (bad history_head)');
      return;
    }
    link.lastKeys = head.keys;
    link.lastTimes = head.times;
    if (head.deleted.length > 0) await this.applyDeleted(head.deleted);
    await this.askForMissing(link);
  }

  // Deletes what a peer says was deleted (its delete message, or the tombstones
  // in its head): the same as deleting here, but the clipboard is never touched
  // and the UI hears of it once.
  private async applyDeleted(keys: string[]): Promise<void> {
    await this.host.deleteKeys(keys);
    this.host.log(`${keys.length} item(s) deleted by a peer`);
    this.host.deleted(keys);
  }

  // Works out which of the connection's last head's items this device is
  // missing and worth keeping, and asks for them: the newest alone first, then
  // the rest. Items another connection is being asked for already are left to
  // it (see close for what happens if that connection dies).
  private async askForMissing(link: SyncLink, allowFront: boolean = true): Promise<void> {
    const keys: string[] | null = link.lastKeys;
    if (keys === null || link.closed) return;
    const history: ClipboardEntry[] = await this.host.getHistory();
    const gone: Set<string> = await this.host.goneKeys(keys);
    if (link.closed) return;
    const localTimes: number[] = history.map((entry: ClipboardEntry) => unixMillis(canonicalTimestamp(entry.Timestamp)));
    const wanted: string[] = wantedKeys(keys, link.lastTimes, (key: string) => gone.has(key),
      (key: string) => this.pending.has(key), localTimes, MAX_HISTORY_ITEMS);
    if (wanted.length === 0) return;

    // One item per connection goes on the clipboard, and none when asking again
    // after another connection died whose own newest item arrived: that sync
    // has had its turn.
    const convenience: boolean = allowFront && !link.askedFront;
    if (convenience) link.askedFront = true;
    const now: number = this.host.now();
    const requests: SentRequest[] = [];
    if (convenience && wanted.length > 1) {
      requests.push(new SentRequest(wanted.slice(0, 1), true, now, wanted.length));
      requests.push(new SentRequest(wanted.slice(1), false, now, wanted.length));
    } else {
      requests.push(new SentRequest(wanted, convenience, now, wanted.length));
    }
    for (const request of requests) {
      link.queue.push(request);
      this.pending.claim(link.id, request.keys);
    }
    try {
      for (const request of requests) {
        await link.send(envelopeJson('history_request', buildKeysPayload(request.keys)));
      }
    } catch (e) {
      // the link is going down: close() cleans up
    }
  }

  // A head of the old form: its newest entry is checked like a live entry and
  // added at once, and the UI hears how many items the batch behind it will
  // bring. Its signature failing leaves it ignored entirely - the batch then
  // works as it does without a head.
  private async handleHeadV1(link: SyncLink, payload: string): Promise<void> {
    const head = parseHead(payload);
    if (head === null) {
      this.host.log('received invalid message from peer (bad history_head)');
      return;
    }
    await applyHead(head,
      (entry: ClipboardEntry) => this.host.verified(entry),
      (keys: string[]) => this.host.goneKeys(keys),
      (candidates: ClipboardEntry[]) => this.host.addBatch(candidates, true, anyEntry),
      (newest: ClipboardEntry, expectedNew: number) => this.announceHead(newest, expectedNew, link),
      MAX_HISTORY_ITEMS);
  }

  // What the batch's newest item does besides being listed - on the clipboard
  // (a file's once its bytes are here, asking for them if they are not) - once,
  // here; the batch that follows does not do it again (headDone).
  private async announceHead(newest: ClipboardEntry, expectedNew: number, link: SyncLink): Promise<void> {
    let applied: ApplyResult | null = null;
    if (newest.Type !== 'file') {
      applied = await this.host.applyToClipboard(newest);
    } else if (this.host.prepareFile(newest, true)) {
      applied = await this.host.applyToClipboard(newest);
    }
    link.headPending = true;
    link.headAt = this.host.now();
    this.quietUntil = this.host.now() + STACK_SETTLE_MS;
    this.host.log(`received the newest item from ${link.label}, ${expectedNew} to come`);
    this.host.headApplied({ from: link.id, newest: newest, expectedNew: expectedNew, applied: applied });
  }

  // ---- history_batch -------------------------------------------------------

  // A history_batch. On a v2 connection it answers the oldest request sent
  // there: that request takes its place at once, before anything is awaited, so
  // the answers are matched to the requests in the order they came. A batch
  // nobody asked for (the queue is empty, or the connection is v1) is dealt
  // with as a whole history of the old kind.
  onBatch(link: SyncLink, payload: string): Promise<void> {
    let request: SentRequest | null = null;
    let last: boolean = false;
    let late: boolean = false;
    if (link.protocol >= PROTOCOL_VERSION) {
      const marker: SentRequest | undefined = link.expired.shift();
      if (marker !== undefined) {
        // The answer to a request given up on: it takes its marker, and its
        // items are stored quietly (no clipboard, no notice, no stack). Its
        // keys were released when it expired.
        request = marker;
        late = true;
      } else {
        const asked: SentRequest | undefined = link.queue.shift();
        if (asked !== undefined) {
          request = asked;
          last = link.queue.length === 0;
          this.pending.release(link.id, asked.keys);
        }
      }
    }
    const answers: SentRequest | null = request;
    const counted: boolean = answers !== null && !late;
    if (counted) link.answering++;
    return this.enqueue(async (): Promise<void> => {
      try {
        await this.dealWithBatch(link, payload, answers, last, late);
      } finally {
        if (counted) link.answering--;
      }
    });
  }

  private async dealWithBatch(link: SyncLink, payload: string, answers: SentRequest | null, last: boolean, late: boolean): Promise<void> {
    // The stack a head just put on screen is still coming in: parsing a big
    // batch (it holds the UI thread for 0.1 to 0.2 s) waits until it has
    // settled.
    const quiet: number = this.quietUntil - this.host.now();
    if (quiet > 0) await this.host.wait(quiet);
    let entries: ClipboardEntry[] = [];
    try {
      const parsed: ClipboardEntry[] = JSON.parse(payload) as ClipboardEntry[];
      if (!Array.isArray(parsed)) throw new Error('not a list');
      entries = parsed;
    } catch (e) {
      this.host.log('received invalid message from peer (bad history_batch JSON)');
      // An answer still counts as one: the queue and the stack move on.
      if (answers === null) return;
    }
    if (answers !== null && late) {
      await this.handleLateAnswer(link, entries);
    } else if (answers !== null) {
      await this.handleAnswer(link, answers, entries, last);
    } else {
      await this.handleBatchV1(link, entries);
    }
  }

  // The answer to a request of this device (see onBatch): every entry is
  // checked as for any batch, all the new ones go into the history in one step,
  // and the UI hears once. Only the convenience request's newest new entry goes
  // on the clipboard.
  private async handleAnswer(link: SyncLink, request: SentRequest, entries: ClipboardEntry[], last: boolean): Promise<void> {
    // Whether the convenience item goes on the clipboard is decided once, inside
    // the merge, with the newest entry really added (see ConvenienceMemory): the
    // trim spares that entry and announceAnswer puts it on the clipboard.
    let sparedKey: string | null = null;
    const outcome = await applyBatch(entries,
      (entry: ClipboardEntry) => this.host.verified(entry),
      (entry: ClipboardEntry) => this.host.isDeleted(entry),
      async (candidates: ClipboardEntry[]): Promise<MergeResult> => {
        const merged: MergeResult = await this.host.addBatch(candidates, request.convenience,
          (newest: ClipboardEntry): boolean => this.convenience.allows(canonicalTimestamp(newest.Timestamp), this.host.now()));
        sparedKey = merged.front !== null ? entryKey(merged.front) : null;
        return merged;
      },
      (added: ClipboardEntry[]) => this.announceAnswer(link, request, added, sparedKey, last));
    if (last) {
      // The stack, if there was one, is final now. When the answer added items
      // the UI was told with them (announceAnswer); if it added none, say so.
      const waited: boolean = link.waiting;
      link.waiting = false;
      if (waited && outcome.added.length === 0) this.host.settled(link.id);
    }
  }

  // The answer to a request given up on: the same checks as for any answer
  // (signature, trusted maker, not deleted here), the new entries added in one
  // step with nothing spared by the trim, and the bytes of new files asked for.
  // The clipboard, the user and the stacks are left alone: the sync it belonged
  // to has had its turn.
  private async handleLateAnswer(link: SyncLink, entries: ClipboardEntry[]): Promise<void> {
    await applyBatch(entries,
      (entry: ClipboardEntry) => this.host.verified(entry),
      (entry: ClipboardEntry) => this.host.isDeleted(entry),
      (candidates: ClipboardEntry[]) => this.host.addBatch(candidates, false, anyEntry),
      async (added: ClipboardEntry[]): Promise<void> => {
        for (const entry of added) {
          if (entry.Type === 'file') this.host.prepareFile(entry, false);
        }
        this.host.log(`received ${added.length} item(s) late from ${link.label}`);
        this.host.syncApplied({
          from: link.id, added: added, front: null, applied: null, expectedTotal: 0, last: false, superseded: false, quiet: true
        });
      });
  }

  // What a received item does besides being listed, once for the answer: with
  // the convenience request, its newest item goes on the clipboard (a file's
  // once its bytes are here); every file in it that is not here yet is asked
  // for either way. Then the UI hears of it, once. sparedKey: the entry the
  // merge decided goes on the clipboard (and spared from the trim), or null.
  private async announceAnswer(link: SyncLink, request: SentRequest, added: ClipboardEntry[], sparedKey: string | null,
    last: boolean): Promise<void> {
    const front: ClipboardEntry | null = request.convenience ? newestOf(added) : null;
    // Another sync's convenience item went on the clipboard a moment ago and
    // this one is not newer: this one is listed, and leads its stack, but the
    // clipboard and the user are left alone.
    const goes: boolean = front !== null && sparedKey !== null && entryKey(front) === sparedKey;
    if (front !== null && goes) {
      this.convenience.record(canonicalTimestamp(front.Timestamp), this.host.now());
    }
    let applied: ApplyResult | null = null;
    for (const entry of added) {
      if (entry.Type !== 'file') continue;
      const ready: boolean = this.host.prepareFile(entry, entry === front && goes);
      if (ready && entry === front && goes) {
        applied = await this.host.applyToClipboard(entry);
      }
    }
    if (front !== null && goes && front.Type !== 'file') {
      applied = await this.host.applyToClipboard(front);
    }
    // Decided here, after the awaits above: while they ran, the connection may
    // have closed or the requests behind this one given up on, and close() and
    // expire() settle only a stack that is waiting by then. A stack made now
    // for a connection that has nothing more to bring would wait for ever.
    const finished: boolean = last || link.closed || (link.queue.length === 0 && link.answering <= 1);
    if (front !== null) {
      link.frontServed = true;
      this.quietUntil = this.host.now() + STACK_SETTLE_MS;
      link.waiting = request.groupSize >= GROUP_MIN_ITEMS && !finished;
    }
    this.host.log(`received ${added.length} item(s) from ${link.label}`);
    this.host.syncApplied({
      from: link.id, added: added, front: front, applied: applied, expectedTotal: front !== null ? request.groupSize : 0, last: finished,
      superseded: front !== null && !goes, quiet: false
    });
    if (finished) link.waiting = false;
  }

  // A whole history_batch of the old kind, as ONE unit: every entry is checked
  // (signature, trusted maker, not deleted here), then all the new ones go
  // into the history in one step - one write, and one report to the UI.
  private async handleBatchV1(link: SyncLink, entries: ClipboardEntry[]): Promise<void> {
    const outcome = await applyBatch(entries,
      (entry: ClipboardEntry) => this.host.verified(entry),
      (entry: ClipboardEntry) => this.host.isDeleted(entry),
      (candidates: ClipboardEntry[]) => this.host.addBatch(candidates, !link.headPending, anyEntry),
      (added: ClipboardEntry[]) => this.announceBatch(added, link));
    // The head's stack, if there was one, is final now. When the batch added
    // items the UI was told with them (announceBatch); if it added none, say so.
    if (link.headPending) {
      link.headPending = false;
      if (outcome.added.length === 0) this.host.settled(link.id);
    }
  }

  // What a received item does besides being listed, once for the batch: its
  // newest NEW item goes on the clipboard (a file's once its bytes are here),
  // even when it is older than this device's own newest, and every file in it
  // that is not here yet is asked for - the ask made when the peer connected
  // went out before this batch came, so an older file would otherwise stay
  // "transferring" until the next connection. Then the UI hears of the batch,
  // once. After a head, the peer's newest item is the head's, which has had its
  // turn already.
  private async announceBatch(added: ClipboardEntry[], link: SyncLink): Promise<void> {
    const newest: ClipboardEntry | null = newestOf(added);
    if (newest === null) return;
    const headDone: boolean = link.headPending;
    let applied: ApplyResult | null = null;
    for (const entry of added) {
      if (entry.Type !== 'file') continue;
      const ready: boolean = this.host.prepareFile(entry, entry === newest && !headDone);
      if (ready && entry === newest && !headDone) {
        applied = await this.host.applyToClipboard(entry);
      }
    }
    if (newest.Type !== 'file' && !headDone) {
      applied = await this.host.applyToClipboard(newest);
    }
    this.host.log(`received ${added.length} item(s) from ${link.label}`);
    this.host.batchApplied({ from: link.id, added: added, newest: newest, applied: applied, headDone: headDone });
  }

  // ---- history_request and delete (v2) -----------------------------------------

  // A peer asks for items by key: it gets ONE history_batch with the ones this
  // device has, newest first, and [] when it has none, so the asker can stop
  // waiting. Answers go out one at a time in the order the requests came, so a
  // big one never overtakes a small earlier one.
  onRequest(link: SyncLink, payload: string): void {
    if (link.protocol < PROTOCOL_VERSION) {
      this.host.log('ignored a history_request from a peer that does not speak sync v2');
      return;
    }
    const keys: string[] | null = parseKeysPayload(payload);
    if (keys === null) {
      this.host.log('received invalid message from peer (bad history_request)');
      return;
    }
    link.replies = link.replies.then(async (): Promise<void> => {
      const history: ClipboardEntry[] = await this.host.getHistory();
      const answer: ClipboardEntry[] = answerFor(history, keys, (entry: ClipboardEntry) => entryKey(entry));
      await link.send(envelopeJson('history_batch', JSON.stringify(answer)));
    }).catch((e: Error) => { /* the link is gone: nobody to answer */ });
  }

  // A peer deleted items. They are deleted here as well, whether or not this
  // device has them, and are not sent on to anyone.
  onDelete(link: SyncLink, payload: string): Promise<void> {
    if (link.protocol < PROTOCOL_VERSION) {
      this.host.log('ignored a delete from a peer that does not speak sync v2');
      return Promise.resolve();
    }
    const keys: string[] | null = parseKeysPayload(payload);
    if (keys === null) {
      this.host.log('received invalid message from peer (bad delete)');
      return Promise.resolve();
    }
    return this.enqueue(() => this.applyDeleted(keys));
  }

  // ---- when a connection ends or goes quiet ---------------------------------

  // Called with every heartbeat tick of the connection: a request not answered
  // within REQUEST_TIMEOUT_MS is given up on: it stays as a marker (link.expired)
  // and its answer, if it still comes, takes it and is added quietly (see
  // onBatch); the next reconnect does the work again. Markers are not looked at
  // here, so they never time out and never keep a stack waiting,
  // and so is the stack a head of the old form made, if its batch does not come.
  // When that was the last thing a stack waited for, the stack settles.
  expire(link: SyncLink): void {
    const now: number = this.host.now();
    let dropped: boolean = false;
    while (link.queue.length > 0 && now - link.queue[0].sentAt > REQUEST_TIMEOUT_MS) {
      const request: SentRequest = link.queue.shift() as SentRequest;
      this.pending.release(link.id, request.keys);
      // Its answer may still come: the marker is kept for it (see onBatch).
      link.expired.push(request);
      dropped = true;
    }
    if (dropped) {
      this.host.log(`gave up waiting for an answer from ${link.label}`);
      if (link.queue.length === 0 && link.waiting) {
        link.waiting = false;
        this.host.settled(link.id);
      }
    }
    if (link.headPending && now - link.headAt > REQUEST_TIMEOUT_MS) {
      link.headPending = false;
      this.host.settled(link.id);
    }
  }

  // The connection is gone. Whatever it still owed is dropped; a stack waiting
  // on it settles; and the items it was asked for are asked of the other v2
  // connections, from the last head each sent.
  close(link: SyncLink): void {
    link.closed = true;
    this.links.delete(link.id);
    link.queue = [];
    link.expired = [];
    const released: number = this.pending.releaseLink(link.id);
    if (link.waiting || link.headPending) {
      link.waiting = false;
      link.headPending = false;
      this.host.settled(link.id);
    }
    if (released === 0) return;
    this.links.forEach((other: SyncLink) => {
      if (other.protocol >= PROTOCOL_VERSION) {
        void this.enqueue(() => this.askForMissing(other, !link.frontServed));
      }
    });
  }
}
