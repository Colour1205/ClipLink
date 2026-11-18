// Step 6 of the build order in ../../../../README.md: handshake + session
// encryption. Matches PeerConnection.cs's Encrypt/Decrypt exactly: packed
// = nonce(12) || tag(16) || ciphertext, AES-256-GCM. The Base64 around it is
// PeerConnection.ets's, which keeps the packed bytes in hand to tell its own
// lines by their nonce (see nonceKey there).
//
// GENUINE UNKNOWN going in: this SDK's Cipher interface has no getAuthTag()
// method (unlike some blog examples referencing a different SDK version) -
// GcmParamsSpec.authTag is a *required* field even in the type declaration.
// Working hypothesis, to be confirmed by the self round-trip diagnostic:
// doFinal() for ENCRYPT_MODE returns ciphertext with the tag appended
// (ciphertext || tag), and authTag in the init() params is only meaningful
// for DECRYPT_MODE (a placeholder value is passed at encrypt time since the
// type requires *a* DataBlob regardless of mode).

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { releaseBuffer } from '../networking/FreeOnWorker';

export const NONCE_SIZE = 12;
const TAG_SIZE = 16;

const decoder = util.TextDecoder.create('utf-8');

// See Signing.ets's stringToBytes for the full explanation - this was the
// SAME bug (truncating UTF-16 code units into single bytes instead of real
// UTF-8 encoding), but here it's worse: it corrupted the actual PLAINTEXT
// fed into AES-GCM encryption for any message containing a non-ASCII
// character, not just a signature check. Encryption/decryption still
// "succeeded" (the auth tag is self-consistent with whatever bytes were
// actually encrypted), so this failed silently further downstream instead
// of as a decrypt error - typically as a JSON parse failure on the
// now-corrupted decrypted string, causing the whole message to be
// silently dropped.
const textEncoder = util.TextEncoder.create('utf-8');
function utf8Bytes(s: string): Uint8Array {
  return textEncoder.encodeInto(s);
}

function randomBytes(len: number): Uint8Array {
  return cryptoFramework.createRandom().generateRandomSync(len).data;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, p) => sum + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

// The session key as the cipher takes it. Made once per connection (see
// PeerConnection.create) and used for every envelope after: converting it
// again for each one - a ping each way every 3 s, hundreds of file chunks
// for a big file - cost two native round trips that did no new work. Only
// the key is shared; every envelope still gets a fresh random nonce and a
// cipher of its own.
export async function importSessionKey(sessionKey: Uint8Array): Promise<cryptoFramework.SymKey> {
  const keyGen = cryptoFramework.createSymKeyGenerator('AES256');
  return keyGen.convertKey({ data: sessionKey });
}

// One line's bytes before the Base64: nonce || tag || ciphertext.
export async function encryptPacked(symKey: cryptoFramework.SymKey, plaintext: string): Promise<Uint8Array> {
  const bytes: Uint8Array = utf8Bytes(plaintext);
  const packed: Uint8Array = await encryptPackedBytes(symKey, bytes);
  // A history batch is megabytes, freed now rather than whenever this
  // thread's collector next runs (see SpentBuffers).
  releaseBuffer(bytes.buffer as ArrayBuffer);
  return packed;
}

// encryptPacked for a message that is UTF-8 bytes already.
export async function encryptPackedBytes(symKey: cryptoFramework.SymKey, plaintext: Uint8Array): Promise<Uint8Array> {
  const nonce = randomBytes(NONCE_SIZE);

  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  const params: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: nonce },
    aad: { data: new Uint8Array(0) },
    authTag: { data: new Uint8Array(TAG_SIZE) }, // placeholder - unused for encrypt, see file header
  };
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
  const output = await cipher.doFinal({ data: plaintext });

  // Working hypothesis: output.data = ciphertext || tag (16 bytes at the end).
  // Views, not copies: concatBytes copies them into the packed line anyway,
  // and a file chunk's ciphertext is about 350 KB.
  const outBytes = output.data;
  const cipherBytes = outBytes.subarray(0, outBytes.length - TAG_SIZE);
  const tag = outBytes.subarray(outBytes.length - TAG_SIZE);

  const packed: Uint8Array = concatBytes([nonce, tag, cipherBytes]);
  // The cipher's own output, copied into packed: freed now (see SpentBuffers).
  releaseBuffer(outBytes.buffer as ArrayBuffer);
  return packed;
}

// A line already decoded from its Base64. Throws if it's too short to hold
// a nonce and a tag (as Windows' and Android's Decrypt do), or was forged,
// corrupted or sealed with another key.
export async function decryptPacked(symKey: cryptoFramework.SymKey, packed: Uint8Array): Promise<string> {
  return decoder.decodeToString(await decryptPackedBytes(symKey, packed));
}

// decryptPacked's plaintext as the UTF-8 bytes the cipher gave back.
export async function decryptPackedBytes(symKey: cryptoFramework.SymKey, packed: Uint8Array): Promise<Uint8Array> {
  if (packed.length < NONCE_SIZE + TAG_SIZE) {
    throw new Error('packed message too short');
  }
  // Views, not copies: the cipher honours a view's offset into a bigger
  // buffer (checked on a phone: a line placed at an offset inside a larger
  // buffer decrypted, tag and all, to the same text). A copy cost about
  // 350 KB per file chunk, garbage the collector has to catch up with. The
  // cipher is still made per line, not kept per connection: re-initialising
  // one after doFinal is not proven here, and a failure would end every
  // connection.
  const nonce = packed.subarray(0, NONCE_SIZE);
  const tag = packed.subarray(NONCE_SIZE, NONCE_SIZE + TAG_SIZE);
  const cipherBytes = packed.subarray(NONCE_SIZE + TAG_SIZE);

  const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
  const params: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: nonce },
    aad: { data: new Uint8Array(0) },
    authTag: { data: tag },
  };
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
  const output = await cipher.doFinal({ data: cipherBytes });
  return output.data;
}
