import { describe, it, expect } from '@ohos/hypium';
import { ClipboardEntry, MAX_ENTRY_NAME_LENGTH, entryNameOf, signedText, storedEntry, withoutLoneSurrogates } from '../main/ets/crypto/Signing';
import { pictureCacheFolder, pictureExtension, pictureFileName, pictureStem } from '../main/ets/storage/PictureNames';

const PNG: Uint8Array = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);
const JPEG: Uint8Array = new Uint8Array([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]);
const GIF: Uint8Array = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0, 0, 0, 0, 0]);
const WEBP: Uint8Array = new Uint8Array([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50]);
const FALLBACK: string = 'Image from Laptop 2026-11-17 10.05';
const FOLDER: RegExp = new RegExp('^[0-9a-f]{14}$');

// An entry as it arrives on the wire, parsed the way SyncManager parses one.
function wire(json: string): ClipboardEntry {
  return JSON.parse(json) as ClipboardEntry;
}

const OLD_IMAGE: string = '{"Content":"iVBORw0=","Type":"image","DeviceId":"dev","Timestamp":"2026-11-17T10:05:00.1234567Z","Signature":"c2ln"}';
const NAMED_IMAGE: string = '{"Content":"iVBORw0=","Type":"image","DeviceId":"dev","Timestamp":"2026-11-17T10:05:00.1234567Z","Signature":"c2ln","Name":"after-like.png"}';

