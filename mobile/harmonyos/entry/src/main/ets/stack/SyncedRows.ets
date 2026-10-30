// Which cards the Synced tab shows when the entries that arrived together in
// one history_batch are folded into a stack, and the numbers behind the
// stack's gestures and animations. Plain code on purpose, with no ArkUI in it,
// so entry/src/test can run it. Mirrors windows/ClipLink/BatchGrouping.cs,
// Android's SyncedRows.kt / BatchGroups.kt and iOS's BatchGroups.swift.
//
// Nothing here is saved or sent: a group lives in the list the page holds
// (each member carries its group's id), so after a restart the history shows
// as ordinary cards, and no peer ever hears of a group.
//
// What arrives in one sync is a block: the stack's front card, then (when the
// stack is opened) its other members, directly below it. Blocks sit at the top
// of the list, the one that arrived last first; everything else is below them
// in timeline order. A block is only the order of the list the page holds, so a
// restart, which sorts by time, leaves none.

import { GROUP_MIN_ITEMS } from '../storage/HistoryBatch';

// What a list item has to say for grouping. `groupId` is '' for an item that
// is in no group; `stamp` is its timestamp in canonical form (see
// Signing.canonicalTimestamp), which sorts as text. `blockId` is the id of the
// block the item arrived in, or '' for an item that is not part of one: it is
// the group's id, and stays when the group is opened, so the members still
// belong together.
export interface BatchMember {
  id: string;
  groupId: string;
  blockId: string;
  stamp: string;
  // While a history_head has put the front of a group on screen and its batch
  // has not come yet: how many items the group will have. 0 otherwise. The
  // badge counts from it until the batch is in.
  expected: number;
}

// A group made on a peer's history_head, before its history_batch has come:
// its front card is the head's newest item.
interface ProvisionalGroup {
  groupId: string;
  newestId: string;
  // The user opened it before the batch came: the rest of the items then
  // arrive as ordinary cards.
  opened: boolean;
}

// What to do with a history_batch that has just been applied.
export interface BatchPlan {
  // The group the batch's new items join: '' for none (they are just cards).
  groupId: string;
  // The block they belong to: the group's id, also when the user has opened it
  // already (then groupId is ''); '' for none.
  blockId: string;
  // The group made on the head that came before this batch, to settle now
  // (its expected size is over; with fewer than GROUP_MIN_ITEMS members it
  // dissolves): '' if there was none.
  settleId: string;
}

// The groups of this session: makes their ids, and remembers the provisional
// ones a history_head made until the batch behind it is in.
export class BatchGroupTracker {
  private serial: number = 0;
  private provisional: Map<string, ProvisionalGroup> = new Map<string, ProvisionalGroup>();

  private nextId(): string {
    this.serial++;
    return `batch-${this.serial}`;
  }

  // The id for a batch that added `newCount` new entries, or '' when that is
  // too few to make a group (then they are just cards). Entries the batch did
  // not add (known, deleted here, cut by the cap) are not in `newCount`, so
  // they never join a group, and a batch that is delivered again adds nothing
  // and makes none.
  next(newCount: number): string {
    if (newCount < GROUP_MIN_ITEMS) return '';
    return this.nextId();
  }

  // The head of a batch from `from` put its newest item `newestId` on screen,
  // and `expectedNew` items (that one included) are on their way. Returns the
  // id of the provisional group that makes, or '' when fewer than
  // GROUP_MIN_ITEMS are expected (the newest item is then just a card).
  headArrived(from: string, expectedNew: number, newestId: string): string {
    this.provisional.delete(from);
    if (expectedNew < GROUP_MIN_ITEMS) return '';
    const groupId: string = this.nextId();
    this.provisional.set(from, { groupId: groupId, newestId: newestId, opened: false });
    return groupId;
  }

  // The batch from `from` has been applied and added `addedCount` new items.
  batchArrived(from: string, addedCount: number): BatchPlan {
    return this.answerArrived(from, addedCount, true);
  }

  // What a v2 sync's first answer brought: the item that goes on the clipboard
  // (the front card) and maybe more. The sync asked for `expectedTotal` items
  // in all (the stack's badge counts them from the start), `addedCount` of
  // them are here, and `last` says no request of this connection is still
  // waiting. Returns the plan for the new items, as batchArrived does; with
  // `last`, the group is settled at once (settleId).
  frontArrived(from: string, expectedTotal: number, frontId: string, addedCount: number, last: boolean): BatchPlan {
    this.provisional.delete(from);
    const groupId: string = expectedTotal >= GROUP_MIN_ITEMS ? this.nextId() : this.next(addedCount);
    if (groupId === '') return { groupId: '', blockId: '', settleId: '' };
    if (!last) this.provisional.set(from, { groupId: groupId, newestId: frontId, opened: false });
    return { groupId: groupId, blockId: groupId, settleId: last ? groupId : '' };
  }

