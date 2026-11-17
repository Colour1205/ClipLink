import { describe, it, expect } from '@ohos/hypium';
import socket from '@ohos.net.socket';
import { PeerVerdict, SESSION_QUEUE_MAX_BYTES, TcpLike, TcpLineChannel, exactBuffer } from '../main/ets/networking/PeerConnection';

// ASCII only, so no text codec is needed.
function bytesOf(s: string): ArrayBuffer {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out.buffer as ArrayBuffer;
}

function textOf(line: Uint8Array | null): string {
  if (line === null) return 'null';
  let s = '';
  for (let i = 0; i < line.length; i++) s += String.fromCharCode(line[i]);
  return s;
}

function repeat(c: string, n: number): string {
  let s = '';
  for (let i = 0; i < n; i++) s += c;
  return s;
}

// A socket that only delivers what a test pushes into it.
class FakeSocket implements TcpLike {
  private messageCallback: ((info: socket.SocketMessageInfo) => void) | null = null;
  closed: boolean = false;
  // What was written, each send as text.
  sent: string[] = [];

  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.messageCallback = callback;
  }

  onClose(callback: () => void): void {
  }

  send(options: socket.TCPSendOptions): Promise<void> {
    const data: string | ArrayBuffer = options.data;
    this.sent.push(typeof data === 'string' ? data : textOf(new Uint8Array(data)));
    return Promise.resolve();
  }

  close(): Promise<void> {
    this.closed = true;
    return Promise.resolve();
  }

  push(text: string): void {
    const message: ArrayBuffer = bytesOf(text);
    this.messageCallback?.({
      message: message, remoteInfo: { address: '192.168.1.40', family: 'IPv4', port: 49000, size: message.byteLength }
    });
  }
}

