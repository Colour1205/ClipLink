import { describe, it, expect } from '@ohos/hypium';
import {
  LastWrite, classifyOwnWrite, classifyRead, contentKey, emptyLastWrite, filePrint, historyKeys, newestKeys, norm, parseLastWrite,
  printsMatch, rawTextHash, sha256Hex, textPrint, utf8
} from '../main/ets/storage/ContentPrint';
import { BatchMember, buildRows, foldTwins, twinIds, StackRow } from '../main/ets/stack/SyncedRows';
import { isFresh, newestStamp } from '../main/ets/storage/HistoryBatch';
import { PENDING_APPLY_LIMIT_MS, pendingFileMayApply } from '../main/ets/networking/PendingFiles';
import { ClipboardEntry } from '../main/ets/crypto/Signing';

const ABC: string = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const LINES: string = '683376e290829b482c2655745caffa7a1dccfa10afaa62dac2b42dd6c68d0f83';
const FILE_HASH: string = 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789';

// An entry named by its signature (prints are cached by it); `minute` is its time.
function entry(signature: string, type: string, content: string, minute: number = 0): ClipboardEntry {
  const mm: string = minute < 10 ? `0${minute}` : `${minute}`;
  return { Content: content, Type: type, DeviceId: 'peer', Timestamp: `2026-01-01T10:${mm}:00.0000000Z`, Signature: signature };
}

function fileContent(hash: string): string {
  return JSON.stringify({ FileName: 'report.pdf', FileHash: hash, FileSize: 10 });
}

function lastWrite(prints: string[], count: number = -1): LastWrite {
  return { prints: prints, count: count };
}

interface Card extends BatchMember {
  key: string | null;
}

function card(id: string, key: string | null, groupId: string = ''): Card {
  return { id: id, groupId: groupId, blockId: groupId, stamp: id, expected: 0, key: key };
}

function keyOf(item: Card): string | null {
  return item.key;
}

function ids(items: Card[]): string {
  return items.map((item: Card) => item.id).join(',');
}

