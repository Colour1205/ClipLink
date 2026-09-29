// Mirrors windows/daemon/Storage/FileNames.cs. A file's name always comes
// from somewhere else - a peer's signed FilePayload, or the app that shared
// the file to ClipLink - and it's shown, offered to a save picker, and sent
// on to peers that do turn it into a path. Only its last path segment counts
// (a "../../x" or "/data/storage/.../x" must never reach any of those as
// one), with the characters Windows refuses, control characters and the
// bidi overrides that can disguise an extension ("txt.exe" shown as
// "exe.txt") replaced, trailing dots/spaces dropped, and the length capped
// with the extension kept. Blank after all that: fallback. Windows' extra
// reserved-device-name rule only matters where the name becomes a Windows
// path, so the receiver there applies it.

const MAX_NAME_LENGTH: number = 120;
const UNSAFE_CHARS: RegExp = new RegExp('[\\\\/:*?"<>|\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]', 'g');

function trimEndDotsAndSpaces(s: string): string {
  let end: number = s.length;
  while (end > 0 && (s.charAt(end - 1) === '.' || s.charAt(end - 1) === ' ')) end--;
  return s.substring(0, end);
}

export function safeFileName(name: string | null | undefined, fallback: string): string {
  // Also covers a FileName that isn't a string at all in a malformed
  // payload - JSON.parse(...) as FilePayload checks nothing.
  if (typeof name !== 'string') return fallback;
  let safe: string = name.split('\\').join('/');
  safe = safe.substring(safe.lastIndexOf('/') + 1);
  safe = trimEndDotsAndSpaces(safe.replace(UNSAFE_CHARS, '_').trim());
  if (safe.length === 0) return fallback;
  if (safe.length > MAX_NAME_LENGTH) {
    const dot: number = safe.lastIndexOf('.');
    let extension: string = dot > 0 ? safe.substring(dot) : '';
    if (extension.length > 20) extension = '';
    let keep: number = MAX_NAME_LENGTH - extension.length;
    const last: number = safe.charCodeAt(keep - 1);
    if (last >= 0xD800 && last <= 0xDBFF) keep--; // never half a character
    safe = trimEndDotsAndSpaces(safe.substring(0, keep)) + extension;
  }
  return safe;
}
