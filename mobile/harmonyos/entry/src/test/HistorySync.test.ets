import { describe, it, expect } from '@ohos/hypium';
import { BatchApplied, HeadApplied, HistorySync, SyncApplied, SyncHost, SyncLink } from '../main/ets/networking/HistorySync';
import { CONVENIENCE_WINDOW_MS, REQUEST_TIMEOUT_MS, buildKeysPayload, unixMillis } from '../main/ets/networking/SyncProtocol';
import { MergeResult, buildHeadPayload, mergeBatch } from '../main/ets/storage/HistoryBatch';
import { ClipboardEntry } from '../main/ets/crypto/Signing';
import { ApplyResult } from '../main/ets/clipboard/ClipboardApply';

interface Envelope {
  Type: string;
  Payload: string;
}

interface KeysBody {
  Keys: string[];
}

// An entry named by its signature; `minute` is its time (later is newer).
function e(signature: string, minute: number): ClipboardEntry {
  const mm: string = minute < 10 ? `0${minute}` : `${minute}`;
  return { Content: `text ${signature}`, Type: 'text', DeviceId: 'peer', Timestamp: `2026-01-01T10:${mm}:00.0000000Z`, Signature: signature };
}

// A file entry named by its signature.
function fileEntry(signature: string, minute: number): ClipboardEntry {
  const mm: string = minute < 10 ? `0${minute}` : `${minute}`;
  return { Content: '{}', Type: 'file', DeviceId: 'peer', Timestamp: `2026-01-01T10:${mm}:00.0000000Z`, Signature: signature };
}

function t(minute: number): number {
  return unixMillis(`2026-01-01T10:${minute < 10 ? '0' : ''}${minute}:00.0000000Z`);
}

function sigs(entries: ClipboardEntry[]): string {
  return entries.map((x: ClipboardEntry) => x.Signature ?? '').join(',');
}

function sameEntry(a: ClipboardEntry, b: ClipboardEntry): boolean {
  return a.Signature === b.Signature;
}

// Lets every promise chain run to its end: nothing in these tests waits for
// the outside world, so one trip through the timer queue is enough.
function shortWait(): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 3); });
}

function flush(): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 20); });
}

// A v2 head as a peer sends it.
function headJson(keys: string[], minutes: number[], deleted: string[] = []): string {
  return JSON.stringify({ Keys: keys, Times: minutes.map((m: number) => t(m)), Deleted: deleted });
}

// One message a link sent.
class Sent {
  type: string;
  payload: string;

  constructor(type: string, payload: string) {
    this.type = type;
    this.payload = payload;
  }

  keys(): string[] {
    return (JSON.parse(this.payload) as KeysBody).Keys;
  }

  entries(): ClipboardEntry[] {
    return JSON.parse(this.payload) as ClipboardEntry[];
  }
}

// A device's end of a connection: what it sent, and where that goes.
class Port {
  link: SyncLink;
  sent: Sent[] = [];
  // The lines as they were sent, envelope and all.
  raw: string[] = [];
  peer: Device | null = null;
  peerPort: Port | null = null;

  constructor(id: string, protocol: number) {
    this.link = new SyncLink(id, id, protocol, (json: string) => this.send(json));
  }

  private send(json: string): Promise<void> {
    const envelope: Envelope = JSON.parse(json) as Envelope;
    this.raw.push(json);
    this.sent.push(new Sent(envelope.Type, envelope.Payload));
    const peer: Device | null = this.peer;
    const at: Port | null = this.peerPort;
    if (peer !== null && at !== null) {
      Promise.resolve().then(() => { void peer.receive(at.link, envelope.Type, envelope.Payload); });
    }
    return Promise.resolve();
  }

  types(): string {
    return this.sent.map((s: Sent) => s.type).join(',');
  }

  ofType(type: string): Sent[] {
    return this.sent.filter((s: Sent) => s.type === type);
  }
}

// A device with a history, tombstones and a clipboard of its own, built on the
// same merge rule as HistoryAccess.addBatch.
class Device {
  entries: ClipboardEntry[] = [];
  tombstones: string[] = []; // oldest first
  protectedKey: string | null = null;
  clipboard: string[] = [];
  syncs: SyncApplied[] = [];
  batches: BatchApplied[] = [];
  heads: HeadApplied[] = [];
  settled: string[] = [];
  deletedEvents: string[][] = [];
  adds: number = 0;
  // Files asked for, as "signature:applyWhenStored".
  prepared: string[] = [];
  clock: number = 1000;
  slowFirstRead: boolean = false;
  // Putting an item on the clipboard takes a few ms (a place to close the link in).
  slowClipboard: boolean = false;
  reads: number = 0;
  engine: HistorySync;

  constructor() {
    this.engine = new HistorySync(this.host());
  }

  private has(key: string): boolean {
    return this.entries.some((x: ClipboardEntry) => x.Signature === key);
  }

