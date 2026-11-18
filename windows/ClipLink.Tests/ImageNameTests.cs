using System.Text;
using System.Text.Json;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.Tests;

// The original name of a picture copied as a picture (ImageName): read from
// the formats a "Copy image" puts next to the bitmap, made short and safe,
// and carried as the optional, unsigned "Name" of an "image" entry
// (ClipboardEntry), which older builds never see.
public class ImageNameTests
{
    private static readonly DateTime At = new(2026, 11, 17, 9, 30, 0, DateTimeKind.Utc);

    // CF_HTML as Chrome writes it for "Copy image": a header, then the HTML
    // with the copied part between the fragment comments.
    private static string CfHtml(string fragment) =>
        "Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000300\r\nStartFragment:0000000141\r\nEndFragment:0000000264\r\n"
        + "SourceURL:https://example.com/gallery/page.html\r\n"
        + "<html><body>\r\n<!--StartFragment-->" + fragment + "<!--EndFragment-->\r\n</body></html>";

    // ---- from an address ----

    [Theory]
    [InlineData("https://cdn.example.com/img/after-like.png?x=1", "after-like")]
    [InlineData("https://cdn.example.com/img/after-like.png#top", "after-like")]
    [InlineData("https://example.com/photos/Sunset%20at%20the%20beach.jpeg", "Sunset at the beach")]
    [InlineData("https://example.com/%E5%9B%BE%E7%89%87/%E7%8C%AB.webp", "猫")]
    [InlineData("HTTPS://EXAMPLE.COM/A/Cat.GIF", "Cat")]
    [InlineData("http://example.com/media/Fabc123", "Fabc123")]
    [InlineData("//cdn.example.com/a/b/logo.svg", "logo")]
    [InlineData("/images/hero.png", "hero")]
    [InlineData("hero.png", "hero")]
    [InlineData("file:///C:/Users/me/Pictures/holiday.png", "holiday")]
    [InlineData("C:\\Users\\me\\Pictures\\holiday.png", "holiday")]
    [InlineData("https://example.com/files/report.php?id=7", "report")]
    [InlineData("https://example.com/v1.2/diagram v1.2", "diagram v1.2")]
    [InlineData("https://example.com/a/photo/", "photo")]
    public void An_address_gives_its_last_path_segment_without_query_or_extension(string url, string expected)
    {
        Assert.Equal(expected, ImageName.FromUrl(url));
    }

