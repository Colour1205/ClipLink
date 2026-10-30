using System.Text.Json;

namespace ClipboardDaemon.Networking;

// The payload of "history_request" and "delete": {"Keys":["<key>", ...]},
// each a ClipboardEntry.Key() (its signature). At most MaxKeys to a message.
public sealed record KeysMessage(List<string> Keys)
{
    public const int MaxKeys = 100;
    // A longer key is not a key any device made.
    public const int MaxKeyLength = 2048;

    // The message for these keys, split in messages of at most MaxKeys.
    public static List<string> Serialize(IReadOnlyList<string> keys) =>
        keys.Chunk(MaxKeys).Select(chunk => JsonSerializer.Serialize(new KeysMessage(chunk.ToList()))).ToList();

    // The keys of a received payload: the first MaxKeys of its list, without
    // anything that is not a string or is too long. Never throws: anything
    // else (not JSON, no Keys) is no keys.
    public static List<string> Parse(string? payload)
    {
        var keys = new List<string>();
        if (string.IsNullOrEmpty(payload)) return keys;
        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("Keys", out var list) || list.ValueKind != JsonValueKind.Array)
            {
                return keys;
            }
            foreach (var item in list.EnumerateArray().Take(MaxKeys))
            {
                if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: <= MaxKeyLength } key && key.Length > 0)
                {
                    keys.Add(key);
                }
            }
        }
        catch (JsonException) { }
        return keys;
    }
}
