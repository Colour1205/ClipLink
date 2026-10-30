using System.Text.Json;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.Tests;

// The version 2 messages on the wire: the history_head of keys, times and
// deletions, and the key lists of history_request and delete.
public class SyncMessageTests
{
    private static readonly DateTime Start = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    private static ClipboardEntry Entry(int n) => new($"text {n}", "text", "PEER", Start.AddMinutes(n), $"sig-{n}");

    private static long Ms(int minutes) => new DateTimeOffset(Start.AddMinutes(minutes)).ToUnixTimeMilliseconds();

    private static string Payload(string keys, string? times = null, string? deleted = null, string? extra = null)
    {
        var parts = new List<string> { $"\"Keys\":{keys}" };
        if (times != null) parts.Add($"\"Times\":{times}");
        if (deleted != null) parts.Add($"\"Deleted\":{deleted}");
        if (extra != null) parts.Add(extra);
        return "{" + string.Join(",", parts) + "}";
    }

    private static string KeyList(int count, string prefix = "k") =>
        "[" + string.Join(",", Enumerable.Range(1, count).Select(i => $"\"{prefix}{i}\"")) + "]";

    private static string TimeList(int count) => "[" + string.Join(",", Enumerable.Range(1, count).Select(i => 1000 + i)) + "]";

    // ---- the head, written ----

    [Fact]
    public void The_head_lists_the_keys_newest_first_with_their_times_and_the_deletions()
    {
        var history = new List<ClipboardEntry> { Entry(1), Entry(3), Entry(2) };

        var head = HistoryHead.ForSync(history, new[] { "gone-2", "gone-1" });

        Assert.Equal(new[] { "sig-3", "sig-2", "sig-1" }, head.Keys);
        Assert.Equal(new[] { Ms(3), Ms(2), Ms(1) }, head.Times);
        Assert.Equal(new[] { "gone-2", "gone-1" }, head.Deleted);
    }

    [Fact]
    public void The_head_is_written_as_keys_times_and_deleted_and_nothing_else()
    {
        var head = HistoryHead.ForSync(new List<ClipboardEntry> { Entry(1), Entry(2) }, new[] { "gone" });

        string json = JsonSerializer.Serialize(new Envelope("history_head", JsonSerializer.Serialize(head)));

        using var envelope = JsonDocument.Parse(json);
        using var payload = JsonDocument.Parse(envelope.RootElement.GetProperty("Payload").GetString()!);
        Assert.Equal(new[] { "Keys", "Times", "Deleted" }, payload.RootElement.EnumerateObject().Select(p => p.Name)); // no Newest
        Assert.Equal(
            "{\"Type\":\"history_head\",\"Payload\":\"{\\u0022Keys\\u0022:[\\u0022sig-2\\u0022,\\u0022sig-1\\u0022],\\u0022Times\\u0022:[" + Ms(2) + "," + Ms(1) + "],\\u0022Deleted\\u0022:[\\u0022gone\\u0022]}\"}",
            json);
    }

    [Fact]
    public void An_empty_history_still_has_a_head()
    {
        var head = HistoryHead.ForSync(new List<ClipboardEntry>(), Array.Empty<string>());

        Assert.Equal("{\"Keys\":[],\"Times\":[],\"Deleted\":[]}", JsonSerializer.Serialize(head));
    }

    [Fact]
    public void The_head_lists_at_most_25_keys_and_500_deletions()
    {
        var history = Enumerable.Range(1, 40).Select(Entry).ToList();

        var head = HistoryHead.ForSync(history, Enumerable.Range(1, 800).Select(i => $"gone-{i}"));

        Assert.Equal(25, head.Keys.Count);
        Assert.Equal("sig-40", head.Keys[0]);
        Assert.Equal("sig-16", head.Keys[^1]);
        Assert.Equal(25, head.Times!.Count);
        Assert.Equal(500, head.Deleted.Count);
        Assert.Equal("gone-1", head.Deleted[0]);
    }

    [Fact]
    public void A_time_is_unix_milliseconds_in_utc_whatever_the_kind_of_the_timestamp()
    {
        var utc = new DateTime(2026, 10, 1, 12, 0, 0, 123, DateTimeKind.Utc);

        Assert.Equal(1_790_856_000_123, HistoryHead.UnixMs(utc));
        Assert.Equal(HistoryHead.UnixMs(utc), HistoryHead.UnixMs(DateTime.SpecifyKind(utc, DateTimeKind.Unspecified)));
        Assert.Equal(HistoryHead.UnixMs(utc), HistoryHead.UnixMs(utc.ToLocalTime()));
    }

    // ---- the head, read ----

