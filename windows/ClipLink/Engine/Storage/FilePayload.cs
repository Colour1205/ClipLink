namespace ClipboardDaemon.Storage;

// What ClipboardEntry.Content holds for Type == "file": just a small
// descriptor — name, hash, size — never the file's actual bytes. The bytes
// travel separately, streamed in chunks (see Networking/FileChunkMessage.cs),
// and get cached locally by hash in FileStore. Keeping this tiny is what
// makes signing it (and storing it in history) cheap regardless of file size.
public record FilePayload(string FileName, string FileHash, long FileSize);
