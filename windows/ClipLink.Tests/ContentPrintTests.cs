using System.Text.Json;
using ClipboardDaemon.Storage;
using ClipLink;
using Xunit;

namespace ClipLink.Tests;

// How content is recognised whoever copied it (ContentPrint): the comparison
// text, the prints - the same vectors every app's tests use (see
// design/sync-dedupe-spec.md, rule 5) - one card per content on the Synced
// page, and the newest items.
public class ContentPrintTests
{
    private static readonly DateTime Start = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    [Theory]
    [InlineData("abc", "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")]
    [InlineData("abc\n", "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")]
    [InlineData("abc\r\n", "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")]
    [InlineData("abc\n\n", "abc\n", "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb")]
    [InlineData("line1\r\nline2", "line1\nline2", "683376e290829b482c2655745caffa7a1dccfa10afaa62dac2b42dd6c68d0f83")]
    [InlineData("line1\rline2\r", "line1\nline2", "683376e290829b482c2655745caffa7a1dccfa10afaa62dac2b42dd6c68d0f83")]
    [InlineData("  abc  ", "  abc  ", "e1df0bfff7ba8ed81085b91ad7dde5d31777855835b80db6d99b56ef9f3aaa6b")]
    [InlineData("日本語\r\n", "日本語", "77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5")]
    [InlineData("a\r\n\r\n", "a\n", "87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0fde60c4cf25c7")]
    [InlineData("\n", "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")]
    public void Text_is_compared_with_its_line_endings_and_one_trailing_newline_made_alike(string input, string norm, string hex)
    {
        Assert.Equal(norm, ContentPrint.Norm(input));
        Assert.Equal("t:" + hex, ContentPrint.Text(input));
    }

    [Fact]
    public void A_file_print_is_its_hash_in_lowercase_whatever_case_it_came_in()
    {
        string upper = "ABCDEF" + new string('0', 58);
        Assert.Equal("f:abcdef" + new string('0', 58), ContentPrint.File(upper));
        Assert.Equal(ContentPrint.File(upper), ContentPrint.File(upper.ToLowerInvariant()));
    }

    [Fact]
    public void The_empty_file_and_the_empty_text_never_match_though_the_hashes_are_the_same()
    {
        string emptyHash = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855";
        Assert.NotEqual(ContentPrint.Text(""), ContentPrint.File(emptyHash));
        Assert.EndsWith(emptyHash.ToLowerInvariant(), ContentPrint.File(emptyHash));
    }

    [Fact]
    public void An_entry_print_is_of_its_text_its_decoded_picture_or_its_file_hash()
    {
        byte[] picture = { 0x89, 0x50, 0x4E, 0x47, 1, 2, 3 };
        string hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(picture));

