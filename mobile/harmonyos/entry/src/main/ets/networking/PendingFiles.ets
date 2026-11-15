// When a file entry that waited for its bytes may still go on the clipboard
// (design/sync-dedupe-spec.md 6.4). Plain code, so entry/src/test can run it;
// SyncManager keeps the waiting entries.

// A file is only put on the clipboard within this long of its entry arriving.
export const PENDING_APPLY_LIMIT_MS: number = 10 * 60 * 1000;

// Whether a file whose entry was set to go on the clipboard at `armedAt` (ms
// since the epoch), when the pasteboard's change count was `armedGeneration`,
// still may now that its bytes are here. Not once anything else went on the
// clipboard (the count moved: the user copied something, or ClipLink put a
// newer item there), and not once PENDING_APPLY_LIMIT_MS have passed: a big
// file finishing on a reconnect hours later replaced whatever the user had
// copied since. A count that can't be read (-1) never matches one that could.
export function pendingFileMayApply(armedAt: number, armedGeneration: number, now: number, generation: number): boolean {
  if (now - armedAt > PENDING_APPLY_LIMIT_MS) return false;
  return generation === armedGeneration;
}
