import { describe, it, expect } from '@ohos/hypium';
import {
  BatchGroupTracker, BatchMember, BatchPlan, StackMotion, StackRow, buildRows, dissolveGroup, dragProgress, hiddenCount, layerCount,
  placeBatch, revealAnimates, settleGroup, shouldExpand, staggerDelayMs
} from '../main/ets/stack/SyncedRows';

// A list item as grouping sees it. `minute` is its time (later is newer).
class Item implements BatchMember {
  id: string;
  groupId: string;
  stamp: string;
  expected: number;

  constructor(id: string, minute: number, groupId: string = '', expected: number = 0) {
    this.id = id;
    this.groupId = groupId;
    this.stamp = `2026-01-01T10:${minute < 10 ? '0' : ''}${minute}:00.0000000Z`;
    this.expected = expected;
  }
}

function retag(item: Item, groupId: string, expected: number): Item {
  const copy: Item = new Item(item.id, 0, groupId, expected);
  copy.stamp = item.stamp;
  return copy;
}

function ids(items: Item[]): string {
  return items.map((i: Item) => i.id).join(',');
}

// Rows as text: a plain card is its id, a stack is "front[+hidden]".
function rows(items: Item[]): string {
  return buildRows<Item>(items).map((r: StackRow<Item>) => (r.groupId === '' ? r.front.id : `${r.front.id}[+${hiddenCount(r)}]`)).join(' ');
}

