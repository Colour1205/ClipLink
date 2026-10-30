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

const base64Helper = new util.Base64Helper();

// 'skipped': the user turned off "Copy received items automatically", so the
// entry was recorded but deliberately not written to the pasteboard.
export type ApplyResult = 'applied' | 'unsupported-type' | 'error' | 'skipped';

export async function applyEntryToClipboard(entry: ClipboardEntry, fileStore?: FileStore): Promise<ApplyResult> {
  try {
    if (entry.Type === 'text') {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, entry.Content);
      await pasteboard.getSystemPasteboard().setData(data);
      return 'applied';
    } else if (entry.Type === 'image') {
      // Decoded on a worker (the promise form): a photo is MBs of Base64,
      // and this runs as an item arrives, with the UI thread busy already.
      const imageBytes = await base64Helper.decode(entry.Content);
      const imageSource = image.createImageSource(imageBytes.buffer as ArrayBuffer);
      const pixelMap = await imageSource.createPixelMap();
      const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
      await pasteboard.getSystemPasteboard().setData(data);
      return 'applied';
    } else if (entry.Type === 'file' && fileStore) {
      let payload: FilePayload;
      try {
        payload = JSON.parse(entry.Content) as FilePayload;
      } catch (e) {
        return 'error';
      }
      if (!fileStore.exists(payload.FileHash)) return 'unsupported-type'; // bytes not here yet
      const uri = fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
      const data = pasteboard.createUriData(uri);
      await pasteboard.getSystemPasteboard().setData(data);
      return 'applied';
    } else {
      return 'unsupported-type';
    }
  } catch (e) {
    return 'error';
  }
}
