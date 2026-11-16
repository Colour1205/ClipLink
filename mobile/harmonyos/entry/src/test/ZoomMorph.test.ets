import { describe, it, expect } from '@ohos/hypium';
import {
  CARD_RADIUS_VP, PAGE_RADIUS_VP, ZoomMorph, containRect, contentShift, picturePlace, startScale, zoomHeight,
  zoomRadius, zoomRect, zoomScale
} from '../main/ets/stack/ZoomMorph';

function close(actual: number, expected: number): void {
  expect(Math.abs(actual - expected) < 0.001).assertTrue();
}

// A grid card 180 x 240 on a 400 x 880 page.
function gridZoom(p: number): ZoomMorph {
  const z: ZoomMorph = new ZoomMorph();
  z.card = zoomRect(16, 300, 180, 240);
  z.pageW = 400;
  z.pageH = 880;
  z.contentTop = 100;
  z.p = p;
  return z;
}

export default function zoomMorphTest() {
  describe('ZoomMorph', () => {
    it('startsExactlyOnTheCard', 0, () => {
      const z: ZoomMorph = gridZoom(0);
      close(startScale(z), 0.45);
      close(zoomScale(z), 0.45);
      // On screen: the card's own height and corners.
      close(zoomHeight(z) * zoomScale(z), 240);
      close(zoomRadius(z) * zoomScale(z), CARD_RADIUS_VP);
      // The first line sits 12 in from the card's top.
      close((z.contentTop + contentShift(z)) * zoomScale(z), 12);
    });

    it('endsFillingThePageWithRoundCorners', 0, () => {
      const z: ZoomMorph = gridZoom(1);
      close(zoomScale(z), 1);
      close(zoomHeight(z), 880);
      close(zoomRadius(z), PAGE_RADIUS_VP);
      close(contentShift(z), 0);
    });

    it('neverLetsTheCornersGoSharpOnTheWay', 0, () => {
      for (let i = 0; i <= 10; i++) {
        const z: ZoomMorph = gridZoom(i / 10);
        expect(zoomRadius(z) * zoomScale(z) >= CARD_RADIUS_VP - 0.001).assertTrue();
      }
    });

    it('fitsAPictureWholeAndCentred', 0, () => {
      // Wide: full width, centred down.
      const wide = containRect(zoomRect(0, 0, 200, 200), 2);
      close(wide.w, 200);
      close(wide.h, 100);
      close(wide.y, 50);
      // Tall: full height, centred across.
      const tall = containRect(zoomRect(10, 0, 200, 200), 0.5);
      close(tall.w, 100);
      close(tall.x, 60);
    });

    it('placesTheFullViewsPictureBetweenTheBars', 0, () => {
      // A landscape picture on a 400 x 880 page with 100 above and 120 below.
      const place = picturePlace(1.5, 400, 880, 100, 120);
      close(place.w, 360);
      close(place.h, 240);
      close(place.x, 20);
      close(place.y, 100 + (660 - 240 - 32) / 2);
      // A screenshot is held to 65% of the page and centred across.
      const tall = picturePlace(0.45, 400, 880, 100, 120);
      close(tall.h, 572);
      close(tall.x, (400 - 572 * 0.45) / 2);
    });
  });
}
