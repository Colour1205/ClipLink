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
