// One session line opened: its Base64 decoded, the envelope inside decrypted
// and, for a file chunk, the chunk's own Base64 decoded too (see ChunkSplit).
// PeerConnection's read loop opens a few lines at once and takes them back in
// order. The decoding and the decryption run on the helpers' own threads
// (their promise forms); only the small steps in between run here.
//
// Every buffer made on the way is freed as soon as it is used up (see
// SpentBuffers): a file chunk passes through about 2 MB of them, and this
// thread's collector does not run at all for the app's first seconds.
//
// (Opening lines in TaskPool workers instead was measured too: no faster -
// a phone receiving a 290 MB file waits on the link, not on decoding - and
// the workers' own collectors left up to 470 MB of spent buffers about.)

import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import * as AesGcm from '../crypto/AesGcm';
import { SplitChunk, splitFileChunk } from './ChunkSplit';
import { releaseBuffer } from './FreeOnWorker';

const base64Helper = new util.Base64Helper();

// What a line came to. envelope: the decrypted envelope's UTF-8 bytes, or for
// a file chunk the envelope with DataBase64 left empty, and then data holds
// the chunk's bytes, decoded. A file chunk whose Base64 does not decode comes
// back whole, as any other envelope, for SyncManager to refuse as before.
// Both are buffers of their own, for the caller to free once used.
export interface OpenedLine {
  nonce: string | null;
  envelope: Uint8Array;
  data: Uint8Array | null;
}

// What PeerConnection's sentNonces keeps a line by: its nonce - the first
// AesGcm.NONCE_SIZE of its packed nonce || tag || ciphertext bytes - in hex.
// The decoded bytes, as Windows and Android keep them, never the line's text:
// a decoder may take more than one spelling of the same bytes (whitespace in
// them, or a character outside the alphabet read as some other), so an echo
// of one of our lines spelt another way would miss a text match and still
// decrypt. null for bytes too short to hold a nonce, which decryptPacked
// refuses.
export function nonceKey(packed: Uint8Array): string | null {
  if (packed.length < AesGcm.NONCE_SIZE) return null;
  let key = '';
  for (let i = 0; i < AesGcm.NONCE_SIZE; i++) {
    key += packed[i].toString(16).padStart(2, '0');
  }
  return key;
}

// These bytes in a buffer of their own: theirs when they fill it, otherwise
// a copy (and the buffer they were in is freed).
function own(bytes: Uint8Array, release: (buffer: ArrayBuffer) => void): Uint8Array {
  if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) return bytes;
  const copy: Uint8Array = bytes.slice();
  release(bytes.buffer as ArrayBuffer);
  return copy;
}

function decodeWithHelper(data: Uint8Array): Promise<Uint8Array> {
  return base64Helper.decode(data);
}

// Throws for a line that is not Base64 or does not decrypt: the connection
// is then ended, as before. The line's buffer must be its own (see
// LineFramer.push): it is freed here.
export async function openLine(line: Uint8Array, symKey: cryptoFramework.SymKey): Promise<OpenedLine> {
  let packed: Uint8Array;
  try {
    packed = await base64Helper.decode(line);
  } finally {
    releaseBuffer(line.buffer as ArrayBuffer);
  }
  const nonce: string | null = nonceKey(packed);
  let plain: Uint8Array;
  try {
    plain = await AesGcm.decryptPackedBytes(symKey, packed);
  } finally {
    releaseBuffer(packed.buffer as ArrayBuffer);
  }
  return openPlain(plain, nonce);
}

// openLine once the line is decrypted: a file chunk split and its Base64
// decoded (see ChunkSplit), anything else handed on as it is. plain is this
// call's to free. decode and release are the real ones but for the tests
// (see test/LineOpener.test.ets), which have no Base64Helper worker.
export async function openPlain(plain: Uint8Array, nonce: string | null,
  decode: (data: Uint8Array) => Promise<Uint8Array> = decodeWithHelper,
  release: (buffer: ArrayBuffer) => void = releaseBuffer): Promise<OpenedLine> {
  const split: SplitChunk | null = splitFileChunk(plain);
  if (split !== null) {
    let data: Uint8Array | null = null;
    try {
      // An empty file's only chunk is empty (see SyncManager.streamFileToPeer).
      data = split.data.length === 0 ? new Uint8Array(0) : await decode(split.data);
    } catch (e) {
      // not Base64: handed on whole, below
    }
    if (data !== null) {
      // split.rest is a copy of its own (see ChunkSplit), and data was decoded
      // out of plain: plain is spent.
      release(plain.buffer as ArrayBuffer);
      const opened: OpenedLine = { nonce: nonce, envelope: split.rest, data: own(data, release) };
      return opened;
    }
  }
  const opened: OpenedLine = { nonce: nonce, envelope: own(plain, release), data: null };
  return opened;
}
