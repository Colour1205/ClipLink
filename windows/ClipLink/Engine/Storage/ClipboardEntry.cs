using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace ClipboardDaemon.Storage;

// One history entry, exactly as it is signed, sent, stored and relayed.
//
// Name is optional and only for Type "image": the picture's original name
// when the copy had one (see ImageName), without an extension, so the other
// devices can save it under that name. It is left out of the JSON when null,
// so an entry without one is written exactly as before. It is not signed (the
// signature covers Content, Type, DeviceId and Timestamp only, see
// SigningService), and it is not part of Key(): it is only a suggested file
// name, from a trusted device over the encrypted link, and every incoming one
// is cleaned (ImageNameJsonConverter). Older builds ignore the field.
public record ClipboardEntry(
    string Content,
    string Type,
    string DeviceId,
    DateTime Timestamp,
    string? Signature = null,
    string? Name = null)
{
    // The name reads as null on any entry that is not a picture, whatever a
    // peer sent, the history file held or a "with" set, so a text or file
    // entry is never stored or passed on with one (the protocol says a
    // receiver ignores it there). The JSON reader fills it through the
    // constructor, with this property's converter.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [JsonConverter(typeof(ImageNameJsonConverter))]
    public string? Name { get => Type == "image" ? field : null; init => field = value; } = Name;

    // What identifies this entry locally - to delete it, and to remember that
    // it was deleted (see DeletedEntries). Its signature exactly as received:
    // every synced entry has one, and it's the same wherever the entry
    // travels. The fallback is for an unsigned entry (none should reach
    // history). A method rather than a property, so it never ends up in the
    // entry's JSON - on disk or on the wire.
    public string Key() => !string.IsNullOrEmpty(Signature)
        ? Signature
        : $"{DeviceId}|{Type}|{Timestamp:o}|{Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Content ?? "")))}";

    // Two entries are the same entry when the signed fields and the
    // signature are, whatever their Name. History finds duplicates with this
    // (HistoryAccess.addToHistory, HistoryBatch.Merge), and the same entry
    // can arrive with its name and without it: relayed by an Android or iOS
    // build, which drops fields it doesn't know. Comparing Name too would
    // keep it twice.
    public virtual bool Equals(ClipboardEntry? other) =>
        other is not null
        && EqualityContract == other.EqualityContract
        && Content == other.Content
        && Type == other.Type
        && DeviceId == other.DeviceId
        && Timestamp == other.Timestamp
        && Signature == other.Signature;

    public override int GetHashCode() => HashCode.Combine(EqualityContract, Content, Type, DeviceId, Timestamp, Signature);
}
