import { describe, it, expect } from '@ohos/hypium';
import { fileExtensionLabel, fileGlyphKind } from '../main/ets/stack/CardFooter';

// The kind a file card's footer shows at its far end - the same cases as
// Android's FileExtensionLabelTest.
export default function cardFooterTest() {
  describe('CardFooter', () => {
    it('showsTheExtensionUpperCaseWithoutTheDot', 0, () => {
      expect(fileExtensionLabel('report.pdf')).assertEqual('PDF');
      expect(fileExtensionLabel('IMG_0042.jpg')).assertEqual('JPG');
      expect(fileExtensionLabel('Road Trip.m3u')).assertEqual('M3U');
      // Only the last one counts.
      expect(fileExtensionLabel('backup.tar.gz')).assertEqual('GZ');
    });

    it('countsEightCharactersAtMostAsAKind', 0, () => {
      expect(fileExtensionLabel('set.torrents')).assertEqual('TORRENTS');
      expect(fileExtensionLabel('notes.withaname')).assertEqual('');
    });

    it('countsOnlyLettersAndDigitsAsAKind', 0, () => {
      expect(fileExtensionLabel('v1.2 beta')).assertEqual('');
      expect(fileExtensionLabel('notes.to-do')).assertEqual('');
      expect(fileExtensionLabel('.bashrc')).assertEqual('BASHRC');
    });

    it('showsNothingWithoutAnExtension', 0, () => {
      expect(fileExtensionLabel('')).assertEqual('');
      expect(fileExtensionLabel('README')).assertEqual('');
      expect(fileExtensionLabel('draft.')).assertEqual('');
    });

    it('picksTheGlyphByExtensionWhateverItsCase', 0, () => {
      expect(fileGlyphKind('Quarterly report.PDF')).assertEqual('pdf');
      expect(fileGlyphKind('Meeting notes.docx')).assertEqual('doc');
      expect(fileGlyphKind('Budget 2026.xlsx')).assertEqual('sheet');
      expect(fileGlyphKind('Kickoff.pptx')).assertEqual('slides');
      expect(fileGlyphKind('todo.txt')).assertEqual('txt');
      expect(fileGlyphKind('contacts.json')).assertEqual('data');
      expect(fileGlyphKind('SyncEngine.kt')).assertEqual('code');
      expect(fileGlyphKind('backup.tar.gz')).assertEqual('archive');
      expect(fileGlyphKind('Favorite (1).m3u')).assertEqual('audio');
      expect(fileGlyphKind('clip.MP4')).assertEqual('video');
      expect(fileGlyphKind('ClipLink-2.1.2.apk')).assertEqual('package');
      expect(fileGlyphKind('Field guide.epub')).assertEqual('ebook');
      expect(fileGlyphKind('Inter.ttf')).assertEqual('font');
      expect(fileGlyphKind('installer.iso')).assertEqual('disc');
    });

    it('keepsThePlainGlyphForAnyOtherFile', 0, () => {
      expect(fileGlyphKind('backup.bin')).assertEqual('');
      expect(fileGlyphKind('README')).assertEqual('');
      expect(fileGlyphKind('')).assertEqual('');
      expect(fileGlyphKind('notes.to-do')).assertEqual('');
    });
  });
}
