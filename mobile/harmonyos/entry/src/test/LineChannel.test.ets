import { describe, it, expect } from '@ohos/hypium';
import socket from '@ohos.net.socket';
import { PeerVerdict, TcpLike, TcpLineChannel } from '../main/ets/networking/PeerConnection';

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

  onMessage(callback: (info: socket.SocketMessageInfo) => void): void {
    this.messageCallback = callback;
  }

  onClose(callback: () => void): void {
  }

  send(options: socket.TCPSendOptions): Promise<void> {
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
