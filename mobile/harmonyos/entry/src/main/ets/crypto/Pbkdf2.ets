// Manual PBKDF2-HMAC-SHA256, built directly on cryptoFramework's HMAC
// primitive. Necessary because cryptoFramework.createKdf('PBKDF2|SHA256')
// fails on-device (code 401, "build context fail") regardless of
// parameters — a platform bug confirmed in the step-2 compatibility spike
// (see README.md), not something wrong on our end. HMAC-SHA256 itself was
// verified working and byte-exact against .NET in isolation, which is what
// this is built on top of.
//
// Standard construction: DK = T_1 || T_2 || ... ; T_i = U_1 xor U_2 xor ...
// xor U_c ; U_1 = HMAC(P, S || INT_32_BE(i)) ; U_j = HMAC(P, U_{j-1}).
// Verified byte-exact against a .NET reference at both 1,000 and 210,000
// iterations during the spike.

import { cryptoFramework } from '@kit.CryptoArchitectureKit';

function xorInPlace(a: Uint8Array, b: Uint8Array): void {
  for (let i = 0; i < a.length; i++) {
    a[i] = a[i] ^ b[i];
  }
}

function int32BE(n: number): Uint8Array {
  return new Uint8Array([(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff]);
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

// The SymKey is converted once and reused across every iteration — only
// the message being MAC'd changes — since re-deriving it per call would be
// both unnecessary and slow.
//
// Uses the *Sync* Mac methods (initSync/updateSync/doFinalSync), not the
// async ones - at 210,000 iterations x 3 calls each, the async version's
// per-call promise/native-bridge round-trip overhead (not the actual HMAC
// compute) is what made this look permanently stuck in practice rather
// than just slow; SDK docs note the sync variants exist specifically for
// tight loops like this. That trades away the async version's one real
// advantage (yielding to the event loop between calls, keeping the UI
// thread free) for something that actually finishes. The loop blocks
// whatever thread runs it for seconds, so PassphraseKeyStore runs it in a
// TaskPool worker (see deriveKeyOffThread there), never on the UI thread.
export async function pbkdf2Sha256Manual(password: Uint8Array, salt: Uint8Array, iterations: number, keyLenBytes: number): Promise<Uint8Array> {
  const hLen = 32; // SHA-256 output size
  const blockCount = Math.ceil(keyLenBytes / hLen);

  const keyGen = cryptoFramework.createSymKeyGenerator('HMAC');
  const symKey = await keyGen.convertKey({ data: password });
  const mac = cryptoFramework.createMac('SHA256');

  const dk = new Uint8Array(blockCount * hLen);
  for (let blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
    mac.initSync(symKey);
    mac.updateSync({ data: concatBytes(salt, int32BE(blockIndex)) });
    let u = mac.doFinalSync().data;
    const t = new Uint8Array(u);
    for (let iter = 2; iter <= iterations; iter++) {
      mac.initSync(symKey);
      mac.updateSync({ data: u });
      u = mac.doFinalSync().data;
      xorInPlace(t, u);
    }
    dk.set(t, (blockIndex - 1) * hLen);
  }
  return dk.slice(0, keyLenBytes);
}
