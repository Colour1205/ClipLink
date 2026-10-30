import { describe, it, expect } from '@ohos/hypium';
import {
  GROUP_MIN_ITEMS, MergeResult, applyBatch, applyHead, buildHeadPayload, mergeBatch, newestOf, parseHead, trimOldest, HistoryHead
} from '../main/ets/storage/HistoryBatch';
import { ClipboardEntry } from '../main/ets/crypto/Signing';

// An entry named by its signature; `minute` is its time (later is newer).
function e(signature: string, minute: number): ClipboardEntry {
  const mm: string = minute < 10 ? `0${minute}` : `${minute}`;
  return { Content: `text ${signature}`, Type: 'text', DeviceId: 'peer', Timestamp: `2026-01-01T10:${mm}:00.0000000Z`, Signature: signature };
}

function same(a: ClipboardEntry, b: ClipboardEntry): boolean {
  return a.Signature === b.Signature;
}

function sigs(entries: ClipboardEntry[]): string {
  return entries.map((x: ClipboardEntry) => x.Signature ?? '').join(',');
}

function noneDeleted(): boolean {
  return false;
}

// What a test's "history" does for applyBatch / applyHead: the real one is
// HistoryAccess.addBatch, which is mergeBatch around a read and a write.
class FakeHistory {
  entries: ClipboardEntry[] = [];
  deletedSigs: Set<string> = new Set<string>();
  adds: number = 0;

  add(candidates: ClipboardEntry[]): Promise<MergeResult> {
    this.adds++;
    return Promise.resolve(mergeBatch(this.entries, candidates, same,
      (entry: ClipboardEntry) => this.deletedSigs.has(entry.Signature ?? ''), 25));
  }
}

function accept(entry: ClipboardEntry): Promise<ClipboardEntry | null> {
  return Promise.resolve(entry.Signature === 'bad' ? null : entry);
}

