import { describe, it, expect } from '@ohos/hypium';
import {
  ACK_TIMEOUT_MS, ACK_WINDOW, AckTimers, AckWindow, ChunkSender, FILE_ACK_CAP, FILE_ACK_TYPE, FileAck, HandedChunk,
  MAX_CAPS, OWN_CAPS, PumpEnd, STALLED_STREAM_MS, acksFiles, buildFileAckPayload, fileAckFor, parseFileAck, peerCapsOf,
  pumpChunks, stallVerdict
} from '../main/ets/networking/FileFlow';
import { HandshakeMessage, handshakeLine } from '../main/ets/networking/PeerConnection';
import { FileChunkMessage } from '../main/ets/networking/FileChunkMessage';

const HASH: string = 'AB12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34';

// A clock the test drives by hand: a timer only goes off when fire() is
// called.
class FakeTimers implements AckTimers {
  private callbacks: Map<number, () => void> = new Map<number, () => void>();
  private nextId: number = 1;
  lastMs: number = 0;

  start(callback: () => void, ms: number): number {
    const id: number = this.nextId++;
    this.callbacks.set(id, callback);
    this.lastMs = ms;
    return id;
  }

  stop(id: number): void {
    this.callbacks.delete(id);
  }

  get running(): number {
    return this.callbacks.size;
  }

  fire(): void {
    const callbacks: Array<() => void> = Array.from(this.callbacks.values());
    this.callbacks.clear();
    for (const callback of callbacks) callback();
  }
}

// Lets promise callbacks and a timer of 0 run.
function settle(): Promise<void> {
  return new Promise<void>((resolve: () => void) => { setTimeout(resolve, 10); });
}

// What SyncManager.streamFileToPeer hands pumpChunks, without the file and
// the socket: `total` chunks, each written at once, or, from chunk holdFrom
// on, only when release() is called. sent counts the chunks handed over.
class FakeChunkSender implements ChunkSender {
  sent: number = 0;
  private readonly total: number;
  private readonly holdFrom: number;
  private readonly failAt: number;
  private releases: Array<() => void> = [];

  constructor(total: number, holdFrom: number = -1, failAt: number = -1) {
    this.total = total;
    this.holdFrom = holdFrom;
    this.failAt = failAt;
  }

  more(): boolean {
    return this.sent < this.total;
  }

  async send(index: number): Promise<HandedChunk | null> {
    if (index === this.failAt) throw new Error('unreadable');
    this.sent++;
    if (this.holdFrom < 0 || index < this.holdFrom) {
      const done: HandedChunk = { written: Promise.resolve() };
      return done;
    }
    const held: HandedChunk = {
      written: new Promise<void>((resolve: () => void) => { this.releases.push(resolve); }),
    };
    return held;
  }

  get waitingWrites(): number {
    return this.releases.length;
  }

  release(): void {
    const releases: Array<() => void> = this.releases;
    this.releases = [];
    for (const release of releases) release();
  }
}

// SyncManager's SEND_WINDOW.
const SEND_WINDOW: number = 3;

function handshakeWith(caps: string): HandshakeMessage {
  return JSON.parse(`{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S"${caps}}`) as HandshakeMessage;
}

