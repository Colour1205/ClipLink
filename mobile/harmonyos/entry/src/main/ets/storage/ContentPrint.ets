// What a piece of content IS, apart from who copied it and when: the "print"
// that design/sync-dedupe-spec.md compares to tell an echo or a twin from a new
// copy. Every platform makes the same prints (Windows ContentPrint.cs, Android
// ContentPrint.kt, iOS ContentPrint.swift), but nothing here goes on the wire
// or into the history: they only decide what to send, what to put on the
// clipboard and which card to show. Plain code, so entry/src/test can run it.
//
//   t: + sha256(UTF-8 of norm(text))   text
//   i: + sha256(the picture's bytes)   an image entry's Base64, decoded
//   f: + lowercase(FileHash)           a file
//   x: + a lowercase raw hash          an older build's single hash (never
//                                      written by this app: older HarmonyOS
//                                      builds kept theirs in memory only)

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';
import { entryKey } from './DeletedEntries';
import { FilePayload } from './FilePayload';
import { decodeBase64 } from '../crypto/Base64Bytes';

const base64Helper = new util.Base64Helper();
const FILE_HASH: RegExp = new RegExp('^[0-9A-Fa-f]{64}$');

// The text as it is compared, never as it is sent, stored or put on the
// clipboard: CRLF and CR become LF, then one trailing LF goes. An app that
// rewrites line endings, or a whole-line copy that adds one, is then still the
// same text.
export function norm(text: string): string {
  const unified: string = text.replace(new RegExp('\r\n', 'g'), '\n').replace(new RegExp('\r', 'g'), '\n');
  return unified.endsWith('\n') ? unified.substring(0, unified.length - 1) : unified;
}

// UTF-8 by hand: the local unit-test runtime's TextEncoder is a stub, and the
// prints have to be right in the tests too.
export function utf8(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c: number = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const low: number = s.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c < 0x10000) {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else {
      out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  return new Uint8Array(out);
}

// ---- SHA-256 ----------------------------------------------------------------
//
// The system's digest, synchronous, so a card's key is ready when the card is
// built. The local unit-test runtime stubs the crypto framework, so the first
// call checks it against a known answer and, if it is not the real one, uses
// the plain implementation below instead (slow for a big picture, which only
// ever happens in the tests).

const ABC_SHA256: string = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
let systemDigestWorks: boolean | null = null;

function hex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

function systemSha256(data: Uint8Array): string | null {
  try {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: data });
    return hex(md.digestSync().data);
  } catch (e) {
    return null;
  }
}

const K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function rotr(x: number, n: number): number {
  return (x >>> n) | (x << (32 - n));
}

function plainSha256(data: Uint8Array): string {
  const bitLength: number = data.length * 8;
  const padded: number = ((data.length + 9 + 63) >> 6) << 6;
  const bytes: Uint8Array = new Uint8Array(padded);
  bytes.set(data);
  bytes[data.length] = 0x80;
  // The length as 64 bits, big-endian; nothing here comes near 2^53 bits.
  const high: number = Math.floor(bitLength / 0x100000000);
  for (let i = 0; i < 4; i++) {
    bytes[padded - 8 + i] = (high >>> (24 - 8 * i)) & 0xff;
    bytes[padded - 4 + i] = (bitLength >>> (24 - 8 * i)) & 0xff;
  }
  const h: number[] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const w: number[] = new Array<number>(64).fill(0);
  for (let block = 0; block < padded; block += 64) {
    for (let i = 0; i < 16; i++) {
      const at: number = block + i * 4;
      w[i] = ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) | 0;
    }
    for (let i = 16; i < 64; i++) {
      const s0: number = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1: number = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let a: number = h[0];
    let b: number = h[1];
    let c: number = h[2];
    let d: number = h[3];
    let e: number = h[4];
    let f: number = h[5];
    let g: number = h[6];
    let k: number = h[7];
    for (let i = 0; i < 64; i++) {
      const t1: number = (k + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0;
      const t2: number = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
      k = g;
      g = f;
      f = e;
      e = (d + t1) | 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) | 0;
    }
    h[0] = (h[0] + a) | 0;
    h[1] = (h[1] + b) | 0;
    h[2] = (h[2] + c) | 0;
    h[3] = (h[3] + d) | 0;
    h[4] = (h[4] + e) | 0;
    h[5] = (h[5] + f) | 0;
    h[6] = (h[6] + g) | 0;
    h[7] = (h[7] + k) | 0;
  }
  let out = '';
  for (const word of h) {
    out += (word >>> 0).toString(16).padStart(8, '0');
  }
  return out;
}