export default function historyBatchTest() {
  describe('HistoryBatch', () => {
    it('thresholdIsTwo', 0, () => {
      expect(GROUP_MIN_ITEMS).assertEqual(2);
    });

    it('mergeSplitsNewKnownAndDeleted', 0, () => {
      const history: ClipboardEntry[] = [e('a', 1), e('b', 2)];
      const result: MergeResult = mergeBatch(history, [e('b', 2), e('c', 3), e('gone', 4), e('d', 5)], same,
        (x: ClipboardEntry) => x.Signature === 'gone', 25);
      expect(sigs(result.added)).assertEqual('c,d');
      expect(result.duplicates).assertEqual(1);
      expect(result.deleted).assertEqual(1);
      expect(result.evicted.length).assertEqual(0);
      expect(sigs(history)).assertEqual('a,b,c,d');
    });

    it('mergeCountsAnEntryTwiceInOneBatchOnce', 0, () => {
      const history: ClipboardEntry[] = [];
      const result: MergeResult = mergeBatch(history, [e('a', 1), e('a', 1), e('b', 2)], same, noneDeleted, 25);
      expect(sigs(result.added)).assertEqual('a,b');
      expect(result.duplicates).assertEqual(1);
    });

    it('mergeTrimsOnceAndAddedHoldsOnlyWhatStays', 0, () => {
      const history: ClipboardEntry[] = [e('a', 10), e('b', 11), e('c', 12)];
      // Cap 4: two new ones come, the oldest of all five goes - a new one,
      // older than the whole history, which therefore was never "added".
      const result: MergeResult = mergeBatch(history, [e('old', 1), e('n', 13)], same, noneDeleted, 4);
      expect(sigs(result.evicted)).assertEqual('old');
      expect(sigs(result.added)).assertEqual('n');
      expect(sigs(history)).assertEqual('a,b,c,n');
    });

    it('mergeTrimmedOldEntriesLeaveTheGroupSmaller', 0, () => {
      const history: ClipboardEntry[] = [e('a', 20), e('b', 21)];
      const result: MergeResult = mergeBatch(history, [e('x1', 1), e('x2', 2), e('x3', 30)], same, noneDeleted, 3);
      // Two of the three were pushed out again: only one is new, so no group.
      expect(result.added.length).assertEqual(1);
      expect(result.added.length < GROUP_MIN_ITEMS).assertTrue();
    });

    it('trimOldestEvictsByTimeNotByPosition', 0, () => {
      const history: ClipboardEntry[] = [e('new', 30), e('old', 1), e('mid', 15)];
      const evicted: ClipboardEntry[] = trimOldest(history, 2);
      expect(sigs(evicted)).assertEqual('old');
      expect(sigs(history)).assertEqual('new,mid');
    });

    it('trimOldestSparesAKeptEntryAndDropsTheOldestOtherInstead', 0, () => {
      const history: ClipboardEntry[] = [e('new', 30), e('old', 1), e('mid', 15)];
      const evicted: ClipboardEntry[] = trimOldest(history, 2, (x: ClipboardEntry) => x.Signature === 'old');
      expect(sigs(evicted)).assertEqual('mid');
      expect(sigs(history)).assertEqual('new,old');
      expect(history.length).assertEqual(2);
    });

    it('trimOldestStopsWhenEverythingLeftIsKept', 0, () => {
      const history: ClipboardEntry[] = [e('a', 1), e('b', 2)];
      expect(trimOldest(history, 1, () => true).length).assertEqual(0);
      expect(history.length).assertEqual(2);
    });

    it('mergeWithNewFrontSparesTheNewestNewEntryEvenWhenItIsTheOldestOfAll', 0, () => {
      const history: ClipboardEntry[] = [e('a', 10), e('b', 11), e('c', 12)];
      // Cap 3, full: the new entry is older than all three, as a convenience
      // item can be. It stays; the oldest of the others goes.
      const result: MergeResult = mergeBatch(history, [e('front', 1)], same, noneDeleted, 3, true);
      expect(result.front?.Signature).assertEqual('front');
      expect(sigs(result.added)).assertEqual('front');
      expect(sigs(result.evicted)).assertEqual('a');
      expect(sigs(history)).assertEqual('b,c,front');
      expect(history.length).assertEqual(3);
    });

    it('mergeWithoutNewFrontTrimsAsBefore', 0, () => {
      const history: ClipboardEntry[] = [e('a', 10), e('b', 11), e('c', 12)];
      const result: MergeResult = mergeBatch(history, [e('x', 1)], same, noneDeleted, 3);
      expect(result.front).assertEqual(null);
      expect(sigs(result.evicted)).assertEqual('x');
      expect(result.added.length).assertEqual(0);
    });

    it('theFrontIsTheNewestOfWhatIsAddedNotOfWhatIsKnown', 0, () => {
      const history: ClipboardEntry[] = [e('known', 50)];
      const result: MergeResult = mergeBatch(history, [e('known', 50), e('x', 3), e('y', 7)], same, noneDeleted, 25, true);
      expect(result.front?.Signature).assertEqual('y');
      expect(mergeBatch([], [], same, noneDeleted, 25, true).front).assertEqual(null);
    });

    it('anEntryAnEarlierMergeSparedStaysSparedByTheNextOne', 0, () => {
      // 'front' was spared by an earlier sync and is the oldest: a second answer
      // of that sync (no new front) must not trim it.
      const history: ClipboardEntry[] = [e('front', 1), e('b', 11), e('c', 12)];
      const result: MergeResult = mergeBatch(history, [e('more', 13)], same, noneDeleted, 3, false,
        (x: ClipboardEntry) => x.Signature === 'front');
      expect(sigs(result.evicted)).assertEqual('b');
      expect(sigs(history)).assertEqual('front,c,more');
    });

    it('frontOkIsAskedOnceWithTheNewestEntryReallyAddedAndDecidesWhatTheTrimSpares', 0, () => {
      const asked: string[] = [];
      const yes = (x: ClipboardEntry): boolean => { asked.push(x.Signature ?? ''); return true; };
      const no = (x: ClipboardEntry): boolean => { asked.push(x.Signature ?? ''); return false; };
      const base = (): ClipboardEntry[] => [e('a', 10), e('b', 11), e('c', 12)];
      // 'b' is known; of the new ones 'y' is the newest. Cap 3 pushes two out.
      const spared: ClipboardEntry[] = base();
      const withYes: MergeResult = mergeBatch(spared, [e('b', 11), e('x', 1), e('y', 2)], same, noneDeleted, 3, true, () => false, yes);
      expect(asked.join(',')).assertEqual('y');
      expect(withYes.front?.Signature).assertEqual('y');
      expect(sigs(withYes.evicted)).assertEqual('x,a');
      expect(sigs(spared)).assertEqual('b,c,y');
      const refused: ClipboardEntry[] = base();
      const withNo: MergeResult = mergeBatch(refused, [e('b', 11), e('x', 1), e('y', 2)], same, noneDeleted, 3, true, () => false, no);
      expect(asked.join(',')).assertEqual('y,y');
      expect(withNo.front).assertEqual(null);
      expect(sigs(withNo.evicted)).assertEqual('x,y');
      expect(sigs(refused)).assertEqual('a,b,c');
      // Not asked at all without newFront or without anything added.
      mergeBatch(base(), [e('x', 1)], same, noneDeleted, 25, false, () => false, no);
      mergeBatch(base(), [e('a', 10)], same, noneDeleted, 25, true, () => false, no);
      expect(asked.length).assertEqual(2);
    });

    it('newestOfTakesTheLatestAndTheFirstOfATie', 0, () => {
      expect(newestOf([])).assertEqual(null);
      expect(newestOf([e('a', 1), e('b', 9), e('c', 5)])?.Signature).assertEqual('b');
      expect(newestOf([e('a', 5), e('b', 5)])?.Signature).assertEqual('a');
    });

    it('applyBatchAnnouncesOnceForTheWholeBatch', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      const announced: string[] = [];
      const outcome = await applyBatch([e('a', 1), e('bad', 2), e('b', 3), e('gone', 4), e('c', 5)], accept,
        (x: ClipboardEntry) => Promise.resolve(x.Signature === 'gone'),
        (c: ClipboardEntry[]) => history.add(c),
        (added: ClipboardEntry[]) => { announced.push(sigs(added)); return Promise.resolve(); });
      expect(announced.length).assertEqual(1);
      expect(announced[0]).assertEqual('a,b,c');
      expect(history.adds).assertEqual(1); // one history update, not one per entry
      expect(outcome.rejected).assertEqual(1);
      expect(outcome.deleted).assertEqual(1);
      expect(outcome.duplicates).assertEqual(0);
      expect(sigs(outcome.added)).assertEqual('a,b,c');
      done();
    });

    it('applyBatchAnnouncesNothingWhenNothingIsNew', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      history.entries = [e('a', 1), e('b', 2)];
      let announced = 0;
      const outcome = await applyBatch([e('a', 1), e('b', 2)], accept, () => Promise.resolve(false),
        (c: ClipboardEntry[]) => history.add(c), () => { announced++; return Promise.resolve(); });
      expect(announced).assertEqual(0);
      expect(outcome.added.length).assertEqual(0);
      expect(outcome.duplicates).assertEqual(2);
      done();
    });

    it('theSameBatchDeliveredAgainAddsNothingAndAnnouncesNothing', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      const batch: ClipboardEntry[] = [e('a', 1), e('b', 2), e('c', 3)];
      let announced = 0;
      const first = await applyBatch(batch, accept, () => Promise.resolve(false), (c: ClipboardEntry[]) => history.add(c),
        () => { announced++; return Promise.resolve(); });
      const second = await applyBatch(batch, accept, () => Promise.resolve(false), (c: ClipboardEntry[]) => history.add(c),
        () => { announced++; return Promise.resolve(); });
      expect(first.added.length).assertEqual(3);
      expect(second.added.length).assertEqual(0);
      expect(announced).assertEqual(1);
      done();
    });

    it('twoBatchesAreTwoAnnouncements', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      const announced: string[] = [];
      const announce = (added: ClipboardEntry[]): Promise<void> => { announced.push(sigs(added)); return Promise.resolve(); };
      await applyBatch([e('a', 1), e('b', 2)], accept, () => Promise.resolve(false), (c: ClipboardEntry[]) => history.add(c), announce);
      await applyBatch([e('c', 3), e('d', 4)], accept, () => Promise.resolve(false), (c: ClipboardEntry[]) => history.add(c), announce);
      expect(announced.join('|')).assertEqual('a,b|c,d');
      done();
    });

    it('headPayloadHasTheNewestAndEveryKeyNewestFirst', 0, () => {
      expect(buildHeadPayload([], (x: ClipboardEntry) => x.Signature ?? '')).assertEqual(null);
      expect(buildHeadPayload([e('a', 1)], (x: ClipboardEntry) => x.Signature ?? '')).assertEqual(null);
      const payload: string | null = buildHeadPayload([e('a', 1), e('c', 3), e('b', 2)], (x: ClipboardEntry) => x.Signature ?? '');
      expect(payload !== null).assertTrue();
      const head: HistoryHead | null = parseHead(payload as string);
      expect(head !== null).assertTrue();
      expect((head as HistoryHead).Newest.Signature).assertEqual('c');
      expect((head as HistoryHead).Keys.join(',')).assertEqual('c,b,a');
    });

    it('parseHeadRefusesWhatIsNotAHead', 0, () => {
      expect(parseHead('not json')).assertEqual(null);
      expect(parseHead('{}')).assertEqual(null);
      expect(parseHead('{"Newest":null,"Keys":[]}')).assertEqual(null);
      expect(parseHead('{"Newest":{"Content":"x","Type":"text","DeviceId":"d","Timestamp":"t"},"Keys":[1]}')).assertEqual(null);
      expect(parseHead('{"Newest":{"Content":"x","Type":"text","DeviceId":"d","Timestamp":"t"},"Keys":["k"]}') !== null).assertTrue();
    });

    it('headWithNoNewKeysAddsNothingAndExpectsNothing', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      history.entries = [e('a', 1), e('b', 2)];
      let announced = 0;
      const head: HistoryHead = { Newest: e('b', 2), Keys: ['b', 'a'] };
      const outcome = await applyHead(head, accept,
        (keys: string[]) => Promise.resolve(new Set<string>(keys.filter((k: string) => history.entries.some((x: ClipboardEntry) => x.Signature === k)))),
        (c: ClipboardEntry[]) => history.add(c), () => { announced++; return Promise.resolve(); }, 25);
      expect(outcome !== null).assertTrue();
      expect(outcome?.newest).assertEqual(null); // the newest is known: nothing is announced
      expect(outcome?.expectedNew).assertEqual(0);
      expect(announced).assertEqual(0);
      done();
    });

    it('headWithOneNewKeyAddsTheNewestAndExpectsOne', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      history.entries = [e('a', 1)];
      const seen: string[] = [];
      const head: HistoryHead = { Newest: e('n', 9), Keys: ['n', 'a'] };
      const outcome = await applyHead(head, accept,
        (keys: string[]) => Promise.resolve(new Set<string>(keys.filter((k: string) => k === 'a'))),
        (c: ClipboardEntry[]) => history.add(c),
        (newest: ClipboardEntry, expected: number) => { seen.push(`${newest.Signature}:${expected}`); return Promise.resolve(); }, 25);
      expect(seen.join(',')).assertEqual('n:1');
      expect(outcome?.expectedNew).assertEqual(1);
      expect(sigs(history.entries)).assertEqual('a,n');
      done();
    });

    it('headWithManyNewKeysAnnouncesTheNewestOnceWithTheCount', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      history.entries = [e('known', 1)];
      const seen: string[] = [];
      const head: HistoryHead = { Newest: e('n', 9), Keys: ['n', 'x', 'y', 'z', 'known', 'x'] };
      const outcome = await applyHead(head, accept,
        (keys: string[]) => Promise.resolve(new Set<string>(keys.filter((k: string) => k === 'known'))),
        (c: ClipboardEntry[]) => history.add(c),
        (newest: ClipboardEntry, expected: number) => { seen.push(`${newest.Signature}:${expected}`); return Promise.resolve(); }, 25);
      // 4 new keys (a key listed twice counts once); the head's own update is ONE add, of the newest only.
      expect(seen.join(',')).assertEqual('n:4');
      expect(history.adds).assertEqual(1);
      expect(sigs(history.entries)).assertEqual('known,n');
      expect(outcome?.expectedNew).assertEqual(4);
      done();
    });

    it('headCountsOnlyWhatTheHistoryCanHold', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      const keys: string[] = ['n'];
      for (let i = 0; i < 40; i++) keys.push(`k${i}`);
      const outcome = await applyHead({ Newest: e('n', 9), Keys: keys }, accept,
        () => Promise.resolve(new Set<string>()), (c: ClipboardEntry[]) => history.add(c), () => Promise.resolve(), 25);
      expect(outcome?.expectedNew).assertEqual(25);
      done();
    });

    it('headWithAnUnverifiedNewestIsIgnoredEntirely', 0, async (done: Function) => {
      const history: FakeHistory = new FakeHistory();
      let announced = 0;
      let asked = 0;
      const outcome = await applyHead({ Newest: e('bad', 9), Keys: ['bad', 'a', 'b'] }, accept,
        () => { asked++; return Promise.resolve(new Set<string>()); },
        (c: ClipboardEntry[]) => history.add(c), () => { announced++; return Promise.resolve(); }, 25);
      expect(outcome).assertEqual(null);
      expect(announced).assertEqual(0);
      expect(history.adds).assertEqual(0);
      expect(history.entries.length).assertEqual(0);
      expect(asked).assertEqual(0);
      done();
    });

    it('headThenBatchAnnouncesTheNewestOnlyOnce', 0, async (done: Function) => {
      // The side effects of the newest item (clipboard, notification) belong
      // to the head: the batch behind it finds the newest known, so it is not
      // announced again.
      const history: FakeHistory = new FakeHistory();
      const all: ClipboardEntry[] = [e('n', 9), e('b', 5), e('a', 1)];
      const announcedByHead: string[] = [];
      const announcedByBatch: string[] = [];
      await applyHead({ Newest: all[0], Keys: ['n', 'b', 'a'] }, accept, () => Promise.resolve(new Set<string>()),
        (c: ClipboardEntry[]) => history.add(c),
        (newest: ClipboardEntry) => { announcedByHead.push(newest.Signature ?? ''); return Promise.resolve(); }, 25);
      const outcome = await applyBatch(all.slice().reverse(), accept, () => Promise.resolve(false), (c: ClipboardEntry[]) => history.add(c),
        (added: ClipboardEntry[]) => { announcedByBatch.push(sigs(added)); return Promise.resolve(); });
      expect(announcedByHead.join(',')).assertEqual('n');
      expect(announcedByBatch.join('|')).assertEqual('a,b'); // the others, not n again
      expect(sigs(outcome.added)).assertEqual('a,b');
      expect(outcome.duplicates).assertEqual(1);
      expect(history.entries.length).assertEqual(3);
      done();
    });
  });
}
