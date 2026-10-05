// Step 10 of the build order in ../../../../README.md: file transfer.
// Mirrors windows/ClipLink/Engine/Networking/FileChunkMessage.cs exactly - one piece
// of a file being streamed (Envelope Type "file_chunk"), read/written
// incrementally on both ends so memory use stays bounded to one chunk
// regardless of the file's total size.
export interface FileChunkMessage {
  FileHash: string;
  ChunkIndex: number;
  IsLast: boolean;
  DataBase64: string;
}
