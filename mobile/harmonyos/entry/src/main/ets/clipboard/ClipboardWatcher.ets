// Step 3 of the build order in ../../../../README.md: clipboard read + watch.
//
// IMPORTANT platform difference from Windows (windows/ClipLink/Engine/Clipboard/ClipboardSync.cs)
// discovered while building this: ohos.permission.READ_PASTEBOARD is a
// restricted permission — declaring it in module.json5 makes the app
// UNINSTALLABLE without ACL provisioning this project doesn't have (confirmed
// on-device: `hdc shell bm install` fails outright with "grant request
// permissions failed"). There is no silent background auto-read on this
// platform for a normal app.
//
// The sanctioned workaround is the PasteButton security component: tapping
// it grants a temporary, dialog-free read privilege for that gesture only —
// no permission declaration needed at all. pasteboard.on('update') itself
// needs no permission either (confirmed: no @permission tag on it in the
// SDK, unlike getData()), so the real flow here is:
//   1. on('update') fires for free -> tell the UI "something changed".
//   2. User taps PasteButton -> read() runs inside that temporary grant.
// This means HarmonyOS sync can only ever be "detect + prompt", never
// "detect + silently pull", unlike Windows or (likely) Android. Worth
// keeping in mind for the eventual UI design in step 9.
//
// UPDATE 2026-10-12: Huawei approved READ_PASTEBOARD through the ACL process,
// for use while the app is in use only. With it granted (see
// PasteboardPermission.ets) getData() works without a tap, so ClipLink reads
// the clipboard by itself when it comes forward (Index.ets's captureOnOpen).
// Still nothing in the background, and the PasteButton stays as the fallback
// for a user who refuses the permission.

import pasteboard from '@ohos.pasteboard';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { sha256File } from '../storage/FileStore';
import {
  LastWrite, emptyLastWrite, filePrint, imagePrint, rawTextHash, sha256Hex, textPrint
} from '../storage/ContentPrint';
import { copyFileIn, CopyRefusal, newCopyPath, removeQuietly, uriFileName } from '../share/ShareIntake';

const base64Helper = new util.Base64Helper();

// How a picture read from the clipboard becomes bytes. ClipboardApply packs
// the picture it writes the same way, so it knows the print a later read of
// it would give.
export const IMAGE_PACKING: image.PackingOption = { format: 'image/png', quality: 100 };

export type ClipboardContentType = 'text' | 'image' | 'file' | 'unsupported';

export interface ClipboardChange {
  type: ClipboardContentType;
  content: string; // text; base64 PNG for images; '' for files (see path)
  // sha256 of exactly what was read: the text's UTF-8, the PNG, the file.
  hash: string;
  // Its prints (see storage/ContentPrint.ets), to compare with what ClipLink
  // last wrote and with the history. Empty for 'unsupported'.
  prints: string[];
  fileName?: string; // only set for type 'file'
  // Type 'file': this app's own cache copy of it, for FileStore.adopt to
  // take over (or the caller to delete), and its size in bytes.
  path?: string;
  size?: number;
  // Type 'unsupported': a file the paste wouldn't take, and why.
  refused?: CopyRefusal;
  // Type 'unsupported': the clipboard could not be read at all (no focus yet,
  // a file that would not copy). Not a decision about what is there, so the
  // change is not marked seen and can be read again.
  failed?: boolean;
  detail?: string; // e.g. the unsupported mime type list, or an error message
}

function arrayBufferToBase64(buf: ArrayBuffer): string {
  return base64Helper.encodeToStringSync(new Uint8Array(buf));
}

// The pasteboard's change counter (getChangeCount, API 18+, no permission),
// or -1 if it can't be read. It moves on every write, ClipLink's own too, so
// it is also how ClipLink tells "nothing has been copied since" (see
// SyncManager's files waiting for their bytes).
export function pasteboardChangeCount(): number {
  try {
    return pasteboard.getSystemPasteboard().getChangeCount();
  } catch (e) {
    return -1;
  }
}

// A count saved before a reboot or a pasteboard service restart, which start
// the counter from 0 again: one above the current count can't be ours, and
// matching it later by chance would hide a real copy. Treated as none.
function freshCount(saved: number): number {
  const now: number = pasteboardChangeCount();
  return now >= 0 && saved > now ? -1 : saved;
}

