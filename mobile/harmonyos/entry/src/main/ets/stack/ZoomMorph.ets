// The zoom a card opens into its full view with, and closes back by, kept out
// of Index so entry/src/test can run the arithmetic.
//
// The full view is laid out once, at full size, and the whole of it is scaled
// down onto the tapped card and up again: its text grows with the card instead
// of being uncovered by a shape that grows over it (what geometryTransition
// did). One uniform scale, so nothing is ever squashed: the scale follows the
// card's width, and the view's height is cut to the card's at the start and
// grows to the page's. A picture flies on its own, from where it sits on the
// card to where it sits in the full view (see picFrom/picTo).

// A rectangle in vp, from the top-left of the page the zoom runs over.
export class ZoomRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

export function zoomRect(x: number, y: number, w: number, h: number): ZoomRect {
  const rect: ZoomRect = new ZoomRect();
  rect.x = x;
  rect.y = y;
  rect.w = w;
  rect.h = h;
  return rect;
}

// The corners of a card, and of the full view once it fills the page: about
// the screen's own, so the view never shows a sharp corner on its way.
export const CARD_RADIUS_VP: number = 18;
export const PAGE_RADIUS_VP: number = 32;

// Where a value is at p (0 = at the card, 1 = full view).
export function lerp(from: number, to: number, p: number): number {
  return from + (to - from) * p;
}

// What one zoom needs to know. p and fade are what the open and close
// animate; the rest is set before they start.
export class ZoomMorph {
  // The tapped card, on the page.
  card: ZoomRect = new ZoomRect();
  // The page the full view fills.
  pageW: number = 0;
  pageH: number = 0;
  // 0 at the card, 1 full view.
  p: number = 1;
  // How much of the full view's own content shows, and how much of the
  // card's picture of itself over it. One after the other, not a crossfade:
  // the card's text goes as the zoom starts and the view's comes in after it,
  // so the two are never seen on top of each other (they are laid out at
  // different widths and do not line up).
  fade: number = 1;
  cover: number = 0;
  // Closing: the full view is on its way back to the card and takes no
  // touches, so the list under it is usable straight away (a back, then a tap
  // on the next card, without waiting for the zoom).
  closing: boolean = false;
  // Counts the zoom's opens and closes, so a callback from one that was cut
  // short by the next (a back mid-open, a tap mid-close) does nothing.
  run: number = 0;
  // Opening or closing: the view is sized in vp from pageW/pageH. At rest it
  // fills its page, so it follows the window when that is resized while open.
  moving: boolean = false;
  // The whole zoom, for a close given up part way (the list was scrolled
  // under it, so the card is no longer where it is heading).
  shown: number = 1;
  // How far down the full view's content starts, so it can ride on the
  // card's top while the zoom is small instead of starting below it.
  contentTop: number = 0;
  // The part of the card its picture of itself shows (a picture card leaves
  // out the picture, which flies on its own), relative to the card.
  part: ZoomRect = new ZoomRect();
  // A picture's flight, on the page: from the card to the full view.
  flying: boolean = false;
  picFrom: ZoomRect = new ZoomRect();
  picTo: ZoomRect = new ZoomRect();
  picRadiusFrom: number = 0;
  // Bumped when the card's picture of itself changes, so the view rebuilds.
  snapVersion: number = 0;
  // Running, or open: the zoom's own layers are drawn.
  active: boolean = false;
  // Closing toward a card that is gone: the view fades as it shrinks.
  vanish: boolean = false;
}

// A picture card's picture, for its flight: the ids of the picture and of
// the rest of the card (its footer), the picture's width over height,
// whether the card fits it whole into its box (the grid) or crops it to a
// square (the list's chip), the card's corner radius for it, and where the
// full view draws it.
export class PictureFlight {
  picId: string;
  partId: string;
  ratio: number;
  contained: boolean;
  radius: number;
  place: ZoomRect;

  constructor(picId: string, partId: string, ratio: number, contained: boolean, radius: number, place: ZoomRect) {
    this.picId = picId;
    this.partId = partId;
    this.ratio = ratio;
    this.contained = contained;
    this.radius = radius;
    this.place = place;
  }
}

// The card's width over the page's: the scale the full view starts at.
export function startScale(z: ZoomMorph): number {
  if (z.pageW <= 0 || z.card.w <= 0) return 1;
  return z.card.w / z.pageW;
}

export function zoomScale(z: ZoomMorph): number {
  return lerp(startScale(z), 1, z.p);
}

// The view's height before it is scaled: the card's height at the start (in
// the view's own, unscaled vp), the page's at the end.
export function zoomHeight(z: ZoomMorph): number {
  return lerp(z.card.h / startScale(z), z.pageH, z.p);
}

// The corner radius before it is scaled, so that on screen it is the card's
// at the start and the page's at the end.
export function zoomRadius(z: ZoomMorph): number {
  return lerp(CARD_RADIUS_VP / startScale(z), PAGE_RADIUS_VP, z.p);
}

// How far the full view's content is moved up, so its first line sits where
// the card's does (12 vp in) at the start and in its own place at the end.
export function contentShift(z: ZoomMorph): number {
  return lerp(12 / startScale(z) - z.contentTop, 0, z.p);
}

// The rectangle a picture of this width-over-height ratio is drawn in when it
// is fitted whole into box (ImageFit.Contain): centred, as big as it fits.
export function containRect(box: ZoomRect, ratio: number): ZoomRect {
  if (ratio <= 0 || box.w <= 0 || box.h <= 0) return zoomRect(box.x, box.y, box.w, box.h);
  if (box.w / box.h > ratio) {
    const w: number = box.h * ratio;
    return zoomRect(box.x + (box.w - w) / 2, box.y, w, box.h);
  }
  const h: number = box.w / ratio;
  return zoomRect(box.x, box.y + (box.h - h) / 2, box.w, h);
}

// Where the full view draws a picture: as wide as the page less 20 vp a side,
// no taller than 65% of the page or the room between the bars (less what the
// line under it needs), and centred in that room with the line below it.
export const PICTURE_SIDE_VP: number = 20;
export const PICTURE_LINE_VP: number = 32;

export function picturePlace(ratio: number, pageW: number, pageH: number, top: number, bottom: number): ZoomRect {
  const room: number = Math.max(0, pageH - top - bottom);
  const maxW: number = Math.max(0, pageW - 2 * PICTURE_SIDE_VP);
  const maxH: number = Math.max(0, Math.min(pageH * 0.65, room - PICTURE_LINE_VP));
  const fitted: ZoomRect = containRect(zoomRect(0, 0, maxW, maxH), ratio > 0 ? ratio : 1);
  const y: number = top + (room - fitted.h - PICTURE_LINE_VP) / 2;
  return zoomRect((pageW - fitted.w) / 2, Math.max(top, y), fitted.w, fitted.h);
}
