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

import pasteboard from '@ohos.pasteboard';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { sha256File } from '../storage/FileStore';
import { copyFileIn, CopyRefusal, newCopyPath, removeQuietly } from '../share/ShareIntake';

const base64Helper = new util.Base64Helper();

export type ClipboardContentType = 'text' | 'image' | 'file' | 'unsupported';

export interface ClipboardChange {
  type: ClipboardContentType;
  content: string; // text; base64 PNG for images; '' for files (see path)
  hash: string;
  fileName?: string; // only set for type 'file'
  // Type 'file': this app's own cache copy of it, for FileStore.adopt to
  // take over (or the caller to delete), and its size in bytes.
  path?: string;
  size?: number;
  // Type 'unsupported': a file the paste wouldn't take, and why.
  refused?: CopyRefusal;
  detail?: string; // e.g. the unsupported mime type list, or an error message
}

async function sha256Hex(data: Uint8Array): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data });
  const result = await md.digest();
  let out = '';
  for (let i = 0; i < result.data.length; i++) {
    out += result.data[i].toString(16).padStart(2, '0');
  }
  return out;
}

// See crypto/Signing.ets's stringToBytes for the full explanation - this
// was the same bug (truncating UTF-16 code units into single bytes instead
// of real UTF-8 encoding). Here it only affected the hash used for local
// change-detection dedup (the actual copied text itself was never mangled
// by this), but a wrong hash for non-ASCII text meant it wouldn't reliably
// suppress echoes/duplicates of that text either.
const textEncoder = util.TextEncoder.create('utf-8');
function utf8Bytes(s: string): Uint8Array {
  return textEncoder.encodeInto(s);
}

function arrayBufferToBase64(buf: ArrayBuffer): string {
  return base64Helper.encodeToStringSync(new Uint8Array(buf));
}

export class ClipboardWatcher {
  private lastKnownHash: string | null = null;
  private listening = false;
  private changedCallback: (() => void) | null = null;
  // The pasteboard's change counter (getChangeCount, API 18+, no permission)
  // as of the last time this app itself wrote to or read the clipboard.
  // -1 until first recorded, so whatever is on the clipboard when the app
  // first opens counts as new - that's the "copied elsewhere, then opened
  // ClipLink" case this exists for.
  private lastSeenCount: number = -1;
  // Filters out 'update' events caused by this app's own writes (applying a
  // received item, Copy, Copy pairing info...), which previously flagged
  // ClipLink's own clipboard writes as something new to send.
  private boundHandler = () => {
    if (this.hasUnseenChange()) this.changedCallback?.();
  };

  // Call right after this app writes to the clipboard, and after a
  // PasteButton read, so the change it caused isn't reported back as new.
  // Returns the recorded count (-1 if unavailable) so the caller can persist
  // it - otherwise a restart forgets it and ClipLink's own last write shows
  // up as "New copy".
  markSeen(): number {
    try {
      this.lastSeenCount = pasteboard.getSystemPasteboard().getChangeCount();
    } catch (e) {
      // counter unavailable - leave the previous value
    }
    return this.lastSeenCount;
  }

  // The counter persists until reboot or a pasteboard service restart; after
  // either it restarts from 0, won't match, and the content counts as new.
  restoreSeen(count: number): void {
    this.lastSeenCount = count;
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

  // For a caller that couldn't sync what readCurrentClipboard just returned
  // (couldn't store the file, say): the next read returns the same content
  // again, rather than null for "unchanged since last sync".
  forget(): void {
    this.lastKnownHash = null;
  }

  // Only valid to call from inside a PasteButton onClick handler, in the
  // window after a SUCCESS result — that's what grants the temporary
  // pasteboard read privilege this needs. context is only used for the
  // file branch (see below) - needed to copy a cross-app URI into this
  // app's own sandbox before it can be read.
  async readCurrentClipboard(context: common.UIAbilityContext): Promise<ClipboardChange | null> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();

      if (data.hasMimeType(pasteboard.MIMETYPE_PIXELMAP)) {
        const pixelMap = data.getPrimaryPixelMap();
        const packer = image.createImagePacker();
        const packed = await packer.packToData(pixelMap, { format: 'image/png', quality: 100 });
        const bytes = new Uint8Array(packed);
        const hash = await sha256Hex(bytes);
        if (hash === this.lastKnownHash) return null;
        this.lastKnownHash = hash;
        return { type: 'image', content: arrayBufferToBase64(packed), hash };
      } else if (data.hasMimeType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        const text = data.getPrimaryText();
        const hash = await sha256Hex(utf8Bytes(text));
        if (hash === this.lastKnownHash) return null;
        this.lastKnownHash = hash;
        return { type: 'text', content: text, hash };
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
          const fileName = decodeURIComponent(uri.split('/').pop() ?? 'file');
          const refused: CopyRefusal | null = await copyFileIn(context, uri, path, false);
          if (refused !== null) {
            return { type: 'unsupported', content: '', hash: '', refused, detail: `file not taken (${refused})` };
          }
          const size: number = fs.statSync(path).size;
          const hash: string = await sha256File(path);
          if (hash === this.lastKnownHash) {
            removeQuietly(path);
            return null;
          }
          this.lastKnownHash = hash;
          return { type: 'file', content: '', hash, fileName, path, size };
        } catch (e) {
          removeQuietly(path);
          return { type: 'unsupported', content: '', hash: '', detail: `could not read file: ${e}` };
        }
      } else {
        return { type: 'unsupported', content: '', hash: '', detail: data.getMimeTypes().join(', ') };
      }
    } catch (e) {
      // Surfaced to the caller rather than swallowed — on a platform this
      // new, a permission or capability failure here is itself a finding.
      return { type: 'unsupported', content: '', hash: '', detail: `error: ${e}` };
    }
  }
}
