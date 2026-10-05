namespace ClipboardDaemon.Networking;

// "Does anyone have this file?" — broadcast to every connected peer, not just
// whoever handed us the entry we're missing bytes for. Only ever carries a
// hash; never a path (see the reasoning in ClipboardSync/Storage/FileStore —
// paths aren't portable across devices or reliable over time, only content
// this device has actually cached itself is ever worth asking about).
public record FileRequestMessage(string FileHash);
