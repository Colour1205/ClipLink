// A file_chunk envelope taken apart as bytes, so its Base64 never becomes a
// string. Nothing in here touches a socket or a file, so it can be checked on
// its own (see test/ChunkSplit.test.ets).
//
// Why: read the usual way, every chunk made three strings of about 350 KB -
// the decrypted envelope, its Payload and the payload's DataBase64 - and
// ArkTS puts strings that size in the shared heap, which is only collected
// when its 356 MB of space for them is full (measured: a 290 MB file filled
// it twice). Handing the DataBase64 string to Base64Helper is what killed the
// app ("shared heap oom"), as that kept every one of them (see
// Base64Bytes.ets), but even without that they were about a megabyte of
// garbage a chunk, in a heap that waits that long to be collected. The bytes
// the cipher gives back already hold the Base64, so it is handed on as a view
// of them, and only the rest of the envelope, a few hundred bytes, is read as
// JSON.
//
// The wire is unchanged: this only reads it. Anything that isn't spelt the
// way it expects - another Type first, the key spelt or spaced another way,
// any escape inside the Base64 (Android writes '/' as "\/", older Windows
// builds write '+' as "\u002B") - is left to the ordinary path, which reads
// the whole envelope as a string, as before.

import { buffer } from '@kit.ArkTS';

// How a file_chunk envelope starts, as bytes, from Windows (Wire.EnvelopeOfUtf8)
// and from this app (JSON.stringify keeps the order the envelope was made in).
// Another sender's spelling simply goes the ordinary way.
const PREFIX: string = '{"Type":"file_chunk","Payload":"';
// The DataBase64 key inside the Payload, as the envelope spells it (the
// payload's quotes escaped), with the comma or brace before it: a quote after
// a comma or a brace whose backslash is not itself escaped is one of the
// payload's own, so this can only be the key, never text inside a value.
const KEY_AFTER_COMMA: string = ',\\"DataBase64\\":\\"';
const KEY_AFTER_BRACE: string = '{\\"DataBase64\\":\\"';
const BACKSLASH: string = '\\';
const QUOTE: string = '"';

// Whether the bytes hold this ASCII text at `at`.
function matchesAt(bytes: Uint8Array, at: number, text: string): boolean {
  if (at < 0 || at + text.length > bytes.length) return false;
  for (let i = 0; i < text.length; i++) {
    if (bytes[at + i] !== text.charCodeAt(i)) return false;
  }
  return true;
}

// A file_chunk envelope in two parts: `rest`, the envelope's bytes with the
// DataBase64 value left empty (read as JSON as any other envelope is), and
// `data`, the value's Base64 bytes - a view into the decrypted bytes, not a
// copy.
export class SplitChunk {
  rest: Uint8Array;
  data: Uint8Array;

  constructor(rest: Uint8Array, data: Uint8Array) {
    this.rest = rest;
    this.data = data;
  }
}

// The decrypted bytes of one envelope taken apart (see SplitChunk), or null
// when they are not a file_chunk spelt the way this reads: then the whole
// envelope is read as text, as before.
//
// The searching is done by the buffer module over the bytes' own memory: a
// loop over every byte in ArkTS took about 45 ms a chunk on a phone (debug
// build), and brought a 290 MB file down from about 19 to 4 MB/s.
export function splitFileChunk(bytes: Uint8Array): SplitChunk | null {
  if (!matchesAt(bytes, 0, PREFIX)) return null;
  const view: buffer.Buffer = buffer.from(bytes.buffer as ArrayBuffer, bytes.byteOffset, bytes.length);
  let start: number;
  if (matchesAt(bytes, PREFIX.length, KEY_AFTER_BRACE)) {
    // First in the payload, right after its opening brace.
    start = PREFIX.length + KEY_AFTER_BRACE.length;
  } else {
    const key: number = view.indexOf(KEY_AFTER_COMMA, PREFIX.length);
    if (key === -1) return null;
    start = key + KEY_AFTER_COMMA.length;
  }
  // The value runs to the payload's closing quote, escaped: the first
  // backslash after its start must be that quote's. Any other (an escape
  // inside the Base64 - Android writes '/' as "\/", older Windows builds '+'
  // as "\u002B") goes the old way, as does a bare quote before it (not JSON
  // at all, which the old way refuses). With neither, the value's bytes are
  // exactly the string JSON.parse would have made of it.
  const end: number = view.indexOf(BACKSLASH, start);
  if (end === -1 || !matchesAt(bytes, end + 1, QUOTE)) return null;
  if (view.indexOf(QUOTE, start) !== end + 1) return null;
  const rest: Uint8Array = new Uint8Array(bytes.length - (end - start));
  rest.set(bytes.subarray(0, start), 0);
  rest.set(bytes.subarray(end), start);
  return new SplitChunk(rest, bytes.subarray(start, end));
}

// The other way, for sending: the envelope JSON.stringify would make of this
// chunk, as UTF-8 bytes, with `data` (the chunk's Base64, as bytes) put in
// without ever being a string. The small parts are still written by
// JSON.stringify, with DataBase64 left empty, so the bytes are exactly the
// ones it writes; the Base64 alphabet needs no escaping, so it goes in as it
// is, before the empty value's closing quote. (The FileHash is one this side
// stored a file under, so it is hex, and plain ASCII like the rest.)
export function joinFileChunk(fileHash: string, chunkIndex: number, isLast: boolean, data: Uint8Array): Uint8Array {
  const payload: FileChunkFields = { FileHash: fileHash, ChunkIndex: chunkIndex, IsLast: isLast, DataBase64: '' };
  const envelope: EnvelopeFields = { Type: 'file_chunk', Payload: JSON.stringify(payload) };
  const text: string = JSON.stringify(envelope);
  // ...,\"DataBase64\":\"\"}"} - the value goes before the last five.
  const at: number = text.length - 5;
  const out: Uint8Array = new Uint8Array(text.length + data.length);
  for (let i = 0; i < at; i++) out[i] = text.charCodeAt(i);
  out.set(data, at);
  for (let i = at; i < text.length; i++) out[i + data.length] = text.charCodeAt(i);
  return out;
}

interface FileChunkFields {
  FileHash: string;
  ChunkIndex: number;
  IsLast: boolean;
  DataBase64: string;
}

interface EnvelopeFields {
  Type: string;
  Payload: string;
}
