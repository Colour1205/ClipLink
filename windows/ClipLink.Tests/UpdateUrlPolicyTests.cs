using ClipLink.Updates;
using Xunit;

namespace ClipLink.Tests;

public class UpdateUrlPolicyTests
{
    [Theory]
    [InlineData("https://github.com/Colour1205/ClipLink/releases/download/v2.0.1/ClipLink-Setup-2.0.1.exe")]
    [InlineData("https://api.github.com/repos/Colour1205/ClipLink/releases?per_page=15")]
    [InlineData("https://objects.githubusercontent.com/github-production-release-asset/1/2?X-Amz-Signature=abc")]
    [InlineData("https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r")]
    [InlineData("https://github-releases.githubusercontent.com/1/2")]
    [InlineData("https://GitHub.com/Colour1205/ClipLink")]
    [InlineData("https://github.com:443/Colour1205/ClipLink")]
    public void GitHubOverHttpsIsAllowed(string url)
    {
        Assert.True(UpdateUrlPolicy.Strict.IsAllowed(new Uri(url)));
    }

    [Theory]
    [InlineData("http://github.com/Colour1205/ClipLink/releases/download/v2.0.1/ClipLink-Setup-2.0.1.exe")]
    [InlineData("http://api.github.com/repos/Colour1205/ClipLink/releases")]
    [InlineData("http://objects.githubusercontent.com/x")]
    [InlineData("https://evil.example/ClipLink-Setup-2.0.1.exe")]
    [InlineData("https://github.com.evil.example/x")]
    [InlineData("https://evilgithub.com/x")]
    [InlineData("https://github.com.cn/x")]
    [InlineData("https://notgithub.com/x")]
    [InlineData("https://api.github.com.evil.example/x")]
    [InlineData("https://objects.githubusercontent.com.evil.example/x")]
    [InlineData("https://evilgithubusercontent.com/x")]
    [InlineData("https://githubusercontent.com/x")] // the bare domain isn't one of GitHub's
    [InlineData("https://raw.github.com/x")] // not one of the listed hosts
    [InlineData("https://gist.github.com/x")]
    [InlineData("https://evil.example/github.com")]
    [InlineData("https://evil.example/?u=https://github.com/")]
    [InlineData("https://github.com@evil.example/x")]
    [InlineData("https://user@github.com/x")]
    [InlineData("https://user:password@github.com/x")]
    [InlineData("https://github.com:8443/x")]
    [InlineData("https://github.com:80/x")]
    [InlineData("https://github.com./x")]
    [InlineData("ftp://github.com/x")]
    [InlineData("file:///C:/Windows/System32/cmd.exe")]
    [InlineData("file://github.com/share/x.exe")]
    [InlineData("javascript:alert(1)")]
    [InlineData("data:text/plain,hello")]
    [InlineData("https://127.0.0.1/x")]
    [InlineData("https://localhost/x")]
    [InlineData("https://[::1]/x")]
    [InlineData("https://140.82.112.3/x")] // an address, not a name
    [InlineData("http://127.0.0.1:8080/releases")]
    [InlineData("http://localhost:8080/releases")]
    public void AnythingElseIsRefused(string url)
    {
        Assert.False(UpdateUrlPolicy.Strict.IsAllowed(new Uri(url)));
    }

    [Fact]
    public void FullWidthLookalikesDoNotGetPast()
    {
        // Uri may fold these to a plain name or leave them alone. Allowed
        // only if the connection would really go to one of GitHub's hosts.
        foreach (string url in new[] { "https://github\u3002com/x", "https://g\u0456thub.com/x", "https://github.com\u2215evil.example/x", "https://\uff47ithub.com/x" })
        {
            if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && UpdateUrlPolicy.Strict.IsAllowed(uri))
                Assert.True(uri.IdnHost is "github.com" or "api.github.com" || uri.IdnHost.EndsWith(".githubusercontent.com", StringComparison.Ordinal), url);
        }
        Assert.False(UpdateUrlPolicy.Strict.IsAllowed(new Uri("https://g\u0456thub.com/x"))); // a Cyrillic i
    }

    [Fact]
    public void ARelativeOrMissingAddressIsRefused()
    {
        Assert.False(UpdateUrlPolicy.Strict.IsAllowed(null));
        Assert.False(UpdateUrlPolicy.Strict.IsAllowed(new Uri("/releases/download/x.exe", UriKind.Relative)));
    }

#if DEBUG
    [Theory]
    [InlineData("http://127.0.0.1:8080/releases", true)]
    [InlineData("http://127.0.0.1:49555/ClipLink-Setup-2.0.2.exe", true)]
    [InlineData("http://127.0.0.1/releases", true)]
    [InlineData("https://github.com/x", true)]
    [InlineData("https://127.0.0.1:8080/releases", false)] // https there isn't the stand-in server
    [InlineData("http://127.0.0.2:8080/releases", false)]
    [InlineData("http://localhost:8080/releases", false)]
    [InlineData("http://[::1]:8080/releases", false)]
    [InlineData("http://127.0.0.1.evil.example:8080/releases", false)]
    [InlineData("http://user@127.0.0.1:8080/releases", false)]
    [InlineData("http://192.168.1.5:8080/releases", false)]
    [InlineData("http://github.com/x", false)]
    [InlineData("http://evil.example/x", false)]
    public void DebugBuildsCanAlsoUseTheLoopbackServer(string url, bool allowed)
    {
        Assert.Equal(allowed, UpdateUrlPolicy.WithLoopback.IsAllowed(new Uri(url)));
        // ... and the normal policy still has no http at all.
        if (url.StartsWith("http://", StringComparison.Ordinal)) Assert.False(UpdateUrlPolicy.Strict.IsAllowed(new Uri(url)));
    }
#endif
}
