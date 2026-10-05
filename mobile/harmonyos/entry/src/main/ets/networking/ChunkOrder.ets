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
//               or begun before this run), or the rest of an older
//               connection's stream that a newer one has taken over.
//   'abandon' - a gap in the transfer under way: it can never hash right.
export type ChunkPlace = 'start' | 'write' | 'restart' | 'ignore' | 'abandon';

// underWay: a transfer of this file from this peer exists; sameConnection:
// it's arriving on the connection this chunk came on; nextIndex: the chunk
// it expects next.
export function placeChunk(underWay: boolean, sameConnection: boolean, nextIndex: number,
  chunkIndex: number): ChunkPlace {
  if (!underWay) return chunkIndex === 0 ? 'start' : 'ignore';
  if (sameConnection && chunkIndex === nextIndex) return 'write';
  if (chunkIndex === 0) return 'restart';
  return sameConnection ? 'abandon' : 'ignore';
}