  private host(): SyncHost {
    return {
      verified: (entry: ClipboardEntry) => Promise.resolve<ClipboardEntry | null>(entry.Signature === 'bad' ? null : entry),
      getHistory: () => {
        this.reads++;
        const copy: ClipboardEntry[] = this.entries.slice();
        if (this.slowFirstRead && this.reads === 1) {
          return new Promise<ClipboardEntry[]>((resolve: (value: ClipboardEntry[]) => void) => { setTimeout(() => { resolve(copy); }, 10); });
        }
        return Promise.resolve(copy);
      },
      deletedKeys: (limit: number) => Promise.resolve(this.tombstones.slice().reverse().slice(0, limit)),
      goneKeys: (keys: string[]) =>
        Promise.resolve(new Set<string>(keys.filter((k: string) => this.has(k) || this.tombstones.includes(k)))),
      isDeleted: (entry: ClipboardEntry) => Promise.resolve(this.tombstones.includes(entry.Signature ?? '')),
      addBatch: (candidates: ClipboardEntry[], newFront: boolean, frontOk: (entry: ClipboardEntry) => boolean) => {
        this.adds++;
        const result: MergeResult = mergeBatch(this.entries, candidates, sameEntry,
          (x: ClipboardEntry) => this.tombstones.includes(x.Signature ?? ''), 25, newFront,
          (x: ClipboardEntry) => x.Signature === this.protectedKey, frontOk);
        if (result.front !== null) this.protectedKey = result.front.Signature ?? null;
        return Promise.resolve(result);
      },
      deleteKeys: (keys: string[]) => {
        for (const key of keys) {
          if (!this.tombstones.includes(key)) this.tombstones.push(key);
        }
        this.entries = this.entries.filter((x: ClipboardEntry) => !keys.includes(x.Signature ?? ''));
        return Promise.resolve();
      },
      applyToClipboard: (entry: ClipboardEntry) => {
        this.clipboard.push(entry.Signature ?? '');
        if (this.slowClipboard) {
          return new Promise<ApplyResult>((resolve: (value: ApplyResult) => void) => { setTimeout(() => { resolve('applied'); }, 10); });
        }
        return Promise.resolve<ApplyResult>('applied');
      },
      prepareFile: (entry: ClipboardEntry, applyWhenStored: boolean) => {
        this.prepared.push(`${entry.Signature ?? ''}:${applyWhenStored}`);
        return true;
      },
      wait: (ms: number) => Promise.resolve(),
      now: () => this.clock,
      log: (message: string) => {},
      headApplied: (head: HeadApplied) => { this.heads.push(head); },
      batchApplied: (batch: BatchApplied) => { this.batches.push(batch); },
      syncApplied: (sync: SyncApplied) => { this.syncs.push(sync); },
      settled: (link: string) => { this.settled.push(link); },
      deleted: (keys: string[]) => { this.deletedEvents.push(keys); },
    };
  }

  port(id: string, protocol: number): Port {
    const port: Port = new Port(id, protocol);
    this.engine.open(port.link);
    return port;
  }

  // What SyncManager.handleMessage does with a message from the link.
  receive(link: SyncLink, type: string, payload: string): Promise<void> {
    if (type === 'history_head') return this.engine.onHead(link, payload);
    if (type === 'history_batch') return this.engine.onBatch(link, payload);
    if (type === 'history_request') {
      this.engine.onRequest(link, payload);
    } else if (type === 'delete') {
      return this.engine.onDelete(link, payload);
    }
    return Promise.resolve();
  }

  // The user deletes an item here (SyncManager.deleteEntry).
  deleteLocally(key: string): void {
    this.tombstones.push(key);
    this.entries = this.entries.filter((x: ClipboardEntry) => x.Signature !== key);
    this.engine.broadcastDelete([key]);
  }

  keys(): string {
    return this.entries.map((x: ClipboardEntry) => x.Signature ?? '').sort().join(',');
  }
}

// Two devices joined by a connection each way.
class Pair {
  a: Device;
  b: Device;
  atA: Port;
  atB: Port;

  constructor(a: Device, b: Device, protocolA: number, protocolB: number, name: string) {
    this.a = a;
    this.b = b;
    this.atA = a.port(`${name}-a`, Math.min(protocolA, protocolB));
    this.atB = b.port(`${name}-b`, Math.min(protocolA, protocolB));
    this.atA.peer = b;
    this.atA.peerPort = this.atB;
    this.atB.peer = a;
    this.atB.peerPort = this.atA;
  }

  async start(): Promise<void> {
    await Promise.all([this.a.engine.announce(this.atA.link), this.b.engine.announce(this.atB.link)]);
    await flush();
  }

  // Entries that went over the wire inside history_batch messages.
  entriesSent(): number {
    let count: number = 0;
    for (const port of [this.atA, this.atB]) {
      for (const batch of port.ofType('history_batch')) count += batch.entries().length;
    }
    return count;
  }
}

