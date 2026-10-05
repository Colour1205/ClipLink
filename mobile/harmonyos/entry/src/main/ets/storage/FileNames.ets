// Mirrors windows/daemon/Storage/FileNames.cs. A file's name always comes
// from somewhere else - a peer's signed FilePayload, or the app that shared
// the file to ClipLink - and it's shown, offered to a save picker, and sent
// on to peers that do turn it into a path. Only its last path segment counts
// (a "../../x" or "/data/storage/.../x" must never reach any of those as
// one), with control characters and the invisible ones Windows'
// FileNames.IsUnsafeChar names - bidi marks and overrides that can disguise
// an extension ("txt.exe" shown as "exe.txt"), zero-width characters that
// hide text - removed, the characters Windows refuses replaced with "_" (as
// Windows, Android and iOS do it, so a name comes out the same on every
// device), trailing dots/spaces dropped, and the length capped with the
// extension kept. Blank after all that: fallback. Windows' extra
// reserved-device-name rule only matters where the name becomes a Windows
// path, so the receiver there applies it.

const MAX_NAME_LENGTH: number = 120;
const MAX_EXTENSION_LENGTH: number = 20;
// HarmonyOS's file systems - and Android's and APFS - cap a name at 255
// bytes of UTF-8, not 255 characters: 120 Chinese characters are 360 bytes,
// and creating that name fails. Kept under 255 so a receiver can still add
// a " (1)" to it. Same cap as Android's FileNames.kt.
const MAX_NAME_UTF8_BYTES: number = 240;
// Removed - the same set a peer's device name loses (see DeviceName.ets).
const UNSAFE_CHARS: RegExp = new RegExp('[\\u0000-\\u001f\\u007f-\\u009f\\u061c\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]', 'g');
// Replaced with "_": the characters Windows refuses in a name.
const INVALID_CHARS: RegExp = new RegExp('[\\\\/:*?"<>|]', 'g');

function trimEndDotsAndSpaces(s: string): string {
  let end: number = s.length;
  while (end > 0 && (s.charAt(end - 1) === '.' || s.charAt(end - 1) === ' ')) end--;
  return s.substring(0, end);
}

// UTF-16 units in the character at i: 2 for a surrogate pair, else 1.
function charLengthAt(s: string, i: number): number {
  const c: number = s.charCodeAt(i);
  const next: number = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
  return c >= 0xD800 && c <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF ? 2 : 1;
}

// UTF-8 bytes of the character at i, charLengthAt(s, i) units long. A lone
// surrogate counts as 3 - the most any encoder writes for one.
function utf8LengthAt(s: string, i: number, units: number): number {
  if (units === 2) return 4;
  const c: number = s.charCodeAt(i);
  return c < 0x80 ? 1 : (c < 0x800 ? 2 : 3);
}

function utf8Length(s: string): number {
  let bytes: number = 0;
  let i: number = 0;
  while (i < s.length) {
    const units: number = charLengthAt(s, i);
    bytes += utf8LengthAt(s, i, units);
    i += units;
  }
  return bytes;
}

// The longest start of s within maxChars UTF-16 units and maxBytes of
// UTF-8 - never half a character.
function prefix(s: string, maxChars: number, maxBytes: number): string {
  let end: number = 0;
  let bytes: number = 0;
  while (end < s.length) {
    const units: number = charLengthAt(s, end);
    bytes += utf8LengthAt(s, end, units);
    if (end + units > maxChars || bytes > maxBytes) break;
    end += units;
  }
  return s.substring(0, end);
}

export function safeFileName(name: string | null | undefined, fallback: string): string {
  // Also covers a FileName that isn't a string at all in a malformed
  // payload - JSON.parse(...) as FilePayload checks nothing.
  if (typeof name !== 'string') return fallback;
  let safe: string = name.split('\\').join('/');
  safe = safe.substring(safe.lastIndexOf('/') + 1);
  // Removed, THEN trimmed: the spaces they were hiding go too.
  safe = trimEndDotsAndSpaces(safe.replace(UNSAFE_CHARS, '').replace(INVALID_CHARS, '_').trim());
  if (safe.length === 0) return fallback;
  if (safe.length > MAX_NAME_LENGTH || utf8Length(safe) > MAX_NAME_UTF8_BYTES) {
    const dot: number = safe.lastIndexOf('.');
    let extension: string = dot > 0 ? safe.substring(dot) : '';
    if (extension.length > MAX_EXTENSION_LENGTH) extension = '';
    const stem: string = prefix(safe, MAX_NAME_LENGTH - extension.length, MAX_NAME_UTF8_BYTES - utf8Length(extension));
    // A stem of nothing but dots and spaces trims away entirely - and with
    // no extension left either, "" would name the folder itself.
    safe = trimEndDotsAndSpaces(stem) + extension;
    if (safe.length === 0) return fallback;
  }
  return safe;
}
