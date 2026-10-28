using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using ClipLink.Updates;
using Xunit;

namespace ClipLink.Tests;

// A releases list as GitHub's API words it, built for tests.
internal static class TestReleases
{
    public const string GoodDigest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    public static string DownloadUrl(string tag, string name) =>
        $"https://github.com/Colour1205/ClipLink/releases/download/{tag}/{name}";

    public static Dictionary<string, object?> Asset(string name, long size = 55_907_797, string? digest = GoodDigest,
        string? url = null, string? state = "uploaded", string tag = "v2.0.1")
    {
        var asset = new Dictionary<string, object?>
        {
            ["name"] = name,
            ["size"] = size,
            ["browser_download_url"] = url ?? DownloadUrl(tag, name),
        };
        if (digest != null) asset["digest"] = digest;
        if (state != null) asset["state"] = state;
        return asset;
    }

    public static Dictionary<string, object?> Release(string tag, params object[] assets) => Release(tag, false, false, assets);

    public static Dictionary<string, object?> Release(string tag, bool draft, bool prerelease, params object[] assets) => new()
    {
        ["tag_name"] = tag,
        ["draft"] = draft,
        ["prerelease"] = prerelease,
        ["html_url"] = $"https://github.com/Colour1205/ClipLink/releases/tag/{tag}",
        ["assets"] = assets,
    };

    // A normal release: the Windows installer, named after the tag.
    public static Dictionary<string, object?> WithInstaller(string tag, bool draft = false, bool prerelease = false,
        long size = 55_907_797, string? digest = GoodDigest)
    {
        string name = $"ClipLink-Setup-{tag.TrimStart('v')}.exe";
        return Release(tag, draft, prerelease, Asset(name, size, digest, tag: tag));
    }

    public static string List(params object[] releases) => JsonSerializer.Serialize(releases);

    public static ReleaseVersion Version(string text)
    {
        Assert.True(ReleaseVersion.TryParse(text, out var version));
        return version;
    }

    public static ReleaseOffer? Find(string json, string current) =>
        ReleaseSelector.FindUpdate(json, Version(current), UpdateUrlPolicy.Strict);

    public static ReleaseOffer Offer(string version, byte[] installer, string? tag = null, string? url = null)
    {
        var v = Version(version);
        string name = ReleaseOffer.AssetName(v);
        var asset = new UpdateAsset(new Uri(url ?? DownloadUrl(tag ?? "v" + version, name)), installer.Length, Sha256Digest(installer));
        return new ReleaseOffer(v, new Uri($"https://github.com/Colour1205/ClipLink/releases/tag/v{version}"), asset);
    }

    public static string Sha256Digest(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    // Something like an installer: deterministic, not all one byte.
    public static byte[] Installer(int size = 200_000, int seed = 7)
    {
        var bytes = new byte[size];
        new Random(seed).NextBytes(bytes);
        return bytes;
    }
}

// A folder of its own for one test.
internal sealed class TempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ClipLink-tests-" + Guid.NewGuid().ToString("N")[..8]);

    public TempFolder()
    {
        Directory.CreateDirectory(Path);
    }

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public string[] Names() => Directory.Exists(Path)
        ? Directory.GetFiles(Path).Select(file => System.IO.Path.GetFileName(file)).Order().ToArray()
        : Array.Empty<string>();

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

// Stands in for the network: every request goes to `respond`.
internal sealed class FakeNetwork : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> respond;

    public FakeNetwork(Func<HttpRequestMessage, HttpResponseMessage> respond)
    {
        this.respond = respond;
    }

    public record Seen(Uri Url, string UserAgent, string Accept);

    public List<Seen> Requests { get; } = new();

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        lock (Requests)
        {
            Requests.Add(new Seen(request.RequestUri!, request.Headers.UserAgent.ToString(), request.Headers.Accept.ToString()));
        }
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(respond(request));
    }

    public static HttpResponseMessage Redirect(string location, HttpStatusCode status = HttpStatusCode.Found)
    {
        var response = new HttpResponseMessage(status);
        response.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
        return response;
    }

    public static HttpResponseMessage Bytes(byte[] bytes) => new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };

    public static HttpResponseMessage Text(string text, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(text) };
}

// A body that hands out `first`, then does what `then` says (wait for a
// cancel, or fail like a dropped connection), with no length announced.
internal sealed class TroubledContent : HttpContent
{
    private readonly byte[] first;
    private readonly Func<CancellationToken, Task> then;

    public TroubledContent(byte[] first, Func<CancellationToken, Task> then)
    {
        this.first = first;
        this.then = then;
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new NotSupportedException();

    protected override bool TryComputeLength(out long length)
    {
        length = 0;
        return false;
    }

    protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new TroubledStream(first, then));

    protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) =>
        Task.FromResult<Stream>(new TroubledStream(first, then));

    private sealed class TroubledStream : Stream
    {
        private readonly byte[] first;
        private readonly Func<CancellationToken, Task> then;
        private int given;

        public TroubledStream(byte[] first, Func<CancellationToken, Task> then)
        {
            this.first = first;
            this.then = then;
        }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (given < first.Length)
            {
                int count = Math.Min(buffer.Length, first.Length - given);
                first.AsMemory(given, count).CopyTo(buffer);
                given += count;
                return count;
            }
            await then(cancellationToken);
            return 0;
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