    [Theory]
    [InlineData("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk")]
    [InlineData("DATA:image/png;base64,AAAA")]
    [InlineData("blob:https://example.com/550e8400-e29b-41d4-a716-446655440000")]
    [InlineData("javascript:alert('x.png')")]
    [InlineData("about:blank")]
    [InlineData("https://example.com")]
    [InlineData("https://example.com/")]
    [InlineData("https://example.com/12345.png")]      // no letters
    [InlineData("https://example.com/2026-11-17_0930")] // no letters
    [InlineData("https://example.com/.png")]
    [InlineData("https://example.com/..")]
    [InlineData("https://example.com/con.png")]        // a reserved device name
    [InlineData("//cdn.example.com/")]                 // a host alone, without the scheme
    [InlineData("//cdn.example.com")]
    [InlineData("/a/data%3Aimage%2Fpng%3Bbase64%2CiVBORw0KGgoAAAANSUhEUgAAAAEAAAAB")] // a data: address, percent-encoded
    [InlineData("blob%3Ahttps%3A%2F%2Fexample.com%2F550e8400")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public void An_address_without_a_usable_name_gives_none(string? url)
    {
        Assert.Null(ImageName.FromUrl(url));
    }

    [Theory]
    [InlineData("https://example.com/..%2F..%2F..%2FWindows%2Fwin.ini", "win")]
    [InlineData("https://example.com/a/..%5C..%5Cstartup%5Cevil.exe", "evil")]
    [InlineData("https://example.com/%2E%2E/%2E%2E/passwd", "passwd")]
    [InlineData("https://example.com/a%00b%0D%0Ac.png", "abc")]
    [InlineData("https://example.com/cat%E2%80%AEgnp.exe", "catgnp")]   // a right-to-left override, dropped
    [InlineData("https://example.com/what%3F%2A%3Cis%3E%7Cthis%22.png", "what___is__this_")]
    public void Encoded_path_parts_and_hidden_characters_never_get_through(string url, string expected)
    {
        string? name = ImageName.FromUrl(url);

        Assert.Equal(expected, name);
        Assert.DoesNotContain('/', name!);
        Assert.DoesNotContain('\\', name!);
        Assert.DoesNotContain(name!, char.IsControl);
    }

    [Fact]
    public void A_very_long_name_is_cut_to_the_limit_without_halving_a_character()
    {
        string longAscii = ImageName.FromUrl("https://example.com/" + new string('a', 5000) + ".png")!;
        Assert.Equal(ImageName.MaxChars, longAscii.Length);

        // An emoji is two UTF-16 units: after "a" and 39 of them (79 units),
        // the 40th would go past 80, so it is left out whole.
        string emoji = ImageName.FromUrl("https://example.com/a" + string.Concat(Enumerable.Repeat("🙂", 200)) + ".png")!;
        Assert.Equal(79, emoji.Length);
        Assert.True(char.IsLowSurrogate(emoji[^1]));

        // Chinese is three UTF-8 bytes a character: the byte limit comes first.
        string chinese = ImageName.FromUrl("https://example.com/" + new string('猫', 200) + ".png")!;
        Assert.Equal(ImageName.MaxUtf8Bytes / 3, chinese.Length);
        Assert.True(Encoding.UTF8.GetByteCount(chinese) <= ImageName.MaxUtf8Bytes);
    }

    // ---- from clipboard HTML ----

    [Fact]
    public void Clipboard_html_with_one_picture_gives_the_name_in_its_src()
    {
        string html = CfHtml("<img src=\"https://cdn.example.com/img/after-like.png?x=1&amp;y=2\" alt=\"A like\">");

        Assert.Equal("after-like", ImageName.FromHtml(html));
        Assert.Equal("after-like", ImageName.FromHtmlBytes(Encoding.UTF8.GetBytes(html + "\0junk after the NUL")));
    }

    [Theory]
    [InlineData("<IMG class='x' SRC='https://e.com/a/Single%20quoted.jpg'>", "Single quoted")]
    [InlineData("<img src=https://e.com/a/unquoted.png width=10>", "unquoted")]
    [InlineData("<img\r\n  data-x=\"1\"\r\n  src = \"/static/Spaced.png\" />", "Spaced")]
    [InlineData("<img src=\"https://e.com/a/%E7%8C%AB&amp;%E7%8B%97.png\">", "猫&狗")]
    [InlineData("<img alt='x src=fake.png' src=\"https://e.com/real.png\">", "real")]          // "src=" inside another value
    [InlineData("<img data-src=\"https://e.com/lazy.jpg\" src=\"https://e.com/shown.gif\">", "shown")] // data-src is another attribute
    [InlineData("<img srcset=\"https://e.com/big.png 2x\" src=\"https://e.com/small.png\">", "small")]
    [InlineData("<img src=https://e.com/a/unquoted.png'>", "unquoted")]                       // a quote never ends up in the name
    public void Any_way_of_writing_the_src_is_read(string fragment, string expected)
    {
        Assert.Equal(expected, ImageName.FromHtml(CfHtml(fragment)));
    }

    [Theory]
    [InlineData("<img src=\"data:image/png;base64,iVBORw0KGgo=\">")]
    [InlineData("<img src=\"https://e.com/a.png\"><img src=\"https://e.com/b.png\">")] // a selection, not one picture
    [InlineData("<p>Just text</p>")]
    [InlineData("<img alt=\"no source\">")]
    [InlineData("<image src=\"https://e.com/not-an-img-tag.png\">")]
    public void Clipboard_html_without_exactly_one_named_picture_gives_none(string fragment)
    {
        Assert.Null(ImageName.FromHtml(CfHtml(fragment)));
    }

    [Fact]
    public void Only_the_copied_fragment_counts_and_html_without_fragment_comments_is_read_whole()
    {
        // A picture outside the fragment (the page around it) is not the one copied.
        string html = "Version:0.9\r\n<html><body><img src=\"https://e.com/outside.png\"><!--StartFragment--><img src=\"https://e.com/inside.png\"><!--EndFragment--></body></html>";
        Assert.Equal("inside", ImageName.FromHtml(html));

        Assert.Equal("bare", ImageName.FromHtml("<img src=\"https://e.com/bare.png\">"));
    }

    [Fact]
    public void Clipboard_html_too_big_to_be_one_picture_is_not_searched()
    {
        string html = CfHtml("<img src=\"https://e.com/big.png\">" + new string(' ', ImageName.MaxHtmlBytes));

        Assert.Null(ImageName.FromHtmlBytes(Encoding.UTF8.GetBytes(html), out bool fromBytes));
        Assert.True(fromBytes);
        // The text a dropped picture brings is held to the same size.
        Assert.Null(ImageName.FromHtml(html, out bool fromText));
        Assert.True(fromText);
    }

    // Whether the HTML settles it, so the address formats (the page's or a
    // link's address, next to such HTML) are not asked.
    [Theory]
    [InlineData("<img src=\"https://e.com/a.png\">", true)]
    [InlineData("<img src=\"https://e.com/a.png\"><img src=\"https://e.com/b.png\">", true)]
    [InlineData("<img src=\"data:image/png;base64,iVBORw0KGgo=\">", true)]
    [InlineData("<img alt=\"no source\">", true)]
    [InlineData("<p>Just text</p>", false)]
    public void Clipboard_html_with_any_picture_decides_and_html_without_one_does_not(string fragment, bool decided)
    {
        ImageName.FromHtml(CfHtml(fragment), out bool result);

        Assert.Equal(decided, result);
        ImageName.FromHtml(null, out bool none);
        Assert.False(none);
    }

    [Fact]
    public void Many_img_tags_in_html_are_searched_quickly()
    {
        string html = CfHtml(string.Concat(Enumerable.Repeat("<img src", 20_000)) + string.Concat(Enumerable.Repeat("<img alt=\"x\" title='y' ", 5_000)));
        var watch = System.Diagnostics.Stopwatch.StartNew();

        Assert.Null(ImageName.FromHtml(html));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(2), watch.Elapsed.ToString());
    }

