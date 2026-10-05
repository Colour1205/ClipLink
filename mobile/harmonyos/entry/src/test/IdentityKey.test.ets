import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { sameIdentityKey } from '../main/ets/networking/PeerConnection';

const base64Helper = new util.Base64Helper();

// Whether the decoder reads a spelling as exactly these bytes. Any other
// spelling names no key, or a different one - either way its handshake's
// signature (made with our key) fails the check.
function decodesTo(s: string, bytes: Uint8Array): boolean {
  let decoded: Uint8Array;
  try {
    decoded = base64Helper.decodeSync(s);
  } catch (e) {
    return false;
  }
  if (decoded.length !== bytes.length) return false;
  for (let i = 0; i < bytes.length; i++) {
    if (decoded[i] !== bytes[i]) return false;
  }
  return true;
}

// A stand-in for an identity key: 91 bytes, the length of a P-256 SPKI, so
// its Base64 ends in '=='.
function keyBytes(seed: number): Uint8Array {
  const out = new Uint8Array(91);
  for (let i = 0; i < out.length; i++) out[i] = (i * 7 + seed) & 0xff;
  return out;
}

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export default function identityKeyTest() {
  describe('sameIdentityKey', () => {
    it('matchesTheSameText', 0, () => {
      const mine = base64Helper.encodeToStringSync(keyBytes(1));
      expect(sameIdentityKey(mine, mine)).assertTrue();
    });

    it('tellsDifferentKeysApart', 0, () => {
      const mine = base64Helper.encodeToStringSync(keyBytes(1));
      const theirs = base64Helper.encodeToStringSync(keyBytes(2));
      expect(sameIdentityKey(theirs, mine)).assertFalse();
      expect(sameIdentityKey('not base64 at all!', mine)).assertFalse();
      expect(sameIdentityKey('', mine)).assertFalse();
    });

    it('matchesEveryOtherSpellingTheDecoderTakes', 0, () => {
      const mine = base64Helper.encodeToStringSync(keyBytes(1));
      expect(mine.endsWith('==')).assertTrue();
      // The character before '==' carries 2 bits; the other 4 are unused, and
      // a decoder that ignores them takes any of these as the same bytes.
      const last = BASE64_ALPHABET.indexOf(mine.charAt(mine.length - 3));
      const loose = mine.substring(0, mine.length - 3) + BASE64_ALPHABET.charAt(last | 0x0f) + '==';
      const variants: string[] = [
        `${mine.substring(0, 40)}\n${mine.substring(40)}`,
        `${mine.substring(0, 40)}\r\n${mine.substring(40, 80)}\r\n${mine.substring(80)}`,
        `${mine.substring(0, 40)} ${mine.substring(40)}`,
        `${mine}\n`,
        ` ${mine}`,
        mine.substring(0, mine.length - 2),
        loose,
      ];
      let taken = 0;
      for (const variant of variants) {
        expect(variant === mine).assertFalse();
        console.info(`DIAG variant=${JSON.stringify(variant.substring(0,3))}... len=${variant.length} decodesTo=${decodesTo(variant, keyBytes(1))} same=${sameIdentityKey(variant, mine)}`);
        if (decodesTo(variant, keyBytes(1))) {
          taken++;
          expect(sameIdentityKey(variant, mine)).assertTrue();
        }
      }
      console.info(`sameIdentityKey: the decoder reads ${taken} of ${variants.length} other spellings as the key`);
    });
  });
}
