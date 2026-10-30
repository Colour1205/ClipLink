import { describe, it, expect } from '@ohos/hypium';
import {
  CONVENIENCE_WINDOW_MS, ConvenienceMemory, MAX_HEAD_DELETED, MAX_HEAD_KEYS_V2, MAX_REQUEST_KEYS, PROTOCOL_VERSION, PendingKeys, answerFor, buildHeadV2Payload, buildKeysPayload,
  negotiatedProtocol, parseHeadV2, parseKeysPayload, peerProtocolOf, splitKeys, unixMillis, wantedKeys, HeadV2
} from '../main/ets/networking/SyncProtocol';
import { HandshakeMessage, handshakeLine } from '../main/ets/networking/PeerConnection';
import { HistoryHead, buildHeadPayload, parseHead } from '../main/ets/storage/HistoryBatch';
import { ClipboardEntry } from '../main/ets/crypto/Signing';

// An entry named by its signature; `minute` is its time (later is newer).
function e(signature: string, minute: number): ClipboardEntry {
  const mm: string = minute < 10 ? `0${minute}` : `${minute}`;
  return { Content: `text ${signature}`, Type: 'text', DeviceId: 'peer', Timestamp: `2026-01-01T10:${mm}:00.0000000Z`, Signature: signature };
}

function keyOf(entry: ClipboardEntry): string {
  return entry.Signature ?? '';
}

function none(key: string): boolean {
  return false;
}

// Times as a head carries them, for the entries of `minute`s.
function t(minute: number): number {
  return unixMillis(`2026-01-01T10:${minute < 10 ? '0' : ''}${minute}:00.0000000Z`);
}

