import { describe, it, expect } from '@ohos/hypium';
import { nonceKey } from '../main/ets/networking/PeerConnection';

// A line's packed bytes - nonce(12) || tag(16) || ciphertext - with byte i
// set to i * step, so two of them can share a nonce and differ after it.
function packed(length: number, step: number): Uint8Array {
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = (i * step) & 0xff;
  return out;
}

// The echo guard's key (see PeerConnection's sentNonces): the nonce's bytes,
// never the line's Base64 text, so a line spelt another way that decodes to
// one of ours is still ours.
export default function nonceKeyTest() {
  describe('nonceKey', () => {
    it('isTheNonceInHex', 0, () => {
      expect(nonceKey(packed(40, 17))).assertEqual('00112233445566778899aabb');
    });

    it('looksOnlyAtTheNonce', 0, () => {
      const line = packed(40, 17);
      const other = packed(64, 17);
      other[12] = 0xff;
      other[63] = 0x01;
      expect(nonceKey(other)).assertEqual(nonceKey(line));
    });

    it('tellsNoncesApart', 0, () => {
      const line = packed(40, 17);
      const other = packed(40, 17);
      other[11] = 0x00;
      expect(nonceKey(other) === nonceKey(line)).assertFalse();
    });

    it('isNullWithoutAWholeNonce', 0, () => {
      expect(nonceKey(new Uint8Array(0))).assertNull();
      expect(nonceKey(packed(11, 17))).assertNull();
      expect(nonceKey(packed(12, 17))).assertEqual('00112233445566778899aabb');
    });
  });
}