export default function syncedRowsTest() {
  describe('SyncedRows', () => {
    it('aBatchOfTwoOrMoreMakesAGroupFewerDoNot', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      expect(groups.next(0)).assertEqual('');
      expect(groups.next(1)).assertEqual('');
      expect(groups.next(2) !== '').assertTrue();
      expect(groups.next(14) !== '').assertTrue();
    });

    it('twoBatchesMakeTwoGroups', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      expect(groups.next(3) !== groups.next(3)).assertTrue();
    });

    it('theNewestOfABatchGoesToTheTopAndTheRestKeepTimelineOrder', 0, () => {
      const list: Item[] = [new Item('p', 50), new Item('q', 40), new Item('r', 10)];
      const fresh: Item[] = [new Item('a', 20, 'g'), new Item('b', 45, 'g'), new Item('c', 30, 'g')];
      const placed: Item[] = placeBatch<Item>(list, fresh, 50);
      // b (the front of the stack) is on top; c and a sit where the time puts
      // them, and p, q, r keep their order.
      expect(ids(placed)).assertEqual('b,p,q,c,a,r');
      expect(rows(placed)).assertEqual('b[+2] p q r');
    });

    it('anItemOlderThanWhatIsListedIsNotBuried', 0, () => {
      const list: Item[] = [new Item('local', 90), new Item('older', 50)];
      expect(ids(placeBatch<Item>(list, [new Item('x', 5)], 50))).assertEqual('x,local,older');
      expect(ids(placeBatch<Item>(list, [new Item('x', 5, 'g'), new Item('y', 6, 'g')], 50))).assertEqual('y,local,older,x');
    });

    it('theBatchAfterAHeadJoinsItsGroupByTimeBelowTheFront', 0, () => {
      // A newer live item came in above the head's stack meanwhile.
      const list: Item[] = [new Item('live', 99), new Item('n', 9, 'g', 4), new Item('z', 1)];
      const placed: Item[] = placeBatch<Item>(list, [new Item('a', 3, 'g'), new Item('c', 7, 'g'), new Item('b', 5, 'g')], 50);
      expect(ids(placed)).assertEqual('live,n,c,b,a,z');
      expect(rows(settleGroup<Item>(placed, 'g', retag))).assertEqual('live n[+3] z');
    });

    it('theFrontCardIsTheNewestMemberWhateverTheBatchOrder', 0, () => {
      const placedOldestFirst: Item[] = placeBatch<Item>([], [new Item('a', 1, 'g'), new Item('b', 2, 'g'), new Item('c', 3, 'g')], 50);
      const placedNewestFirst: Item[] = placeBatch<Item>([], [new Item('c', 3, 'g'), new Item('b', 2, 'g'), new Item('a', 1, 'g')], 50);
      expect(rows(placedOldestFirst)).assertEqual('c[+2]');
      expect(rows(placedNewestFirst)).assertEqual('c[+2]');
      expect(buildRows<Item>(placedOldestFirst)[0].memberIds.join(',')).assertEqual('c,b,a');
    });

    it('anItemAlreadyListedIsReplacedNotRepeated', 0, () => {
      const placed: Item[] = placeBatch<Item>([new Item('a', 1), new Item('z', 9)], [new Item('a', 1, 'g'), new Item('b', 2, 'g')], 50);
      expect(ids(placed)).assertEqual('b,z,a');
    });

    it('theListKeepsAtMostTheCap', 0, () => {
      const list: Item[] = [new Item('p', 50), new Item('q', 40), new Item('r', 10)];
      expect(ids(placeBatch<Item>(list, [new Item('n', 60, 'g'), new Item('m', 55, 'g')], 4))).assertEqual('n,m,p,q');
    });

    it('oneItemOfAGroupIsJustACard', 0, () => {
      expect(rows([new Item('a', 2, 'g'), new Item('b', 1)])).assertEqual('a b');
    });

    it('deletingTheFrontMakesTheNextNewestTheFront', 0, () => {
      const items: Item[] = [new Item('c', 3, 'g'), new Item('b', 2, 'g'), new Item('a', 1, 'g'), new Item('z', 0)];
      expect(rows(items)).assertEqual('c[+2] z');
      const withoutFront: Item[] = items.filter((i: Item) => i.id !== 'c');
      expect(rows(withoutFront)).assertEqual('b[+1] z');
      expect(buildRows<Item>(withoutFront)[0].front.id).assertEqual('b');
    });

    it('oneMemberLeftBecomesANormalCardAndNoneLeftIsGone', 0, () => {
      const items: Item[] = [new Item('c', 3, 'g'), new Item('b', 2, 'g'), new Item('a', 1, 'g')];
      expect(rows(items.filter((i: Item) => i.id !== 'c' && i.id !== 'b'))).assertEqual('a');
      expect(rows(items.filter((i: Item) => i.groupId !== 'g'))).assertEqual('');
    });

    it('trimmingTheListShrinksTheGroup', 0, () => {
      const items: Item[] = [new Item('d', 4, 'g'), new Item('c', 3, 'g'), new Item('b', 2, 'g'), new Item('a', 1, 'g')];
      expect(rows(items)).assertEqual('d[+3]');
      expect(rows(items.slice(0, 3))).assertEqual('d[+2]');
      expect(rows(items.slice(0, 2))).assertEqual('d[+1]');
      expect(rows(items.slice(0, 1))).assertEqual('d');
    });

    it('twoGroupsAreTwoStacksEachWhereItsNewestIs', 0, () => {
      const items: Item[] = [new Item('b2', 9, 'g2'), new Item('a2', 8, 'g1'), new Item('b1', 7, 'g2'), new Item('a1', 6, 'g1')];
      expect(rows(items)).assertEqual('b2[+1] a2[+1]');
    });

    it('layersAreTwoAtMostAndOneForAGroupOfTwo', 0, () => {
      const two: StackRow<Item> = buildRows<Item>([new Item('b', 2, 'g'), new Item('a', 1, 'g')])[0];
      const five: StackRow<Item> = buildRows<Item>([new Item('e', 5, 'g'), new Item('d', 4, 'g'), new Item('c', 3, 'g'),
        new Item('b', 2, 'g'), new Item('a', 1, 'g')])[0];
      expect(layerCount(two)).assertEqual(1);
      expect(layerCount(five)).assertEqual(2);
      expect(hiddenCount(five)).assertEqual(4);
    });

    it('openingAGroupMakesItsItemsOrdinaryCardsForGood', 0, () => {
      const items: Item[] = [new Item('b', 2, 'g'), new Item('a', 1, 'g'), new Item('z', 0)];
      const opened: Item[] = dissolveGroup<Item>(items, 'g', retag);
      expect(rows(opened)).assertEqual('b a z');
      expect(ids(opened)).assertEqual('b,a,z'); // order unchanged
    });

    it('clearingTheListLeavesNoRows', 0, () => {
      expect(buildRows<Item>([]).length).assertEqual(0);
    });

    it('aHeadMakesAProvisionalGroupWithTheBadgeFromExpectedSize', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const gid: string = groups.headArrived('peer', 6, 'n');
      expect(gid !== '').assertTrue();
      // Only the newest item is there, but the stack already counts 5 behind it.
      const items: Item[] = [new Item('n', 9, gid, 6), new Item('old', 1)];
      expect(rows(items)).assertEqual('n[+5] old');
      expect(layerCount(buildRows<Item>(items)[0])).assertEqual(2);
    });

    it('aHeadExpectingFewerThanTwoMakesNoGroup', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      expect(groups.headArrived('peer', 0, 'n')).assertEqual('');
      expect(groups.headArrived('peer', 1, 'n')).assertEqual('');
      expect(groups.headArrived('peer', 2, 'n') !== '').assertTrue();
    });

    it('theBatchAfterAHeadJoinsTheSameGroup', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const gid: string = groups.headArrived('peer', 4, 'n');
      const plan: BatchPlan = groups.batchArrived('peer', 3); // the 3 others
      expect(plan.groupId).assertEqual(gid);
      expect(plan.settleId).assertEqual(gid);
      let items: Item[] = [new Item('n', 9, gid, 4)];
      items = placeBatch<Item>(items, [new Item('c', 7, plan.groupId), new Item('b', 5, plan.groupId), new Item('a', 3, plan.groupId)], 50);
      items = settleGroup<Item>(items, plan.settleId, retag);
      // The same group, the same front card, the same count: nothing for the
      // badge to flash through.
      expect(rows(items)).assertEqual('n[+3]');
      expect(items[0].expected).assertEqual(0);
    });

    it('theBatchAfterAHeadWithOneMoreItemKeepsTwoInTheGroup', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const gid: string = groups.headArrived('peer', 5, 'n');
      const plan: BatchPlan = groups.batchArrived('peer', 1); // the rest were trimmed or known
      expect(plan.groupId).assertEqual(gid);
      const items: Item[] = settleGroup<Item>(placeBatch<Item>([new Item('n', 9, gid, 5)], [new Item('a', 3, gid)], 50), gid, retag);
      expect(rows(items)).assertEqual('n[+1]');
    });

    it('aBatchThatAddsNothingDissolvesTheProvisionalGroup', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const gid: string = groups.headArrived('peer', 3, 'n');
      const plan: BatchPlan = groups.batchArrived('peer', 0);
      expect(plan.groupId).assertEqual('');
      expect(plan.settleId).assertEqual(gid);
      expect(rows(settleGroup<Item>([new Item('n', 9, gid, 3), new Item('z', 1)], gid, retag))).assertEqual('n z');
    });

    it('aConnectionClosedBeforeTheBatchSettlesTheGroup', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const gid: string = groups.headArrived('peer', 3, 'n');
      expect(groups.headSettled('peer')).assertEqual(gid);
      expect(groups.headSettled('peer')).assertEqual(''); // only once
      // With only the newest item there, it is a normal card and no badge.
      expect(rows(settleGroup<Item>([new Item('n', 9, gid, 3)], gid, retag))).assertEqual('n');
    });

    it('aProvisionalGroupOpenedBeforeTheBatchMakesTheRestOrdinaryCards', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const gid: string = groups.headArrived('peer', 4, 'n');
      groups.opened(gid);
      const plan: BatchPlan = groups.batchArrived('peer', 3);
      expect(plan.groupId).assertEqual('');
      expect(plan.settleId).assertEqual('');
      expect(groups.headSettled('peer')).assertEqual('');
    });

    it('noHeadMeansTheBatchMakesItsOwnGroupAsBefore', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const plan: BatchPlan = groups.batchArrived('peer', 3);
      expect(plan.groupId !== '').assertTrue();
      expect(plan.settleId).assertEqual('');
      expect(groups.batchArrived('peer', 1).groupId).assertEqual('');
    });

    it('headsOfTwoPeersDoNotMixTheirGroups', 0, () => {
      const groups: BatchGroupTracker = new BatchGroupTracker();
      const g1: string = groups.headArrived('one', 3, 'n1');
      const g2: string = groups.headArrived('two', 3, 'n2');
      expect(g1 !== g2).assertTrue();
      expect(groups.batchArrived('two', 2).groupId).assertEqual(g2);
      expect(groups.batchArrived('one', 2).groupId).assertEqual(g1);
    });

    it('dragProgressFollowsTheFingerOver120vp', 0, () => {
      expect(dragProgress(-20)).assertEqual(0);
      expect(dragProgress(0)).assertEqual(0);
      expect(dragProgress(60)).assertEqual(0.5);
      expect(dragProgress(120)).assertEqual(1);
      expect(dragProgress(500)).assertEqual(1);
    });

    it('releaseOpensPastAThirdOrOnAFastSwipe', 0, () => {
      expect(shouldExpand(0.2, 0)).assertFalse();
      expect(shouldExpand(0.34, 0)).assertTrue();
      expect(shouldExpand(0.1, 700)).assertTrue(); // a fast swipe down opens it whatever the distance
      expect(shouldExpand(0.1, 699)).assertFalse();
      expect(shouldExpand(0.9, -700)).assertFalse(); // a fast swipe back up closes it
    });

    it('theRevealStaggersBy30msAndCapsAt400msAndOnlyTenAnimate', 0, () => {
      expect(StackMotion.STAGGER_STEP_MS).assertEqual(30);
      expect(StackMotion.MAX_STAGGER_MS).assertEqual(400);
      expect(staggerDelayMs(1)).assertEqual(30);
      expect(staggerDelayMs(10)).assertEqual(300);
      expect(staggerDelayMs(40)).assertEqual(400);
      expect(revealAnimates(0)).assertFalse();
      expect(revealAnimates(1)).assertTrue();
      expect(revealAnimates(10)).assertTrue();
      expect(revealAnimates(11)).assertFalse();
      expect(StackMotion.HANDLE_HEIGHT_VP >= 44).assertTrue();
    });
  });
}
