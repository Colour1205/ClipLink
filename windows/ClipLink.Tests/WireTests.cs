using System.Net;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.Tests;

// How messages are written for the wire (Wire): fewer escapes than the default
// encoder, but the same JSON values, which every older build reads as before.
// And the per-network beacon targets (Discovery.DirectedBroadcast).
public class WireTests
{
    private static readonly DateTime Start = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    // Base64 with '+' and '/', a quote, a backslash, a control character, CJK,
    // an emoji (a surrogate pair) and an HTML-ish '<' - every kind of text the
    // two encoders write differently.
    private const string Awkward = "ab+/cd== \"quoted\" back\\slash tab\t 中文剪贴板 🙂 <b>&amp;</b>";

    private static ClipboardEntry Entry(string content) => new(content, "text", "PEER+KEY/==", Start, "sig+/==");

    [Fact]
    public void An_envelope_is_the_same_text_as_serializing_it_the_usual_way_with_the_wire_options()
    {
        var entry = Entry(Awkward);

        byte[] made = Wire.Envelope("entry", entry).ToArray();

        string expected = JsonSerializer.Serialize(new Envelope("entry", JsonSerializer.Serialize(entry, Wire.Json)), Wire.Json);
        Assert.Equal(expected, Encoding.UTF8.GetString(made));
    }

    [Fact]
    public void An_envelope_reads_back_with_the_default_options_as_the_same_values()
    {
        // What an older build does with it: the default deserializer, twice.
        var entry = Entry(Awkward);

        var envelope = JsonSerializer.Deserialize<Envelope>(Wire.Envelope("entry", entry).Span)!;
        var read = JsonSerializer.Deserialize<ClipboardEntry>(envelope.Payload)!;

        Assert.Equal("entry", envelope.Type);
        Assert.Equal(entry, read);
    }

    [Fact]
    public void An_envelope_of_json_text_carries_that_text_unchanged()
    {
        var envelope = JsonSerializer.Deserialize<Envelope>(Wire.Envelope("unpair", "{}").Span)!;

        Assert.Equal("unpair", envelope.Type);
        Assert.Equal("{}", envelope.Payload);
    }

    [Theory]
    [InlineData("{\n  \"Keys\": [\"a\\\\b\", \"q\\\"\"]\r\n}\t")] // indented: whitespace between tokens
    [InlineData("\u0001\u001F\b\f raw controls, \"quotes\" and \\ backslashes")]
    [InlineData("")]
    public void Json_text_goes_into_the_envelope_as_the_writer_would_put_it(string payloadJson)
    {
        string made = Encoding.UTF8.GetString(Wire.Envelope("delete", payloadJson).Span);

        Assert.Equal(JsonSerializer.Serialize(new Envelope("delete", payloadJson), Wire.Json), made);
        Assert.Equal(payloadJson, JsonSerializer.Deserialize<Envelope>(made)!.Payload);
    }

    [Fact]
    public void A_serialized_payload_with_cjk_and_emoji_goes_in_as_the_writer_would_put_it()
    {
        string payloadJson = JsonSerializer.Serialize(new KeysMessage(new List<string> { "中文 🙂 é <&> '+/'" }), Wire.Json);

        string made = Encoding.UTF8.GetString(Wire.Envelope("delete", payloadJson).Span);

        Assert.Equal(JsonSerializer.Serialize(new Envelope("delete", payloadJson), Wire.Json), made);
    }

    [Fact]
    public void Raw_non_ascii_in_json_text_still_reads_back_the_same()
    {
        // Not what a serializer writes (it escapes an emoji), but still JSON.
        const string payloadJson = "[\"中文 🙂\"]";

        var envelope = JsonSerializer.Deserialize<Envelope>(Wire.Envelope("delete", payloadJson).Span)!;

        Assert.Equal(payloadJson, envelope.Payload);
    }

    [Fact]
    public void Base64_and_cjk_go_out_smaller_than_with_the_default_encoder()
    {
        var chunk = new FileChunkMessage("HASH", 0, false, Convert.ToBase64String(Enumerable.Range(0, 4096).Select(i => (byte)(i * 37)).ToArray()));
        int relaxed = Wire.Envelope("file_chunk", chunk).Length;
        int usual = Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(new Envelope("file_chunk", JsonSerializer.Serialize(chunk))));
        Assert.True(relaxed < usual, $"{relaxed} >= {usual}");

        int cjk = Wire.Envelope("entry", Entry("中文剪贴板")).Length;
        int cjkUsual = Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(new Envelope("entry", JsonSerializer.Serialize(Entry("中文剪贴板")))));
        Assert.True(cjk < cjkUsual, $"{cjk} >= {cjkUsual}");
    }

    [Fact]
    public void A_key_list_reads_back_the_same_with_the_default_options()
    {
        var keys = new List<string> { "a+b/c==", "中", "\"q\"" };

        string json = Assert.Single(KeysMessage.Serialize(keys));

        Assert.Equal(keys, JsonSerializer.Deserialize<KeysMessage>(json)!.Keys);
        Assert.DoesNotContain("\\u002B", json);
    }

    // ---- directed broadcasts ----

    [Theory]
    [InlineData("192.168.1.120", 24, "192.168.1.255")]
    [InlineData("172.20.80.1", 20, "172.20.95.255")]
    [InlineData("10.1.2.3", 8, "10.255.255.255")]
    [InlineData("192.168.43.5", 30, "192.168.43.7")]
    public void A_network_broadcasts_to_its_own_last_address(string address, int prefix, string expected)
    {
        Assert.Equal(IPAddress.Parse(expected), Discovery.DirectedBroadcast(IPAddress.Parse(address), prefix));
    }

    [Theory]
    [InlineData("100.100.1.1", 32)]   // Tailscale: one address, no broadcast
    [InlineData("192.168.1.2", 31)]   // a point-to-point pair
    [InlineData("169.254.10.20", 16)] // an adapter that never got an address
    [InlineData("127.0.0.1", 8)]      // loopback
    [InlineData("192.168.1.2", 0)]
    [InlineData("fe80::1", 64)]       // IPv6 has no broadcast
    public void Links_without_a_broadcast_worth_sending_get_none(string address, int prefix)
    {
        Assert.Null(Discovery.DirectedBroadcast(IPAddress.Parse(address), prefix));
    }

    [Fact]
    public void This_pcs_own_networks_never_include_the_limited_broadcast_or_loopback()
    {
        foreach (var target in Discovery.DirectedBroadcasts())
        {
            Assert.NotEqual(IPAddress.Broadcast, target);
            Assert.False(IPAddress.IsLoopback(target));
        }
    }
}
