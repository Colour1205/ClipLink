import { describe, it, expect } from '@ohos/hypium';
import { LineFramer } from '../main/ets/networking/LineFramer';

// ASCII only, so no text codec is needed.
function bytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function texts(lines: Uint8Array[] | null): string {
  if (lines === null) return 'null';
  return JSON.stringify(lines.map((line: Uint8Array): string => {
    let s = '';
    for (let i = 0; i < line.length; i++) s += String.fromCharCode(line[i]);
    return s;
  }));
}

export default function lineFramerTest() {
  describe('LineFramer', () => {
    it('joinsSplitLines', 0, () => {
      const f = new LineFramer(1024);
      expect(texts(f.push(bytes('ab')))).assertEqual('[]');
      expect(f.bufferedBytes).assertEqual(2);
      // '\r' and empty lines are passed on: TcpLineChannel strips the one,
      // and the handshake or the decrypt refuses the other, as before.
      expect(texts(f.push(bytes('c\r\n\nde')))).assertEqual('["abc\\r",""]');
      expect(f.bufferedBytes).assertEqual(2);
      expect(texts(f.push(bytes('f\ng\n')))).assertEqual('["def","g"]');
      expect(f.bufferedBytes).assertEqual(0);
    });

    it('joinsALongLineArrivingInPieces', 0, () => {
      const f = new LineFramer();
      // Past the handshake: a line this long would be refused as a first one.
      expect(texts(f.push(bytes('{"handshake":1}\n')))).assertEqual('["{\\"handshake\\":1}"]');
      const piece = new Uint8Array(1024).fill(97);
      for (let i = 0; i < 1024; i++) {
        expect(texts(f.push(piece))).assertEqual('[]');
      }
      expect(f.bufferedBytes).assertEqual(1024 * 1024);
      const lines = f.push(bytes('\n')) as Uint8Array[];
      expect(lines.length).assertEqual(1);
      expect(lines[0].length).assertEqual(1024 * 1024);
      expect(lines[0][1024 * 1024 - 1]).assertEqual(97);
      expect(f.bufferedBytes).assertEqual(0);
    });

    it('returnsCopiesOfTheSocketBytes', 0, () => {
      const f = new LineFramer();
      const chunk = bytes('abc\n');
      const lines = f.push(chunk);
      chunk[0] = 120;
      expect(texts(lines)).assertEqual('["abc"]');
    });

    it('refusesAnOversizedFirstLine', 0, () => {
      const big = new LineFramer();
      expect(texts(big.push(new Uint8Array(64 * 1024 + 1).fill(97)))).assertEqual('null');
      const f = new LineFramer(1000, 8);
      expect(f.push(bytes('0123456789'))).assertNull();
      // Refused for good - the connection is closed.
      expect(f.push(bytes('\nok\n'))).assertNull();
      const g = new LineFramer(1000, 8);
      expect(g.push(bytes('0123456789\n'))).assertNull();
      const h = new LineFramer(1000, 8);
      expect(texts(h.push(bytes('01234567\n')))).assertEqual('["01234567"]');
    });

    it('anEmptyFirstLineLiftsNoCap', 0, () => {
      const f = new LineFramer(1000, 8);
      expect(texts(f.push(bytes('\n')))).assertEqual('[""]');
      expect(f.push(bytes('0123456789'))).assertNull();
    });

    it('skipsOversizedSessionLinesAndRecovers', 0, () => {
      const f = new LineFramer(8, 8);
      expect(texts(f.push(bytes('hello\n')))).assertEqual('["hello"]');
      // A huge line arriving in pieces: dropped without being kept...
      expect(texts(f.push(bytes('0123456789')))).assertEqual('[]');
      expect(f.bufferedBytes).assertEqual(0);
      expect(texts(f.push(bytes('abcdef')))).assertEqual('[]');
      expect(f.bufferedBytes).assertEqual(0);
      // ...and framing picks up after its newline.
      expect(texts(f.push(bytes('xyz\nok\n')))).assertEqual('["ok"]');
      expect(texts(f.push(bytes('0123456789\nfine\n')))).assertEqual('["fine"]');
      expect(f.droppedLines).assertEqual(2);
    });
  });
}