export default function fileFlowTest() {
  describe('FileFlow', () => {
    it('theHandshakeListsFileAck', 0, () => {
      expect(OWN_CAPS.length).assertEqual(1);
      expect(OWN_CAPS[0]).assertEqual('file-ack');
      const handshake: HandshakeMessage = {
        EphemeralPublicKey: 'E', IdentityPublicKey: 'I', Signature: 'S', Protocol: 2, Caps: OWN_CAPS,
      };
      expect(handshakeLine(handshake))
        .assertEqual('{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","Protocol":2,"Caps":["file-ack"]}');
    });

    it('readsAPeersCapabilities', 0, () => {
      const caps: string[] = peerCapsOf(handshakeWith(',"Caps":["file-ack","file-raw1"]').Caps);
      expect(caps.length).assertEqual(2);
      expect(acksFiles(caps)).assertTrue();
      // Only other names: not this one.
      expect(acksFiles(peerCapsOf(handshakeWith(',"Caps":["file-raw1"]').Caps))).assertFalse();
      // Case matters: the name is "file-ack" exactly.
      expect(acksFiles(peerCapsOf(handshakeWith(',"Caps":["FILE-ACK"]').Caps))).assertFalse();
    });

    it('anOlderPeerListsNothing', 0, () => {
      // No field at all: every build before this one.
      expect(peerCapsOf(handshakeWith('').Caps).length).assertEqual(0);
      expect(acksFiles(peerCapsOf(handshakeWith('').Caps))).assertFalse();
      expect(peerCapsOf(handshakeWith(',"Caps":null').Caps).length).assertEqual(0);
      // Not a list: ignored rather than read as one name.
      expect(acksFiles(peerCapsOf(handshakeWith(',"Caps":"file-ack"').Caps))).assertFalse();
      expect(acksFiles(peerCapsOf(handshakeWith(',"Caps":{"file-ack":true}').Caps))).assertFalse();
    });

    it('skipsCapabilitiesThatAreNotNames', 0, () => {
      const caps: string[] = peerCapsOf(handshakeWith(`,"Caps":[1,null,"","${'x'.repeat(65)}",["file-ack"],"file-ack"]`).Caps);
      expect(caps.length).assertEqual(1);
      expect(caps[0]).assertEqual(FILE_ACK_CAP);
      const many: string[] = [];
      for (let i = 0; i < MAX_CAPS + 10; i++) many.push(`cap${i}`);
      many.push('file-ack');
      // A stranger's long list is cut down: past MAX_CAPS nothing is read.
      expect(peerCapsOf(many).length).assertEqual(MAX_CAPS);
      expect(acksFiles(peerCapsOf(many))).assertFalse();
    });

    it('anAckGoesThereAndBack', 0, () => {
      expect(FILE_ACK_TYPE).assertEqual('file_ack');
      const payload: string = buildFileAckPayload(HASH, 41);
      expect(payload).assertEqual(`{"FileHash":"${HASH}","ChunkIndex":41}`);
      const ack: FileAck | null = parseFileAck(payload);
      expect(ack !== null).assertTrue();
      // The hash comes back spelt as it went, capitals and all.
      expect(ack?.FileHash).assertEqual(HASH);
      expect(ack?.ChunkIndex).assertEqual(41);
      // Fields it does not know are ignored.
      expect(parseFileAck(`{"FileHash":"${HASH}","ChunkIndex":0,"Later":true}`)?.ChunkIndex).assertEqual(0);
    });

    it('refusesAnAckThatIsNotOne', 0, () => {
      expect(parseFileAck('not json')).assertNull();
      expect(parseFileAck('null')).assertNull();
      expect(parseFileAck('[1]')).assertNull();
      expect(parseFileAck('{"ChunkIndex":1}')).assertNull();
      expect(parseFileAck('{"FileHash":"","ChunkIndex":1}')).assertNull();
      expect(parseFileAck('{"FileHash":7,"ChunkIndex":1}')).assertNull();
      expect(parseFileAck(`{"FileHash":"${HASH}"}`)).assertNull();
      expect(parseFileAck(`{"FileHash":"${HASH}","ChunkIndex":-1}`)).assertNull();
      expect(parseFileAck(`{"FileHash":"${HASH}","ChunkIndex":1.5}`)).assertNull();
      expect(parseFileAck(`{"FileHash":"${HASH}","ChunkIndex":"3"}`)).assertNull();
    });

    it('usesAWindowOfEightAndThirtySeconds', 0, () => {
      expect(ACK_WINDOW).assertEqual(8);
      expect(ACK_TIMEOUT_MS).assertEqual(30000);
      expect(STALLED_STREAM_MS > ACK_TIMEOUT_MS).assertTrue();
    });

    it('stopsAtTheWindowAndGoesOnWithAnAck', 0, async () => {
      const timers: FakeTimers = new FakeTimers();
      const acks: AckWindow = new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, timers);
      const sender: FakeChunkSender = new FakeChunkSender(20);
      const done: Promise<PumpEnd> = pumpChunks(sender, acks, SEND_WINDOW);
      await settle();
      // Eight sent and none acknowledged: the ninth waits.
      expect(sender.sent).assertEqual(8);
      expect(acks.unacked).assertEqual(8);
      expect(acks.hasRoom).assertFalse();
      expect(timers.running).assertEqual(1);
      expect(timers.lastMs).assertEqual(ACK_TIMEOUT_MS);
      // One acknowledgement (chunk 0) makes room for one more.
      expect(acks.ack(0)).assertTrue();
      await settle();
      expect(sender.sent).assertEqual(9);
      // An acknowledgement covers every chunk before it.
      expect(acks.ack(5)).assertTrue();
      await settle();
      expect(sender.sent).assertEqual(14);
      expect(acks.unacked).assertEqual(8);
      // Then the rest.
      acks.ack(13);
      await settle();
      expect(sender.sent).assertEqual(20);
      expect(await done).assertEqual('ended');
      expect(acks.timedOut).assertFalse();
      expect(timers.running).assertEqual(0);
    });

    it('ignoresAcksThatChangeNothing', 0, () => {
      const acks: AckWindow = new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, new FakeTimers());
      for (let i = 0; i < 4; i++) acks.sent(i);
      // Not sent yet in this stream.
      expect(acks.ack(4)).assertFalse();
      expect(acks.ack(100)).assertFalse();
      expect(acks.ack(2)).assertTrue();
      // Already covered.
      expect(acks.ack(1)).assertFalse();
      expect(acks.ack(2)).assertFalse();
      expect(acks.unacked).assertEqual(1);
    });

    it('givesUpWhenNoAckComes', 0, async () => {
      const timers: FakeTimers = new FakeTimers();
      const acks: AckWindow = new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, timers);
      const sender: FakeChunkSender = new FakeChunkSender(20);
      const done: Promise<PumpEnd> = pumpChunks(sender, acks, SEND_WINDOW);
      await settle();
      expect(sender.sent).assertEqual(8);
      // Thirty seconds and nothing: the stream stops where it was.
      timers.fire();
      expect(await done).assertEqual('timed-out');
      expect(sender.sent).assertEqual(8);
      expect(acks.timedOut).assertTrue();
      // An acknowledgement after that sends nothing more.
      acks.ack(7);
      await settle();
      expect(sender.sent).assertEqual(8);
    });

    it('stopsAtOnceWhenCancelled', 0, async () => {
      const timers: FakeTimers = new FakeTimers();
      const acks: AckWindow = new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, timers);
      const sender: FakeChunkSender = new FakeChunkSender(20);
      const done: Promise<PumpEnd> = pumpChunks(sender, acks, SEND_WINDOW);
      await settle();
      // Its connection closed: the wait ends now, not in thirty seconds.
      acks.cancel();
      expect(await done).assertEqual('ended');
      expect(sender.sent).assertEqual(8);
      expect(acks.timedOut).assertFalse();
      expect(timers.running).assertEqual(0);
      expect(await acks.waitForRoom()).assertFalse();
    });

    it('startsTheWindowAgainWhenAStreamStartsOver', 0, () => {
      const acks: AckWindow = new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, new FakeTimers());
      for (let i = 0; i < ACK_WINDOW; i++) acks.sent(i);
      expect(acks.ack(2)).assertTrue();
      expect(acks.unacked).assertEqual(5);
      // Chunk 0 again: nothing from before is owed.
      acks.sent(0);
      expect(acks.unacked).assertEqual(1);
      expect(acks.hasRoom).assertTrue();
      // A late acknowledgement of the old stream's chunk 5 is for a chunk not
      // sent yet in this one: ignored.
      expect(acks.ack(5)).assertFalse();
      expect(acks.ack(0)).assertTrue();
      expect(acks.unacked).assertEqual(0);
    });

    it('anOlderPeerIsSentEverythingAtOnce', 0, async () => {
      // A receiver that did not list file-ack gets no window (see
      // SyncManager.streamFileToPeer), and nothing is waited for: all 1160
      // chunks of a 290 MB file go with no acknowledgement at all.
      expect(acksFiles(peerCapsOf(undefined))).assertFalse();
      const sender: FakeChunkSender = new FakeChunkSender(1160);
      expect(await pumpChunks(sender, null, SEND_WINDOW)).assertEqual('ended');
      expect(sender.sent).assertEqual(1160);
    });

    it('anOlderPeerIsSentNoAck', 0, () => {
      // A sender that did not list file-ack: nothing, for any chunk.
      expect(fileAckFor(false, HASH, 0)).assertNull();
      expect(fileAckFor(false, HASH, 41)).assertNull();
      // One that did: the chunk's own hash and index.
      const payload: string | null = fileAckFor(true, HASH, 41);
      expect(payload).assertEqual(buildFileAckPayload(HASH, 41));
      expect(parseFileAck(payload ?? '')?.ChunkIndex).assertEqual(41);
      // A chunk with no usable index is not acknowledged.
      const wire: FileChunkMessage = JSON.parse('{"FileHash":"x","ChunkIndex":"3"}') as FileChunkMessage;
      expect(fileAckFor(true, HASH, wire.ChunkIndex)).assertNull();
      expect(fileAckFor(true, HASH, -1)).assertNull();
      expect(fileAckFor(true, HASH, 2.5)).assertNull();
    });

    it('startsTheClockOnceItsOwnChunksAreWritten', 0, async () => {
      const timers: FakeTimers = new FakeTimers();
      const acks: AckWindow = new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, timers);
      // Chunks 6 and 7 sit in this side's own write queue (behind a big
      // history batch, say).
      const sender: FakeChunkSender = new FakeChunkSender(12, 6);
      const done: Promise<PumpEnd> = pumpChunks(sender, acks, ACK_WINDOW + 4);
      await settle();
      expect(sender.sent).assertEqual(8);
      expect(sender.waitingWrites).assertEqual(2);
      // The receiver can't have acknowledged what it has not got: no clock.
      expect(timers.running).assertEqual(0);
      sender.release();
      await settle();
      expect(timers.running).assertEqual(1);
      acks.ack(7);
      await settle();
      sender.release();
      expect(await done).assertEqual('ended');
      expect(sender.sent).assertEqual(12);
    });

    it('stopsWhenAChunkCannotBeRead', 0, async () => {
      const sender: FakeChunkSender = new FakeChunkSender(20, -1, 3);
      let failed: boolean = false;
      try {
        await pumpChunks(sender, new AckWindow(ACK_WINDOW, ACK_TIMEOUT_MS, new FakeTimers()), SEND_WINDOW);
      } catch (e) {
        failed = true;
      }
      expect(failed).assertTrue();
      expect(sender.sent).assertEqual(3);
    });

    it('dropsAStreamOnlyWhenItsSenderHasGoneQuiet', 0, () => {
      const t: number = 1000000;
      // Chunks still being written: the sender is waiting on this side.
      expect(stallVerdict(2, false, t - STALLED_STREAM_MS * 2, t)).assertEqual('wait');
      // Something still on its way through (a big line on a slow link): the
      // quiet is not the sender's, so the clock starts again.
      expect(stallVerdict(0, true, t - STALLED_STREAM_MS * 2, t)).assertEqual('touch');
      // Quiet, but not for long enough yet.
      expect(stallVerdict(0, false, t - STALLED_STREAM_MS + 1, t)).assertEqual('wait');
      // Quiet for STALLED_STREAM_MS: given up.
      expect(stallVerdict(0, false, t - STALLED_STREAM_MS, t)).assertEqual('drop');
    });
  });
}