export class ClipboardWatcher {
  private listening = false;
  private changedCallback: (() => void) | null = null;
  // The pasteboard's change counter as of the last time this app itself
  // wrote to or read the clipboard. -1 until first recorded, so whatever is
  // on the clipboard when the app first opens counts as new - that's the
  // "copied elsewhere, then opened ClipLink" case this exists for.
  private lastSeenCount: number = -1;
  // What ClipLink last wrote to the clipboard, or last read and dealt with
  // (see ContentPrint's LastWrite). It replaces the single in-memory hash of
  // older builds, which only ever knew what this app had READ: a received
  // item it put there itself, or a card's Copy, then came back as a new copy
  // on the next Paste tap. Saved by Index (DeviceSettings' lastWrite).
  private lastWrite: LastWrite = emptyLastWrite();
  // Filters out 'update' events caused by this app's own writes (applying a
  // received item, Copy, Copy pairing info...), which previously flagged
  // ClipLink's own clipboard writes as something new to send.
  private boundHandler = () => {
    if (this.hasUnseenChange()) this.changedCallback?.();
  };

  // Call right after this app reads the clipboard, so the change isn't
  // reported back as new. Returns the recorded count (-1 if unavailable) so
  // the caller can persist it - otherwise a restart forgets it and the last
  // copy shows up as "New copy" again.
  markSeen(): number {
    const count: number = pasteboardChangeCount();
    if (count >= 0) this.lastSeenCount = count;
    return this.lastSeenCount;
  }

  // The counter persists until reboot or a pasteboard service restart; after
  // either it restarts from 0, and a saved count above it is dropped (see
  // freshCount) rather than left to match a later copy by chance.
  restoreSeen(count: number): void {
    this.lastSeenCount = freshCount(count);
  }

  restoreLastWrite(saved: LastWrite): void {
    this.lastWrite = { prints: saved.prints.slice(), count: freshCount(saved.count) };
  }

  // Call right after this app's own write to the clipboard succeeded, with the
  // prints of what it wrote: the change is seen, and remembered as ClipLink's
  // (see holdsOwnWrite). Returns the record for the caller to save.
  noteOwnWrite(prints: string[]): LastWrite {
    const count: number = pasteboardChangeCount();
    if (count >= 0) this.lastSeenCount = count;
    this.lastWrite = { prints: prints.slice(), count: count };
    return this.lastWrite;
  }

  // A capture was dealt with (sent, or found already synced): its prints
  // become what ClipLink believes is on the clipboard. The count stays: the
  // clipboard no longer holds a write of ClipLink's own.
  noteCapture(prints: string[]): LastWrite {
    this.lastWrite = { prints: prints.slice(), count: this.lastWrite.count };
    return this.lastWrite;
  }

  getLastWrite(): LastWrite {
    return this.lastWrite;
  }

  // Whether the clipboard still holds ClipLink's own last write, without
  // reading it: nothing has been copied since (the change count is the one
  // recorded right after that write).
  holdsOwnWrite(): boolean {
    if (this.lastWrite.count < 0) return false;
    return pasteboardChangeCount() === this.lastWrite.count;
  }

  // The hash of the file ClipLink last put on the clipboard, while it is still
  // there (holdsOwnWrite), or null: its named copy must outlive a restart.
  ownFileOnClipboard(): string | null {
    if (!this.holdsOwnWrite()) return null;
    const print: string | undefined = this.lastWrite.prints.find((p: string) => p.startsWith('f:'));
    return print !== undefined ? print.substring(2) : null;
  }

  // Whether this content is what ClipLink last wrote or dealt with.
  holds(print: string | null): boolean {
    return print !== null && this.lastWrite.prints.includes(print);
  }

  // Whether something was copied since markSeen, without reading it (that
  // still needs a PasteButton tap). The counter also bumps when identical
  // data is copied again, and resets on reboot.
  hasUnseenChange(): boolean {
    try {
      const pb = pasteboard.getSystemPasteboard();
      return pb.getChangeCount() !== this.lastSeenCount && pb.hasDataSync();
    } catch (e) {
      return false;
    }
  }