  // A later answer of a sync, or a batch after a head, from `from`: `addedCount`
  // new items. They join the block the front card started; with no such block
  // they make a block of their own, if they are enough for one. `last`: no
  // request of this connection is still waiting, so the group is settled.
  answerArrived(from: string, addedCount: number, last: boolean): BatchPlan {
    const waiting: ProvisionalGroup | undefined = this.provisional.get(from);
    if (waiting === undefined) {
      const groupId: string = this.next(addedCount);
      return { groupId: groupId, blockId: groupId, settleId: '' };
    }
    if (last) this.provisional.delete(from);
    if (waiting.opened) return { groupId: '', blockId: waiting.groupId, settleId: '' };
    // The front card is one of the group, so the answer's own count is one
    // short of the group's.
    const tagged: boolean = !last || addedCount + 1 >= GROUP_MIN_ITEMS;
    return { groupId: tagged ? waiting.groupId : '', blockId: waiting.groupId, settleId: last ? waiting.groupId : '' };
  }

  // The batch behind a head is over without adding anything (all of it was
  // known), or its connection closed. Returns the group to settle, or ''.
  headSettled(from: string): string {
    const waiting: ProvisionalGroup | undefined = this.provisional.get(from);
    this.provisional.delete(from);
    return waiting === undefined || waiting.opened ? '' : waiting.groupId;
  }

  // The user opened the group `groupId`. A provisional one stays on record,
  // so that the batch still to come does not make a new group of its items.
  opened(groupId: string): void {
    this.provisional.forEach((waiting: ProvisionalGroup) => {
      if (waiting.groupId === groupId) waiting.opened = true;
    });
  }
}

// `list` with `fresh` (a batch's new items, or a head's newest item) put in.
// This is the one place that decides where received items go:
//  - the items of a new block go to the TOP of the list, whatever their
//    timestamps are: the newest of them first (the front card of a stack, or a
//    lone new card), then the others, newest first. What arrives from another
//    device is shown first, an item older than something copied here is not
//    buried in the middle of the list, and a stack that is opened later has its
//    items right below its front card, above every item not in a block;
//  - items that join a block already in the list (the rest of a sync, or the
//    batch after a head) go right below its front card, newest first among the
//    members it has;
//  - no item already in the list changes its place.
// An item already in the list with the same id is replaced. At most `maxItems`
// stay.
export function placeBatch<T extends BatchMember>(list: T[], fresh: T[], maxItems: number): T[] {
  const sorted: T[] = fresh.slice().sort((a: T, b: T) => (a.stamp < b.stamp ? 1 : (a.stamp > b.stamp ? -1 : 0)));
  const ids: Set<string> = new Set<string>();
  for (const item of sorted) ids.add(item.id);
  const placed: T[] = list.filter((item: T) => !ids.has(item.id));
  const blockId: string = sorted.length > 0 ? sorted[0].blockId : '';
  const front: number = blockId === '' ? -1 : placed.findIndex((item: T) => item.blockId === blockId);
  if (front === -1) {
    return [...sorted, ...placed].slice(0, maxItems);
  }
  for (const item of sorted) {
    let at: number = front + 1;
    while (at < placed.length && placed[at].blockId === blockId && placed[at].stamp >= item.stamp) at++;
    placed.splice(at, 0, item);
  }
  return placed.slice(0, maxItems);
}

// `list` with `fresh` (items stored quietly: the late answer to a request given
// up on) put in by time. They make no block and go nowhere near the top: each
// goes below every item that is part of a block and below every newer card, so
// the blocks above keep their order. An item already in the list with the same
// id is replaced. At most `maxItems` stay.
export function placeQuiet<T extends BatchMember>(list: T[], fresh: T[], maxItems: number): T[] {
  const sorted: T[] = fresh.slice().sort((a: T, b: T) => (a.stamp < b.stamp ? 1 : (a.stamp > b.stamp ? -1 : 0)));
  const ids: Set<string> = new Set<string>();
  for (const item of sorted) ids.add(item.id);
  const placed: T[] = list.filter((item: T) => !ids.has(item.id));
  let floor: number = 0;
  for (let i = 0; i < placed.length; i++) {
    if (placed[i].blockId !== '') floor = i + 1;
  }
  for (const item of sorted) {
    let at: number = floor;
    while (at < placed.length && placed[at].stamp >= item.stamp) at++;
    placed.splice(at, 0, item);
  }
  return placed.slice(0, maxItems);
}

// One card position of the list: an ordinary card (`memberIds` empty), or the
// front card of a stack. `memberIds`: every member that is still there,
// newest (the front card) first.
export interface StackRow<T> {
  front: T;
  groupId: string;
  memberIds: string[];
  // The size its group will have, from a head still waiting for its batch; 0
  // when it is not waiting.
  expected: number;
}

// Items hidden behind a stack's front card: those here, or - before a batch
// has come that a head announced - as many as it said.
export function hiddenCount<T>(row: StackRow<T>): number {
  if (row.memberIds.length === 0) return 0;
  return Math.max(row.memberIds.length, row.expected) - 1;
}