    // ---- from an address that may be the page's ----

    [Theory]
    [InlineData("https://cdn.example.com/img/after-like.png?x=1", "after-like")]
    [InlineData("https://example.com/a/Photo.JPEG#x", "Photo")]
    [InlineData("https://example.com/a/anim.webp", "anim")]
    [InlineData("https://www.youtube.com/watch?v=dQw4w9WgXcQ", null)]   // a page, not a picture
    [InlineData("https://example.com/blog/my-trip-to-rome", null)]
    [InlineData("https://example.com/report.php?id=7", null)]
    [InlineData("https://example.com/", null)]
    [InlineData("data:image/png;base64,AAAA", null)]
    [InlineData(null, null)]
    public void An_address_that_may_be_the_page_counts_only_with_a_picture_extension(string? url, string? expected)
    {
        Assert.Equal(expected, ImageName.FromPictureUrl(url));
    }

    // ---- from file names ----

    [Theory]
    [InlineData("C:\\Users\\me\\Pictures\\Holiday 2026.JPG", "Holiday 2026")]
    [InlineData("\\\\server\\share\\scan.tiff", "scan")]
    [InlineData("Screenshot 2026-11-17 093000.png", "Screenshot 2026-11-17 093000")]
    [InlineData("archive.tar.gz", "archive.tar")]
    [InlineData("noextension", "noextension")]
    [InlineData("draft. final", "draft. final")]
    [InlineData("  .hidden name.png  ", "hidden name")]
    [InlineData("..\\..\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\evil.exe", "evil")]
    [InlineData("../../../../etc/passwd", "passwd")]
    [InlineData("tab\there\u0001.png", "tabhere")]
    public void A_file_name_gives_its_stem_from_the_last_path_part(string path, string expected)
    {
        Assert.Equal(expected, ImageName.Suggest(path));
    }

