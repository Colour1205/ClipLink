import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { sameIdentityKey, sameKeyBytes } from '../main/ets/networking/PeerConnection';

const base64Helper = new util.Base64Helper();

// Two P-256 public keys from throwaway key pairs, as device ids are written:
// Base64 X.509 SubjectPublicKeyInfo, 91 bytes, so each ends in '=='.
const MINE = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELJdLZfH8G9XIDYe6E1HXjg728AExFbYPZCfEVXyR9VQMPSbc3EQF/4nq8fPoAi6oZ/WT1rf1pZC/ayr/V8oofw==';
const THEIRS = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEgazFzBKfh/g12wsXJC/pl7US3pudskOkL7RE1+C3ro/pRCMwalXnn/525S3RDiDwUvpqwm+QAbS42KFK0/F84g==';

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

// Whether this runtime's Base64Helper is the real one. The local unit-test
// runtime's is a stub that encodes everything to '' and decodes everything
// to no bytes, so what the real decoder accepts can only be checked on a
// device - the rest of these tests hold either way.
function realBase64(): boolean {
  try {
    return base64Helper.encodeToStringSync(new Uint8Array([102, 111, 111])) === 'Zm9v';
  } catch (e) {
    return false;
  }
}

function decoded(s: string): Uint8Array | null {
  try {
    return base64Helper.decodeSync(s);
  } catch (e) {
    return null;
  }
}

export default function identityKeyTest() {
  describe('sameKeyBytes', () => {
    it('matchesEqualBytes', 0, () => {
      expect(sameKeyBytes(new Uint8Array([48, 89, 1]), new Uint8Array([48, 89, 1]))).assertTrue();
    });

    it('tellsDifferentBytesApart', 0, () => {
      expect(sameKeyBytes(new Uint8Array([48, 89, 1]), new Uint8Array([48, 89, 2]))).assertFalse();
      expect(sameKeyBytes(new Uint8Array([48, 89, 1]), new Uint8Array([48, 89]))).assertFalse();
    });

    it('noBytesAreNobodysKey', 0, () => {
      expect(sameKeyBytes(new Uint8Array(0), new Uint8Array(0))).assertFalse();
      expect(sameKeyBytes(null, null)).assertFalse();
      expect(sameKeyBytes(null, new Uint8Array([48]))).assertFalse();
      expect(sameKeyBytes(new Uint8Array([48]), null)).assertFalse();
    });
  });

  describe('sameIdentityKey', () => {
    it('matchesTheSameText', 0, () => {
      expect(sameIdentityKey(MINE, MINE)).assertTrue();
    });

    it('tellsDifferentKeysApart', 0, () => {
      expect(sameIdentityKey(THEIRS, MINE)).assertFalse();
      expect(sameIdentityKey('not base64 at all!', MINE)).assertFalse();
      expect(sameIdentityKey('', MINE)).assertFalse();
      expect(sameIdentityKey('', '')).assertFalse();
    });

    it('matchesEveryOtherSpellingTheDecoderTakes', 0, () => {
      if (!realBase64()) {
        console.info('sameIdentityKey: no real Base64 decoder in this runtime - spellings are checked on a device');
        return;
      }
      const mine: Uint8Array | null = decoded(MINE);
      expect(mine !== null && mine.length === 91).assertTrue();
      // The character before '==' carries 2 bits; the other 4 are unused, and
      // a decoder that ignores them takes any of these as the same bytes.
      const last = BASE64_ALPHABET.indexOf(MINE.charAt(MINE.length - 3));
      const loose = MINE.substring(0, MINE.length - 3) + BASE64_ALPHABET.charAt(last | 0x0f) + '==';
      const variants: string[] = [
        `${MINE.substring(0, 40)}\n${MINE.substring(40)}`,
        `${MINE.substring(0, 40)}\r\n${MINE.substring(40, 80)}\r\n${MINE.substring(80)}`,
        `${MINE.substring(0, 40)} ${MINE.substring(40)}`,
        `${MINE}\n`,
        ` ${MINE}`,
        MINE.substring(0, MINE.length - 2),
        loose,
      ];
      let taken = 0;
      for (const variant of variants) {
        expect(variant === MINE).assertFalse();
        // Read as our key's bytes: refused as ours. Read as anything else (or
        // not at all): someone else's key, or none - its handshake signature,
        // made with our key, then fails the check.
        const isMine: boolean = sameKeyBytes(decoded(variant), mine);
        if (isMine) taken++;
        expect(sameIdentityKey(variant, MINE)).assertEqual(isMine);
      }
      console.info(`sameIdentityKey: the decoder reads ${taken} of ${variants.length} other spellings as the key`);
    });
  });
}
