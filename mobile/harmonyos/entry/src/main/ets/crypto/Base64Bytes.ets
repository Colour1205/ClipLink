// util.Base64Helper's promise-form decode (it runs on a worker), never handed
// a string. Given a string, that form costs memory that never comes back, as
// measured on a phone (debug build):
// - its ArkTS wrapper strips line breaks with src.replace(/[\r\n]/g, ''), and
//   the engine's RegExp cache keeps the string it was run on: a heap snapshot
//   taken part-way through a 290 MB file held 514 of the chunks' Base64
//   strings, 175 MB, held by GlobalEnv's RegExpCache, and the
//   app died soon after with the shared heap out of memory;
// - the native side copies the string for its worker and never frees the
//   copy: about 0.39 MB of native heap lost for every 350 KB string decoded
//   (1500 decodes took it from 75 to 658 MB, and it stayed there).
// Neither happens for bytes (400 decodes of a 466 KB line left nothing
// behind), and Base64 is ASCII, so its UTF-8 bytes are the same characters.

import { util } from '@kit.ArkTS';
import { releaseBuffer } from '../networking/FreeOnWorker';

const base64Helper = new util.Base64Helper();
const encoder = util.TextEncoder.create('utf-8');

//
// A string's bytes are made here, and freed here once decoded (see
// SpentBuffers): an older sender's file chunk comes as a string, hundreds a
// second.
export async function decodeBase64(base64: string | Uint8Array): Promise<Uint8Array> {
  if (typeof base64 !== 'string') return base64Helper.decode(base64);
  const bytes: Uint8Array = encoder.encodeInto(base64);
  try {
    return await base64Helper.decode(bytes);
  } finally {
    releaseBuffer(bytes.buffer as ArrayBuffer);
  }
}
