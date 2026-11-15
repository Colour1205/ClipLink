// Step 8/10 of the build order in ../../../../README.md: full sync + file
// transfer. Mirrors ClipboardSync.cs's setContent - applies a received
// (already verified) entry's content to the local system clipboard. Unlike
// reading (step 3), writing needs no restricted permission at all - setData/
// setDataSync carry no @permission tag in the SDK, confirmed by inspection.
//
// "file" applying a URI onto the system pasteboard (fileUri.getUriFromPath +
// pasteboard.createUriData) is best-effort: HarmonyOS's sandboxing means a
// file:// URI scoped to this app may not resolve for whatever app the user
// pastes into without an explicit URI permission grant this project doesn't
// set up. The synced list's "Share" (images, files) and "Copy" actions
// (Index.ets) are the reliable path; this is a bonus that works
// when it works.

import pasteboard from '@ohos.pasteboard';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import fileUri from '@ohos.file.fileuri';
import { ClipboardEntry } from '../crypto/Signing';
import { FileStore } from '../storage/FileStore';
import { FilePayload } from '../storage/FilePayload';
import { safeFileName } from '../storage/FileNames';
import { contentKey, imagePrint } from '../storage/ContentPrint';
import { IMAGE_PACKING } from './ClipboardWatcher';

const base64Helper = new util.Base64Helper();

// 'skipped': the user turned off "Copy received items automatically", so the
// entry was recorded but deliberately not written to the pasteboard.
// 'already': not written because the clipboard holds that content already,
// as far as ClipLink knows (it wrote it, or just sent it - an older peer
// echoing it back, say): nothing changes, so nobody is told.
// 'held': a file whose bytes came late, not written because something newer
// went on the clipboard meanwhile (see SyncManager's pending files).
export type ApplyResult = 'applied' | 'unsupported-type' | 'error' | 'skipped' | 'already' | 'held';

// What a write did, and on success the prints of what is on the clipboard now
// (see storage/ContentPrint.ets): the entry's own, and for a picture the one
// this app's own read would give for it, since a read packs it into a PNG of
// its own (ClipboardWatcher), whose bytes are not the ones received.
export interface ClipboardWrite {
  result: ApplyResult;
  prints: string[];
}

export async function applyEntryToClipboard(entry: ClipboardEntry, fileStore?: FileStore): Promise<ApplyResult> {
  return (await writeEntryToClipboard(entry, fileStore)).result;
}

function written(entry: ClipboardEntry, extra: string | null = null): ClipboardWrite {
  const prints: string[] = [];
  const key: string | null = contentKey(entry);
  if (key !== null) prints.push(key);
  if (extra !== null && !prints.includes(extra)) prints.push(extra);
  return { result: 'applied', prints: prints };
}

function failed(result: ApplyResult): ClipboardWrite {
  return { result: result, prints: [] };
}

export async function writeEntryToClipboard(entry: ClipboardEntry, fileStore?: FileStore): Promise<ClipboardWrite> {
  try {
    if (entry.Type === 'text') {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, entry.Content);
      await pasteboard.getSystemPasteboard().setData(data);
      return written(entry);
    } else if (entry.Type === 'image') {
      // Decoded on a worker (the promise form): a photo is MBs of Base64,
      // and this runs as an item arrives, with the UI thread busy already.
      const imageBytes = await base64Helper.decode(entry.Content);
      // Released as soon as they are done with, not left to the garbage
      // collector, which does not see native memory: a 4K picture is about
      // 33 MB of pixels, and a run of them piled up before a finalizer ran.
      // setData has handed the pasteboard service its own copy by the time it
      // resolves, so the pasted picture is not affected.
      const imageSource = image.createImageSource(imageBytes.buffer as ArrayBuffer);
      let pixelMap: image.PixelMap | null = null;
      try {
        pixelMap = await imageSource.createPixelMap();
        const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
        await pasteboard.getSystemPasteboard().setData(data);
        return written(entry, await readBackPrint(pixelMap));
      } finally {
        releaseQuietly(pixelMap);
        imageSource.release().catch(() => { /* released already */ });
      }
    } else if (entry.Type === 'file' && fileStore) {
      let payload: FilePayload;
      try {
        payload = JSON.parse(entry.Content) as FilePayload;
      } catch (e) {
        return failed('error');
      }
      if (!fileStore.exists(payload.FileHash)) return failed('unsupported-type'); // bytes not here yet
      // Under its real name, as Share and drag-out hand it over: the stored
      // blob is named by its hash, with no extension, and a paste made a file
      // of that name.
      const path: string = await fileStore.clipboardPath(payload.FileHash, safeFileName(payload.FileName, 'file'));
      const data = pasteboard.createUriData(fileUri.getUriFromPath(path));
      await pasteboard.getSystemPasteboard().setData(data);
      return written(entry);
    } else {
      return failed('unsupported-type');
    }
  } catch (e) {
    return failed('error');
  }
}

// The print a read of this picture would give - best effort: none if packing
// fails. Mostly the change count tells ClipLink's own write apart; this is for
// when the count can't (the pasteboard service restarted, say).
async function readBackPrint(pixelMap: image.PixelMap): Promise<string | null> {
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const packed: ArrayBuffer = await packer.packToData(pixelMap, IMAGE_PACKING);
    return imagePrint(new Uint8Array(packed));
  } catch (e) {
    return null;
  } finally {
    packer.release().catch(() => { /* released already */ });
  }
}

// Frees a PixelMap's native pixels now; never throws (see the image branch
// above for why this is not left to the garbage collector).
export function releaseQuietly(pixelMap: image.PixelMap | null): void {
  if (pixelMap === null) return;
  try {
    pixelMap.release().catch(() => { /* released already */ });
  } catch (e) {
    // released already
  }
}