// What a connection nobody reads may hold (see TcpLineChannel.limitUntilRead):
// a pairing request waits minutes for its answer, and a stranger must not be
// able to fill this device's memory meanwhile.
export default function lineChannelTest() {
  describe('LineChannel', () => {
    it('keepsWhatFitsUnderTheLimitInOrder', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      expect(textOf(await channel.readLine())).assertEqual('handshake');
      channel.limitUntilRead(100);
      fake.push(`${repeat('a', 30)}\n${repeat('b', 30)}\n`);
      expect(channel.overflowed).assertFalse();
      expect(textOf(await channel.readLine())).assertEqual(repeat('a', 30));
      expect(textOf(await channel.readLine())).assertEqual(repeat('b', 30));
    });

    it('dropsEverythingOnceOverTheLimitButStaysOpen', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitUntilRead(100);
      fake.push(`${repeat('a', 60)}\n`);
      fake.push(`${repeat('b', 60)}\n`);
      expect(channel.overflowed).assertTrue();
      expect(channel.isClosed).assertFalse();
      expect(fake.closed).assertFalse();
      // Ignored from here on, and nothing queued is handed out.
      fake.push('c\n');
      const verdict: PeerVerdict = await channel.waitForActivity(10);
      expect(verdict).assertEqual('accepted');
      expect(textOf(await channel.readLineWithin(10))).assertEqual('null');
    });

    it('countsALineStillArrivingAgainstTheLimit', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitUntilRead(100);
      fake.push(repeat('a', 80));
      expect(channel.overflowed).assertFalse();
      fake.push(repeat('a', 80));
      expect(channel.overflowed).assertTrue();
    });

    it('holdsAnyAmountOnceTheLimitIsLifted', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitUntilRead(100);
      channel.stopLimit();
      fake.push(`${repeat('a', 500)}\n`);
      expect(channel.overflowed).assertFalse();
      expect(textOf(await channel.readLine())).assertEqual(repeat('a', 500));
    });

    it('freesTheLimitAsLinesAreRead', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitUntilRead(100);
      for (let i = 0; i < 5; i++) {
        fake.push(`${repeat('a', 60)}\n`);
        expect(textOf(await channel.readLine())).assertEqual(repeat('a', 60));
      }
      expect(channel.overflowed).assertFalse();
    });

    // A trusted connection being read (see SESSION_QUEUE_MAX_BYTES): lines
    // pile up only when this side falls behind, and past the cap it closes
    // rather than holding more.
    it('closesWhenTheReadQueueGoesOverItsCap', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitQueue(100);
      fake.push(`${repeat('a', 60)}\n`);
      expect(channel.hasPendingLine).assertTrue();
      expect(channel.isClosed).assertFalse();
      fake.push(`${repeat('b', 60)}\n${repeat('c', 60)}\n`);
      expect(channel.queueOverflow).assertTrue();
      expect(channel.isClosed).assertTrue();
      expect(fake.closed).assertTrue();
      expect(channel.hasPendingLine).assertFalse();
      expect(textOf(await channel.readLine())).assertEqual('null');
    });

    // One line may be bigger than the cap, a big picture say, and it still
    // gets through (see TcpLineChannel.deliverLine), with a quarter of the
    // cap behind it, not the whole cap.
    it('letsOneLongLineWaitWithALittleBehindIt', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitQueue(100);
      fake.push(`${repeat('a', 150)}\n`);
      expect(channel.isClosed).assertFalse();
      fake.push(`${repeat('b', 20)}\n`);
      expect(channel.isClosed).assertFalse();
      expect(textOf(await channel.readLine())).assertEqual(repeat('a', 150));
      expect(textOf(await channel.readLine())).assertEqual(repeat('b', 20));
      fake.push(`${repeat('c', 150)}\n${repeat('d', 20)}\n`);
      expect(channel.isClosed).assertFalse();
      // 30 behind it, past the 25 a quarter of the cap allows.
      fake.push(`${repeat('e', 10)}\n`);
      expect(channel.queueOverflow).assertTrue();
      expect(channel.isClosed).assertTrue();
    });

    it('knowsWhenALineIsHalfWayIn', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      expect(channel.hasPartLine).assertFalse();
      fake.push('half a li');
      expect(channel.hasPartLine).assertTrue();
      expect(channel.hasPendingLine).assertFalse();
      fake.push('ne\n');
      expect(channel.hasPartLine).assertFalse();
      expect(channel.hasPendingLine).assertTrue();
      expect(textOf(await channel.readLine())).assertEqual('half a line');
    });

    // 512 MB was more than the phone could hold (it ran out of memory at
    // about 365 MB); see SESSION_QUEUE_MAX_BYTES.
    it('capsTheQueueAtWhatAPhoneCanHold', 0, () => {
      expect(SESSION_QUEUE_MAX_BYTES).assertEqual(128 * 1024 * 1024);
    });

    it('keepsWhatIsReadUnderTheCapAndNotesTheHighest', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      fake.push('handshake\n');
      await channel.readLine();
      channel.limitQueue(100);
      fake.push(`${repeat('a', 60)}\n`);
      expect(textOf(await channel.readLine())).assertEqual(repeat('a', 60));
      fake.push(`${repeat('b', 60)}\n`);
      expect(textOf(await channel.readLine())).assertEqual(repeat('b', 60));
      expect(channel.isClosed).assertFalse();
      expect(channel.takeQueueHigh()).assertEqual(60);
      expect(channel.takeQueueHigh()).assertEqual(0);
    });

    // A file's chunks are made a few at a time (see SyncManager.
    // streamFileToPeer): each line keeps the place it was sent in, even
    // when a later one is ready first.
    it('writesLinesInTheOrderTheyWereSent', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      let finishFirst: (bytes: Uint8Array) => void = (bytes: Uint8Array): void => {};
      const first: Promise<Uint8Array> = new Promise<Uint8Array>((resolve: (bytes: Uint8Array) => void) => {
        finishFirst = resolve;
      });
      const one: Promise<void> = channel.writeLineBytes(first);
      const two: Promise<void> = channel.writeLineBytes(Promise.resolve(new Uint8Array(bytesOf('second\n'))));
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 10); });
      expect(fake.sent.length).assertEqual(0);
      finishFirst(new Uint8Array(bytesOf('first\n')));
      await one;
      await two;
      expect(fake.sent.join('')).assertEqual('first\nsecond\n');
    });

    it('goesOnWritingAfterALineFailsToBeMade', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      let failed: boolean = false;
      await channel.writeLineBytes(Promise.reject<Uint8Array>(new Error('no line'))).catch(() => { failed = true; });
      await channel.writeLineBytes(Promise.resolve(new Uint8Array(bytesOf('next\n'))));
      expect(failed).assertTrue();
      expect(fake.sent.join('')).assertEqual('next\n');
    });

    it('sendsExactlyTheLinesBytes', 0, () => {
      const backing: Uint8Array = new Uint8Array(bytesOf('xxline\nyy'));
      expect(textOf(new Uint8Array(exactBuffer(backing.subarray(2, 7))))).assertEqual('line\n');
      const whole: Uint8Array = new Uint8Array(bytesOf('all'));
      expect(exactBuffer(whole) === whole.buffer).assertTrue();
    });

    // The heartbeat counts any bytes once the session is proven (see
    // PeerConnection.lastHeardAt): a piece of a long line is news too.
    it('notesBytesThatAreNotYetALine', 0, async () => {
      const fake = new FakeSocket();
      const channel = new TcpLineChannel(fake);
      const before: number = channel.lastBytesAt;
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 20); });
      fake.push('part of a line');
      expect(channel.lastBytesAt > before).assertTrue();
    });
  });
}
