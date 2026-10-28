using System.Net;
using ClipLink.Updates;
using Xunit;
using static ClipLink.Tests.TestReleases;

namespace ClipLink.Tests;

public class UpdateClientCheckTests
{
    private static UpdateClient Client(FakeNetwork network, UpdateEndpoint? endpoint = null) =>
        new(endpoint ?? UpdateEndpoint.Default, "2.0.1", network);

    private static Task<ReleaseOffer?> Check(UpdateClient client, string current = "2.0.1") =>
        client.CheckAsync(Version(current), CancellationToken.None);

    [Fact]
    public async Task AsksGitHubOnceAndFindsTheUpdate()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text(List(WithInstaller("v2.0.2"), WithInstaller("v2.0.1"))));
        using var client = Client(network);

        var offer = await Check(client);

        Assert.Equal("2.0.2", offer!.Version.Text);
        var request = Assert.Single(network.Requests);
        Assert.Equal("https://api.github.com/repos/Colour1205/ClipLink/releases?per_page=15", request.Url.AbsoluteUri);
        Assert.Equal("ClipLink/2.0.1", request.UserAgent);
        Assert.Equal("application/vnd.github+json", request.Accept);
    }

    [Fact]
    public async Task NoUpdateWhenThisIsTheNewest()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text(List(WithInstaller("v2.0.1"))));
        using var client = Client(network);
        Assert.Null(await Check(client));
    }

    [Fact]
    public async Task AWeirdVersionStringStillSendsAValidUserAgent()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text("[]"));
        using var client = new UpdateClient(UpdateEndpoint.Default, "2.0.1 (weird;;) \n", network);
        await Check(client);
        Assert.StartsWith("ClipLink", Assert.Single(network.Requests).UserAgent);
    }

    [Theory]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData((HttpStatusCode)429)]
    public async Task TooManyRequestsIsSaidPlainly(HttpStatusCode status)
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text("{\"message\":\"API rate limit exceeded\"}", status));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Server, ex.Kind);
        Assert.Contains("limiting", ex.Message);
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.BadGateway)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    public async Task AnErrorFromGitHubIsAServerError(HttpStatusCode status)
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text("oops", status));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Server, ex.Kind);
    }

    [Theory]
    [InlineData("")]
    [InlineData("<html>captive portal</html>")]
    [InlineData("{\"message\":\"Not Found\"}")]
    [InlineData("null")]
    public async Task AnAnswerThatIsNotAListOfReleasesIsABadResponse(string body)
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text(body));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.BadResponse, ex.Kind);
    }

    [Fact]
    public async Task AnAnswerThatAnnouncesItIsHugeIsNotRead()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Bytes(new byte[5 * 1024 * 1024]));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.BadResponse, ex.Kind);
    }

    [Fact]
    public async Task AnEndlessAnswerIsCutOff()
    {
        // No length announced, and it never ends.
        var network = new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new EndlessContent() });
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.BadResponse, ex.Kind);
    }

    [Fact]
    public async Task NoNetworkIsANetworkProblem()
    {
        var network = new FakeNetwork(_ => throw new HttpRequestException("No such host is known."));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Network, ex.Kind);
    }

    [Fact]
    public async Task ADroppedConnectionWhileReadingIsANetworkProblem()
    {
        var network = new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new TroubledContent(new byte[10], _ => throw new IOException("The response ended prematurely.")),
        });
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Network, ex.Kind);
    }

    [Fact]
    public async Task CancellingIsNotAnError()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text("[]"));
        using var client = Client(network);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.CheckAsync(Version("2.0.1"), cancelled.Token));
    }

    [Fact]
    public async Task ARedirectToAnotherHostIsNotFollowed()
    {
        var network = new FakeNetwork(request => request.RequestUri!.Host == "api.github.com"
            ? FakeNetwork.Redirect("https://evil.example/releases")
            : FakeNetwork.Text(List(WithInstaller("v9.9.9"))));
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));

        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.DoesNotContain(network.Requests, r => r.Url.Host == "evil.example");
    }

    [Fact]
    public async Task ARedirectToPlainHttpIsNotFollowed()
    {
        var network = new FakeNetwork(request => request.RequestUri!.Scheme == "https"
            ? FakeNetwork.Redirect("http://api.github.com/repos/Colour1205/ClipLink/releases")
            : FakeNetwork.Text(List(WithInstaller("v9.9.9"))));
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));

        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.Single(network.Requests);
    }

    [Fact]
    public async Task ARedirectWithinGitHubIsFollowed()
    {
        var network = new FakeNetwork(request => request.RequestUri!.AbsolutePath.EndsWith("/moved")
            ? FakeNetwork.Text(List(WithInstaller("v2.0.2")))
            : FakeNetwork.Redirect("/repos/Colour1205/ClipLink/releases/moved", HttpStatusCode.MovedPermanently));
        using var client = Client(network);

        Assert.Equal("2.0.2", (await Check(client))!.Version.Text);
        Assert.Equal(2, network.Requests.Count);
    }

    [Fact]
    public async Task EndlessRedirectsStop()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Redirect("https://api.github.com/again"));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Server, ex.Kind);
        Assert.True(network.Requests.Count <= 7);
    }

    [Fact]
    public async Task ARedirectWithNowhereToGoIsAServerProblem()
    {
        var network = new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.Found));
        using var client = Client(network);
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Server, ex.Kind);
    }

    [Fact]
    public async Task AnEndpointThePolicyRefusesIsNeverAsked()
    {
        var network = new FakeNetwork(_ => FakeNetwork.Text("[]"));
        using var client = Client(network, new UpdateEndpoint(new Uri("http://api.github.com/releases"), UpdateUrlPolicy.Strict));
        var ex = await Assert.ThrowsAsync<UpdateException>(() => Check(client));
        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.Empty(network.Requests);
    }