// Layers drawn peeking out below a stack's front card: two, or one for a
// group of two.
export function layerCount<T>(row: StackRow<T>): number {
  return Math.min(StackMotion.MAX_LAYERS, hiddenCount(row));
}

// `items` (newest first, all of them) as the rows of the list. A group is one
// row placed where its newest member is; its other members have no row. Every
// other item keeps its place. A group with fewer than GROUP_MIN_ITEMS members
// left in the list (the rest deleted, cleared or cut by the cap) is not a
// stack: its member is an ordinary card - unless a head has said more are on
// their way (`expected`). When the front item goes, the next
// newest member becomes the front.
export function buildRows<T extends BatchMember>(items: T[]): StackRow<T>[] {
  const members: Map<string, string[]> = new Map<string, string[]>();
  const expected: Map<string, number> = new Map<string, number>();
  for (const item of items) {
    if (item.groupId === '') continue;
    const list: string[] | undefined = members.get(item.groupId);
    if (list === undefined) {
      members.set(item.groupId, [item.id]);
    } else {
      list.push(item.id);
    }
    if (item.expected > (expected.get(item.groupId) ?? 0)) expected.set(item.groupId, item.expected);
  }
  const rows: StackRow<T>[] = [];
  const placed: Set<string> = new Set<string>();
  for (const item of items) {
    const together: string[] | undefined = item.groupId === '' ? undefined : members.get(item.groupId);
    const waitingFor: number = item.groupId === '' ? 0 : (expected.get(item.groupId) ?? 0);
    if (together === undefined || Math.max(together.length, waitingFor) < GROUP_MIN_ITEMS) {
      rows.push({ front: item, groupId: '', memberIds: [], expected: 0 });
    } else if (!placed.has(item.groupId)) {
      placed.add(item.groupId);
      rows.push({ front: item, groupId: item.groupId, memberIds: together, expected: waitingFor });
    }
  }
  return rows;
}

// `items` with group `groupId` ended: its members are ordinary cards from now
// on, and it never stacks again. `retag` makes a copy of an item with the
// given group id and expected size.
export function dissolveGroup<T extends BatchMember>(items: T[], groupId: string, retag: (item: T, groupId: string, expected: number) => T): T[] {
  return items.map((item: T) => (item.groupId === groupId ? retag(item, '', 0) : item));
}

// `items` with the group `groupId`, which waited for a batch, settled: no
// member expects more, and a group with fewer than GROUP_MIN_ITEMS members is
// dissolved into cards.
export function settleGroup<T extends BatchMember>(items: T[], groupId: string, retag: (item: T, groupId: string, expected: number) => T): T[] {
  const size: number = items.filter((item: T) => item.groupId === groupId).length;
  const kept: string = size >= GROUP_MIN_ITEMS ? groupId : '';
  return items.map((item: T) => (item.groupId === groupId ? retag(item, kept, 0) : item));
}

// The numbers behind the stack's gestures and animations, apart from the UI
// so they can be tested. The same on every platform.
export class StackMotion {
  // Cards drawn behind the front one.
  static readonly MAX_LAYERS: number = 2;
  // A drag this long (vp) opens the stack all the way.
  static readonly FULL_DRAG_VP: number = 120;
  // Let go past this share of the distance and it opens.
  static readonly COMPLETE_FRACTION: number = 1 / 3;
  // A swipe down at least this fast (vp per second) opens it whatever the distance.
  static readonly FLING_VP_PER_SECOND: number = 700;
  // Each card that fans out starts this much (ms) after the one before.
  static readonly STAGGER_STEP_MS: number = 30;
  // However many items there are, the last one starts by then.
  static readonly MAX_STAGGER_MS: number = 400;
  // A very large stack animates only its first cards; the rest appear in place.
  static readonly MAX_ANIMATED_CARDS: number = 10;
  // The touch target of the handle: at least 44 vp tall.
  static readonly HANDLE_HEIGHT_VP: number = 44;
}

// 0 (closed) to 1 (open) for a finger that moved `translationVp` down.
export function dragProgress(translationVp: number): number {
  return Math.min(Math.max(translationVp / StackMotion.FULL_DRAG_VP, 0), 1);
}

// On release: open when the drag got about a third of the way, or the swipe
// down was fast; a fast swipe back up closes it.
export function shouldExpand(progress: number, velocityVpPerSecond: number): boolean {
  if (velocityVpPerSecond >= StackMotion.FLING_VP_PER_SECOND) return true;
  if (velocityVpPerSecond <= -StackMotion.FLING_VP_PER_SECOND) return false;
  return progress >= StackMotion.COMPLETE_FRACTION;
}

// Whether the hidden card `index` (1 is the one right behind the front card)
// animates when the stack opens.
export function revealAnimates(index: number): boolean {
  return index >= 1 && index <= StackMotion.MAX_ANIMATED_CARDS;
}

// How long (ms) the hidden card `index` waits before it moves.
export function staggerDelayMs(index: number): number {
  return Math.min(Math.max(index, 0) * StackMotion.STAGGER_STEP_MS, StackMotion.MAX_STAGGER_MS);
}
