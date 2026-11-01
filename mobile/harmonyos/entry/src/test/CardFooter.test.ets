import { describe, it, expect } from '@ohos/hypium';
import { fileExtensionLabel } from '../main/ets/stack/CardFooter';

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
  });
}