export default function historySyncTest() {
  describe('HistorySync', () => {
    // ---- the connect flow ----

    it('aV2ConnectionSendsOnlyAHeadWithKeysTimesAndTombstones', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1), e('b', 2)];
      d.tombstones = ['x', 'y']; // y was deleted last
      const port: Port = d.port('l', 2);
      await d.engine.announce(port.link);
      expect(port.types()).assertEqual('history_head');
      expect(port.sent[0].payload).assertEqual(`{"Keys":["b","a"],"Times":[${t(2)},${t(1)}],"Deleted":["y","x"]}`);
      done();
    });

    it('aV2HeadIsSentEvenForAnEmptyHistory', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.announce(port.link);
      expect(port.types()).assertEqual('history_head');
      expect(port.sent[0].payload).assertEqual('{"Keys":[],"Times":[],"Deleted":[]}');
      done();
    });

    it('aV1PeerGetsTheOldHeadAndTheWholeBatchAndNeverARequestOrDelete', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1), e('c', 3), e('b', 2)];
      const port: Port = d.port('l', 1);
      await d.engine.announce(port.link);
      expect(port.types()).assertEqual('history_head,history_batch');
      expect(port.sent[0].payload).assertEqual(buildHeadPayload(d.entries, (x: ClipboardEntry) => x.Signature ?? ''));
      expect(port.sent[0].payload.indexOf('"Newest"') !== -1).assertTrue();
      expect(sigs(port.sent[1].entries())).assertEqual('a,c,b');
      // The user deletes something: the old peer is not told, and a request
      // from it is not answered.
      d.deleteLocally('a');
      d.engine.onRequest(port.link, buildKeysPayload(['b']));
      await flush();
      expect(port.types()).assertEqual('history_head,history_batch');
      done();
    });

    it('aV1PeerWithOneEntryGetsJustTheBatch', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1)];
      const port: Port = d.port('l', 1);
      await d.engine.announce(port.link);
      expect(port.types()).assertEqual('history_batch');
      done();
    });

    it('headRequestAndDeleteAreEnvelopesWithAJsonStringPayload', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('k1', 1)];
      d.tombstones = ['gone1'];
      const port: Port = d.port('l', 2);
      await d.engine.announce(port.link);
      expect(port.raw[0]).assertEqual(
        `{"Type":"history_head","Payload":"{\\"Keys\\":[\\"k1\\"],\\"Times\\":[${t(1)}],\\"Deleted\\":[\\"gone1\\"]}"}`);
      await d.engine.onHead(port.link, headJson(['k9'], [9]));
      expect(port.raw[1]).assertEqual('{"Type":"history_request","Payload":"{\\"Keys\\":[\\"k9\\"]}"}');
      d.engine.broadcastDelete(['k1']);
      expect(port.raw[2]).assertEqual('{"Type":"delete","Payload":"{\\"Keys\\":[\\"k1\\"]}"}');
      done();
    });

    // ---- asking for what is missing ----

    it('aHeadIsAnsweredWithTheNewestMissingItemAloneThenTheRest', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('k1', 1)];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['k4', 'k3', 'k2', 'k1'], [4, 3, 2, 1]));
      expect(port.types()).assertEqual('history_request,history_request');
      expect(port.sent[0].payload).assertEqual('{"Keys":["k4"]}');
      expect(port.sent[1].keys().join(',')).assertEqual('k3,k2');
      expect(port.link.queue.length).assertEqual(2);
      expect(port.link.queue[0].convenience).assertTrue();
      expect(port.link.queue[1].convenience).assertFalse();
      expect(port.link.queue[0].groupSize).assertEqual(3);
      done();
    });

    it('aHeadWithOneMissingItemMakesOneRequest', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['k1'], [1]));
      expect(port.types()).assertEqual('history_request');
      expect(port.link.queue[0].groupSize).assertEqual(1);
      done();
    });

    it('knownAndDeletedItemsAreNotAskedFor', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('k2', 2)];
      d.tombstones = ['k3'];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['k4', 'k3', 'k2', 'k1'], [4, 3, 2, 1]));
      expect(port.sent[0].keys().join(',')).assertEqual('k4');
      expect(port.sent[1].keys().join(',')).assertEqual('k1');
      done();
    });

    it('aHeadWithNothingMissingAsksForNothing', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('k1', 1), e('k2', 2)];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['k2', 'k1'], [2, 1]));
      expect(port.sent.length).assertEqual(0);
      await d.engine.onHead(port.link, headJson([], []));
      expect(port.sent.length).assertEqual(0);
      done();
    });

    it('whatAnotherConnectionIsBeingAskedForIsNotAskedAgain', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['k3', 'k2', 'k1'], [3, 2, 1]));
      await d.engine.onHead(two.link, headJson(['k3', 'k2', 'k1'], [3, 2, 1]));
      expect(one.types()).assertEqual('history_request,history_request');
      expect(two.sent.length).assertEqual(0);
      done();
    });

    it('aPeerWithMoreThan25ItemsOnlyHasTheNewestWantedWhenTheHistoryIsFull', 0, async (done: Function) => {
      const d: Device = new Device();
      for (let i = 0; i < 25; i++) d.entries.push(e(`l${i}`, 20 + i)); // minutes 20 to 44
      const port: Port = d.port('l', 2);
      // 'new' is newer than all; 'old' is older than all and would not stay; 'mid' would.
      await d.engine.onHead(port.link, headJson(['new', 'mid', 'old'], [50, 30, 5]));
      expect(port.sent[0].keys().join(',')).assertEqual('new');
      expect(port.sent[1].keys().join(',')).assertEqual('mid');
      expect(port.sent.length).assertEqual(2);
      done();
    });

    it('theNewestMissingItemIsAskedForEvenIfItWouldNotStay', 0, async (done: Function) => {
      const d: Device = new Device();
      for (let i = 0; i < 25; i++) d.entries.push(e(`l${i}`, 20 + i));
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['old'], [5]));
      expect(port.sent[0].keys().join(',')).assertEqual('old');
      done();
    });

    it('aHeadWithoutTimesAsksForEverythingMissing', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, '{"Keys":["k3","k2","k1"]}');
      expect(port.sent[0].keys().join(',')).assertEqual('k3');
      expect(port.sent[1].keys().join(',')).assertEqual('k2,k1');
      done();
    });

    it('theNewestOfAnOldStyleHeadIsIgnoredOnAV2Connection', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      const old: string = buildHeadPayload([e('a', 1), e('c', 3), e('b', 2)], (x: ClipboardEntry) => x.Signature ?? '') as string;
      await d.engine.onHead(port.link, old);
      expect(d.clipboard.length).assertEqual(0);
      expect(d.heads.length).assertEqual(0);
      expect(d.entries.length).assertEqual(0);
      expect(port.sent[0].keys().join(',')).assertEqual('c');
      done();
    });

    // ---- the answers ----

    it('twoAnswersAreMatchedInOrderAndOnlyTheFirstGoesOnTheClipboard', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      // Both arrive before either has been dealt with.
      const first: Promise<void> = d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      const second: Promise<void> = d.engine.onBatch(port.link, JSON.stringify([e('b', 2), e('a', 1)]));
      await first;
      await second;
      expect(d.clipboard.join(',')).assertEqual('c');
      expect(d.syncs.length).assertEqual(2);
      expect(d.syncs[0].front?.Signature).assertEqual('c');
      expect(d.syncs[0].expectedTotal).assertEqual(3);
      expect(d.syncs[0].last).assertFalse();
      expect(d.syncs[1].front).assertEqual(null);
      expect(d.syncs[1].applied).assertEqual(null);
      expect(sigs(d.syncs[1].added)).assertEqual('b,a');
      expect(d.syncs[1].last).assertTrue();
      expect(d.keys()).assertEqual('a,b,c');
      expect(d.batches.length).assertEqual(0); // not dealt with as a v1 batch
      expect(port.link.queue.length).assertEqual(0);
      done();
    });

    it('theConvenienceAnswerAppliesItsNewestNewEntryEvenIfOlderThanTheOwnNewest', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('own', 50)];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['old'], [5]));
      await d.engine.onBatch(port.link, JSON.stringify([e('old', 5)]));
      expect(d.clipboard.join(',')).assertEqual('old');
      expect(d.protectedKey).assertEqual('old');
      done();
    });

    it('theConvenienceItemIsKeptWhenTheHistoryIsFullAndTheOldestOtherGoes', 0, async (done: Function) => {
      const d: Device = new Device();
      for (let i = 0; i < 25; i++) d.entries.push(e(`l${i}`, 20 + i));
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['old'], [5]));
      await d.engine.onBatch(port.link, JSON.stringify([e('old', 5)]));
      expect(d.entries.length).assertEqual(25);
      expect(d.keys().indexOf('old') !== -1).assertTrue();
      expect(d.keys().indexOf('l0,') === -1).assertTrue(); // the oldest other item went instead
      expect(d.syncs[0].added.length).assertEqual(1);
      done();
    });

    it('anAnswerThatIsEmptyEndsTheWaitAndTheStackSettles', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      await d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      expect(d.settled.length).assertEqual(0); // a request is still out
      await d.engine.onBatch(port.link, '[]');
      expect(d.settled.join(',')).assertEqual('l');
      expect(d.clipboard.join(',')).assertEqual('c');
      done();
    });

    it('aSingleAnswerThatIsAlsoTheLastAddsItsItemsWithoutSettlingTwice', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c'], [3]));
      await d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      expect(d.syncs.length).assertEqual(1);
      expect(d.syncs[0].last).assertTrue();
      expect(d.syncs[0].expectedTotal).assertEqual(1);
      expect(d.settled.length).assertEqual(0);
      done();
    });

    it('anAnswerWithABadSignatureAddsNothingButStillCountsAsTheAnswer', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['bad', 'b'], [3, 2]));
      await d.engine.onBatch(port.link, JSON.stringify([e('bad', 3)]));
      expect(d.entries.length).assertEqual(0);
      expect(d.clipboard.length).assertEqual(0);
      expect(port.link.queue.length).assertEqual(1);
      await d.engine.onBatch(port.link, JSON.stringify([e('b', 2)]));
      expect(d.clipboard.length).assertEqual(0); // the second answer never goes on the clipboard
      expect(d.keys()).assertEqual('b');
      expect(d.syncs.length).assertEqual(1);
      done();
    });

    it('anAnswerThatIsNotJsonCountsAsTheAnswerToo', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['b'], [2]));
      await d.engine.onBatch(port.link, 'not json');
      expect(port.link.queue.length).assertEqual(0);
      expect(d.syncs.length).assertEqual(0);
      done();
    });

    it('aBatchNobodyAskedForIsDealtWithAsAnOldOneAndAppliesOnlyTheNewestNewItem', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('own', 9)];
      const port: Port = d.port('l', 2); // nothing was asked: the queue is empty
      await d.engine.onBatch(port.link, JSON.stringify([e('x', 1), e('y', 5), e('own', 9)]));
      expect(d.clipboard.join(',')).assertEqual('y');
      expect(d.batches.length).assertEqual(1);
      expect(sigs(d.batches[0].added)).assertEqual('x,y');
      expect(d.syncs.length).assertEqual(0);
      done();
    });

    // ---- time-outs and closing ----

    it('aRequestNotAnsweredIn90SecondsIsDroppedAndFreesItsKeys', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      d.clock += REQUEST_TIMEOUT_MS;
      d.engine.expire(one.link);
      expect(one.link.queue.length).assertEqual(2); // exactly 90 s is not over yet
      d.clock += 1;
      d.engine.expire(one.link);
      expect(one.link.queue.length).assertEqual(0);
      expect(d.settled.length).assertEqual(0); // no stack was waiting
      // The keys are free: another connection can be asked.
      await d.engine.onHead(two.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      expect(two.sent[0].keys().join(',')).assertEqual('c');
      done();
    });

    it('theStackStopsWaitingWhenItsLastRequestTimesOut', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      await d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link);
      expect(port.link.queue.length).assertEqual(0);
      expect(d.settled.join(',')).assertEqual('l');
      d.engine.expire(port.link);
      expect(d.settled.length).assertEqual(1); // once
      done();
    });

    it('aHeadWithoutItsBatchSettlesItsStackAfter90Seconds', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 1);
      const head: string = buildHeadPayload([e('c', 3), e('b', 2), e('a', 1)], (x: ClipboardEntry) => x.Signature ?? '') as string;
      await d.engine.onHead(port.link, head);
      expect(d.heads.length).assertEqual(1);
      expect(d.heads[0].expectedNew).assertEqual(3);
      expect(d.clipboard.join(',')).assertEqual('c');
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link);
      expect(d.settled.join(',')).assertEqual('l');
      // The batch that comes late finds nothing to settle.
      await d.engine.onBatch(port.link, JSON.stringify([e('a', 1), e('b', 2), e('c', 3)]));
      expect(d.settled.length).assertEqual(1);
      done();
    });

    it('aClosedConnectionDropsItsQueueSettlesItsStackAndTheOthersAskInItsPlace', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      await d.engine.onHead(two.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      await d.engine.onBatch(one.link, JSON.stringify([e('c', 3)]));
      expect(two.sent.length).assertEqual(0);
      d.engine.close(one.link);
      await flush();
      expect(one.link.queue.length).assertEqual(0);
      expect(d.settled.join(',')).assertEqual('one');
      // c arrived; two is asked for the others, and nothing else.
      expect(two.types()).assertEqual('history_request');
      expect(two.sent[0].keys().join(',')).assertEqual('b,a');
      done();
    });

    it('closingAConnectionThatAskedForNothingAsksNobody', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(two.link, headJson(['b'], [2]));
      await d.engine.onBatch(two.link, JSON.stringify([e('b', 2)]));
      d.engine.close(one.link);
      await flush();
      expect(two.types()).assertEqual('history_request');
      done();
    });

    it('anItemAskedAgainAfterAConnectionDiedDoesNotGoOnTheClipboardTwice', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['k3', 'k2', 'k1'], [3, 2, 1]));
      await d.engine.onHead(two.link, headJson(['k3', 'k2', 'k1', 'x9'], [3, 2, 1, 0]));
      expect(two.sent[0].keys().join(',')).assertEqual('x9'); // two asks what one is not asked for
      d.engine.close(one.link);
      await flush();
      expect(two.types()).assertEqual('history_request,history_request');
      expect(two.sent[1].keys().join(',')).assertEqual('k3,k2,k1');
      expect(two.link.queue[1].convenience).assertFalse();
      done();
    });

    it('aConnectionThatClosesWhileItsFirstAnswerIsBeingDealtWithLeavesNoStackWaiting', 0, async (done: Function) => {
      const d: Device = new Device();
      d.slowClipboard = true;
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      const first: Promise<void> = d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      await shortWait(); // c is being put on the clipboard
      d.engine.close(port.link); // nothing was waiting yet: it settles nothing
      await first;
      expect(d.settled.length).assertEqual(0);
      expect(d.syncs.length).assertEqual(1);
      expect(d.syncs[0].expectedTotal).assertEqual(3);
      expect(d.syncs[0].last).assertTrue(); // the UI settles the stack at once
      expect(port.link.waiting).assertFalse();
      done();
    });

    it('requestsGivenUpOnWhileTheFirstAnswerIsBeingDealtWithLeaveNoStackWaiting', 0, async (done: Function) => {
      const d: Device = new Device();
      d.slowClipboard = true;
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      const first: Promise<void> = d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      await shortWait();
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link); // the second request goes: no stack waits yet, so nothing settles
      await first;
      expect(d.settled.length).assertEqual(0);
      expect(d.syncs[0].last).assertTrue();
      expect(port.link.waiting).assertFalse();
      done();
    });

    it('aLateAnswerInProgressDoesNotKeepAnotherAnswersStackFromSettling', 0, async (done: Function) => {
      const d: Device = new Device();
      d.slowClipboard = true;
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      const first: Promise<void> = d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      await shortWait();
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link); // the second request goes: its answer is a late one
      const late: Promise<void> = d.engine.onBatch(port.link, JSON.stringify([e('b', 2), e('a', 1)]));
      expect(port.link.answering).assertEqual(1); // only the first answer counts
      await first;
      await late;
      expect(d.syncs[0].last).assertTrue(); // nothing else is coming for the stack
      expect(d.syncs[1].quiet).assertTrue();
      expect(port.link.waiting).assertFalse();
      expect(port.link.answering).assertEqual(0);
      done();
    });

    it('theLateAnswersOfRequestsGivenUpOnAddTheirItemsWithoutTouchingTheClipboard', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('own', 9)];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link);
      expect(port.link.queue.length).assertEqual(0);
      await d.engine.onBatch(port.link, JSON.stringify([e('c', 3)])); // the convenience answer, late
      await d.engine.onBatch(port.link, JSON.stringify([e('b', 2), e('a', 1)]));
      expect(d.keys()).assertEqual('a,b,c,own');
      expect(d.clipboard.length).assertEqual(0);
      expect(d.batches.length).assertEqual(0); // not dealt with as old batches
      expect(d.syncs.length).assertEqual(2);
      expect(d.syncs[0].front).assertEqual(null);
      expect(d.syncs[1].front).assertEqual(null);
      expect(d.syncs[0].quiet).assertTrue(); // no stack, no clipboard, no notice
      expect(d.syncs[1].quiet).assertTrue();
      expect(d.protectedKey).assertEqual(null);
      expect(port.link.expired.length).assertEqual(0);
      // The next batch nobody asked for is an old one again.
      await d.engine.onBatch(port.link, JSON.stringify([e('z', 7)]));
      expect(d.batches.length).assertEqual(1);
      expect(d.clipboard.join(',')).assertEqual('z');
      done();
    });

    it('aLateAnswerStillAsksForTheBytesOfNewFilesButNeverAppliesThem', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['f', 'g'], [3, 2]));
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link);
      await d.engine.onBatch(port.link, JSON.stringify([fileEntry('f', 3)])); // the convenience answer, late
      expect(d.prepared.join(',')).assertEqual('f:false');
      expect(d.clipboard.length).assertEqual(0);
      expect(d.syncs[0].quiet).assertTrue();
      expect(d.syncs[0].front).assertEqual(null);
      expect(d.syncs[0].applied).assertEqual(null);
      done();
    });

    it('aMarkerIsNotAnOpenRequestAndLeavesOnlyWithItsAnswer', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      port.link.queue[1].sentAt += 60000; // the second request is asked later
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link);
      expect(port.link.expired.length).assertEqual(1);
      d.clock += 200000;
      d.engine.expire(port.link); // the second goes too; the first marker does not go twice or time out
      expect(port.link.queue.length).assertEqual(0);
      expect(port.link.expired.length).assertEqual(2);
      expect(d.settled.length).assertEqual(0); // markers keep and end no stack
      await d.engine.onBatch(port.link, JSON.stringify([e('c', 3)]));
      expect(port.link.expired.length).assertEqual(1);
      await d.engine.onBatch(port.link, JSON.stringify([e('b', 2), e('a', 1)]));
      expect(port.link.expired.length).assertEqual(0);
      expect(d.keys()).assertEqual('a,b,c');
      expect(d.clipboard.length).assertEqual(0);
      expect(d.syncs.filter((s: SyncApplied) => s.quiet).length).assertEqual(2);
      done();
    });

    it('anAnswerIsMatchedToTheRequestGivenUpOnBeforeTheOneStillWaiting', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      one.link.queue[1].sentAt += 60000; // asked later: still within its 90 s
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(one.link);
      expect(one.link.queue.length).assertEqual(1);
      expect(one.link.expired.length).assertEqual(1);
      await d.engine.onBatch(one.link, JSON.stringify([e('c', 3)])); // belongs to the first request
      expect(d.clipboard.length).assertEqual(0);
      expect(one.link.queue.length).assertEqual(1); // the second request is still waiting
      expect(d.syncs[0].last).assertFalse();
      // Its keys are still being asked for here: another connection leaves them alone.
      await d.engine.onHead(two.link, headJson(['c', 'b', 'a'], [3, 2, 1]));
      expect(two.sent.length).assertEqual(0);
      await d.engine.onBatch(one.link, JSON.stringify([e('b', 2), e('a', 1)]));
      expect(d.keys()).assertEqual('a,b,c');
      expect(d.clipboard.length).assertEqual(0);
      expect(d.syncs[1].last).assertTrue();
      done();
    });

    it('aClosedConnectionForgetsTheRequestsItGaveUpOn', 0, async (done: Function) => {
      const d: Device = new Device();
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b'], [3, 2]));
      d.clock += REQUEST_TIMEOUT_MS + 1;
      d.engine.expire(port.link);
      expect(port.link.expired.length).assertEqual(2);
      d.engine.close(port.link);
      expect(port.link.expired.length).assertEqual(0);
      done();
    });

    // ---- one clipboard change when two peers answer at once ----

    it('twoPeersAnsweringAtOnceGiveOneClipboardChangeAndTheOlderItemIsOnlyListed', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['x'], [5]));
      await d.engine.onHead(two.link, headJson(['y'], [4]));
      await d.engine.onBatch(one.link, JSON.stringify([e('x', 5)]));
      await d.engine.onBatch(two.link, JSON.stringify([e('y', 4)]));
      expect(d.clipboard.join(',')).assertEqual('x');
      expect(d.keys()).assertEqual('x,y'); // y is in the history all the same
      expect(d.syncs[0].superseded).assertFalse();
      expect(d.syncs[1].front?.Signature).assertEqual('y'); // and leads its stack
      expect(d.syncs[1].superseded).assertTrue();
      expect(d.syncs[1].applied).assertEqual(null);
      expect(d.protectedKey).assertEqual('x'); // only what went on the clipboard is spared
      done();
    });

    it('aNewerConvenienceItemOfTheSecondPeerStillGoesOnTheClipboard', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['x'], [5]));
      await d.engine.onHead(two.link, headJson(['y'], [6]));
      await d.engine.onBatch(one.link, JSON.stringify([e('x', 5)]));
      await d.engine.onBatch(two.link, JSON.stringify([e('y', 6)]));
      expect(d.clipboard.join(',')).assertEqual('x,y');
      expect(d.syncs[1].superseded).assertFalse();
      expect(d.protectedKey).assertEqual('y');
      done();
    });

    it('anItemThatIsNotNewerThanTheLastConvenienceItemStaysOffTheClipboardEvenAtTheSameTime', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['x'], [5]));
      await d.engine.onHead(two.link, headJson(['y'], [5]));
      await d.engine.onBatch(one.link, JSON.stringify([e('x', 5)]));
      await d.engine.onBatch(two.link, JSON.stringify([e('y', 5)]));
      expect(d.clipboard.join(',')).assertEqual('x');
      expect(d.syncs[1].superseded).assertTrue();
      done();
    });

    it('anOlderConvenienceItemGoesOnTheClipboardOnceTheLastOneIs90SecondsOld', 0, async (done: Function) => {
      const d: Device = new Device();
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['x'], [5]));
      await d.engine.onHead(two.link, headJson(['y'], [4]));
      await d.engine.onBatch(one.link, JSON.stringify([e('x', 5)]));
      d.clock += CONVENIENCE_WINDOW_MS;
      await d.engine.onBatch(two.link, JSON.stringify([e('y', 4)]));
      expect(d.clipboard.join(',')).assertEqual('x,y');
      expect(d.syncs[1].superseded).assertFalse();
      expect(d.protectedKey).assertEqual('y');
      done();
    });

    it('aSecondItemInsideTheWindowIsNotSparedByTheTrim', 0, async (done: Function) => {
      const d: Device = new Device();
      for (let i = 0; i < 24; i++) d.entries.push(e(`l${i}`, 20 + i));
      const one: Port = d.port('one', 2);
      const two: Port = d.port('two', 2);
      await d.engine.onHead(one.link, headJson(['x'], [5]));
      await d.engine.onHead(two.link, headJson(['y'], [4]));
      await d.engine.onBatch(one.link, JSON.stringify([e('x', 5)])); // 25 items, x spared
      await d.engine.onBatch(two.link, JSON.stringify([e('y', 4)])); // 26: y is the oldest and not spared
      expect(d.entries.length).assertEqual(25);
      expect(d.keys().indexOf('x') !== -1).assertTrue();
      expect(d.keys().indexOf('y') === -1).assertTrue();
      expect(d.keys().indexOf('l0') !== -1).assertTrue(); // the oldest other item stays
      expect(d.clipboard.join(',')).assertEqual('x');
      done();
    });

    // ---- answering requests ----

    it('aRequestIsAnsweredWithOneBatchNewestFirstAndUnknownKeysAreSkipped', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1), e('b', 5), e('c', 3)];
      const port: Port = d.port('l', 2);
      d.engine.onRequest(port.link, buildKeysPayload(['a', 'b', 'nope']));
      await flush();
      expect(port.types()).assertEqual('history_batch');
      expect(sigs(port.sent[0].entries())).assertEqual('b,a');
      done();
    });

    it('aRequestForNothingWeHaveIsAnsweredWithAnEmptyArray', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1)];
      const port: Port = d.port('l', 2);
      d.engine.onRequest(port.link, buildKeysPayload(['nope']));
      d.engine.onRequest(port.link, buildKeysPayload([]));
      await flush();
      expect(port.types()).assertEqual('history_batch,history_batch');
      expect(port.sent[0].payload).assertEqual('[]');
      expect(port.sent[1].payload).assertEqual('[]');
      done();
    });

    it('aRequestForMoreThan100KeysIsAnsweredForTheFirst100', 0, async (done: Function) => {
      const d: Device = new Device();
      const keys: string[] = [];
      for (let i = 0; i < 101; i++) {
        d.entries.push(e(`k${i}`, i % 60));
        keys.push(`k${i}`);
      }
      const port: Port = d.port('l', 2);
      d.engine.onRequest(port.link, buildKeysPayload(keys));
      await flush();
      const answered: string[] = port.sent[0].entries().map((x: ClipboardEntry) => x.Signature ?? '');
      expect(answered.length).assertEqual(100);
      expect(answered.includes('k100')).assertFalse();
      done();
    });

    it('answersGoOutInTheOrderTheRequestsCameEvenIfTheFirstIsSlow', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1), e('b', 2)];
      d.slowFirstRead = true;
      const port: Port = d.port('l', 2);
      d.engine.onRequest(port.link, buildKeysPayload(['a']));
      d.engine.onRequest(port.link, buildKeysPayload(['b']));
      await flush();
      await flush();
      expect(port.types()).assertEqual('history_batch,history_batch');
      expect(sigs(port.sent[0].entries())).assertEqual('a');
      expect(sigs(port.sent[1].entries())).assertEqual('b');
      done();
    });

    // ---- delete ----

    it('aReceivedDeleteRemovesItemsAddsTombstonesAndLeavesTheClipboardAlone', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1), e('b', 2), e('c', 3)];
      const port: Port = d.port('l', 2);
      await d.engine.onDelete(port.link, buildKeysPayload(['b', 'never-had']));
      expect(d.keys()).assertEqual('a,c');
      expect(d.tombstones.join(',')).assertEqual('b,never-had');
      expect(d.clipboard.length).assertEqual(0);
      expect(d.deletedEvents.length).assertEqual(1);
      expect(d.deletedEvents[0].join(',')).assertEqual('b,never-had');
      expect(port.sent.length).assertEqual(0); // not passed on
      done();
    });

    it('aReceivedDeleteNamesAtMost100Keys', 0, async (done: Function) => {
      const d: Device = new Device();
      const keys: string[] = [];
      for (let i = 0; i < 130; i++) keys.push(`k${i}`);
      const port: Port = d.port('l', 2);
      await d.engine.onDelete(port.link, buildKeysPayload(keys));
      expect(d.tombstones.length).assertEqual(100);
      done();
    });

    it('theTombstonesOfAHeadAreDeletedFirstAndNotAskedFor', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('b', 2), e('a', 1)];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['z', 'b'], [3, 2], ['b']));
      expect(d.keys()).assertEqual('a');
      expect(d.tombstones.join(',')).assertEqual('b');
      expect(d.deletedEvents.length).assertEqual(1);
      expect(d.clipboard.length).assertEqual(0);
      expect(port.sent[0].keys().join(',')).assertEqual('z'); // b is gone, not missing
      done();
    });

    it('aDeletedItemOfferedAgainInAnAnswerOrABatchDoesNotComeBack', 0, async (done: Function) => {
      const d: Device = new Device();
      d.tombstones = ['b'];
      const port: Port = d.port('l', 2);
      await d.engine.onHead(port.link, headJson(['c', 'b'], [3, 2]));
      await d.engine.onBatch(port.link, JSON.stringify([e('c', 3), e('b', 2)]));
      expect(d.keys()).assertEqual('c');
      const old: Port = d.port('old', 1);
      await d.engine.onBatch(old.link, JSON.stringify([e('b', 2), e('c', 3)]));
      expect(d.keys()).assertEqual('c');
      done();
    });

    it('aDeleteReachesV2PeersOnlyInPiecesOf100AndNotAV1Peer', 0, async (done: Function) => {
      const d: Device = new Device();
      const v2: Port = d.port('v2', 2);
      const v1: Port = d.port('v1', 1);
      const keys: string[] = [];
      for (let i = 0; i < 250; i++) keys.push(`k${i}`);
      keys.push('k0');
      d.engine.broadcastDelete(keys);
      await flush();
      expect(v2.types()).assertEqual('delete,delete,delete');
      expect(v2.sent.map((s: Sent) => s.keys().length).join(',')).assertEqual('100,100,50');
      expect(v1.sent.length).assertEqual(0);
      d.engine.close(v2.link);
      d.engine.broadcastDelete(['z']);
      expect(v2.sent.length).assertEqual(3); // not to a closed connection
      done();
    });

    it('aDeleteFromAV1ConnectionIsIgnored', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('a', 1)];
      const port: Port = d.port('l', 1);
      await d.engine.onDelete(port.link, buildKeysPayload(['a']));
      expect(d.keys()).assertEqual('a');
      expect(d.tombstones.length).assertEqual(0);
      done();
    });

    // ---- the old flow with an old peer ----

    it('anOldHeadThenItsBatchPutTheNewestOnTheClipboardOnce', 0, async (done: Function) => {
      const d: Device = new Device();
      d.entries = [e('own', 9)];
      const port: Port = d.port('l', 1);
      const all: ClipboardEntry[] = [e('c', 3), e('b', 2), e('a', 1)];
      const head: string = buildHeadPayload(all, (x: ClipboardEntry) => x.Signature ?? '') as string;
      await d.engine.onHead(port.link, head);
      await d.engine.onBatch(port.link, JSON.stringify(all.slice().reverse()));
      // c is older than the own newest, and is the item on the clipboard.
      expect(d.clipboard.join(',')).assertEqual('c');
      expect(d.heads.length).assertEqual(1);
      expect(d.batches.length).assertEqual(1);
      expect(d.batches[0].headDone).assertTrue();
      expect(sigs(d.batches[0].added)).assertEqual('a,b');
      expect(d.protectedKey).assertEqual('c');
      done();
    });

    // ---- two devices ----

    it('twoV2DevicesSyncOnlyWhatIsMissing', 0, async (done: Function) => {
      const a: Device = new Device();
      const b: Device = new Device();
      a.entries = [e('a1', 1), e('a2', 2), e('a3', 3)];
      b.entries = [e('a1', 1), e('b4', 4)];
      const pair: Pair = new Pair(a, b, 2, 2, 'c');
      await pair.start();
      expect(a.keys()).assertEqual('a1,a2,a3,b4');
      expect(b.keys()).assertEqual('a1,a2,a3,b4');
      // Three entries crossed the wire, not eight.
      expect(pair.entriesSent()).assertEqual(3);
      expect(pair.atA.ofType('history_batch').length).assertEqual(2); // two answers to b's two requests
      expect(a.clipboard.join(',')).assertEqual('b4');
      expect(b.clipboard.join(',')).assertEqual('a3');
      expect(b.syncs.length).assertEqual(2);
      expect(b.syncs[0].expectedTotal).assertEqual(2);
      expect(b.syncs[1].last).assertTrue();
      expect(a.syncs.length).assertEqual(1);
      expect(a.batches.length).assertEqual(0);
      done();
    });

    it('twoV2DevicesWithTheSameHistoryExchangeNoEntries', 0, async (done: Function) => {
      const a: Device = new Device();
      const b: Device = new Device();
      a.entries = [e('a1', 1), e('a2', 2)];
      b.entries = [e('a1', 1), e('a2', 2)];
      const pair: Pair = new Pair(a, b, 2, 2, 'c');
      await pair.start();
      expect(pair.atA.types()).assertEqual('history_head');
      expect(pair.atB.types()).assertEqual('history_head');
      expect(a.clipboard.length + b.clipboard.length).assertEqual(0);
      done();
    });

    it('anItemDeletedWhileConnectedGoesAwayOnTheOtherDeviceAndStaysAway', 0, async (done: Function) => {
      const a: Device = new Device();
      const b: Device = new Device();
      a.entries = [e('a1', 1), e('a2', 2), e('a3', 3)];
      b.entries = [e('a1', 1), e('a2', 2), e('a3', 3)];
      const pair: Pair = new Pair(a, b, 2, 2, 'c');
      await pair.start();
      a.deleteLocally('a2');
      await flush();
      expect(b.keys()).assertEqual('a1,a3');
      expect(b.tombstones.join(',')).assertEqual('a2');
      expect(b.deletedEvents.length).assertEqual(1);
      expect(b.clipboard.length).assertEqual(0);
      // They meet again: the tombstone is in both heads, nothing comes back.
      a.engine.close(pair.atA.link);
      b.engine.close(pair.atB.link);
      const again: Pair = new Pair(a, b, 2, 2, 'd');
      await again.start();
      expect(a.keys()).assertEqual('a1,a3');
      expect(b.keys()).assertEqual('a1,a3');
      expect(again.atA.types()).assertEqual('history_head');
      expect(again.atB.types()).assertEqual('history_head');
      done();
    });

    it('aDeviceThatWasOfflineLearnsTheDeletionFromTheHead', 0, async (done: Function) => {
      const a: Device = new Device();
      const b: Device = new Device();
      a.entries = [e('a1', 1), e('a3', 3)];
      a.tombstones = ['a2'];
      b.entries = [e('a1', 1), e('a2', 2), e('a3', 3)];
      const pair: Pair = new Pair(a, b, 2, 2, 'c');
      await pair.start();
      expect(b.keys()).assertEqual('a1,a3');
      expect(a.keys()).assertEqual('a1,a3'); // a2 was not asked for back
      expect(pair.entriesSent()).assertEqual(0);
      done();
    });

    it('aV2DeviceAndAV1DeviceKeepToTheOldFlow', 0, async (done: Function) => {
      const a: Device = new Device();
      const b: Device = new Device();
      a.entries = [e('a1', 1), e('a2', 2), e('a3', 3)];
      b.entries = [e('b4', 4)];
      const pair: Pair = new Pair(a, b, 2, 1, 'c'); // b is an older build
      await pair.start();
      for (const port of [pair.atA, pair.atB]) {
        expect(port.ofType('history_request').length).assertEqual(0);
        expect(port.ofType('delete').length).assertEqual(0);
      }
      expect(pair.atA.types()).assertEqual('history_head,history_batch');
      expect(a.keys()).assertEqual('a1,a2,a3,b4');
      expect(b.keys()).assertEqual('a1,a2,a3,b4');
      // Each put the other's newest new item on the clipboard.
      expect(a.clipboard.join(',')).assertEqual('b4');
      expect(b.clipboard.join(',')).assertEqual('a3');
      // A delete here is not sent to the older build.
      a.deleteLocally('a1');
      await flush();
      expect(pair.atA.ofType('delete').length).assertEqual(0);
      expect(b.keys()).assertEqual('a1,a2,a3,b4');
      done();
    });
  });
}
