// Newline framing for PeerConnection's TcpLineChannel: socket bytes in,
// complete lines out (without their '\n'), for the whole connection,
// handshake and session alike. Nothing in here touches a socket, so it can be
// checked on its own (see test/LineFramer.test.ets).
//
// Each byte is searched for a newline once, and a line arriving in pieces is
// joined once, when it's complete. The old buffer was copied whole on every
// socket message and searched from its start each time - quadratic, on the UI
// thread - and had no cap (docs/security.md #3). Now, as iOS's LineFramer:
// - until the first line (always the handshake) is complete, at most
//   FIRST_LINE_MAX_BYTES are held - an unpaired stranger on the LAN can't
//   pin more than that per connection. Past it, push returns null and the
//   connection is closed;
// - after that, a line over MAX_LINE_BYTES is dropped as it arrives, and
//   framing picks up again after its newline. Not fatal: the other ports
//   have no cap and resend the same history batch on every reconnect, so
//   closing would only loop.

import { buffer } from '@kit.ArkTS';

export const FIRST_LINE_MAX_BYTES = 64 * 1024;
export const MAX_LINE_BYTES = 192 * 1024 * 1024;

const NEWLINE_TEXT = '\n';

// Where the next '\n' at or after `from` is, or -1. Searched through the
// buffer module, as text: Uint8Array.indexOf took 22 to 43 ms per MB on a
// phone (measured, debug build), and a 16 MB history batch arrives as
// hundreds of chunks, each searched as it comes - 0.4 to 0.9 s of the UI
// thread in all, against 1.3 ms per MB this way. The byte must be given as
// the one-character string: Buffer.indexOf given the number 10 was slower
// still (115 ms per MB). buffer.from over the chunk's own memory copies
// nothing, and 0x0A is never inside a multi-byte UTF-8 character, so the
// byte found is always a line's end.
function findNewline(chunk: Uint8Array, from: number): number {
  if (from >= chunk.length) return -1;
  const view: buffer.Buffer = buffer.from(chunk.buffer as ArrayBuffer, chunk.byteOffset + from, chunk.length - from);
  const at: number = view.indexOf(NEWLINE_TEXT);
  return at === -1 ? -1 : from + at;
}

export class LineFramer {
  private readonly firstLineMaxBytes: number;
  private readonly maxLineBytes: number;
  // The line still arriving, in pieces, and their total length.
  private parts: Uint8Array[] = [];
  private partBytes: number = 0;
  private sawFirstLine: boolean = false;
  // Dropping the rest of an over-long line, up to its newline.
  private discarding: boolean = false;
  // The first line went over its cap: this connection is done.
  private refused: boolean = false;
  // Lines dropped for being over MAX_LINE_BYTES.
  droppedLines: number = 0;

  constructor(maxLineBytes: number = MAX_LINE_BYTES, firstLineMaxBytes: number = FIRST_LINE_MAX_BYTES) {
    this.maxLineBytes = maxLineBytes;
    this.firstLineMaxBytes = Math.min(firstLineMaxBytes, maxLineBytes);
  }

  // Bytes of a line that hasn't finished arriving.
  get bufferedBytes(): number {
    return this.partBytes;
  }

  // The lines this chunk completes, each a copy of its own; null once the
  // first line is over its cap (close the connection - nothing more comes
  // out of here after that).
  push(chunk: Uint8Array): Uint8Array[] | null {
    if (this.refused) return null;
    const lines: Uint8Array[] = [];
    let start = 0;
    while (start < chunk.length) {
      const newline: number = findNewline(chunk, start);
      const end: number = newline === -1 ? chunk.length : newline;
      if (!this.discarding && end > start) {
        if (this.partBytes + (end - start) > (this.sawFirstLine ? this.maxLineBytes : this.firstLineMaxBytes)) {
          this.parts = [];
          this.partBytes = 0;
          if (!this.sawFirstLine) {
            this.refused = true;
            return null;
          }
          this.discarding = true;
          this.droppedLines++;
        } else {
          this.parts.push(chunk.slice(start, end));
          this.partBytes += end - start;
        }
      }
      if (newline === -1) break;
      if (this.discarding) {
        this.discarding = false;
      } else {
        const line: Uint8Array = this.takeLine();
        // An empty line is passed on (the handshake fails on it) but lifts
        // no cap.
        if (line.length > 0) this.sawFirstLine = true;
        lines.push(line);
      }
      start = newline + 1;
    }
    return lines;
  }

  private takeLine(): Uint8Array {
    const line: Uint8Array = this.parts.length === 1 ? this.parts[0] : new Uint8Array(this.partBytes);
    if (this.parts.length > 1) {
      let at = 0;
      for (const part of this.parts) {
        line.set(part, at);
        at += part.length;
      }
    }
    this.parts = [];
    this.partBytes = 0;
    return line;
  }
}
