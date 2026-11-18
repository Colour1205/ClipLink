import { describe, it, expect } from '@ohos/hypium';
import { SplitChunk, joinFileChunk, splitFileChunk } from '../main/ets/networking/ChunkSplit';

// ASCII text as bytes and back (everything here is ASCII).
function bytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i);
  return out;
}

function text(data: Uint8Array): string {
  let out = '';
  for (let i = 0; i < data.length; i++) out += String.fromCharCode(data[i]);
  return out;
}

interface Chunk {
  FileHash: string;
  ChunkIndex: number;
  IsLast: boolean;
  DataBase64: string;
}

interface Envelope {
  Type: string;
  Payload: string;
}

const HASH: string = 'ab'.repeat(32);
const DATA: string = 'SGVsbG8sIHdvcmxkIQ+/AAEC==';

// An envelope as this app and Windows write one: JSON inside JSON.
function envelope(chunk: Chunk): string {
  const env: Envelope = { Type: 'file_chunk', Payload: JSON.stringify(chunk) };
  return JSON.stringify(env);
}

function chunk(data: string): Chunk {
  const c: Chunk = { FileHash: HASH, ChunkIndex: 7, IsLast: true, DataBase64: data };
  return c;
}

// What the ordinary path makes of the split's rest, with its data put back.
function rejoin(split: SplitChunk): Chunk {
  const env: Envelope = JSON.parse(text(split.rest)) as Envelope;
  const c: Chunk = JSON.parse(env.Payload) as Chunk;
  c.DataBase64 = text(split.data);
  return c;
}

export default function chunkSplitTest() {
  describe('ChunkSplit', () => {
    it('takesTheBase64OutAsBytes', 0, () => {
      const split: SplitChunk | null = splitFileChunk(bytes(envelope(chunk(DATA))));
      expect(split !== null).assertTrue();
      const back: Chunk = rejoin(split!);
      expect(back.DataBase64).assertEqual(DATA);
      expect(back.FileHash).assertEqual(HASH);
      expect(back.ChunkIndex).assertEqual(7);
      expect(back.IsLast).assertTrue();
      // The rest reads as the same chunk with no data.
      const env: Envelope = JSON.parse(text(split!.rest)) as Envelope;
      expect((JSON.parse(env.Payload) as Chunk).DataBase64).assertEqual('');
    });

    it('findsTheKeyWhereverItIs', 0, () => {
      const first: string = `{"Type":"file_chunk","Payload":"{\\"DataBase64\\":\\"${DATA}\\",\\"FileHash\\":\\"${HASH}\\",\\"ChunkIndex\\":7,\\"IsLast\\":true}"}`;
      const split: SplitChunk | null = splitFileChunk(bytes(first));
      expect(split !== null).assertTrue();
      expect(rejoin(split!).DataBase64).assertEqual(DATA);
      expect(rejoin(split!).ChunkIndex).assertEqual(7);
    });

    it('takesAnEmptyChunk', 0, () => {
      const split: SplitChunk | null = splitFileChunk(bytes(envelope(chunk(''))));
      expect(split !== null).assertTrue();
      expect(split!.data.length).assertEqual(0);
    });

    it('leavesEscapedBase64ToTheOrdinaryPath', 0, () => {
      // Android writes '/' as "\/", older Windows builds '+' as "+".
      const android: string = envelope(chunk('AB')).replace('\\"AB\\"', '\\"A\\\\/B\\"');
      expect(splitFileChunk(bytes(android)) === null).assertTrue();
      const windows: string = envelope(chunk('AB')).replace('\\"AB\\"', '\\"A\\\\u002BB\\"');
      expect(splitFileChunk(bytes(windows)) === null).assertTrue();
    });

    it('leavesEverythingElseAlone', 0, () => {
      const entry: Envelope = { Type: 'entry', Payload: '{"DataBase64":"AAAA"}' };
      expect(splitFileChunk(bytes(JSON.stringify(entry))) === null).assertTrue();
      // Spaced another way, or Payload first.
      expect(splitFileChunk(bytes(envelope(chunk(DATA)).replace('"Type":"file_chunk"', '"Type": "file_chunk"'))) === null)
        .assertTrue();
      const payloadFirst: string = `{"Payload":"{\\"DataBase64\\":\\"${DATA}\\"}","Type":"file_chunk"}`;
      expect(splitFileChunk(bytes(payloadFirst)) === null).assertTrue();
      // Cut off inside the Base64.
      const whole: string = envelope(chunk(DATA));
      expect(splitFileChunk(bytes(whole.substring(0, whole.indexOf(DATA) + 5))) === null).assertTrue();
      expect(splitFileChunk(new Uint8Array(0)) === null).assertTrue();
      // A bare quote inside the value: not JSON, which the ordinary path refuses.
      const bare: string = whole.replace(DATA, 'AB"CD');
      expect(splitFileChunk(bytes(bare)) === null).assertTrue();
    });

    it('joinsTheSameBytesJsonStringifyWrites', 0, () => {
      expect(text(joinFileChunk(HASH, 7, true, bytes(DATA)))).assertEqual(envelope(chunk(DATA)));
      const c: Chunk = { FileHash: HASH, ChunkIndex: 0, IsLast: false, DataBase64: '' };
      expect(text(joinFileChunk(HASH, 0, false, new Uint8Array(0)))).assertEqual(envelope(c));
      const split: SplitChunk | null = splitFileChunk(joinFileChunk(HASH, 7, true, bytes(DATA)));
      expect(split !== null && text(split.data) === DATA).assertTrue();
    });

    it('isNotFooledByTheKeyInsideAValue', 0, () => {
      // A string value holding the key's text: its quotes are escaped twice
      // in the envelope, so it is not taken for the key, and the real one is.
      const c: Chunk = chunk(DATA);
      c.FileHash = ',"DataBase64":"QUJD';
      const split: SplitChunk | null = splitFileChunk(bytes(envelope(c)));
      expect(split !== null).assertTrue();
      const back: Chunk = rejoin(split!);
      expect(back.DataBase64).assertEqual(DATA);
      expect(back.FileHash).assertEqual(',"DataBase64":"QUJD');
    });
  });
}