// Lowercase hex.
export function sha256Hex(data: Uint8Array): string {
  if (systemDigestWorks === null) systemDigestWorks = systemSha256(utf8('abc')) === ABC_SHA256;
  if (systemDigestWorks) {
    const digest: string | null = systemSha256(data);
    if (digest !== null) return digest;
  }
  return plainSha256(data);
}

// ---- Base64, for an image entry's bytes ----------------------------------

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
let systemBase64Works: boolean | null = null;

// The plain decoder, for the same stubbed runtime: null for text that is not
// Base64.
function plainBase64(s: string): Uint8Array | null {
  const clean: string = s.replace(new RegExp('[\\s]', 'g'), '');
  if (clean.length % 4 !== 0) return null;
  const pad: number = clean.endsWith('==') ? 2 : (clean.endsWith('=') ? 1 : 0);
  const out: Uint8Array = new Uint8Array(clean.length / 4 * 3 - pad);
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    let bits = 0;
    for (let j = 0; j < 4; j++) {
      const ch: string = clean.charAt(i + j);
      const v: number = ch === '=' && i + 4 === clean.length && j >= 4 - pad ? 0 : BASE64_ALPHABET.indexOf(ch);
      if (v < 0) return null;
      bits = (bits << 6) | v;
    }
    if (o < out.length) out[o++] = (bits >> 16) & 0xff;
    if (o < out.length) out[o++] = (bits >> 8) & 0xff;
    if (o < out.length) out[o++] = bits & 0xff;
  }
  return out;
}

function systemBase64(): boolean {
  if (systemBase64Works === null) {
    try {
      systemBase64Works = base64Helper.encodeToStringSync(new Uint8Array([102, 111, 111])) === 'Zm9v';
    } catch (e) {
      systemBase64Works = false;
    }
  }
  return systemBase64Works;
}

function base64Bytes(s: string): Uint8Array | null {
  if (!systemBase64()) return plainBase64(s);
  try {
    return base64Helper.decodeSync(s);
  } catch (e) {
    return null;
  }
}

// ---- prints ---------------------------------------------------------------

export function textPrint(text: string): string {
  return `t:${sha256Hex(utf8(norm(text)))}`;
}

// sha256 of the exact text, unnormalised: what an older build's single hash
// held, for an x: print (see printsMatch).
export function rawTextHash(text: string): string {
  return sha256Hex(utf8(text));
}

export function imagePrint(bytes: Uint8Array): string {
  return `i:${sha256Hex(bytes)}`;
}

// Only a real hash makes one: anything else never matches anything.
export function filePrint(fileHash: string): string | null {
  return typeof fileHash === 'string' && FILE_HASH.test(fileHash) ? `f:${fileHash.toLowerCase()}` : null;
}

// Worked out once per entry (an image's means decoding megabytes): by entry
// key, dropped wholesale once it holds far more than any list shows.
const keyCache: Map<string, string | null> = new Map<string, string | null>();
const KEY_CACHE_MAX = 400;

function computeKey(entry: ClipboardEntry): string | null {
  if (entry.Type === 'text') return textPrint(entry.Content);
  if (entry.Type === 'image') {
    const bytes: Uint8Array | null = base64Bytes(entry.Content);
    return bytes === null || bytes.length === 0 ? null : imagePrint(bytes);
  }
  if (entry.Type === 'file') {
    try {
      const payload: FilePayload = JSON.parse(entry.Content) as FilePayload;
      return payload === null || payload === undefined ? null : filePrint(payload.FileHash);
    } catch (e) {
      return null;
    }
  }
  return null;
}

// The print of an entry's content, or null (an unknown type, a picture that
// is not Base64, a file whose descriptor is no good): null never matches.
export function contentKey(entry: ClipboardEntry): string | null {
  const key: string = entryKey(entry);
  if (keyCache.has(key)) return keyCache.get(key) ?? null;
  const print: string | null = computeKey(entry);
  remember(key, print);
  return print;
}

function remember(key: string, print: string | null): void {
  if (keyCache.size >= KEY_CACHE_MAX) keyCache.clear();
  keyCache.set(key, print);
}

// Works out the pictures' keys before the list asks for them, decoding and
// hashing off the UI thread (the promise forms run on a worker). contentKey
// is synchronous, so the list would otherwise decode every picture of a peer's
// history batch on the UI thread as the cards are made: about 0.4 s for 25
// screenshots, at the moment the batch comes in (see the README's UI thread
// notes). Text and files are cheap and are left to contentKey. Best effort:
// what fails here, contentKey works out itself.
export async function primeContentKeys(entries: ClipboardEntry[]): Promise<void> {
  if (!systemBase64() || systemDigestWorks === false) return;
  for (const entry of entries) {
    if (entry.Type !== 'image') continue;
    const key: string = entryKey(entry);
    if (keyCache.has(key)) continue;
    try {
      const bytes: Uint8Array = await decodeBase64(entry.Content);
      if (bytes.length === 0) continue;
      const md = cryptoFramework.createMd('SHA256');
      await md.update({ data: bytes });
      const digest: string = hex((await md.digest()).data);
      // Checked like the synchronous digest is before it is trusted.
      if (systemDigestWorks === null) systemDigestWorks = systemSha256(utf8('abc')) === ABC_SHA256;
      if (!systemDigestWorks) return;
      remember(key, `i:${digest}`);
    } catch (e) {
      // left to contentKey
    }
  }
}