    [Theory]
    [InlineData("C:\\pictures\\")]
    [InlineData("C:\\pictures\\..")]
    [InlineData("12345.png")]
    [InlineData("NUL")]
    [InlineData("com1.jpg")]
    [InlineData("COM\u00b9.png")]   // Windows counts the superscript digits too
    [InlineData("lpt\u00b3")]
    [InlineData("CONIN$.png")]
    [InlineData("conout$")]
    [InlineData("CON .png")]      // spaces before the dot do not help
    [InlineData("\u202E\u200B")]
    [InlineData("")]
    public void A_file_name_without_a_usable_name_gives_none(string path)
    {
        Assert.Null(ImageName.Suggest(path));
    }

    // FILEGROUPDESCRIPTORW: a count, then 592-byte descriptors with the name
    // as 260 UTF-16 characters from byte 72.
    private static byte[] FileGroupDescriptor(params string[] names)
    {
        var bytes = new byte[4 + 592 * names.Length];
        BitConverter.TryWriteBytes(bytes.AsSpan(0, 4), (uint)names.Length);
        for (int i = 0; i < names.Length; i++)
        {
            byte[] name = Encoding.Unicode.GetBytes(names[i]);
            name.AsSpan(0, Math.Min(name.Length, 520)).CopyTo(bytes.AsSpan(4 + 592 * i + 72));
        }
        return bytes;
    }

    [Fact]
    public void A_file_group_descriptor_with_one_file_gives_its_name()
    {
        Assert.Equal("Vacation photo", ImageName.FromFileGroupDescriptorW(FileGroupDescriptor("Vacation photo.jpg")));
        Assert.Equal("evil", ImageName.FromFileGroupDescriptorW(FileGroupDescriptor("..\\..\\evil.exe")));
        // A name filling all 260 characters, with no NUL: still read, and cut.
        Assert.Equal(ImageName.MaxChars, ImageName.FromFileGroupDescriptorW(FileGroupDescriptor(new string('x', 300)))!.Length);
    }

    [Fact]
    public void A_file_group_descriptor_with_no_file_several_or_too_few_bytes_gives_none()
    {
        Assert.Null(ImageName.FromFileGroupDescriptorW(FileGroupDescriptor()));
        Assert.Null(ImageName.FromFileGroupDescriptorW(FileGroupDescriptor("a.png", "b.png")));
        Assert.Null(ImageName.FromFileGroupDescriptorW(FileGroupDescriptor("a.png").AsSpan(0, 100)));
        Assert.Null(ImageName.FromFileGroupDescriptorW(ReadOnlySpan<byte>.Empty));
    }

    [Theory]
    [InlineData("a.b.c")]
    [InlineData("  ..x..  ")]
    [InlineData("名前 🙂.png")]
    [InlineData("CON.backup")]
    public void Clean_twice_is_the_same_as_once(string raw)
    {
        Assert.Equal(ImageName.Clean(raw), ImageName.Clean(ImageName.Clean(raw)));
    }

    // ---- on the entry ----

    private static ClipboardEntry Picture(string? name) =>
        new("iVBORw0KGgo=", "image", "DEVICE+KEY/==", At, "sig+/==", name);

    [Fact]
    public void An_entry_without_a_name_is_written_exactly_as_before()
    {
        string json = JsonSerializer.Serialize(Picture(null), Wire.Json);

        Assert.Equal("{\"Content\":\"iVBORw0KGgo=\",\"Type\":\"image\",\"DeviceId\":\"DEVICE+KEY/==\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Signature\":\"sig+/==\"}", json);
        Assert.DoesNotContain("Name", JsonSerializer.Serialize(Picture(null)));
    }

