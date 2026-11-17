// Where one file_chunk fits in its stream - SyncManager.handleFileChunk's
// bookkeeping, worked out from the transfer already under way for that peer
// and file, if any. Nothing in here touches a socket or a file, so it can be
// checked on its own (see test/ChunkOrder.test.ets).
//
// A stream always starts at chunk 0 and counts up by one, on every platform,
// and nobody resumes one: a sender that's cut off, or asked again, starts
// over at 0. So:
//   'start'   - chunk 0, nothing under way: a new transfer starts with it.
//   'write'   - the next chunk of the transfer under way, on its connection.
//   'restart' - chunk 0 while a transfer is under way: its sender (or the
//               sender's newer connection) started over, so the old bytes
//               go and a new transfer starts with this chunk - never
//               appended to them.
//   'ignore'  - the middle of a stream this side never saw start (cut off,
//               or begun before this run), the rest of an older
//               connection's stream that a newer one has taken over, or a
//               second sender's stream of a file another sender's stream is
//               already bringing (see otherSender).
//   'abandon' - a gap in the transfer under way: it can never hash right.
export type ChunkPlace = 'start' | 'write' | 'restart' | 'ignore' | 'abandon';

// underWay: a transfer of this file from this peer exists; sameConnection:
// it's arriving on the connection this chunk came on; nextIndex: the chunk
// it expects next. otherSender: another peer's stream of this same file is
// under way. A receiver takes one stream per file, the first, as Windows,
// Android and iOS do: a file_request goes to every peer, and decoding and
// writing the same file twice at once only halved the speed of both. The
// second sender is not told anything (nothing on the wire changes); its
// chunks are dropped unread, and when its stream ends it may be asked again
// if the first one came to nothing (see SyncManager.handleFileChunk).
export function placeChunk(underWay: boolean, sameConnection: boolean, nextIndex: number,
  chunkIndex: number, otherSender: boolean = false): ChunkPlace {
  if (!underWay) return chunkIndex === 0 && !otherSender ? 'start' : 'ignore';
  if (sameConnection && chunkIndex === nextIndex) return 'write';
  if (chunkIndex === 0) return 'restart';
  return sameConnection ? 'abandon' : 'ignore';
}