#if DEBUG
    [Fact]
    public async Task ATestEndpointOnLoopbackWorksInDebugBuilds()
    {
        var endpoint = new UpdateEndpoint(new Uri("http://127.0.0.1:49555/releases"), UpdateUrlPolicy.WithLoopback);
        var json = List(Release("v2.0.2", Asset("ClipLink-Setup-2.0.2.exe", url: "http://127.0.0.1:49555/ClipLink-Setup-2.0.2.exe")));
        var network = new FakeNetwork(_ => FakeNetwork.Text(json));
        using var client = Client(network, endpoint);

        var offer = await client.CheckAsync(Version("2.0.1"), CancellationToken.None);

        Assert.Equal("http://127.0.0.1:49555/ClipLink-Setup-2.0.2.exe", offer!.Asset.Url!.AbsoluteUri);
    }
#endif

    // A body that never stops.
    private sealed class EndlessContent : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new NotSupportedException();

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }

        protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult<Stream>(new EndlessStream());

        private sealed class EndlessStream : Stream
        {
            public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            {
                buffer.Span.Fill((byte)'['); // not valid JSON, but it'll never get that far
                return ValueTask.FromResult(buffer.Length);
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
}

public class UpdateClientDownloadTests
{
    private const string AssetUrl = "https://github.com/Colour1205/ClipLink/releases/download/v2.0.2/ClipLink-Setup-2.0.2.exe";
    private const string Cdn = "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r&sig=secret";

    private static readonly byte[] Installer = TestReleases.Installer();

    // GitHub's way: the release URL redirects to the CDN, which has the file.
    private static FakeNetwork GitHub(byte[]? served = null) => new(request =>
        request.RequestUri!.Host == "github.com" ? FakeNetwork.Redirect(Cdn)
        : request.RequestUri.Host == "release-assets.githubusercontent.com" ? FakeNetwork.Bytes(served ?? Installer)
        : new HttpResponseMessage(HttpStatusCode.NotFound));

    private static UpdateClient Client(FakeNetwork network) => new(UpdateEndpoint.Default, "2.0.1", network);

    private static ReleaseOffer Offer(byte[]? installer = null) => TestReleases.Offer("2.0.2", installer ?? Installer, "v2.0.2", AssetUrl);

    [Fact]
    public async Task DownloadsChecksAndHoldsTheInstaller()
    {
        using var folder = new TempFolder();
        var network = GitHub();
        using var client = Client(network);
        var reports = new List<UpdateProgress>();

        using (var installer = await client.DownloadAsync(Offer(), folder.Path, new SyncProgress<UpdateProgress>(reports.Add), CancellationToken.None))
        {
            Assert.Equal(folder.File("ClipLink-Setup-2.0.2.exe"), installer.FilePath);
            Assert.Equal(Installer, await File.ReadAllBytesAsync(installer.FilePath));
            Assert.Equal(new[] { "ClipLink-Setup-2.0.2.exe" }, folder.Names());

            // Held: the file that was checked can't be swapped for another.
            Assert.Throws<IOException>(() => File.Delete(installer.FilePath));
            Assert.Throws<IOException>(() => File.Move(installer.FilePath, folder.File("other.exe")));
            Assert.Throws<IOException>(() => File.Open(installer.FilePath, FileMode.Open, FileAccess.Write, FileShare.None).Dispose());
            Assert.Throws<IOException>(() => File.WriteAllBytes(installer.FilePath, new byte[1]));
        }
        File.Delete(folder.File("ClipLink-Setup-2.0.2.exe")); // let go of at Dispose

        Assert.Equal(new[] { "github.com", "release-assets.githubusercontent.com" }, network.Requests.Select(r => r.Url.Host));
        Assert.Equal("application/octet-stream", network.Requests[0].Accept);
        Assert.Equal("ClipLink/2.0.1", network.Requests[0].UserAgent);
        Assert.Equal(UpdateStage.Verifying, reports[^1].Stage);
        Assert.Equal(Installer.Length, reports[^1].Total);
    }

    [Fact]
    public async Task ReportsProgressWhileDownloading()
    {
        using var folder = new TempFolder();
        var big = TestReleases.Installer(3_000_000);
        var network = new FakeNetwork(request => FakeNetwork.Bytes(big));
        using var client = Client(network);
        var reports = new List<UpdateProgress>();

        using var installer = await client.DownloadAsync(Offer(big), folder.Path, new SyncProgress<UpdateProgress>(reports.Add), CancellationToken.None);

        Assert.All(reports.Where(r => r.Stage == UpdateStage.Downloading), r =>
        {
            Assert.Equal(big.Length, r.Total);
            Assert.InRange(r.Done, 1, big.Length);
        });
        Assert.Equal(reports.Select(r => r.Done).Order(), reports.Select(r => r.Done)); // only ever forwards
    }

    [Fact]
    public async Task AWrongHashIsRefusedAndLeavesNothing()
    {
        using var folder = new TempFolder();
        var tampered = (byte[])Installer.Clone();
        tampered[tampered.Length / 2] ^= 0xFF; // same size, one byte different
        using var client = Client(GitHub(tampered));

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        Assert.Empty(folder.Names());
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(1)]
    [InlineData(-199_999)]
    public async Task AWrongSizeIsRefusedAndLeavesNothing(int difference)
    {
        using var folder = new TempFolder();
        var wrongSize = difference < 0 ? Installer[..(Installer.Length + difference)] : Installer.Concat(new byte[difference]).ToArray();
        using var client = Client(GitHub(wrongSize));

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task ABodyLongerThanAnnouncedIsCutOffAndRefused()
    {
        using var folder = new TempFolder();
        // No length announced, and more than the asset's size is sent.
        var network = new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new TroubledContent(new byte[Installer.Length + 1], cancellation => Task.Delay(Timeout.Infinite, cancellation)),
        });
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task WithoutADigestNothingIsDownloaded()
    {
        using var folder = new TempFolder();
        var network = GitHub();
        using var client = Client(network);
        var offer = Offer() with { Asset = Offer().Asset with { Sha256 = null } };

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(offer, folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        Assert.Empty(network.Requests);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task WithoutAnAddressNothingIsDownloaded()
    {
        using var folder = new TempFolder();
        var network = GitHub();
        using var client = Client(network);
        var offer = Offer() with { Asset = Offer().Asset with { Url = null } };

        await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(offer, folder.Path, null, CancellationToken.None));

        Assert.Empty(network.Requests);
    }

    [Fact]
    public async Task ARedirectToAnotherHostIsNotFollowed()
    {
        using var folder = new TempFolder();
        var network = new FakeNetwork(request => request.RequestUri!.Host == "github.com"
            ? FakeNetwork.Redirect("https://evil.example/ClipLink-Setup-2.0.2.exe")
            : FakeNetwork.Bytes(Installer));
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.DoesNotContain(network.Requests, r => r.Url.Host == "evil.example");
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task ARedirectLaterInTheChainToAnotherHostIsNotFollowed()
    {
        using var folder = new TempFolder();
        var network = new FakeNetwork(request => request.RequestUri!.Host switch
        {
            "github.com" => FakeNetwork.Redirect(Cdn),
            "release-assets.githubusercontent.com" => FakeNetwork.Redirect("https://download.evil.example/x.exe"),
            _ => FakeNetwork.Bytes(Installer),
        });
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.DoesNotContain(network.Requests, r => r.Url.Host.EndsWith("evil.example"));
    }

    [Fact]
    public async Task ARedirectDownToHttpIsNotFollowed()
    {
        using var folder = new TempFolder();
        var network = new FakeNetwork(request => request.RequestUri!.Scheme == "https"
            ? FakeNetwork.Redirect("http://objects.githubusercontent.com/x.exe")
            : FakeNetwork.Bytes(Installer));
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.Single(network.Requests);
    }

    [Fact]
    public async Task AnAddressThePolicyRefusesIsNeverAsked()
    {
        using var folder = new TempFolder();
        var network = GitHub();
        using var client = Client(network);
        var offer = TestReleases.Offer("2.0.2", Installer, url: "https://evil.example/ClipLink-Setup-2.0.2.exe");

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(offer, folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Untrusted, ex.Kind);
        Assert.Empty(network.Requests);
    }

    [Fact]
    public async Task ANotFoundIsAServerProblem()
    {
        using var folder = new TempFolder();
        using var client = Client(new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.NotFound)));

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Server, ex.Kind);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task ADroppedConnectionLeavesNothing()
    {
        using var folder = new TempFolder();
        var network = new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new TroubledContent(new byte[50_000], _ => throw new IOException("The response ended prematurely.")),
        });
        using var client = Client(network);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Network, ex.Kind);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task CancellingStopsAndLeavesNothing()
    {
        using var folder = new TempFolder();
        var started = new TaskCompletionSource();
        var network = new FakeNetwork(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new TroubledContent(new byte[50_000], async cancellation =>
            {
                started.TrySetResult();
                await Task.Delay(Timeout.Infinite, cancellation);
            }),
        });
        using var client = Client(network);
        using var cancel = new CancellationTokenSource();

        var download = client.DownloadAsync(Offer(), folder.Path, null, cancel.Token);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(10));
        cancel.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => download);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public async Task ADownloadThatAlreadyHappenedIsReusedWithoutAskingAgain()
    {
        using var folder = new TempFolder();
        var network = GitHub();
        using var client = Client(network);

        (await client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None)).Dispose();
        int asked = network.Requests.Count;
        using var again = await client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None);

        Assert.Equal(asked, network.Requests.Count);
        Assert.Equal(folder.File("ClipLink-Setup-2.0.2.exe"), again.FilePath);
    }

    [Fact]
    public async Task ADownloadThatWasTamperedWithIsNotReused()
    {
        using var folder = new TempFolder();
        var network = GitHub();
        using var client = Client(network);
        (await client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None)).Dispose();
        await File.WriteAllBytesAsync(folder.File("ClipLink-Setup-2.0.2.exe"), TestReleases.Installer(Installer.Length, seed: 99));
        int asked = network.Requests.Count;

        using var again = await client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None);

        Assert.True(network.Requests.Count > asked);
        Assert.Equal(Installer, await File.ReadAllBytesAsync(again.FilePath));
    }

    [Fact]
    public async Task OldLeftoversAreCleanedUpButOtherFilesAreNot()
    {
        using var folder = new TempFolder();
        await File.WriteAllBytesAsync(folder.File("ClipLink-Setup-1.0.0.exe"), new byte[10]);
        await File.WriteAllBytesAsync(folder.File("ClipLink-Setup-2.0.0.exe.part"), new byte[10]);
        await File.WriteAllBytesAsync(folder.File("notes.txt"), new byte[10]);
        using var client = Client(GitHub());

        (await client.DownloadAsync(Offer(), folder.Path, null, CancellationToken.None)).Dispose();

        Assert.Equal(new[] { "ClipLink-Setup-2.0.2.exe", "notes.txt" }, folder.Names());
    }

    [Fact]
    public async Task AnUnwritableFolderIsADiskProblem()
    {
        using var folder = new TempFolder();
        // A file where the folder should be.
        string blocked = folder.File("blocked");
        await File.WriteAllBytesAsync(blocked, new byte[1]);
        using var client = Client(GitHub());

        var ex = await Assert.ThrowsAsync<UpdateException>(() => client.DownloadAsync(Offer(), blocked, null, CancellationToken.None));

        Assert.Equal(UpdateFailure.Disk, ex.Kind);
    }

    [Fact]
    public async Task TheFileIsNamedFromTheVersionWhateverTheAddressSays()
    {
        using var folder = new TempFolder();
        // The address ends in a hostile-looking name; the file doesn't take it.
        var offer = TestReleases.Offer("2.0.2", Installer, url: "https://github.com/Colour1205/ClipLink/releases/download/v2.0.2/..%2F..%2Fevil.exe");
        using var client = Client(new FakeNetwork(_ => FakeNetwork.Bytes(Installer)));

        using var installer = await client.DownloadAsync(offer, folder.Path, null, CancellationToken.None);

        Assert.Equal(folder.File("ClipLink-Setup-2.0.2.exe"), installer.FilePath);
        Assert.Equal(folder.Path, Path.GetDirectoryName(installer.FilePath));
    }

    // Progress<T> posts to another thread; these tests want the calls in order, right away.
    private sealed class SyncProgress<T> : IProgress<T>
    {
        private readonly Action<T> report;

        public SyncProgress(Action<T> report)
        {
            this.report = report;
        }

        public void Report(T value) => report(value);
    }
}
