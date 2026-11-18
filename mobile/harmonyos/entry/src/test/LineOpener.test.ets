import { describe, it, expect } from '@ohos/hypium';
import { OpenedLine, nonceKey as openerNonceKey, openLine, openPlain } from '../main/ets/networking/LineOpener';
import { joinFileChunk } from '../main/ets/networking/ChunkSplit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { nonceKey } from '../main/ets/networking/PeerConnection';

// ASCII only, so no text codec is needed.
function bytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function text(data: Uint8Array): string {
  let out = '';
  for (let i = 0; i < data.length; i++) out += String.fromCharCode(data[i]);
  return out;
}

const HASH: string = 'cd'.repeat(32);

// Stands in for Base64Helper: 'QUJD' is ABC, anything else is not Base64.
// Its bytes come in a buffer of their own, as the helper's do.
function fakeDecode(data: Uint8Array): Promise<Uint8Array> {
  if (text(data) !== 'QUJD') return Promise.reject(new Error('not base64'));
  return Promise.resolve(bytes('ABC'));
}

// The same, but its bytes are a view into a bigger buffer.
function viewDecode(data: Uint8Array): Promise<Uint8Array> {
  const big: Uint8Array = bytes('xxABCxx');
  return Promise.resolve(big.subarray(2, 5));
}

function noDecode(data: Uint8Array): Promise<Uint8Array> {
  return Promise.reject(new Error('should not be called'));
}

// What can be checked without the phone's cipher (the unit tests have none):
// the nonce lines are told apart by, and that a line which is not even Base64
// is refused, so the connection ends as it did before.
export default function lineOpenerTest() {
  describe('LineOpener', () => {
    it('keysLinesByTheSameNonceAsTheConnection', 0, () => {
      const packed = new Uint8Array(40);
      for (let i = 0; i < packed.length; i++) packed[i] = i;
      expect(openerNonceKey(packed)).assertEqual(nonceKey(packed));
      expect(openerNonceKey(packed)).assertEqual('000102030405060708090a0b');
    });

    it('splitsAFileChunkAndFreesTheDecryptedBytes', 0, async () => {
      const plain: Uint8Array = joinFileChunk(HASH, 3, false, bytes('QUJD'));
      const freed: ArrayBuffer[] = [];
      const opened: OpenedLine = await openPlain(plain, 'n1', fakeDecode, (b: ArrayBuffer) => { freed.push(b); });
      expect(opened.nonce).assertEqual('n1');
      expect(text(opened.data!)).assertEqual('ABC');
      expect(text(opened.envelope)).assertEqual(text(joinFileChunk(HASH, 3, false, new Uint8Array(0))));
      // The decrypted bytes are freed, and nothing handed back is.
      expect(freed.length).assertEqual(1);
      expect(freed[0] === plain.buffer).assertTrue();
      expect(freed.indexOf(opened.data!.buffer as ArrayBuffer)).assertEqual(-1);
      expect(freed.indexOf(opened.envelope.buffer as ArrayBuffer)).assertEqual(-1);
    });

    it('givesDecodedBytesABufferOfTheirOwn', 0, async () => {
      const plain: Uint8Array = joinFileChunk(HASH, 0, true, bytes('QUJD'));
      const freed: ArrayBuffer[] = [];
      const opened: OpenedLine = await openPlain(plain, null, viewDecode, (b: ArrayBuffer) => { freed.push(b); });
      expect(text(opened.data!)).assertEqual('ABC');
      expect(opened.data!.byteOffset).assertEqual(0);
      expect(opened.data!.buffer.byteLength).assertEqual(3);
      // The decrypted bytes and the bigger buffer the view was in.
      expect(freed.length).assertEqual(2);
      expect(freed.indexOf(opened.data!.buffer as ArrayBuffer)).assertEqual(-1);
    });

    it('handsOnAChunkWhoseBase64IsBadWholeAndFreesNothing', 0, async () => {
      const plain: Uint8Array = joinFileChunk(HASH, 0, true, bytes('QU!D'));
      const freed: ArrayBuffer[] = [];
      const opened: OpenedLine = await openPlain(plain, null, fakeDecode, (b: ArrayBuffer) => { freed.push(b); });
      expect(opened.data === null).assertTrue();
      expect(opened.envelope === plain).assertTrue();
      expect(freed.length).assertEqual(0);
    });

    it('handsOnOtherEnvelopesAsTheyAre', 0, async () => {
      const plain: Uint8Array = bytes('{"Type":"entry","Payload":"{}"}');
      const freed: ArrayBuffer[] = [];
      const opened: OpenedLine = await openPlain(plain, null, noDecode, (b: ArrayBuffer) => { freed.push(b); });
      expect(opened.data === null).assertTrue();
      expect(opened.envelope === plain).assertTrue();
      expect(freed.length).assertEqual(0);
    });

    it('takesAnEmptyChunkWithoutDecoding', 0, async () => {
      const plain: Uint8Array = joinFileChunk(HASH, 0, true, new Uint8Array(0));
      const opened: OpenedLine = await openPlain(plain, null, noDecode, (b: ArrayBuffer) => {});
      expect(opened.data!.length).assertEqual(0);
    });

    it('refusesALineThatIsNotBase64', 0, async () => {
      let refused: boolean = false;
      // Never reaches the cipher, so no key is needed.
      await openLine(bytes('not base64 at all!'), {} as cryptoFramework.SymKey).catch(() => { refused = true; });
      expect(refused).assertTrue();
    });
  });
}
