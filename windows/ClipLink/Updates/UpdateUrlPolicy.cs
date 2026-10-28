namespace ClipLink.Updates;

// Which addresses the updater may talk to: https, on a GitHub host, with no
// user name in it. Asked about the first address and about every redirect
// after it, so a redirect can't take a download anywhere else.
internal sealed class UpdateUrlPolicy
{
    public static UpdateUrlPolicy Strict { get; } = new();

#if DEBUG
    // Debug builds only (see UpdateEndpoint): http://127.0.0.1:<port> too, for
    // a stand-in releases server. Not here at all in a Release build - there
    // is nothing to switch on.
    public static UpdateUrlPolicy WithLoopback { get; } = new() { allowLoopback = true };

    private bool allowLoopback;
#endif

    private UpdateUrlPolicy()
    {
    }

    public bool IsAllowed(Uri? uri)
    {
        if (uri == null || !uri.IsAbsoluteUri || uri.UserInfo.Length > 0) return false;
        // The name the connection goes to (the punycode form of an
        // international one), not the one typed.
        string host = uri.IdnHost;
        if (uri.Scheme == Uri.UriSchemeHttps) return uri.Port == 443 && IsGitHubHost(host);
#if DEBUG
        if (allowLoopback && uri.Scheme == Uri.UriSchemeHttp) return host == "127.0.0.1";
#endif
        return false;
    }

    // github.com, api.github.com, and *.githubusercontent.com (where the
    // release files are served from).
    private static bool IsGitHubHost(string host) =>
        host is "github.com" or "api.github.com"
        || host.Length > ".githubusercontent.com".Length && host.EndsWith(".githubusercontent.com", StringComparison.Ordinal);
}
