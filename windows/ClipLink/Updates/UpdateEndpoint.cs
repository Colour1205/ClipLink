namespace ClipLink.Updates;

// Where the updater looks for releases, and which addresses it may use.
internal sealed class UpdateEndpoint
{
    public const string ReleasesPageUrl = "https://github.com/Colour1205/ClipLink/releases";
    private const string ReleasesApiUrl = "https://api.github.com/repos/Colour1205/ClipLink/releases?per_page=15";

    // The first automatic check comes this long after ClipLink starts.
    public static readonly TimeSpan DefaultStartupDelay = TimeSpan.FromSeconds(10);

    public UpdateEndpoint(Uri apiUrl, UpdateUrlPolicy policy)
    {
        ApiUrl = apiUrl;
        Policy = policy;
    }

    public Uri ApiUrl { get; }
    public UpdateUrlPolicy Policy { get; }

    // True when a Debug build was pointed at a stand-in server (see below).
    public bool IsTestOverride { get; private init; }

    public static UpdateEndpoint Default { get; } = new(new Uri(ReleasesApiUrl), UpdateUrlPolicy.Strict);

    public static UpdateEndpoint FromEnvironment() => FromEnvironment(Environment.GetEnvironmentVariable);

    public static TimeSpan StartupDelay() => StartupDelay(Environment.GetEnvironmentVariable);

    // Test hooks for the end-to-end tests - in Debug builds ONLY. All of this
    // is compiled out of a Release build (#if DEBUG): no variable, command
    // line option or setting can switch it on there, and the URL policy has
    // no loopback rule to relax.
    //   CLIPLINK_UPDATE_API_URL=http://127.0.0.1:<port>/<path>
    //       asks this address for the releases instead of GitHub's, and lets
    //       the updater use http://127.0.0.1:<port> addresses (for the
    //       releases and for the installers they list). Anything else in
    //       the variable - another host, https elsewhere - is ignored.
    //   CLIPLINK_UPDATE_CHECK_DELAY_SECONDS=<n>
    //       the wait before the first automatic check (10 seconds usually).
    internal static UpdateEndpoint FromEnvironment(Func<string, string?> variable)
    {
#if DEBUG
        if (variable("CLIPLINK_UPDATE_API_URL") is { Length: > 0 } text
            && Uri.TryCreate(text, UriKind.Absolute, out var url)
            && url.Scheme == Uri.UriSchemeHttp && UpdateUrlPolicy.WithLoopback.IsAllowed(url))
        {
            Console.WriteLine($"[update] test hook: asking {url.GetLeftPart(UriPartial.Path)} for releases");
            return new UpdateEndpoint(url, UpdateUrlPolicy.WithLoopback) { IsTestOverride = true };
        }
#endif
        return Default;
    }

    internal static TimeSpan StartupDelay(Func<string, string?> variable)
    {
#if DEBUG
        if (int.TryParse(variable("CLIPLINK_UPDATE_CHECK_DELAY_SECONDS"), out int seconds) && seconds is >= 0 and <= 3600)
            return TimeSpan.FromSeconds(seconds);
#endif
        return DefaultStartupDelay;
    }
}
