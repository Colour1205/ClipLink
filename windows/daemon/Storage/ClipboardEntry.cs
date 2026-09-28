using System.Security.Cryptography;
using System.Text;

namespace ClipboardDaemon.Storage;

public record ClipboardEntry(string Content, string Type, string DeviceId, DateTime Timestamp, string? Signature = null)
{
    // What identifies this entry locally - to delete it, and to remember that
    // it was deleted (see DeletedEntries). Its signature exactly as received:
    // every synced entry has one, and it's the same wherever the entry
    // travels. The fallback is for an unsigned entry (none should reach
    // history). A method rather than a property, so it never ends up in the
    // entry's JSON - on disk or on the wire.
    public string Key() => !string.IsNullOrEmpty(Signature)
        ? Signature
        : $"{DeviceId}|{Type}|{Timestamp:o}|{Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Content ?? "")))}";
}
