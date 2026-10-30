namespace ClipboardDaemon.Networking;

// Wraps every message sent over a PeerConnection so the receiver knows what
// kind of thing Payload actually is before trying to deserialize it.
//   Type == "entry"         -> Payload is one serialized ClipboardEntry (a live clipboard change)
//   Type == "history_head"  -> Payload is a serialized HistoryHead.Payload (sent just before the batch, only when it has 2+ entries)
//   Type == "history_batch" -> Payload is a serialized List<ClipboardEntry> (sent once on connect)
public record Envelope(string Type, string Payload);
