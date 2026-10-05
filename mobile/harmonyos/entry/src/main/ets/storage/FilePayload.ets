// Step 10 of the build order in ../../../../README.md: file transfer.
// Mirrors windows/ClipLink/Engine/Storage/FilePayload.cs exactly - what
// ClipboardEntry.Content holds for Type == "file": just a small descriptor
// (name, hash, size), never the file's actual bytes. The bytes travel
// separately, streamed in chunks (see networking/FileChunkMessage.ets), and
// get cached locally by hash in FileStore.
export interface FilePayload {
  FileName: string;
  FileHash: string;
  FileSize: number;
}
