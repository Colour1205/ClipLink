// The file name a picture item is saved or opened under. A picture copied as a
// picture travels as an image entry whose Content is its bytes in Base64, and
// it has a name only when the device that copied it found one (a picture
// copied in a browser has the last part of its address; a screenshot has
// none). That name is the entry's optional Name (see crypto/Signing.ets). It
// comes from another device, so it is cut to a safe last part here, and its
// extension is never trusted: the extension always comes from what the bytes
// really are. Without a usable name the picture gets the old one, "Image from
// <device> <date> <time>", which the page builds from a string resource.

import { safeFileName } from './FileNames';

// The extension that matches what a picture's bytes really are (their first
// bytes), so a saved or opened file is not a JPEG named .png. PNG otherwise,
// which is what every platform sends for a copied picture.
export function pictureExtension(bytes: Uint8Array): string {
  if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) return 'jpg';
  if (bytes.length >= 4 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) return 'gif';
  if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'webp';
  return 'png';
}

// What counts as an extension to drop from the end of a name: one to five
// ASCII letters or digits, at least one of them a letter. So "photo.jpeg" and
// "photo.exe" lose theirs, but "v1.2" and "Scan 2026.11" keep their numbers.
const EXTENSION: RegExp = new RegExp('^[A-Za-z0-9]{1,5}$');
const HAS_ASCII_LETTER: RegExp = new RegExp('[A-Za-z]');
// A stem must hold at least one letter, in any script, as the sender's rule
// asks: a name of only digits, dots or symbols says nothing about the picture.
const HAS_LETTER: RegExp = new RegExp('\\p{L}', 'u');

function trimDotsAndSpaces(s: string): string {
  let start: number = 0;
  let end: number = s.length;
  while (start < end && (s.charAt(start) === '.' || s.charAt(start) === ' ')) start++;
  while (end > start && (s.charAt(end - 1) === '.' || s.charAt(end - 1) === ' ')) end--;
  return s.substring(start, end);
}

// The part of a received Name that may start a file name: its last path part
// with unsafe characters removed (safeFileName), without its extension, and
// without dots or spaces at either end, so it is never hidden or a folder
// name. null when nothing usable is left: a missing or empty Name, one that is
// not text, a data: address (the picture itself, not a name), or one with no
// letter in it.
export function pictureStem(name: string | null | undefined): string | null {
  if (typeof name === 'string' && name.trim().toLowerCase().startsWith('data:')) return null;
  const safe: string = safeFileName(name, '');
  if (safe.length === 0) return null;
  let stem: string = safe;
  // A dot at the very start counts too, as on Windows: ".png" is only an
  // extension, so it leaves no stem and the picture gets the fallback name.
  const dot: number = stem.lastIndexOf('.');
  if (dot >= 0) {
    const extension: string = stem.substring(dot + 1);
    if (EXTENSION.test(extension) && HAS_ASCII_LETTER.test(extension)) stem = stem.substring(0, dot);
  }
  stem = trimDotsAndSpaces(stem);
  if (stem.length === 0 || !HAS_LETTER.test(stem)) return null;
  return stem;
}

// The name a picture is saved or opened under: the stem of its Name with the
// extension its bytes really have, or, when the Name is missing or unsafe,
// `fallbackBase` (the device-and-time name) with that extension. The result
// always goes through safeFileName, which also caps its length with the
// extension kept.
export function pictureFileName(name: string | null | undefined, bytes: Uint8Array, fallbackBase: string): string {
  const extension: string = pictureExtension(bytes);
  const fallback: string = safeFileName(`${fallbackBase}.${extension}`, `image.${extension}`);
  const stem: string | null = pictureStem(name);
  return stem === null ? fallback : safeFileName(`${stem}.${extension}`, fallback);
}

// The folder under the cache's "opened" folder that a picture is written to
// before it is opened: one per item, named by a hash of the item's key (its
// Signature). Without it, two pictures with the same name, as many web
// pictures are ("image.png"), would write the same file, and the second could
// overwrite the one a previewer still shows. The key itself holds "/" and
// "+", so it is not used as a folder name directly. The hash is the 53-bit
// cyrb53, written as hex; it only has to tell apart the few pictures opened
// close together.
export function pictureCacheFolder(itemKey: string): string {
  let h1: number = 0xDEADBEEF;
  let h2: number = 0x41C6CE57;
  for (let i: number = 0; i < itemKey.length; i++) {
    const unit: number = itemKey.charCodeAt(i);
    h1 = Math.imul(h1 ^ unit, 2654435761);
    h2 = Math.imul(h2 ^ unit, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  const hash: number = 4294967296 * (2097151 & h2) + (h1 >>> 0);
  return hash.toString(16).padStart(14, '0');
}