// Whether a capture with these prints (and this raw hash: sha256 of the exact
// text or picture, or the lowercase file hash) is one of `known`. An x: print
// from an older build matches the raw hash, as that build's single hash did.
export function printsMatch(known: string[], prints: string[], rawHash: string): boolean {
  for (const print of known) {
    if (print.startsWith('x:')) {
      if (rawHash.length > 0 && print.substring(2) === rawHash.toLowerCase()) return true;
    } else if (prints.includes(print)) {
      return true;
    }
  }
  return false;
}

// The content keys of the n newest entries by time (canonical timestamps, as
// the trim compares them), with every entry tied at the boundary included.
export function newestKeys(history: ClipboardEntry[], n: number): Set<string> {
  const keys: Set<string> = new Set<string>();
  if (n <= 0 || history.length === 0) return keys;
  const stamps: string[] = history.map((entry: ClipboardEntry) => canonicalTimestamp(entry.Timestamp))
    .sort((a: string, b: string) => (a < b ? 1 : (a > b ? -1 : 0)));
  const boundary: string = stamps[Math.min(n, stamps.length) - 1];
  for (const entry of history) {
    if (canonicalTimestamp(entry.Timestamp) < boundary) continue;
    const key: string | null = contentKey(entry);
    if (key !== null) keys.add(key);
  }
  return keys;
}

export function historyKeys(history: ClipboardEntry[]): Set<string> {
  const keys: Set<string> = new Set<string>();
  for (const entry of history) {
    const key: string | null = contentKey(entry);
    if (key !== null) keys.add(key);
  }
  return keys;
}

function anyIn(prints: string[], keys: Set<string>): boolean {
  return prints.some((print: string) => keys.has(print));
}

// ---- echo suppression (rule 1 of the spec) ----------------------------------

// How a capture started: the on-open capture (auto) or a Paste tap (manual).
export type CaptureMode = 'auto' | 'manual';
export type CaptureVerdict = 'already' | 'read' | 'new';

// What this device believes is on its clipboard because of ClipLink: the
// prints of the last thing it wrote there or the last capture it classified,
// and the pasteboard's change count just after its last write (-1: none).
// Kept until replaced (DeviceSettings' lastWrite).
export interface LastWrite {
  prints: string[];
  count: number;
}

export function emptyLastWrite(): LastWrite {
  return { prints: [], count: -1 };
}

// The stored record, or an empty one for anything that is not one (none was
// stored before this build).
export function parseLastWrite(json: string): LastWrite {
  try {
    const raw: LastWrite = JSON.parse(json) as LastWrite;
    if (raw === null || raw === undefined || typeof raw !== 'object' || !Array.isArray(raw.prints)) return emptyLastWrite();
    const prints: string[] = raw.prints.filter((p: string) => typeof p === 'string' && p.length > 2);
    const count: number = typeof raw.count === 'number' && isFinite(raw.count) ? raw.count : -1;
    return { prints: prints, count: count };
  } catch (e) {
    return emptyLastWrite();
  }
}

// Step 1, before anything is read: the clipboard still holds ClipLink's own
// last write (the change count says so). An auto capture is then never news;
// a Paste tap is only news when that content is gone from the history - the
// user deleted it and is pasting it again - and then it is read ('read').
export function classifyOwnWrite(mode: CaptureMode, lastWrite: LastWrite, history: Set<string>): CaptureVerdict {
  if (mode === 'auto' || anyIn(lastWrite.prints, history)) return 'already';
  return 'read';
}

// Steps 3 to 5, after the read: what ClipLink last wrote or classified (on a
// Paste tap only while that content is still in the history), or what the
// newest entry already holds, is not sent again. An older entry's content is
// a deliberate re-copy, and goes out.
export function classifyRead(mode: CaptureMode, prints: string[], rawHash: string, lastWrite: LastWrite,
  history: Set<string>, newest: Set<string>): CaptureVerdict {
  if (printsMatch(lastWrite.prints, prints, rawHash) && (mode === 'auto' || anyIn(prints, history))) return 'already';
  if (anyIn(prints, newest)) return 'already';
  return 'new';
}