    [Fact]
    public void An_entry_with_a_name_round_trips_on_the_wire_and_in_the_history_file()
    {
        var entry = Picture("after-like");

        string json = JsonSerializer.Serialize(entry, Wire.Json);
        Assert.EndsWith(",\"Name\":\"after-like\"}", json);

        var read = JsonSerializer.Deserialize<ClipboardEntry>(json)!;
        Assert.Equal("after-like", read.Name);
        Assert.Equal(entry, read);

        // The history file: a list, written with the wire options and read with the defaults.
        var list = JsonSerializer.Deserialize<List<ClipboardEntry>>(JsonSerializer.Serialize(new List<ClipboardEntry> { entry, Picture(null) }, Wire.Json))!;
        Assert.Equal(new[] { "after-like", null }, list.Select(e => e.Name));

        // And inside an envelope, as an entry or a history batch travels.
        var envelope = JsonSerializer.Deserialize<Envelope>(Wire.Envelope("history_batch", new List<ClipboardEntry> { entry }).Span)!;
        Assert.Equal("after-like", JsonSerializer.Deserialize<List<ClipboardEntry>>(envelope.Payload)!.Single().Name);
    }

    [Fact]
    public void An_entry_from_an_older_build_without_the_field_still_reads()
    {
        const string old = "{\"Content\":\"hello\",\"Type\":\"text\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00.0000000Z\",\"Signature\":\"S\"}";

        var entry = JsonSerializer.Deserialize<ClipboardEntry>(old)!;

        Assert.Equal(("hello", "text", "D", "S"), (entry.Content, entry.Type, entry.DeviceId, entry.Signature));
        Assert.Null(entry.Name);
    }

    [Fact]
    public void An_entry_with_fields_nobody_knows_yet_still_reads()
    {
        const string newer = "{\"Content\":\"x\",\"Type\":\"image\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Signature\":\"S\",\"Name\":\"cat\",\"Future\":{\"a\":[1,2]}}";

        var entry = JsonSerializer.Deserialize<ClipboardEntry>(newer)!;

        Assert.Equal("cat", entry.Name);
        Assert.Equal("S", entry.Signature);
    }

    // What an older Windows build (2.2 and before) has as its entry: the same
    // record without Name. It reads a new entry with the name, and drops it.
    private sealed record OldClipboardEntry(string Content, string Type, string DeviceId, DateTime Timestamp, string? Signature = null);

    [Fact]
    public void An_older_build_reads_an_entry_with_a_name_and_ignores_it()
    {
        var entry = Picture("after-like");

        var old = JsonSerializer.Deserialize<OldClipboardEntry>(JsonSerializer.Serialize(entry, Wire.Json))!;

        Assert.Equal((entry.Content, entry.Type, entry.DeviceId, entry.Timestamp, entry.Signature), (old.Content, old.Type, old.DeviceId, old.Timestamp, old.Signature));
    }

    [Theory]
    [InlineData("\"..\\\\..\\\\Startup\\\\evil.exe\"", "evil.exe")]
    [InlineData("\"a/b/c/cat.png\"", "cat.png")]
    [InlineData("\"bad\\u0000\\u001Fname\\u202E\"", "badname")]
    [InlineData("\"12345\"", null)]
    [InlineData("\"\"", null)]
    [InlineData("null", null)]
    [InlineData("42", null)]
    [InlineData("true", null)]
    [InlineData("{\"a\":\"b\"}", null)]
    [InlineData("[\"x\",{\"y\":1}]", null)]
    public void An_incoming_name_is_cleaned_and_one_of_the_wrong_kind_costs_only_the_name(string nameJson, string? expected)
    {
        string json = "{\"Content\":\"x\",\"Type\":\"image\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Name\":" + nameJson + ",\"Signature\":\"S\"}";

        var entry = JsonSerializer.Deserialize<ClipboardEntry>(json)!;

        Assert.Equal(expected, entry.Name);
        Assert.Equal("S", entry.Signature);
    }

