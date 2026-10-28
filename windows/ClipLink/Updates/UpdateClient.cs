using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace ClipLink.Updates;

internal enum UpdateStage
{
    Downloading,
    Verifying,
}

internal readonly record struct UpdateProgress(UpdateStage Stage, long Done, long Total);

// The updater's contact with GitHub: asks for the list of releases, and
// downloads an installer. The only thing it sends is a plain HTTPS GET with
// the header User-Agent: ClipLink/<version> - nothing about this PC or
// its user. It follows redirects itself, checking every address against the
// endpoint's UpdateUrlPolicy first.
internal sealed class UpdateClient : IDisposable
{
    // GitHub's answer for 15 releases is well under 1 MB.
    private const int MaxAnswerBytes = 4 * 1024 * 1024;
    private const int MaxRedirects = 5;
    private const int BufferSize = 1 << 16;
    private static readonly TimeSpan AnswerTimeout = TimeSpan.FromSeconds(20);
    // A download is given up when no data comes for this long (however long it takes otherwise).
    private static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DefaultProgressInterval = TimeSpan.FromMilliseconds(100);

    private readonly UpdateEndpoint endpoint;
    private readonly HttpClient http;
    private readonly TimeSpan progressInterval;

    // `handler` is for tests, to stand in for the network. It must not follow
    // redirects itself (the real one doesn't): that's done here, address by address.
    // `progressInterval` is for tests too: how often a download reports.
    public UpdateClient(UpdateEndpoint endpoint, string appVersion, HttpMessageHandler? handler = null, TimeSpan? progressInterval = null)
    {
        this.endpoint = endpoint;
        this.progressInterval = progressInterval ?? DefaultProgressInterval;
        http = new HttpClient(handler ?? new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(15),
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        })
        {
            // Each call has its own limits instead.
            Timeout = System.Threading.Timeout.InfiniteTimeSpan,
        };
        if (!http.DefaultRequestHeaders.UserAgent.TryParseAdd($"ClipLink/{appVersion}"))
            http.DefaultRequestHeaders.UserAgent.ParseAdd("ClipLink");
    }

    public void Dispose() => http.Dispose();

    // The newest release above `current` that ClipLink can update to (see
    // ReleaseSelector), or null if this is the newest. Throws an UpdateException.
    public async Task<ReleaseOffer?> CheckAsync(ReleaseVersion current, CancellationToken cancellation)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        limit.CancelAfter(AnswerTimeout);
        string json;
        try
        {
            using var response = await GetAsync(endpoint.ApiUrl, "application/vnd.github+json", limit.Token);
            EnsureSuccess(response);
            if (response.Content.Headers.ContentLength > MaxAnswerBytes) throw TooBig();
            await using var body = await response.Content.ReadAsStreamAsync(limit.Token);
            using var bytes = new MemoryStream();
            var buffer = new byte[BufferSize];
            int read;
            while ((read = await body.ReadAsync(buffer, limit.Token)) > 0)
            {
                if (bytes.Length + read > MaxAnswerBytes) throw TooBig();
                bytes.Write(buffer, 0, read);
            }
            json = Encoding.UTF8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new UpdateException(UpdateFailure.Network, "GitHub didn't answer in time.");
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException)
        {
            throw new UpdateException(UpdateFailure.Network, "Couldn't reach GitHub.", ex);
        }
        return ReleaseSelector.FindUpdate(json, current, endpoint.Policy);
    }

    private static UpdateException TooBig() =>
        new(UpdateFailure.BadResponse, "GitHub's answer was far bigger than a list of releases.");

    // Downloads the installer of `offer` into `folder`, checks it and returns
    // it, held open (VerifiedInstaller). The file is called what
    // offer.InstallerFileName says. Written as <name>.part first, which is
    // renamed only once the size and SHA-256 match what GitHub lists; and
    // those are checked again, on the file that will run. Throws an
    // UpdateException; cancelling throws OperationCanceledException and
    // leaves nothing behind.
    public async Task<VerifiedInstaller> DownloadAsync(ReleaseOffer offer, string folder, IProgress<UpdateProgress>? progress,
        CancellationToken cancellation)
    {
        if (!offer.CanInstallInApp)
        {
            throw new UpdateException(UpdateFailure.Verification,
                "GitHub lists no checksum for this version, so ClipLink can't check the download. Use the download page instead.");
        }
        var asset = offer.Asset;
        string finalPath = Path.Combine(folder, offer.InstallerFileName);
        string partPath = finalPath + ".part";
        try
        {
            Directory.CreateDirectory(folder);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw DiskError(ex);
        }
        UpdateFolder.Clear(folder, keep: finalPath);

        // Downloaded and checked on an earlier click (the installer wasn't
        // given permission to run, say): no need to fetch it again.
        if (File.Exists(finalPath))
        {
            try
            {
                var existing = await VerifiedInstaller.OpenAsync(finalPath, asset, cancellation);
                Console.WriteLine($"[update] {offer.InstallerFileName} was downloaded and checked already");
                return existing;
            }
            catch (UpdateException)
            {
                UpdateFolder.TryDelete(finalPath);
            }
        }

        try
        {
            await DownloadToAsync(asset, partPath, progress, cancellation);
            progress?.Report(new UpdateProgress(UpdateStage.Verifying, asset.Size, asset.Size));
            await MoveAsync(partPath, finalPath, cancellation);
        }
        catch
        {
            UpdateFolder.TryDelete(partPath);
            throw;
        }

        try
        {
            return await VerifiedInstaller.OpenAsync(finalPath, asset, cancellation);
        }
        catch
        {
            // Under its final name only if it is good.
            UpdateFolder.TryDelete(finalPath);
            throw;
        }
    }

    // Streams the file to partPath, hashing as it goes: a download that is
    // wrong is found out here, before it has a name that could be run.
    private async Task DownloadToAsync(UpdateAsset asset, string partPath, IProgress<UpdateProgress>? progress, CancellationToken cancellation)
    {
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        try
        {
            stall.CancelAfter(StallTimeout);
            using var response = await GetAsync(asset.Url!, "application/octet-stream", stall.Token);
            EnsureSuccess(response);
            if (response.Content.Headers.ContentLength is long length && length != asset.Size) throw VerifiedInstaller.NotVerified();

            await using var body = await response.Content.ReadAsStreamAsync(stall.Token);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long received = 0;
            FileStream file;
            try
            {
                file = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None, BufferSize,
                    FileOptions.Asynchronous | FileOptions.SequentialScan);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw DiskError(ex);
            }
            await using (file)
            {
                var buffer = new byte[BufferSize];
                var clock = Stopwatch.StartNew();
                var lastReport = TimeSpan.Zero;
                while (true)
                {
                    int read;
                    stall.CancelAfter(StallTimeout);
                    try
                    {
                        read = await body.ReadAsync(buffer, stall.Token);
                    }
                    catch (IOException ex)
                    {
                        throw new UpdateException(UpdateFailure.Network, "The connection dropped during the download.", ex);
                    }
                    stall.CancelAfter(System.Threading.Timeout.InfiniteTimeSpan);
                    if (read == 0) break;

                    received += read;
                    if (received > asset.Size) throw VerifiedInstaller.NotVerified();
                    hash.AppendData(buffer, 0, read);
                    try
                    {
                        await file.WriteAsync(buffer.AsMemory(0, read), cancellation);
                    }
                    catch (IOException ex)
                    {
                        throw DiskError(ex);
                    }
                    if (clock.Elapsed - lastReport >= progressInterval)
                    {
                        lastReport = clock.Elapsed;
                        progress?.Report(new UpdateProgress(UpdateStage.Downloading, received, asset.Size));
                    }
                }
            }
            if (UpdateVerification.Check(received, UpdateVerification.ToHex(hash.GetHashAndReset()), asset) != VerifyResult.Ok)
                throw VerifiedInstaller.NotVerified();
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new UpdateException(UpdateFailure.Network, "The download stopped getting data. Check your connection and try again.");
        }
        catch (HttpRequestException ex)
        {
            throw new UpdateException(UpdateFailure.Network, "Couldn't reach GitHub.", ex);
        }
    }

    private static UpdateException DiskError(Exception inner) =>
        new(UpdateFailure.Disk, "Couldn't save the download to the temporary folder. Is the disk full?", inner);

    private static async Task MoveAsync(string from, string to, CancellationToken cancellation)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                File.Move(from, to, overwrite: true);
                return;
            }
            catch (IOException) when (attempt < 5 && File.Exists(from))
            {
                // (A virus scanner may have just been at the new file.)
                await Task.Delay(200, cancellation);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw DiskError(ex);
            }
        }
    }

    // GET, following redirects by hand: every address - the first and each
    // redirect's - has to pass the endpoint's policy before it is asked for.
    private async Task<HttpResponseMessage> GetAsync(Uri url, string accept, CancellationToken cancellation)
    {
        for (int redirects = 0; ; redirects++)
        {
            if (!endpoint.Policy.IsAllowed(url))
            {
                Console.WriteLine($"[update] refusing {url.GetLeftPart(UriPartial.Path)}");
                throw new UpdateException(UpdateFailure.Untrusted, "The update pointed somewhere ClipLink doesn't trust, so it was stopped.");
            }
            // (Not the query: a download's redirect carries a signed token in it.)
            Console.WriteLine($"[update] GET {url.GetLeftPart(UriPartial.Path)}");
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Accept.ParseAdd(accept);
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if (response.StatusCode is not (HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther
                or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect))
                return response;

            var location = response.Headers.Location;
            response.Dispose();
            if (location == null || redirects >= MaxRedirects)
                throw new UpdateException(UpdateFailure.Server, "GitHub sent ClipLink around in circles.");
            url = location.IsAbsoluteUri ? location : new Uri(url, location);
        }
    }

    private static void EnsureSuccess(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode) return;
        int code = (int)response.StatusCode;
        // GitHub answers 403 or 429 when one address has asked too often.
        throw new UpdateException(UpdateFailure.Server, code is 403 or 429
            ? "GitHub is limiting requests from this network right now. Try again later."
            : $"GitHub answered with an error ({code}).");
    }
}
