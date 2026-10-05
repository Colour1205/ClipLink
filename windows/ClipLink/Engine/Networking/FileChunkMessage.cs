namespace ClipboardDaemon.Networking;

// One piece of a file being streamed — sent as a sequence of these (Envelope
// Type "file_chunk"), read/written incrementally on both ends, so memory use
// stays bounded to one chunk regardless of the file's total size.
public record FileChunkMessage(string FileHash, int ChunkIndex, bool IsLast, string DataBase64);