        Assert.Equal(ContentPrint.Text("hi"), ContentPrint.Of("hi\r\n", "text"));
        Assert.Equal(ContentPrint.Image(picture), ContentPrint.Of(Convert.ToBase64String(picture), "image"));
        Assert.Equal("i:" + hash.ToLowerInvariant(), ContentPrint.Image(picture));
        string upperFile = JsonSerializer.Serialize(new FilePayload("a.txt", hash, 7));
        string lowerFile = JsonSerializer.Serialize(new FilePayload("b.txt", hash.ToLowerInvariant(), 7));
        Assert.Equal(ContentPrint.Of(upperFile, "file"), ContentPrint.Of(lowerFile, "file"));
        Assert.Equal("f:" + hash.ToLowerInvariant(), ContentPrint.Of(upperFile, "file"));
    }

    [Theory]
    [InlineData("not base64!", "image")]
    [InlineData("{not json", "file")]
    [InlineData("{\"FileName\":\"x\",\"FileHash\":\"..\\\\secret\",\"FileSize\":1}", "file")]
    [InlineData("anything", "audio")]
    public void Content_that_cannot_be_read_has_no_print(string content, string type)
    {
        Assert.Null(ContentPrint.Of(content, type));
    }

    // ---- one card per content ----

    private static ClipboardEntry Text(string text, int minute, string device = "PEER") =>
        new(text, "text", device, Start.AddMinutes(minute), $"sig-{device}-{minute}");

    private static string[] Keys(IEnumerable<ClipboardEntry> entries) => entries.Select(e => e.Key()).ToArray();

    [Fact]
    public void A_live_twin_on_top_hides_the_older_card()
    {
        var mine = Text("abc", 1, "PC");
        var echo = Text("abc\r\n", 2, "PHONE");
        var other = Text("xyz", 0);

        var (visible, hidden) = ContentPrint.Fold(new[] { echo, other, mine }, ContentPrint.Key);

        Assert.Equal(Keys(new[] { echo, other }), Keys(visible));
        Assert.Equal(new[] { mine.Key() }, hidden);
    }

    [Fact]
    public void After_a_restart_the_newest_by_time_wins()
    {
        var older = Text("abc", 1);
        var newer = Text("abc", 5);
        var groups = new BatchGroups();

        var (visible, _) = ContentPrint.Fold(groups.Order(new[] { older, newer }), ContentPrint.Key);

        Assert.Equal(Keys(new[] { newer }), Keys(visible));
    }

    [Fact]
    public void Entries_without_a_print_are_never_twins()
    {
        var a = new ClipboardEntry("x", "audio", "PEER", Start, "sig-a");
        var b = new ClipboardEntry("x", "audio", "PEER", Start, "sig-b");

        var (visible, hidden) = ContentPrint.Fold(new[] { a, b }, ContentPrint.Key);

        Assert.Equal(2, visible.Count);
        Assert.Empty(hidden);
    }

    [Fact]
    public void A_stack_left_with_one_visible_card_is_a_plain_card_and_one_still_waiting_stays_a_stack()
    {
        var batchOf = new Dictionary<string, string> { ["a"] = "1", ["b"] = "1", ["c"] = "2", ["d"] = "2", ["e"] = "2" };
        var expected = new Dictionary<string, int> { ["3"] = 4 };
        batchOf["f"] = "3";
        batchOf["g"] = "3";

        ContentPrint.DropFolded(batchOf, expected, new HashSet<string> { "b", "e", "g" });

        Assert.False(batchOf.ContainsKey("a"));      // stack 1 is down to one card
        Assert.Equal("2", batchOf["c"]);             // stack 2 still has two
        Assert.Equal("2", batchOf["d"]);
        Assert.Equal("3", batchOf["f"]);             // stack 3 still waits for more
        Assert.DoesNotContain("b", batchOf.Keys);
        Assert.DoesNotContain("e", batchOf.Keys);
        Assert.DoesNotContain("g", batchOf.Keys);
    }

    [Fact]
    public void The_stack_twin_of_a_card_above_is_hidden_and_the_next_member_leads()
    {
        // A live "abc" on top; a stack below whose front is also "abc".
        var live = Text("abc", 9, "PC");
        var front = Text("abc", 5);
        var second = Text("def", 4);
        var third = Text("ghi", 3);
        var ordered = new[] { live, front, second, third };
        var batchOf = new Dictionary<string, string> { [front.Key()] = "7", [second.Key()] = "7", [third.Key()] = "7" };

        var (visible, hidden) = ContentPrint.Fold(ordered, ContentPrint.Key);
        ContentPrint.DropFolded(batchOf, new Dictionary<string, int>(), hidden);
        var rows = BatchGrouping.Build(visible.Select(e => new BatchGrouping.Entry(e.Key(), batchOf.GetValueOrDefault(e.Key()), null)).ToList(), new HashSet<string>());

        Assert.Equal(2, rows.Count);
        Assert.Equal(live.Key(), rows[0].FrontKey);
        Assert.Equal(second.Key(), rows[1].FrontKey);
        Assert.True(rows[1].IsStack);
        Assert.Equal(new[] { third.Key() }, rows[1].HiddenKeys);
    }

    // ---- the newest items ----

    [Fact]
    public void The_newest_n_include_every_entry_tied_with_the_last_of_them()
    {
        var history = new[] { Text("a", 1), Text("b", 3), Text("c", 3, "OTHER"), Text("d", 2) };

        Assert.Equal(2, ContentPrint.Newest(history, 1).Count); // both at minute 3
        Assert.Equal(2, ContentPrint.Newest(history, 2).Count);
        Assert.Equal(3, ContentPrint.Newest(history, 3).Count);
        Assert.Equal(4, ContentPrint.Newest(history, 10).Count);
        Assert.Empty(ContentPrint.Newest(history, 0));
    }
}