export default function contentPrintTest() {
  describe('ContentPrint', () => {
    // ---- norm and the text print (the spec's vectors) ----

    it('normChangesLineEndingsAndOneTrailingNewlineOnly', 0, () => {
      expect(norm('abc')).assertEqual('abc');
      expect(norm('abc\n')).assertEqual('abc');
      expect(norm('abc\r\n')).assertEqual('abc');
      expect(norm('abc\n\n')).assertEqual('abc\n');
      expect(norm('line1\r\nline2')).assertEqual('line1\nline2');
      expect(norm('line1\rline2\r')).assertEqual('line1\nline2');
      expect(norm('  abc  ')).assertEqual('  abc  ');
      expect(norm('a\r\n\r\n')).assertEqual('a\n');
      expect(norm('\n')).assertEqual('');
    });

    it('textPrintsMatchTheSharedVectors', 0, () => {
      expect(textPrint('abc')).assertEqual(`t:${ABC}`);
      expect(textPrint('abc\n')).assertEqual(`t:${ABC}`);
      expect(textPrint('abc\r\n')).assertEqual(`t:${ABC}`);
      expect(textPrint('abc\n\n')).assertEqual('t:edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb');
      expect(textPrint('line1\r\nline2')).assertEqual(`t:${LINES}`);
      expect(textPrint('line1\rline2\r')).assertEqual(`t:${LINES}`);
      expect(textPrint('  abc  ')).assertEqual('t:e1df0bfff7ba8ed81085b91ad7dde5d31777855835b80db6d99b56ef9f3aaa6b');
      expect(textPrint('日本語\r\n')).assertEqual('t:77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5');
      expect(textPrint('a\r\n\r\n')).assertEqual('t:87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0fde60c4cf25c7');
      expect(textPrint('\n')).assertEqual('t:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    it('theRawHashIsOfTheExactText', 0, () => {
      expect(rawTextHash('abc')).assertEqual(ABC);
      expect(rawTextHash('abc\n') === ABC).assertFalse();
    });

    it('utf8AndSha256AreRightForLongerInput', 0, () => {
      // 300 times the bytes 0..255: many blocks, and a length that is not a
      // multiple of 64 once padded.
      const bytes: Uint8Array = new Uint8Array(256 * 300);
      for (let i = 0; i < bytes.length; i++) bytes[i] = i % 256;
      expect(sha256Hex(bytes)).assertEqual('f8b0585eb91f58c007a5634362c9f90d8543822c113f702523bc7b73408a9392');
      expect(Array.from(utf8('é😀')).join(',')).assertEqual('195,169,240,159,152,128');
    });

    // ---- contentKey ----

    it('contentKeyForTextImageAndFile', 0, () => {
      expect(contentKey(entry('t1', 'text', 'abc\r\n'))).assertEqual(`t:${ABC}`);
      // An image entry is Base64: the print is of the decoded bytes (1, 2, 3).
      expect(contentKey(entry('i1', 'image', 'AQID'))).assertEqual('i:039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81');
      // A file's hash in either case is the same key.
      expect(contentKey(entry('f1', 'file', fileContent(FILE_HASH)))).assertEqual(`f:${FILE_HASH.toLowerCase()}`);
      expect(contentKey(entry('f2', 'file', fileContent(FILE_HASH.toLowerCase())))).assertEqual(`f:${FILE_HASH.toLowerCase()}`);
    });

    it('aMalformedEntryHasNoKey', 0, () => {
      expect(contentKey(entry('bad-image', 'image', 'not base64!'))).assertEqual(null);
      expect(contentKey(entry('bad-file', 'file', '{nope'))).assertEqual(null);
      expect(contentKey(entry('short-hash', 'file', fileContent('abc')))).assertEqual(null);
      expect(contentKey(entry('unknown', 'html', '<b>x</b>'))).assertEqual(null);
      expect(filePrint('../../etc')).assertEqual(null);
    });

    it('newestKeysTakesTheNNewestAndEveryTieAtTheBoundary', 0, () => {
      const history: ClipboardEntry[] = [
        entry('n1', 'text', 'old', 1), entry('n2', 'text', 'tie a', 5), entry('n3', 'text', 'tie b', 5), entry('n4', 'text', 'mid', 3)
      ];
      const one: Set<string> = newestKeys(history, 1);
      expect(one.size).assertEqual(2);
      expect(one.has(textPrint('tie a')) && one.has(textPrint('tie b'))).assertTrue();
      expect(newestKeys(history, 3).has(textPrint('mid'))).assertTrue();
      expect(newestKeys(history, 3).has(textPrint('old'))).assertFalse();
      expect(newestKeys([], 1).size).assertEqual(0);
    });

    it('aSavedLastWriteRoundTripsAndAnythingElseIsEmpty', 0, () => {
      const saved: LastWrite = parseLastWrite(JSON.stringify(lastWrite([`t:${ABC}`], 7)));
      expect(saved.prints.join(',')).assertEqual(`t:${ABC}`);
      expect(saved.count).assertEqual(7);
      expect(parseLastWrite('').prints.length).assertEqual(0);
      expect(parseLastWrite('').count).assertEqual(-1);
      expect(parseLastWrite('[1,2]').prints.length).assertEqual(0);
    });

    // ---- classify ----

    it('theOwnWriteIsNeverNewForAnAutoCapture', 0, () => {
      const written: LastWrite = lastWrite([`t:${ABC}`], 4);
      const held: Set<string> = new Set<string>([`t:${ABC}`]);
      expect(classifyOwnWrite('auto', written, held)).assertEqual('already');
      expect(classifyOwnWrite('auto', written, new Set<string>())).assertEqual('already');
    });

    it('aPasteTapOnTheOwnWriteIsNewOnlyWhenItWasDeleted', 0, () => {
      const written: LastWrite = lastWrite([`t:${ABC}`], 4);
      expect(classifyOwnWrite('manual', written, new Set<string>([`t:${ABC}`]))).assertEqual('already');
      // Deleted from the history: the tap is a deliberate re-send, so it is read.
      expect(classifyOwnWrite('manual', written, new Set<string>())).assertEqual('read');
    });

    it('whatClipLinkLastWroteIsNotSentBack', 0, () => {
      const written: LastWrite = lastWrite([`t:${ABC}`]);
      const held: Set<string> = new Set<string>([`t:${ABC}`]);
      expect(classifyRead('auto', [`t:${ABC}`], ABC, written, held, new Set<string>())).assertEqual('already');
      expect(classifyRead('manual', [`t:${ABC}`], ABC, written, held, new Set<string>())).assertEqual('already');
      // Deleted meanwhile: an auto capture still leaves it, a tap sends it.
      expect(classifyRead('auto', [`t:${ABC}`], ABC, written, new Set<string>(), new Set<string>())).assertEqual('already');
      expect(classifyRead('manual', [`t:${ABC}`], ABC, written, new Set<string>(), new Set<string>())).assertEqual('new');
    });

    it('whatTheNewestItemHoldsIsNotSentAgain', 0, () => {
      const newest: Set<string> = new Set<string>([textPrint('abc')]);
      // The text came back with Windows line endings: still the same.
      expect(classifyRead('auto', [textPrint('abc\r\n')], rawTextHash('abc\r\n'), emptyLastWrite(), newest, newest)).assertEqual('already');
      expect(classifyRead('manual', [textPrint('xyz')], rawTextHash('xyz'), emptyLastWrite(), newest, newest)).assertEqual('new');
    });

    it('aDeliberateReCopyOfAnOlderItemGoesOut', 0, () => {
      // A, then B; the user copies A again: B is the newest and the last write.
      const held: Set<string> = new Set<string>([textPrint('A'), textPrint('B')]);
      const newest: Set<string> = new Set<string>([textPrint('B')]);
      const written: LastWrite = lastWrite([textPrint('B')]);
      expect(classifyRead('auto', [textPrint('A')], rawTextHash('A'), written, held, newest)).assertEqual('new');
      expect(classifyRead('manual', [textPrint('A')], rawTextHash('A'), written, held, newest)).assertEqual('new');
    });

    it('anOlderBuildsRawHashMatchesTheExactContent', 0, () => {
      const legacy: LastWrite = lastWrite([`x:${ABC}`]);
      expect(printsMatch(legacy.prints, [textPrint('abc')], ABC)).assertTrue();
      expect(printsMatch(legacy.prints, [textPrint('abc\n')], rawTextHash('abc\n'))).assertFalse();
      expect(classifyRead('auto', [textPrint('abc')], ABC, legacy, new Set<string>(), new Set<string>())).assertEqual('already');
    });

    it('historyKeysSkipsEntriesWithNoKey', 0, () => {
      const keys: Set<string> = historyKeys([entry('h1', 'text', 'abc'), entry('h2', 'html', 'x')]);
      expect(keys.size).assertEqual(1);
    });
  });

  describe('foldTwins', () => {
    it('aTwinOnTopHidesTheOlderCard', 0, () => {
      const items: Card[] = [card('new', 'k1'), card('other', 'k2'), card('old', 'k1')];
      expect(ids(foldTwins(items, keyOf))).assertEqual('new,other');
    });

    it('afterARestartTheNewestByTimeWins', 0, () => {
      // Time order, newest first, is the list a restart builds.
      const items: Card[] = [card('c', 'k'), card('b', 'k'), card('a', 'j')];
      expect(ids(foldTwins(items, keyOf))).assertEqual('c,a');
    });

    it('aNullKeyIsNeverATwin', 0, () => {
      expect(ids(foldTwins([card('a', null), card('b', null)], keyOf))).assertEqual('a,b');
    });

    it('aStackMemberThatIsATwinIsHiddenAndAStackOfOneIsACard', 0, () => {
      // 'top' is a twin of stack member 'm2'; the stack m1, m2 is left with one.
      const items: Card[] = [card('top', 'k2'), card('m1', 'k1', 'g'), card('m2', 'k2', 'g'), card('x', 'k3')];
      const rows: StackRow<Card>[] = buildRows(foldTwins(items, keyOf));
      expect(rows.map((r: StackRow<Card>) => r.front.id).join(',')).assertEqual('top,m1,x');
      expect(rows[1].groupId).assertEqual('');
      // With three members, losing one leaves a stack of two, its front the next.
      const three: Card[] = [card('top', 'k1'), card('m1', 'k1', 'g'), card('m2', 'k2', 'g'), card('m3', 'k3', 'g')];
      const stacked: StackRow<Card>[] = buildRows(foldTwins(three, keyOf));
      expect(stacked.length).assertEqual(2);
      expect(stacked[1].front.id).assertEqual('m2');
      expect(stacked[1].memberIds.join(',')).assertEqual('m2,m3');
    });

    it('deletingACardTakesEveryTwin', 0, () => {
      const items: Card[] = [card('new', 'k1'), card('other', 'k2'), card('old', 'k1')];
      expect(twinIds(items, 'new', keyOf).join(',')).assertEqual('new,old');
      expect(twinIds(items, 'other', keyOf).join(',')).assertEqual('other');
      expect(twinIds([card('a', null), card('b', null)], 'a', keyOf).join(',')).assertEqual('a');
      expect(twinIds(items, 'gone', keyOf).join(',')).assertEqual('gone');
    });
  });

  describe('Freshness', () => {
    it('anEntryIsFreshOnlyWhenLaterThanEverythingHeld', 0, () => {
      const history: ClipboardEntry[] = [entry('f1', 'text', 'a', 3), entry('f2', 'text', 'b', 5)];
      const newest: string | null = newestStamp(history);
      expect(isFresh(entry('f3', 'text', 'c', 6), newest)).assertTrue();
      expect(isFresh(entry('f4', 'text', 'd', 5), newest)).assertFalse();
      expect(isFresh(entry('f5', 'text', 'e', 1), newest)).assertFalse();
      expect(newestStamp([])).assertEqual(null);
      expect(isFresh(entry('f6', 'text', 'f', 1), null)).assertTrue();
    });
  });

  describe('PendingFiles', () => {
    it('aFileWaitingForItsBytesIsAppliedOnlyIfNothingChangedAndInTime', 0, () => {
      expect(pendingFileMayApply(1000, 7, 2000, 7)).assertTrue();
      // Something else went on the clipboard meanwhile.
      expect(pendingFileMayApply(1000, 7, 2000, 8)).assertFalse();
      // Too long ago.
      expect(pendingFileMayApply(1000, 7, 1000 + PENDING_APPLY_LIMIT_MS + 1, 7)).assertFalse();
      expect(pendingFileMayApply(1000, 7, 1000 + PENDING_APPLY_LIMIT_MS, 7)).assertTrue();
    });
  });
}
