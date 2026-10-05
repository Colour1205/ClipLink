import { describe, it, expect } from '@ohos/hypium';
import { safeFileName } from '../main/ets/storage/FileNames';

// UTF-8 length of a well-formed string.
function utf8Length(s: string): number {
  let bytes = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      bytes += 4;
      i++;
    } else {
      bytes += c < 0x80 ? 1 : (c < 0x800 ? 2 : 3);
    }
  }
  return bytes;
}

// The same cases as Android's ShareTest (FileNames.safe).
export default function fileNamesTest() {
  describe('FileNames', () => {
    it('keepsOnlyTheLastPathSegment', 0, () => {
      expect(safeFileName('../../etc/passwd', 'file')).assertEqual('passwd');
      expect(safeFileName('C:\\Users\\me\\AppData\\Roaming\\Startup\\evil.exe', 'file')).assertEqual('evil.exe');
      expect(safeFileName('/data/data/io.uaena.cliplink/shared_prefs/../x.txt', 'file')).assertEqual('x.txt');
      expect(safeFileName('report.pdf', 'file')).assertEqual('report.pdf');
    });

    it('fallsBackWhenNothingIsLeft', 0, () => {
      expect(safeFileName(null, 'file')).assertEqual('file');
      expect(safeFileName(undefined, 'file')).assertEqual('file');
      expect(safeFileName('', 'file')).assertEqual('file');
      expect(safeFileName('   ', 'file')).assertEqual('file');
      expect(safeFileName('.', 'file')).assertEqual('file');
      expect(safeFileName('..', 'file')).assertEqual('file');
      expect(safeFileName('../..', 'file')).assertEqual('file');
      expect(safeFileName('dir/', 'file')).assertEqual('file');
      expect(safeFileName('. . .', 'file')).assertEqual('file');
    });

    it('replacesUnsafeCharacters', 0, () => {
      expect(safeFileName('a:b*c?d"e<f>g|.txt', 'file')).assertEqual('a_b_c_d_e_f_g_.txt');
      expect(safeFileName('line\nbreak.txt', 'file')).assertEqual('line_break.txt');
      expect(safeFileName('nul\u0000.txt', 'file')).assertEqual('nul_.txt');
      // Shown as "invoiceexe.txt" if the override were kept.
      expect(safeFileName('invoice\u202Etxt.exe', 'file')).assertEqual('invoice_txt.exe');
      expect(safeFileName('  name.txt . ', 'file')).assertEqual('name.txt');
      expect(safeFileName('Café 日本語 😀.png', 'file')).assertEqual('Café 日本語 😀.png');
    });

    it('cutsALongNameTo120CharactersKeepingItsExtension', 0, () => {
      const safe = safeFileName('a'.repeat(200) + '.jpeg', 'file');
      expect(safe.length).assertEqual(120);
      expect(safe.endsWith('a.jpeg')).assertTrue();
      // An "extension" over 20 characters isn't kept.
      const noExtension = safeFileName('x.' + 'b'.repeat(200), 'file');
      expect(noExtension.length).assertEqual(120);
      expect(noExtension.substring(0, 2)).assertEqual('x.');
    });

    it('fitsALongNameIn240BytesOfUtf8', 0, () => {
      // 100 CJK characters: under the character cap, but 300 bytes.
      const cjk = safeFileName('文'.repeat(100) + '.pdf', 'file');
      expect(cjk.endsWith('文.pdf')).assertTrue();
      expect(utf8Length(cjk) <= 240).assertTrue();
      expect(cjk.length).assertEqual(78 + 4); // 78 * 3 + 4 bytes = 238
      const emoji = safeFileName('😀'.repeat(70), 'file');
      expect(emoji).assertEqual('😀'.repeat(60));
    });

    it('fallsBackWhenALongNameCutsDownToNothing', 0, () => {
      expect(safeFileName('.'.repeat(150) + 'b'.repeat(21), 'file')).assertEqual('file');
      expect(safeFileName('. '.repeat(75) + '.' + 'b'.repeat(30), 'file')).assertEqual('file');
    });

    it('neverSplitsACharacter', 0, () => {
      expect(safeFileName('a'.repeat(119) + '😀' + 'tail', 'file')).assertEqual('a'.repeat(119));
    });
  });
}