    [Fact]
    public void An_incoming_name_that_is_not_valid_text_costs_only_the_name()
    {
        // An escaped surrogate without its pair: GetString throws for it.
        const string lone = "{\"Content\":\"x\",\"Type\":\"image\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Name\":\"a\\ud800b\",\"Signature\":\"S\"}";
        var entry = JsonSerializer.Deserialize<ClipboardEntry>(lone)!;
        Assert.Null(entry.Name);
        Assert.Equal("S", entry.Signature);

        // Bytes that are not UTF-8 inside the name.
        byte[] json = Encoding.UTF8.GetBytes("{\"Content\":\"x\",\"Type\":\"image\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Signature\":\"S\",\"Name\":\"aXb\"}");
        json[Array.IndexOf(json, (byte)'X')] = 0xFF;
        Assert.Null(JsonSerializer.Deserialize<ClipboardEntry>(json)!.Name);

        // In a history batch, the other entries are not lost either.
        string batch = "[" + lone + "," + JsonSerializer.Serialize(Picture("cat"), Wire.Json) + "]";
        Assert.Equal(new[] { null, "cat" }, JsonSerializer.Deserialize<List<ClipboardEntry>>(batch)!.Select(e => e.Name));
    }

    [Fact]
    public void A_name_on_an_entry_that_is_not_a_picture_is_never_kept_or_passed_on()
    {
        const string text = "{\"Content\":\"hello\",\"Type\":\"text\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Signature\":\"S\",\"Name\":\"x\"}";

        var entry = JsonSerializer.Deserialize<ClipboardEntry>(text)!;

        Assert.Null(entry.Name);
        Assert.DoesNotContain("Name", JsonSerializer.Serialize(entry, Wire.Json));
        Assert.Null(new ClipboardEntry("f", "file", "D", At, "S", "x").Name);
        Assert.Null((Picture("cat") with { Type = "text" }).Name);
        Assert.Equal("cat", Picture("cat").Name);
    }

    [Fact]
    public void Half_characters_are_dropped_and_whole_ones_kept()
    {
        // In code, not in an attribute: a lone surrogate does not survive
        // being stored in an attribute.
        Assert.Equal("half a character", ImageName.Suggest("half\ud800 a\udc00 character.png"));
        Assert.Equal("pair 🙂", ImageName.Suggest("pair 🙂.png"));
        Assert.Equal("ends", ImageName.Clean("ends\ud83d"));
    }

    [Fact]
    public void An_incoming_name_megabytes_long_is_cut_to_the_limit()
    {
        string json = "{\"Content\":\"x\",\"Type\":\"image\",\"DeviceId\":\"D\",\"Timestamp\":\"2026-11-17T09:30:00Z\",\"Signature\":\"S\",\"Name\":\"" + new string('n', 2_000_000) + "\"}";

        Assert.Equal(ImageName.MaxChars, JsonSerializer.Deserialize<ClipboardEntry>(json)!.Name!.Length);
    }

    [Fact]
    public void The_name_changes_neither_the_key_nor_whether_two_entries_are_the_same()
    {
        var named = Picture("after-like");
        var unnamed = Picture(null);

        Assert.Equal(unnamed.Key(), named.Key());
        Assert.Equal("sig+/==", named.Key());
        // The same entry relayed by a build that drops the name is still a duplicate.
        Assert.Equal(unnamed, named);
        Assert.Equal(unnamed.GetHashCode(), named.GetHashCode());
        Assert.Contains(unnamed, new List<ClipboardEntry> { named });
        // Anything signed differing still makes it another entry.
        Assert.NotEqual(unnamed, unnamed with { Signature = "other" });
        Assert.NotEqual(unnamed, unnamed with { Content = "other" });
    }
}
