import { describe, it, expect } from '@ohos/hypium';
import { ChunkPlace, placeChunk } from '../main/ets/networking/ChunkOrder';

// One file_chunk of one peer's stream of one file: the connection it came
// on, and its ChunkIndex.
interface Chunk {
  conn: string;
  index: number;
}

function c(conn: string, index: number): Chunk {
  const chunk: Chunk = { conn: conn, index: index };
  return chunk;
}

// Plays chunks through placeChunk, keeping the transfer the way
// SyncManager.handleFileChunk does: 'start' and 'restart' begin one on that
// chunk's connection, every chunk taken moves it on, and 'abandon' ends it.
// The places, space-separated.
function play(chunks: Chunk[]): string {
  let underWay = false;
  let owner = '';
  let nextIndex = 0;
  const places: string[] = [];
  for (const chunk of chunks) {
    const place: ChunkPlace = placeChunk(underWay, underWay && owner === chunk.conn, nextIndex, chunk.index);
    places.push(place);
    if (place === 'start' || place === 'restart') {
      underWay = true;
      owner = chunk.conn;
      nextIndex = 1;
    } else if (place === 'write') {
      nextIndex++;
    } else if (place === 'abandon') {
      underWay = false;
    }
  }
  return places.join(' ');
}

export default function chunkOrderTest() {
  describe('ChunkOrder', () => {
    it('takesAStreamInOrder', 0, () => {
      expect(play([c('a', 0), c('a', 1), c('a', 2)])).assertEqual('start write write');
      // An empty file's one and only chunk.
      expect(play([c('a', 0)])).assertEqual('start');
    });

    it('ignoresAStreamItNeverSawStart', 0, () => {
      expect(play([c('a', 3), c('a', 4), c('a', 0), c('a', 1)])).assertEqual('ignore ignore start write');
    });

    it('startsOverWhenItsSenderDoes', 0, () => {
      // A transfer cut off part-way, then the same file sent again: the new
      // stream's bytes never land after the old one's.
      expect(play([c('a', 0), c('a', 1), c('a', 2), c('a', 0), c('a', 1)]))
        .assertEqual('start write write restart write');
    });

    it('letsANewerConnectionTakeOver', 0, () => {
      // The same peer reconnected and streams the file again, while the old
      // connection's chunks are still coming in.
      expect(play([c('a', 0), c('a', 1), c('b', 0), c('a', 2), c('b', 1), c('a', 3), c('b', 2)]))
        .assertEqual('start write restart ignore write ignore write');
    });

    it('abandonsAStreamWithAGap', 0, () => {
      expect(play([c('a', 0), c('a', 2), c('a', 3)])).assertEqual('start abandon ignore');
      // A chunk repeated is out of order too.
      expect(play([c('a', 0), c('a', 1), c('a', 1), c('a', 2)])).assertEqual('start write abandon ignore');
    });
  });
}