export default function syncProtocolTest() {
  describe('SyncProtocol', () => {
    it('theHandshakeSaysProtocolTwoAndOlderJsonStillParses', 0, () => {
      const handshake: HandshakeMessage = { EphemeralPublicKey: 'E', IdentityPublicKey: 'I', Signature: 'S', DeviceName: 'Phone', Protocol: PROTOCOL_VERSION };
      const line: string = handshakeLine(handshake);
      expect(line).assertEqual('{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"Phone","Protocol":2}');
      expect(line.indexOf('\n')).assertEqual(-1);
      const read: HandshakeMessage = JSON.parse(line) as HandshakeMessage;
      expect(peerProtocolOf(read.Protocol)).assertEqual(2);
      // A handshake from a build before v2 has no such field.
      const older: HandshakeMessage = JSON.parse('{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"PC"}') as HandshakeMessage;
      expect(older.EphemeralPublicKey).assertEqual('E');
      expect(peerProtocolOf(older.Protocol)).assertEqual(1);
    });

    it('theProtocolOfAPeerIsOneUnlessItSaysTwoOrMore', 0, () => {
      expect(peerProtocolOf(undefined)).assertEqual(1);
      expect(peerProtocolOf(null)).assertEqual(1);
      expect(peerProtocolOf(0)).assertEqual(1);
      expect(peerProtocolOf(1)).assertEqual(1);
      expect(peerProtocolOf(2)).assertEqual(2);
      expect(peerProtocolOf(3)).assertEqual(3);
      expect(peerProtocolOf('2')).assertEqual(1);
      expect(peerProtocolOf(true)).assertEqual(1);
      expect(peerProtocolOf(Number.NaN)).assertEqual(1);
    });

    it('aConnectionSpeaksTheOlderOfTheTwoProtocolsUpToTwo', 0, () => {
      expect(negotiatedProtocol(1)).assertEqual(1);
      expect(negotiatedProtocol(2)).assertEqual(2);
      expect(negotiatedProtocol(7)).assertEqual(2);
    });

    it('unixMillisReadsTheDotNetTextToTheMillisecond', 0, () => {
      expect(unixMillis('1970-01-01T00:00:01.0000000Z')).assertEqual(1000);
      expect(unixMillis('2024-11-07T16:53:20.1234567Z')).assertEqual(1730998400123);
      // Trimmed spellings are the same instant.
      expect(unixMillis('2024-11-07T16:53:20.12Z')).assertEqual(1730998400120);
      expect(unixMillis('2024-11-07T16:53:20Z')).assertEqual(1730998400000);
      expect(unixMillis('2024-11-07T18:53:20.0000000+02:00')).assertEqual(1730998400000);
      expect(unixMillis('not a time')).assertEqual(0);
    });

    it('headV2HasKeysTimesAndTombstonesNewestFirstAndNoNewest', 0, () => {
      const payload: string = buildHeadV2Payload([e('a', 1), e('c', 3), e('b', 2)], keyOf, ['y', 'x']);
      expect(payload).assertEqual(
        `{"Keys":["c","b","a"],"Times":[${t(3)},${t(2)},${t(1)}],"Deleted":["y","x"]}`);
      expect(payload.indexOf('Newest')).assertEqual(-1);
      const head: HeadV2 | null = parseHeadV2(payload);
      expect(head !== null).assertTrue();
      expect((head as HeadV2).keys.join(',')).assertEqual('c,b,a');
      expect(((head as HeadV2).times as number[]).join(',')).assertEqual(`${t(3)},${t(2)},${t(1)}`);
      expect((head as HeadV2).deleted.join(',')).assertEqual('y,x');
    });

    it('aV2HeadIsBuiltEvenForNoEntries', 0, () => {
      expect(buildHeadV2Payload([], keyOf, [])).assertEqual('{"Keys":[],"Times":[],"Deleted":[]}');
      const one: HeadV2 | null = parseHeadV2(buildHeadV2Payload([e('a', 1)], keyOf, []));
      expect((one as HeadV2).keys.join(',')).assertEqual('a');
    });

    it('aV2HeadListsAtMost25KeysAnd500Tombstones', 0, () => {
      const history: ClipboardEntry[] = [];
      for (let i = 0; i < 30; i++) history.push(e(`k${i}`, i));
      const deleted: string[] = [];
      for (let i = 0; i < 700; i++) deleted.push(`d${i}`);
      const head: HeadV2 = parseHeadV2(buildHeadV2Payload(history, keyOf, deleted)) as HeadV2;
      expect(head.keys.length).assertEqual(MAX_HEAD_KEYS_V2);
      expect(head.keys[0]).assertEqual('k29');
      expect((head.times as number[]).length).assertEqual(MAX_HEAD_KEYS_V2);
      expect(head.deleted.length).assertEqual(MAX_HEAD_DELETED);
      expect(head.deleted[0]).assertEqual('d0'); // the most recently deleted first
    });

    it('parseHeadV2AcceptsMissingListsAndUnknownKeys', 0, () => {
      const onlyKeys: HeadV2 = parseHeadV2('{"Keys":["a","b"]}') as HeadV2;
      expect(onlyKeys.keys.join(',')).assertEqual('a,b');
      expect(onlyKeys.times).assertEqual(null);
      expect(onlyKeys.deleted.length).assertEqual(0);
      const onlyDeleted: HeadV2 = parseHeadV2('{"Deleted":["x"],"Extra":{"a":1}}') as HeadV2;
      expect(onlyDeleted.keys.length).assertEqual(0);
      expect(onlyDeleted.deleted.join(',')).assertEqual('x');
      expect((parseHeadV2('{}') as HeadV2).keys.length).assertEqual(0);
    });

    it('parseHeadV2RefusesWhatIsNotAnObject', 0, () => {
      expect(parseHeadV2('not json')).assertEqual(null);
      expect(parseHeadV2('[]')).assertEqual(null);
      expect(parseHeadV2('null')).assertEqual(null);
      expect(parseHeadV2('7')).assertEqual(null);
    });

    it('timesThatDoNotMatchTheKeysAreDropped', 0, () => {
      expect((parseHeadV2('{"Keys":["a","b"],"Times":[5]}') as HeadV2).times).assertEqual(null);
      expect((parseHeadV2('{"Keys":["a","b"],"Times":[5,6,7]}') as HeadV2).times).assertEqual(null);
      expect((parseHeadV2('{"Keys":["a","b"],"Times":[5,"x"]}') as HeadV2).times).assertEqual(null);
      expect((parseHeadV2('{"Keys":["a","b"],"Times":"5"}') as HeadV2).times).assertEqual(null);
      expect(((parseHeadV2('{"Keys":["a","b"],"Times":[5,6]}') as HeadV2).times as number[]).join(',')).assertEqual('5,6');
    });

    it('aV2HeadWithTooManyKeysUsesTheFirst25AndSkipsBadKeys', 0, () => {
      const keys: string[] = [];
      const times: number[] = [];
      for (let i = 0; i < 40; i++) {
        keys.push(`k${i}`);
        times.push(1000 - i);
      }
      const head: HeadV2 = parseHeadV2(JSON.stringify({ Keys: keys, Times: times })) as HeadV2;
      expect(head.keys.length).assertEqual(25);
      expect(head.keys[24]).assertEqual('k24');
      expect((head.times as number[])[24]).assertEqual(976);
      // Something that is not a string, and a key that is too long, are skipped
      // with their times.
      const odd: HeadV2 = parseHeadV2(`{"Keys":["a",7,"${'x'.repeat(2049)}","b"],"Times":[1,2,3,4]}`) as HeadV2;
      expect(odd.keys.join(',')).assertEqual('a,b');
      expect((odd.times as number[]).join(',')).assertEqual('1,4');
      expect((parseHeadV2(`{"Deleted":["${'x'.repeat(2048)}","${'x'.repeat(2049)}"]}`) as HeadV2).deleted.length).assertEqual(1);
    });

    it('theOldHeadStillWorksAndAV2ParserIgnoresItsNewest', 0, () => {
      const payload: string = buildHeadPayload([e('a', 1), e('c', 3), e('b', 2)], keyOf) as string;
      expect(parseHead(payload) !== null).assertTrue();
      expect((parseHead(payload) as HistoryHead).Newest.Signature).assertEqual('c');
      // Read as a v2 head: the Newest is skipped, the keys are what is left.
      const head: HeadV2 = parseHeadV2(payload) as HeadV2;
      expect(head.keys.join(',')).assertEqual('c,b,a');
      expect(head.times).assertEqual(null);
    });

    it('requestsAndDeletesCarryKeysInAnObject', 0, () => {
      expect(buildKeysPayload(['k1', 'k2'])).assertEqual('{"Keys":["k1","k2"]}');
      expect((parseKeysPayload('{"Keys":["k1","k2"]}') as string[]).join(',')).assertEqual('k1,k2');
      expect((parseKeysPayload('{}') as string[]).length).assertEqual(0);
      expect((parseKeysPayload('{"Keys":["a"],"More":1}') as string[]).join(',')).assertEqual('a');
      expect(parseKeysPayload('[1]')).assertEqual(null);
      expect(parseKeysPayload('nope')).assertEqual(null);
    });

    it('onlyTheFirst100KeysAreReadAndBadKeysAreSkipped', 0, () => {
      const keys: string[] = [];
      for (let i = 0; i < 130; i++) keys.push(`k${i}`);
      const read: string[] = parseKeysPayload(buildKeysPayload(keys)) as string[];
      expect(read.length).assertEqual(MAX_REQUEST_KEYS);
      expect(read[99]).assertEqual('k99');
      expect((parseKeysPayload(`{"Keys":[1,null,"a","${'x'.repeat(2049)}"]}`) as string[]).join(',')).assertEqual('a');
    });

    it('splitKeysMakesPiecesOf100', 0, () => {
      const keys: string[] = [];
      for (let i = 0; i < 250; i++) keys.push(`k${i}`);
      const pieces: string[][] = splitKeys(keys);
      expect(pieces.map((p: string[]) => p.length).join(',')).assertEqual('100,100,50');
      expect(splitKeys([]).length).assertEqual(0);
    });

    it('wantedSkipsKnownDeletedAndAskedElsewhere', 0, () => {
      const known: Set<string> = new Set<string>(['k2']); // in the history, or deleted here
      const pending: Set<string> = new Set<string>(['k4']);
      const wanted: string[] = wantedKeys(['k1', 'k2', 'k3', 'k4', 'k1'], [50, 40, 30, 20, 50], (k: string) => known.has(k),
        (k: string) => pending.has(k), [], 25);
      expect(wanted.join(',')).assertEqual('k1,k3');
    });

    it('wantedKeepsOnlyWhatStaysInTheNewest25ByTime', 0, () => {
      // 25 local entries at times 100..124; the peer has an item newer than all
      // (130), one in the middle (110) and one older than all (5).
      const local: number[] = [];
      for (let i = 100; i < 125; i++) local.push(i);
      const wanted: string[] = wantedKeys(['new', 'mid', 'old'], [130, 110, 5], none, none, local, 25);
      // 'new' and 'mid' push two local ones out; 'old' would not stay.
      expect(wanted.join(',')).assertEqual('new,mid');
    });

    it('theFirstMissingKeyIsWantedWhateverItsTime', 0, () => {
      const local: number[] = [];
      for (let i = 100; i < 125; i++) local.push(i);
      expect(wantedKeys(['old', 'older'], [5, 4], none, none, local, 25).join(',')).assertEqual('old');
      expect(wantedKeys(['new', 'old'], [130, 5], none, none, local, 25).join(',')).assertEqual('new');
    });

    it('withoutTimesEveryMissingKeyIsWantedUpTo25', 0, () => {
      const keys: string[] = [];
      for (let i = 0; i < 30; i++) keys.push(`k${i}`);
      const wanted: string[] = wantedKeys(keys, null, none, none, [1, 2, 3], 25);
      expect(wanted.length).assertEqual(25);
      expect(wanted[0]).assertEqual('k0');
    });

    it('theWantedListIsNeverLongerThanTheCapEvenWhenTheTimesAreOutOfOrder', 0, () => {
      // 26 missing keys: the first is the oldest, the 25 after it are newer, so
      // 25 stay by time and the always-wanted first would be the 26th.
      const keys: string[] = ['first'];
      const times: number[] = [1];
      for (let i = 0; i < 25; i++) {
        keys.push(`k${i}`);
        times.push(100 + i);
      }
      const wanted: string[] = wantedKeys(keys, times, none, none, [], 25);
      expect(wanted.length).assertEqual(25);
      expect(wanted[0]).assertEqual('first');
      expect(wanted.includes('k24')).assertFalse(); // the last of the rest is cut
    });

    it('anEmptyKeyIsNoKeyInAHeadARequestOrADelete', 0, () => {
      const head: HeadV2 = parseHeadV2('{"Keys":["","a","b"],"Times":[3,2,1],"Deleted":["","x"]}') as HeadV2;
      expect(head.keys.join(',')).assertEqual('a,b');
      expect((head.times as number[]).join(',')).assertEqual('2,1');
      expect(head.deleted.join(',')).assertEqual('x');
      expect((parseKeysPayload('{"Keys":["","k"]}') as string[]).join(',')).assertEqual('k');
    });

    it('aConvenienceItemIsHeldBackOnlyWhenARecentOneIsNotOlder', 0, () => {
      const memory: ConvenienceMemory = new ConvenienceMemory();
      expect(memory.allows('2026-01-01T10:05:00.0000000Z', 1000)).assertTrue(); // nothing before it
      memory.record('2026-01-01T10:05:00.0000000Z', 1000);
      expect(memory.allows('2026-01-01T10:04:00.0000000Z', 1000 + 5000)).assertFalse(); // older
      expect(memory.allows('2026-01-01T10:05:00.0000000Z', 1000 + 5000)).assertFalse(); // not newer
      expect(memory.allows('2026-01-01T10:06:00.0000000Z', 1000 + 5000)).assertTrue(); // newer
      expect(memory.allows('2026-01-01T10:04:00.0000000Z', 1000 + CONVENIENCE_WINDOW_MS - 1)).assertFalse();
      expect(memory.allows('2026-01-01T10:04:00.0000000Z', 1000 + CONVENIENCE_WINDOW_MS)).assertTrue(); // 90 s have passed
    });

    it('aClockThatWentBackDoesNotHoldConvenienceItemsBack', 0, () => {
      const memory: ConvenienceMemory = new ConvenienceMemory();
      memory.record('2026-01-01T10:05:00.0000000Z', 100000);
      expect(memory.allows('2026-01-01T10:04:00.0000000Z', 100000)).assertFalse(); // same instant: inside the window
      expect(memory.allows('2026-01-01T10:04:00.0000000Z', 100000 - 1)).assertTrue(); // the clock went back
      expect(memory.allows('2026-01-01T10:05:00.0000000Z', 1000)).assertTrue(); // far back
    });

    it('nothingMissingMeansNothingWanted', 0, () => {
      expect(wantedKeys([], [], none, none, [], 25).length).assertEqual(0);
      expect(wantedKeys(['a'], [1], (k: string) => true, none, [], 25).length).assertEqual(0);
    });

    it('answerForGivesTheAskedEntriesNewestFirstAndSkipsWhatIsGone', 0, () => {
      const history: ClipboardEntry[] = [e('a', 1), e('b', 5), e('c', 3)];
      expect(answerFor(history, ['a', 'b', 'nope'], keyOf).map(keyOf).join(',')).assertEqual('b,a');
      expect(answerFor(history, ['nope'], keyOf).length).assertEqual(0);
      expect(answerFor(history, [], keyOf).length).assertEqual(0);
    });

    it('aKeyIsAskedOnOneConnectionAtATime', 0, () => {
      const pending: PendingKeys = new PendingKeys();
      pending.claim('link-1', ['a', 'b']);
      expect(pending.has('a')).assertTrue();
      expect(pending.has('c')).assertFalse();
      pending.release('link-2', ['a']); // not its key
      expect(pending.has('a')).assertTrue();
      pending.release('link-1', ['a']);
      expect(pending.has('a')).assertFalse();
      expect(pending.releaseLink('link-1')).assertEqual(1);
      expect(pending.has('b')).assertFalse();
      expect(pending.releaseLink('link-1')).assertEqual(0);
    });
  });
}
