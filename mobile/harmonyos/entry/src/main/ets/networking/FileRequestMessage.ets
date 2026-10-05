// Step 10 of the build order in ../../../../README.md: file transfer.
// Mirrors windows/ClipLink/Engine/Networking/FileRequestMessage.cs exactly - "does
// anyone have this file?", broadcast to every connected peer, not just
// whoever handed us the entry we're missing bytes for. Only ever carries a
// hash, never a path - paths aren't portable across devices.
export interface FileRequestMessage {
  FileHash: string;
}