    [Fact]
    public void A_head_the_sender_wrote_is_read_back()
    {
        var sent = HistoryHead.ForSync(Enumerable.Range(1, 5).Select(Entry).ToList(), new[] { "a", "b" });

        var received = HistoryHead.ParseSync(JsonSerializer.Serialize(sent))!;

        Assert.Equal(sent.Keys, received.Keys);
        Assert.Equal(sent.Times, received.Times);
        Assert.Equal(sent.Deleted, received.Deleted);
    }

    [Fact]
    public void A_head_without_times_or_deleted_is_read_with_none()
    {
        var head = HistoryHead.ParseSync(Payload("[\"a\",\"b\"]"))!;

        Assert.Equal(new[] { "a", "b" }, head.Keys);
        Assert.Null(head.Times);
        Assert.Empty(head.Deleted);
    }

    [Theory]
    [InlineData("[1]")]
    [InlineData("[1,2,3]")]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("\"1,2\"")]
    [InlineData("[1,\"2\"]")]
    [InlineData("[1,null]")]
    public void Times_that_do_not_fit_the_keys_are_not_used(string times)
    {
        var head = HistoryHead.ParseSync(Payload("[\"a\",\"b\"]", times))!;

        Assert.Equal(new[] { "a", "b" }, head.Keys);
        Assert.Null(head.Times);
    }

    [Fact]
    public void Times_that_fit_are_read_as_they_are()
    {
        var head = HistoryHead.ParseSync(Payload("[\"a\",\"b\"]", "[1730000000123,1730000000100]"))!;

        Assert.Equal(new[] { 1730000000123L, 1730000000100L }, head.Times);
    }

    [Fact]
    public void A_time_written_as_a_float_is_still_a_time()
    {
        var head = HistoryHead.ParseSync(Payload("[\"a\"]", "[1730000000123.0]"))!;

        Assert.Equal(new[] { 1730000000123L }, head.Times);
    }

    [Fact]
    public void More_than_25_keys_use_the_first_25_and_more_than_500_deleted_the_first_500()
    {
        var head = HistoryHead.ParseSync(Payload(KeyList(30), TimeList(30), KeyList(600, "d")))!;

        Assert.Equal(25, head.Keys.Count);
        Assert.Equal("k25", head.Keys[^1]);
        Assert.Equal(25, head.Times!.Count);
        Assert.Equal(1025, head.Times[^1]);
        Assert.Equal(500, head.Deleted.Count);
        Assert.Equal("d500", head.Deleted[^1]);
    }

    [Fact]
    public void Keys_that_are_not_usable_do_not_use_up_places_of_the_25()
    {
        // Five empty keys, then 25 good ones: all 25 good ones are taken.
        string keys = "[\"\",\"\",\"\",\"\",\"\"," + string.Join(",", Enumerable.Range(1, 25).Select(i => $"\"k{i}\"")) + "]";
        string times = "[" + string.Join(",", Enumerable.Range(1, 30)) + "]";

        var head = HistoryHead.ParseSync(Payload(keys, times))!;

        Assert.Equal(25, head.Keys.Count);
        Assert.Equal("k1", head.Keys[0]);
        Assert.Equal("k25", head.Keys[^1]);
        Assert.Equal(25, head.Times!.Count);
        Assert.Equal(6L, head.Times[0]);
        Assert.Equal(30L, head.Times[^1]);
    }

    [Fact]
    public void A_key_that_is_not_a_string_or_is_empty_or_too_long_is_left_out_with_its_time()
    {
        string tooLong = new('x', KeysMessage.MaxKeyLength + 1);
        string json = $"{{\"Keys\":[\"a\",5,\"\",\"{tooLong}\",null,\"b\"],\"Times\":[1,2,3,4,5,6],\"Deleted\":[\"d\",7,\"{tooLong}\"]}}";

        var head = HistoryHead.ParseSync(json)!;

        Assert.Equal(new[] { "a", "b" }, head.Keys);
        Assert.Equal(new[] { 1L, 6L }, head.Times);
        Assert.Equal(new[] { "d" }, head.Deleted);
    }

    [Fact]
    public void A_bad_time_next_to_a_bad_key_does_not_turn_off_the_times_of_the_head()
    {
        // The time of a key that is left out is not looked at at all.
        string json = "{\"Keys\":[\"a\",5,\"\",null,\"b\"],\"Times\":[1,\"x\",null,{},3]}";

        var head = HistoryHead.ParseSync(json)!;

        Assert.Equal(new[] { "a", "b" }, head.Keys);
        Assert.Equal(new[] { 1L, 3L }, head.Times);
    }

    [Fact]
    public void A_bad_time_next_to_a_good_key_still_turns_the_times_off()
    {
        var head = HistoryHead.ParseSync("{\"Keys\":[\"a\",5,\"b\"],\"Times\":[1,2,\"x\"]}")!;

        Assert.Equal(new[] { "a", "b" }, head.Keys);
        Assert.Null(head.Times);
    }

    [Fact]
    public void A_key_of_exactly_the_longest_length_is_kept()
    {
        string longest = new('x', KeysMessage.MaxKeyLength);

        var head = HistoryHead.ParseSync(Payload($"[\"{longest}\"]"))!;

        Assert.Equal(new[] { longest }, head.Keys);
    }

    [Fact]
    public void Unknown_keys_are_skipped_and_a_Newest_is_ignored()
    {
        // A version 1 peer's head, read as a version 2 one: the keys are there, the entry is not used.
        const string v15 = "{\"Newest\":{\"Content\":\"hi\",\"Type\":\"text\",\"DeviceId\":\"PEER\",\"Timestamp\":\"2026-10-01T12:03:00.0000000Z\",\"Signature\":\"sig-3\"},\"Keys\":[\"sig-3\",\"sig-2\"],\"Future\":{\"x\":1}}";

        var head = HistoryHead.ParseSync(v15)!;

        Assert.Equal(new[] { "sig-3", "sig-2" }, head.Keys);
        Assert.Null(head.Times);
        Assert.Empty(head.Deleted);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("\"Keys\"")]
    [InlineData("null")]
    public void A_payload_that_is_not_a_head_is_nothing(string payload)
    {
        Assert.Null(HistoryHead.ParseSync(payload));
    }

    [Fact]
    public void A_head_with_nothing_in_it_is_a_head_with_no_keys()
    {
        var head = HistoryHead.ParseSync("{}")!;

        Assert.Empty(head.Keys);
        Assert.Null(head.Times);
        Assert.Empty(head.Deleted);
    }

    [Fact]
    public void A_version_1_head_is_still_the_same_message()
    {
        // The v1.5 form: used on a connection that speaks version 1, exactly as before.
        var head = HistoryHead.ForBatch(new List<ClipboardEntry> { Entry(1), Entry(2) })!;

        using var payload = JsonDocument.Parse(JsonSerializer.Serialize(head));

        Assert.Equal(new[] { "Newest", "Keys" }, payload.RootElement.EnumerateObject().Select(p => p.Name));
    }

    // ---- history_request and delete ----

    [Fact]
    public void A_key_message_is_written_as_Keys()
    {
        string payload = Assert.Single(KeysMessage.Serialize(new[] { "sig-1", "sig-2" }));

        Assert.Equal("{\"Keys\":[\"sig-1\",\"sig-2\"]}", payload);
        Assert.Equal("{\"Type\":\"history_request\",\"Payload\":\"{\\u0022Keys\\u0022:[\\u0022sig-1\\u0022,\\u0022sig-2\\u0022]}\"}",
            JsonSerializer.Serialize(new Envelope("history_request", payload)));
        Assert.Equal("{\"Type\":\"delete\",\"Payload\":\"{\\u0022Keys\\u0022:[\\u0022sig-1\\u0022]}\"}",
            JsonSerializer.Serialize(new Envelope("delete", KeysMessage.Serialize(new[] { "sig-1" })[0])));
    }

    [Fact]
    public void More_than_100_keys_are_split_into_messages_of_100()
    {
        var keys = Enumerable.Range(1, 250).Select(i => $"k{i}").ToList();

        var messages = KeysMessage.Serialize(keys);

        Assert.Equal(3, messages.Count);
        Assert.Equal(new[] { 100, 100, 50 }, messages.Select(m => KeysMessage.Parse(m).Count));
        Assert.Equal(keys, messages.SelectMany(KeysMessage.Parse));
    }

    [Fact]
    public void No_keys_is_no_message()
    {
        Assert.Empty(KeysMessage.Serialize(Array.Empty<string>()));
    }

    [Fact]
    public void A_received_list_over_100_keys_is_cut_at_the_first_100()
    {
        var keys = KeysMessage.Parse("{\"Keys\":" + KeyList(150) + "}");

        Assert.Equal(100, keys.Count);
        Assert.Equal("k100", keys[^1]);
    }

    [Fact]
    public void Keys_that_are_not_strings_or_are_too_long_are_ignored()
    {
        string tooLong = new('x', KeysMessage.MaxKeyLength + 1);

        var keys = KeysMessage.Parse($"{{\"Keys\":[\"a\",1,null,{{}},\"{tooLong}\",\"b\"],\"Other\":1}}");

        Assert.Equal(new[] { "a", "b" }, keys);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("{\"Keys\":5}")]
    [InlineData("{\"Keys\":null}")]
    public void A_payload_without_keys_is_no_keys(string? payload)
    {
        Assert.Empty(KeysMessage.Parse(payload));
    }
}
