using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ClipboardDaemon.Storage;

// The original name of a picture copied as a picture, when the copy had one.
// It travels as the optional "Name" field of an "image" entry (see
// ClipboardEntry and docs/protocol.md), so the other devices can save the
// picture under that name instead of "Image from <device> <time>".
//
// A screenshot has only pixels, so it has no name. But "Copy image" in a
// browser, and some apps, also put other formats on the clipboard: the file
// it came from ("FileNameW", "FileName", a one-file CF_HDROP), a virtual file
// ("FileGroupDescriptorW"), the HTML of the picture ("HTML Format", with an
// <img src="...">) or its address ("UniformResourceLocatorW",
// "UniformResourceLocator"). Each reader here turns one of those into a short,
// safe name, or null when there is nothing usable. An address is asked only
// when the HTML holds no picture, and only counts when it ends in a picture's
// extension (see FromPictureUrl), since it can be the page's address.
//
// The name never carries an extension. This PC always sends the picture as a
// PNG (it re-encodes whatever was copied), so the original ".jpg" or ".webp"
// would be wrong anyway, and a ".php" or ".exe" from an address means nothing.
// The receiver adds the real extension from the picture's bytes.
public static class ImageName
{
    // The longest name kept, in UTF-16 characters and in UTF-8 bytes. Short
    // enough to read on a phone, and with room for " (12).png" within the
    // 255-byte names the phones' file systems allow.
    public const int MaxChars = 80;
    public const int MaxUtf8Bytes = 160;

    // HTML larger than this is not searched for a picture: "Copy image" puts
    // a few hundred bytes, and a big selection of a page is not one picture.
    public const int MaxHtmlBytes = 256 * 1024;

