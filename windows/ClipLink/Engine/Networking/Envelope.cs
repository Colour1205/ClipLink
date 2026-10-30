namespace ClipboardDaemon.Networking;

// Wraps every message sent over a PeerConnection so the receiver knows what
// kind of thing Payload actually is before trying to deserialize it.
//   Type == "entry"         -> Payload is one serialized ClipboardEntry (a live clipboard change)
//   Type == "history_head"  -> Payload is a serialized HistoryHead (sent on connect: version 2 connections always, the keys and times; version 1 ones just before the batch, only when it has 2+ entries)
//   Type == "history_batch" -> Payload is a serialized List<ClipboardEntry> (version 1: the whole history, sent once on connect; version 2: the answer to a history_request)
//   Type == "history_request" -> Payload is a serialized KeysMessage (version 2 only: the keys of the entries wanted)
//   Type == "delete"        -> Payload is a serialized KeysMessage (version 2 only: entries the user deleted on the sender)
public record Envelope(string Type, string Payload);