export default function pictureNamesTest() {
  describe('EntryName', () => {
    it('readsNameOnlyOnAnImage', 0, () => {
      expect(entryNameOf(wire(NAMED_IMAGE))).assertEqual('after-like.png');
      expect(entryNameOf(wire(OLD_IMAGE))).assertNull();
      expect(entryNameOf(wire('{"Content":"hi","Type":"text","DeviceId":"d","Timestamp":"t","Name":"x.png"}'))).assertNull();
      expect(entryNameOf(wire('{"Content":"{}","Type":"file","DeviceId":"d","Timestamp":"t","Name":"x.png"}'))).assertNull();
    });

    it('ignoresANameThatIsNotText', 0, () => {
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":42}'))).assertNull();
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":null}'))).assertNull();
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":["a.png"]}'))).assertNull();
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":{"x":1}}'))).assertNull();
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":""}'))).assertNull();
    });

    it('cutsAVeryLongNameWithoutSplittingACharacter', 0, () => {
      const entry: ClipboardEntry = wire(OLD_IMAGE);
      entry.Name = 'a'.repeat(10000);
      expect(entryNameOf(entry)?.length).assertEqual(MAX_ENTRY_NAME_LENGTH);
      // A surrogate pair across the cut is dropped whole.
      entry.Name = 'a'.repeat(MAX_ENTRY_NAME_LENGTH - 1) + '😀tail';
      const cut: string = entryNameOf(entry) ?? '';
      expect(cut.length).assertEqual(MAX_ENTRY_NAME_LENGTH - 1);
      expect(cut.charCodeAt(cut.length - 1)).assertEqual(0x61);
    });

    it('dropsHalvesOfSurrogatePairs', 0, () => {
      // A lone half arrives escaped in JSON. Written back out it would make
      // Windows refuse the whole entry, so it never stays in a kept Name.
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":"a\\ud800b.png"}'))).assertEqual('ab.png');
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":"\\udc00x\\ud83d"}'))).assertEqual('x');
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":"\\ud800\\udbff"}'))).assertNull();
      // A whole pair is kept.
      expect(entryNameOf(wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Name":"\\ud83d\\ude00.png"}'))).assertEqual('😀.png');
      expect(withoutLoneSurrogates('plain')).assertEqual('plain');
      expect(withoutLoneSurrogates('a\ude00😀\ud83d')).assertEqual('a😀');
      // What is stored and relayed has no lone half left.
      const stored: ClipboardEntry = storedEntry(
        wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Signature":"s","Name":"x\\udfffy"}'), 't');
      expect(stored.Name).assertEqual('xy');
      expect(JSON.stringify(stored).includes('\\u')).assertFalse();
    });

    it('roundTripsAnEntryWithAName', 0, () => {
      const received: ClipboardEntry = wire(NAMED_IMAGE);
      const stored: ClipboardEntry = storedEntry(received, received.Timestamp);
      const again: ClipboardEntry = wire(JSON.stringify(stored));
      expect(again.Name).assertEqual('after-like.png');
      expect(again.Content).assertEqual(received.Content);
      expect(again.Type).assertEqual('image');
      expect(again.DeviceId).assertEqual('dev');
      expect(again.Timestamp).assertEqual(received.Timestamp);
      expect(again.Signature).assertEqual('c2ln');
      // Stored and relayed again, it is still there (a history batch is a list of these).
      const batch: ClipboardEntry[] = JSON.parse(JSON.stringify([stored])) as ClipboardEntry[];
      expect(entryNameOf(storedEntry(batch[0], batch[0].Timestamp))).assertEqual('after-like.png');
    });

    it('writesNoNameWhenThereIsNone', 0, () => {
      const stored: ClipboardEntry = storedEntry(wire(OLD_IMAGE), '2026-11-17T10:05:00.1234567Z');
      const json: string = JSON.stringify(stored);
      expect(json.includes('"Name"')).assertFalse();
      expect(json).assertEqual(OLD_IMAGE);
    });

    it('parsesAnOldFormatEntryUnchanged', 0, () => {
      const old: ClipboardEntry = wire('{"Content":"hello","Type":"text","DeviceId":"dev","Timestamp":"2026-11-17T10:05:00.12345Z","Signature":"c2ln"}');
      const stored: ClipboardEntry = storedEntry(old, '2026-11-17T10:05:00.1234500Z');
      expect(stored.Content).assertEqual('hello');
      expect(stored.Timestamp).assertEqual('2026-11-17T10:05:00.1234500Z');
      expect(stored.Signature).assertEqual('c2ln');
      expect(stored.Name === undefined).assertTrue();
    });

    it('dropsNameOnOtherTypesAndUnknownFields', 0, () => {
      const text: ClipboardEntry = storedEntry(
        wire('{"Content":"hi","Type":"text","DeviceId":"d","Timestamp":"t","Signature":"s","Name":"x.png","Extra":"y"}'), 't');
      expect(JSON.stringify(text)).assertEqual('{"Content":"hi","Type":"text","DeviceId":"d","Timestamp":"t","Signature":"s"}');
      const image: ClipboardEntry = storedEntry(
        wire('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Signature":"s","Name":"x.png","Extra":"y"}'), 't');
      expect(JSON.stringify(image)).assertEqual('{"Content":"a","Type":"image","DeviceId":"d","Timestamp":"t","Signature":"s","Name":"x.png"}');
    });

    it('signsTheSameTextWithOrWithoutAName', 0, () => {
      const plain: ClipboardEntry = wire(OLD_IMAGE);
      const named: ClipboardEntry = wire(NAMED_IMAGE);
      expect(signedText(named)).assertEqual(signedText(plain));
      expect(signedText(named)).assertEqual('iVBORw0=:image:dev:2026-11-17T10:05:00.1234567Z');
    });
  });

  describe('PictureNames', () => {
    it('takesTheExtensionFromTheBytes', 0, () => {
      expect(pictureExtension(PNG)).assertEqual('png');
      expect(pictureExtension(JPEG)).assertEqual('jpg');
      expect(pictureExtension(GIF)).assertEqual('gif');
      expect(pictureExtension(WEBP)).assertEqual('webp');
      expect(pictureExtension(new Uint8Array(0))).assertEqual('png');
    });

    it('usesTheNameWithTheRealExtension', 0, () => {
      expect(pictureFileName('after-like.png', PNG, FALLBACK)).assertEqual('after-like.png');
      expect(pictureFileName('after-like.png', JPEG, FALLBACK)).assertEqual('after-like.jpg');
      expect(pictureFileName('after-like', WEBP, FALLBACK)).assertEqual('after-like.webp');
      expect(pictureFileName('photo.JPEG', PNG, FALLBACK)).assertEqual('photo.png');
      expect(pictureFileName('photo.exe', PNG, FALLBACK)).assertEqual('photo.png');
      expect(pictureFileName('cat.gif.exe', GIF, FALLBACK)).assertEqual('cat.gif.gif');
      expect(pictureFileName('v1.2', PNG, FALLBACK)).assertEqual('v1.2.png');
      expect(pictureFileName('截图 一.png', PNG, FALLBACK)).assertEqual('截图 一.png');
    });

    it('fallsBackWithoutAUsableName', 0, () => {
      const fallback: string = `${FALLBACK}.png`;
      expect(pictureFileName(null, PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName(undefined, PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName('', PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName('   ', PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName('12345.png', PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName('....png', PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName('../', PNG, FALLBACK)).assertEqual(fallback);
      expect(pictureFileName('---.png', JPEG, FALLBACK)).assertEqual(`${FALLBACK}.jpg`);
      // A name that is only an extension has no stem, as on Windows.
      expect(pictureStem('.png')).assertNull();
      expect(pictureStem('  .JPEG ')).assertNull();
      expect(pictureFileName('.png', PNG, FALLBACK)).assertEqual(fallback);
      // The fallback is still made safe: a device name with characters Windows refuses.
      expect(pictureFileName(null, PNG, 'Image from A: C*')).assertEqual('Image from A_ C_.png');
    });

    it('rejectsDataAddresses', 0, () => {
      expect(pictureStem('data:image/png;base64,iVBORw0KGgo=')).assertNull();
      expect(pictureStem('  DATA:text/html,<b>x</b>')).assertNull();
      expect(pictureFileName('data:image/png;base64,AAAA', PNG, FALLBACK)).assertEqual(`${FALLBACK}.png`);
    });

    it('keepsOnlyASafeLastPart', 0, () => {
      expect(pictureStem('../../etc/passwd')).assertEqual('passwd');
      expect(pictureStem('..\\..\\Windows\\System32\\evil.png')).assertEqual('evil');
      expect(pictureStem('/data/storage/el2/base/files/x.png')).assertEqual('x');
      expect(pictureStem('.hidden.png')).assertEqual('hidden');
      expect(pictureStem('a<b>c?.png')).assertEqual('a_b_c_');
      expect(pictureFileName('../../cliplink_history.json', PNG, FALLBACK)).assertEqual('cliplink_history.png');
    });

    it('removesControlAndInvisibleCharacters', 0, () => {
      expect(pictureStem('a\u0000b\u0007c.png')).assertEqual('abc');
      expect(pictureStem('photo‮gnp.exe')).assertEqual('photognp');
      expect(pictureStem('zero​width.png')).assertEqual('zerowidth');
      expect(pictureFileName('\u0000\u0001\u001f', PNG, FALLBACK)).assertEqual(`${FALLBACK}.png`);
      expect(pictureFileName('line\nbreak.png', PNG, FALLBACK)).assertEqual('linebreak.png');
    });

    it('capsAVeryLongName', 0, () => {
      const name: string = pictureFileName('a'.repeat(5000) + '.png', JPEG, FALLBACK);
      expect(name.length <= 120).assertTrue();
      expect(name.endsWith('.jpg')).assertTrue();
      expect(name.startsWith('aaaa')).assertTrue();
      const wide: string = pictureFileName('图'.repeat(500), PNG, FALLBACK);
      expect(wide.endsWith('.png')).assertTrue();
      // At most 240 bytes of UTF-8: 3 bytes for each of these characters.
      expect((wide.length - 4) * 3 + 4 <= 240).assertTrue();
    });
  });

  describe('PictureCacheFolder', () => {
    it('givesEachItemItsOwnSafeFolder', 0, () => {
      const a: string = pictureCacheFolder('MEUCIQDa+b/c==');
      const b: string = pictureCacheFolder('MEUCIQDa+b/d==');
      expect(a === b).assertFalse();
      expect(pictureCacheFolder('MEUCIQDa+b/c==')).assertEqual(a);
      expect(FOLDER.test(a)).assertTrue();
      expect(FOLDER.test(b)).assertTrue();
      expect(FOLDER.test(pictureCacheFolder(''))).assertTrue();
      expect(FOLDER.test(pictureCacheFolder('../../x'))).assertTrue();
    });
  });
}