    // The extensions of a picture's address. An address from the
    // "UniformResourceLocator" formats or a dropped link only counts when
    // its last part has one of these: it can be the page or the link the
    // picture was on ("https://www.youtube.com/watch?v=..." would give
    // "watch"), not the picture itself.
    private static readonly HashSet<string> PictureExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "png", "apng", "jpg", "jpeg", "jpe", "jfif", "gif", "webp", "bmp", "dib",
        "tif", "tiff", "ico", "svg", "avif", "heic", "heif",
    };

    // Every <img> tag's src attribute, quoted with " or ' or not quoted. The
    // tag is read one attribute at a time, so a "src=" inside another
    // attribute's value (alt='x src=fake.png') or the end of another
    // attribute's name (data-src=) is never taken for the src. Each
    // attribute is matched atomically, so a malformed tag cannot make the
    // search backtrack over it again and again.
    private static readonly Regex ImgSrc = new(
        "<img\\b(?>\\s+(?!src\\s*=)[^\\s=>]+(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+))?)*"
        + "\\s+src\\s*=\\s*(?:\"(?<src>[^\"]*)\"|'(?<src>[^']*)'|(?<src>[^\\s>\"']+))",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200));

    // The start of any <img> tag, with or without a src.
    private static readonly Regex ImgTag = new(
        "<img\\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200));

    // Any text made into a name that is safe to show and to save under: only
    // its last path part (so "..\..\Startup\x" is just "x"), without control
    // characters or the invisible ones that disguise a name (see
    // FileNames.IsUnsafeChar), with characters Windows refuses in a file name
    // turned into '_', without spaces or dots at either end, not a reserved
    // device name, and at most MaxChars characters and MaxUtf8Bytes bytes,
    // never cutting a character in half. Null when nothing with a letter in
    // it is left. Running it again on its own result changes nothing, which
    // is why it is also what an incoming Name goes through (see
    // ImageNameJsonConverter).
    public static string? Clean(string? raw)
    {
        string name = Trim(Prepare(raw));
        name = Trim(Prefix(name, MaxChars, MaxUtf8Bytes));
        if (name.Length == 0 || !name.Any(char.IsLetter)) return null;
        // Windows also ignores spaces before the dot, so "CON .x" is CON too.
        int dot = name.IndexOf('.');
        if (FileNames.Reserved.Contains((dot < 0 ? name : name[..dot]).TrimEnd(' '))) return null;
        return name;
    }

    // A name for a copied picture: Clean, but without its extension first
    // (see the top of this file). An extension is a last '.' followed by one
    // to five ASCII letters and digits with at least one letter, so "v1.2"
    // and "draft. final" keep their dots. A name that is only an extension
    // (".png") is no name.
    public static string? Suggest(string? raw)
    {
        string name = Prepare(raw);
        int dot = name.LastIndexOf('.');
        if (dot >= 0)
        {
            string extension = name[(dot + 1)..];
            if (extension.Length is >= 1 and <= 5 && extension.All(char.IsAsciiLetterOrDigit) && extension.Any(char.IsAsciiLetter))
            {
                name = name[..dot];
            }
        }
        return Clean(name);
    }

    // The last path part of raw, without unsafe characters or half
    // characters (a surrogate without its pair, which is not text and which
    // other devices may refuse to read), with the characters Windows refuses
    // turned into '_', and without spaces or dots at its end (leading dots
    // are kept here, so Suggest still sees ".png" as only an extension).
    private static string Prepare(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "";
        string name = raw.Replace('\\', '/');
        name = name[(name.LastIndexOf('/') + 1)..];
        var invalid = Path.GetInvalidFileNameChars();
        var kept = new StringBuilder(Math.Min(name.Length, MaxChars * 4));
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            if (char.IsHighSurrogate(c) && i + 1 < name.Length && char.IsLowSurrogate(name[i + 1]))
            {
                kept.Append(c).Append(name[++i]);
                continue;
            }
            if (char.IsSurrogate(c) || FileNames.IsUnsafeChar(c)) continue;
            kept.Append(invalid.Contains(c) ? '_' : c);
        }
        return kept.ToString().Trim().TrimEnd('.', ' ').Trim();
    }

    // The name in an address: its last path segment, percent-decoded, without
    // the query or fragment ("https://x.com/a/after-like.png?x=1" gives
    // "after-like"). Only web and file addresses, and relative ones as an
    // <img src> can hold, count: a data: or blob: address holds no name, and
    // anything else (javascript:, about:) is not a picture's address.
    public static string? FromUrl(string? url) => Suggest(LastSegment(url));

    // The same, for an address that may not be the picture's own: from the
    // "UniformResourceLocator" formats or a dropped link. It counts only
    // when its last part ends in a picture's extension (see
    // PictureExtensions), so a page or a link the picture was on gives no
    // name rather than a wrong one.
    public static string? FromPictureUrl(string? url)
    {
        string? segment = LastSegment(url);
        if (segment is null) return null;
        int dot = segment.LastIndexOf('.');
        return dot >= 0 && PictureExtensions.Contains(segment[(dot + 1)..].Trim()) ? Suggest(segment) : null;
    }

    // The last path segment of an address, percent-decoded and without the
    // query or fragment, or null when the address holds no name (see
    // FromUrl).
    private static string? LastSegment(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;
        string address = url.Trim();
        int scheme = address.IndexOf(':');
        int firstSlash = address.IndexOfAny(new[] { '/', '\\', '?', '#' });
        if (scheme > 0 && (firstSlash < 0 || scheme < firstSlash))
        {
            string name = address[..scheme];
            bool web = name.Equals("http", StringComparison.OrdinalIgnoreCase)
                || name.Equals("https", StringComparison.OrdinalIgnoreCase)
                || name.Equals("file", StringComparison.OrdinalIgnoreCase)
                || name.Equals("ftp", StringComparison.OrdinalIgnoreCase);
            // A drive letter ("C:\pictures\a.png") is a path, not a scheme.
            bool drive = scheme == 1 && char.IsAsciiLetter(address[0]);
            if (!web && !drive) return null;
        }
        int end = address.IndexOfAny(new[] { '?', '#' });
        if (end >= 0) address = address[..end];
        // A web address's host alone ("https://example.com/", or
        // "//cdn.example.com/" without the scheme) names no picture.
        int host = address.Contains("://") ? address.IndexOf("://", StringComparison.Ordinal) + 3
            : address.StartsWith("//", StringComparison.Ordinal) ? 2
            : -1;
        if (host >= 0)
        {
            int path = address.IndexOf('/', host);
            if (path < 0) return null;
            address = address[path..];
        }
        address = address.TrimEnd('/', '\\');
        string segment = address.Replace('\\', '/');
        segment = segment[(segment.LastIndexOf('/') + 1)..];
        try
        {
            segment = Uri.UnescapeDataString(segment);
        }
        catch (UriFormatException)
        {
            return null;
        }
        // A whole data: or blob: address written percent-encoded, as a
        // relative src ("data%3Aimage%2Fpng%3Bbase64%2C..."), is no name
        // either, only the picture's bytes.
        foreach (string unnamed in new[] { "data:", "blob:", "javascript:" })
        {
            if (segment.TrimStart().StartsWith(unnamed, StringComparison.OrdinalIgnoreCase)) return null;
        }
        return segment;
    }

    // The picture in clipboard HTML ("HTML Format": a few header lines, then
    // the HTML, with the copied part between StartFragment and EndFragment):
    // the name in its <img src>, when that part holds exactly one picture.
    // With more than one it is a selection of a page, not one picture.
    // Longer than MaxHtmlBytes characters: null, not searched.
    public static string? FromHtml(string? html) => FromHtml(html, out _);

    // The same, and whether the HTML settles the question (decided): it
    // holds a picture, or it is too big to be one picture. Then the address
    // formats are not asked, even when the HTML gives no name (two pictures,
    // or a data: src), because the address next to such HTML is the page's
    // or a link's, not the picture's.
    public static string? FromHtml(string? html, out bool decided)
    {
        decided = false;
        if (string.IsNullOrEmpty(html)) return null;
        if (html.Length > MaxHtmlBytes)
        {
            decided = true;
            return null;
        }
        string fragment = Fragment(html);
        MatchCollection matches;
        try
        {
            decided = ImgTag.IsMatch(fragment);
            matches = ImgSrc.Matches(fragment);
            if (matches.Count != 1) return null;
        }
        catch (RegexMatchTimeoutException)
        {
            decided = true;
            return null;
        }
        return FromUrl(WebUtility.HtmlDecode(matches[0].Groups["src"].Value));
    }

    // The same from the format's raw bytes, which are UTF-8 up to the first
    // NUL. Bigger than MaxHtmlBytes: null, and decided.
    public static string? FromHtmlBytes(ReadOnlySpan<byte> bytes) => FromHtmlBytes(bytes, out _);

    public static string? FromHtmlBytes(ReadOnlySpan<byte> bytes, out bool decided)
    {
        int nul = bytes.IndexOf((byte)0);
        if (nul >= 0) bytes = bytes[..nul];
        if (bytes.Length > MaxHtmlBytes)
        {
            decided = true;
            return null;
        }
        return FromHtml(Encoding.UTF8.GetString(bytes), out decided);
    }

    // "FileGroupDescriptorW": a count, then one FILEDESCRIPTORW (592 bytes,
    // the name as 260 UTF-16 characters from byte 72) per virtual file. The
    // name of the only one; null for none or several.
    public static string? FromFileGroupDescriptorW(ReadOnlySpan<byte> bytes)
    {
        const int countSize = 4;
        const int descriptorSize = 592;
        const int nameOffset = 72;
        const int nameChars = 260;
        if (bytes.Length < countSize + descriptorSize) return null;
        if (BitConverter.ToUInt32(bytes[..countSize]) != 1) return null;
        var name = bytes.Slice(countSize + nameOffset, nameChars * 2);
        string text = Encoding.Unicode.GetString(name);
        int end = text.IndexOf('\0');
        return Suggest(end < 0 ? text : text[..end]);
    }

    // The part of clipboard HTML that was copied: between the
    // <!--StartFragment--> and <!--EndFragment--> comments every writer puts,
    // or the whole text when they are missing. (The header's byte offsets
    // are not used: they count UTF-8 bytes, and some apps get them wrong.)
    private static string Fragment(string html)
    {
        const string start = "<!--StartFragment-->";
        const string end = "<!--EndFragment-->";
        int from = html.IndexOf(start, StringComparison.OrdinalIgnoreCase);
        int to = html.IndexOf(end, StringComparison.OrdinalIgnoreCase);
        if (from < 0 || to < from) return html;
        from += start.Length;
        return html[from..to];
    }

    private static string Trim(string name) => name.Trim().Trim('.', ' ').Trim();

    // The longest start of s within maxChars UTF-16 units and maxBytes of
    // UTF-8, never half a character.
    private static string Prefix(string s, int maxChars, int maxBytes)
    {
        int end = 0;
        int bytes = 0;
        while (end < s.Length)
        {
            Rune.DecodeFromUtf16(s.AsSpan(end), out Rune rune, out int consumed);
            bytes += rune.Utf8SequenceLength;
            if (end + consumed > maxChars || bytes > maxBytes) break;
            end += consumed;
        }
        return s[..end];
    }
}

// How an entry's Name is read from JSON. A string is put through
// ImageName.Clean, because it comes from another device and is only a
// suggestion: a name with a path, control characters or no letters at all,
// or one megabytes long, is never stored or passed on. Anything other than a
// string (a number, an object), and a string that is not valid text (an
// escaped surrogate without its pair, "\ud800", or bytes that are not
// UTF-8), is read as no name, so a peer that writes the field oddly costs
// only the name, never the whole entry or history batch. (A JSON null never
// reaches it: the serializer reads that as null itself.)
public sealed class ImageNameJsonConverter : JsonConverter<string?>
{
    public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            reader.Skip();
            return null;
        }
        // GetString throws ArgumentException for an escaped lone surrogate
        // and InvalidOperationException for invalid UTF-8. It does not move
        // the reader, so the rest of the entry is still read.
        try
        {
            return ImageName.Clean(reader.GetString());
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    public override void Write(Utf8JsonWriter writer, string? value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value);
}
