// What the footer of a Synced card shows at its far end, kept out of Index so
// entry/src/test can run it. The same rule as Android's fileExtensionLabel
// (SyncedScreen.kt), so a file reads the same on every phone.

// A kind of file: 1 to 8 letters and digits. Anything longer, or with a space
// or punctuation in it ("v1.2 beta"), is more likely part of the name.
const EXTENSION_LABEL: RegExp = /^[\p{L}\p{Nd}]{1,8}$/u;

// A file's extension, upper-case and without the dot ("PDF"): only the last
// one counts ("backup.tar.gz" is "GZ"). '' for no extension, or one that does
// not look like a kind of file (see EXTENSION_LABEL).
export function fileExtensionLabel(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.');
  if (dot < 0) return '';
  const extension: string = fileName.substring(dot + 1);
  if (!EXTENSION_LABEL.test(extension)) return '';
  return extension.toUpperCase();
}

// The glyph a grid file card's tile shows, by kind of file (see
// fileGlyphKind). Lower-case extensions, without the dot.
const GLYPH_KINDS: Map<string, string> = new Map<string, string>([
  ['pdf', 'pdf'],
  ['doc', 'doc'], ['docx', 'doc'], ['odt', 'doc'], ['rtf', 'doc'], ['pages', 'doc'],
  ['xls', 'sheet'], ['xlsx', 'sheet'], ['ods', 'sheet'], ['numbers', 'sheet'],
  ['ppt', 'slides'], ['pptx', 'slides'], ['odp', 'slides'], ['key', 'slides'],
  ['txt', 'txt'], ['md', 'txt'], ['log', 'txt'],
  ['csv', 'data'], ['json', 'data'], ['xml', 'data'], ['yaml', 'data'], ['yml', 'data'],
  ['js', 'code'], ['ts', 'code'], ['py', 'code'], ['kt', 'code'], ['swift', 'code'], ['c', 'code'],
  ['cpp', 'code'], ['h', 'code'], ['java', 'code'], ['cs', 'code'], ['sh', 'code'], ['html', 'code'],
  ['css', 'code'], ['ets', 'code'],
  ['zip', 'archive'], ['rar', 'archive'], ['7z', 'archive'], ['tar', 'archive'], ['gz', 'archive'],
  ['mp3', 'audio'], ['m4a', 'audio'], ['flac', 'audio'], ['wav', 'audio'], ['aac', 'audio'],
  ['ogg', 'audio'], ['m3u', 'audio'], ['m3u8', 'audio'],
  ['mp4', 'video'], ['mov', 'video'], ['mkv', 'video'], ['avi', 'video'], ['webm', 'video'],
  ['apk', 'package'], ['hap', 'package'], ['app', 'package'], ['exe', 'package'], ['msi', 'package'],
  ['dmg', 'package'],
  ['epub', 'ebook'], ['mobi', 'ebook'], ['azw3', 'ebook'],
  ['ttf', 'font'], ['otf', 'font'], ['woff', 'font'], ['woff2', 'font'],
  ['iso', 'disc'], ['img', 'disc'],
]);

// Which glyph a file's tile shows: 'pdf', 'doc', 'sheet', 'slides', 'txt',
// 'data', 'code', 'archive', 'audio', 'video', 'package', 'ebook', 'font' or
// 'disc' - '' for any other file, which keeps the plain file glyph. By the
// same extension the footer shows (see fileExtensionLabel).
export function fileGlyphKind(fileName: string): string {
  return GLYPH_KINDS.get(fileExtensionLabel(fileName).toLowerCase()) ?? '';
}