  // Fires on every pasteboard 'update' — free, no permission needed. Use
  // this only to prompt the user to tap the PasteButton; do not call
  // read() from in here, it will fail (no temporary grant active).
  onPasteboardChanged(callback: () => void): void {
    this.changedCallback = callback;
  }

  startListening(): void {
    if (this.listening) return;
    this.listening = true;
    pasteboard.getSystemPasteboard().on('update', this.boundHandler);
  }

  stopListening(): void {
    if (!this.listening) return;
    this.listening = false;
    pasteboard.getSystemPasteboard().off('update', this.boundHandler);
  }

  get isListening(): boolean {
    return this.listening;
  }

  // Only valid to call from inside a PasteButton onClick handler, in the
  // window after a SUCCESS result — that's what grants the temporary
  // pasteboard read privilege this needs - or while READ_PASTEBOARD is
  // granted (and the app is in front). context is only used for the
  // file branch (see below) - needed to copy a cross-app URI into this
  // app's own sandbox before it can be read. What is read is returned
  // whatever it is: whether it is news is the caller's decision (see
  // Index.syncClipboard and ContentPrint's classifyRead).
  async readCurrentClipboard(context: common.UIAbilityContext): Promise<ClipboardChange> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();

      if (data.hasMimeType(pasteboard.MIMETYPE_PIXELMAP)) {
        const pixelMap = data.getPrimaryPixelMap();
        const packer = image.createImagePacker();
        let packed: ArrayBuffer;
        try {
          packed = await packer.packToData(pixelMap, IMAGE_PACKING);
        } finally {
          // Freed now rather than by a later garbage collection, which does
          // not see native memory: the full-size pixels are tens of MB, and
          // the PNG made from them is all that is needed from here on.
          packer.release().catch(() => { /* released already */ });
          pixelMap.release().catch(() => { /* released already */ });
        }
        const bytes = new Uint8Array(packed);
        const hash = sha256Hex(bytes);
        return { type: 'image', content: arrayBufferToBase64(packed), hash, prints: [imagePrint(bytes)] };
      } else if (data.hasMimeType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        const text = data.getPrimaryText();
        return { type: 'text', content: text, hash: rawTextHash(text), prints: [textPrint(text)] };
      } else if (data.hasMimeType(pasteboard.MIMETYPE_TEXT_URI)) {
        // A URI handed to us via the pasteboard is scoped to the app that
        // copied it (e.g. Files), not to us - fs.openSync-ing it directly
        // fails silently/errors, because only the file-management APIs
        // (fs.copy) actually consume the transient cross-app read grant
        // the pasteboard service holds for that URI. Per the official
        // "使用系统剪贴板实现复制粘贴" guide: copy it into our own sandbox
        // first via fs.copy - the way a file shared to ClipLink is copied,
        // and by the same rules (see ShareIntake's copyFileIn): nothing of
        // ClipLink's own (a received file it put on the clipboard itself, or
        // a private file another app named), no folder, nothing over 1 GB.
        // The copy is hashed in chunks and handed over as a path for
        // FileStore to move in - never read into memory whole.
        const uri = data.getPrimaryUri();
        const path: string = newCopyPath(context);
        try {
          // Named the way a share is (no ?query, a stray '%' kept as it is):
          // a bad escape used to throw here and lose the whole paste.
          const fileName = uriFileName(uri);
          const refused: CopyRefusal | null = await copyFileIn(context, uri, path, false);
          if (refused !== null) {
            return { type: 'unsupported', content: '', hash: '', prints: [], refused, detail: `file not taken (${refused})` };
          }
          const size: number = fs.statSync(path).size;
          const hash: string = await sha256File(path);
          const print: string | null = filePrint(hash);
          return { type: 'file', content: '', hash, prints: print !== null ? [print] : [], fileName, path, size };
        } catch (e) {
          removeQuietly(path);
          return { type: 'unsupported', content: '', hash: '', prints: [], failed: true, detail: `could not read file: ${e}` };
        }
      } else {
        return { type: 'unsupported', content: '', hash: '', prints: [], detail: data.getMimeTypes().join(', ') };
      }
    } catch (e) {
      // Surfaced to the caller rather than swallowed — on a platform this
      // new, a permission or capability failure here is itself a finding.
      return { type: 'unsupported', content: '', hash: '', prints: [], failed: true, detail: `error: ${e}` };
    }
  }
}
