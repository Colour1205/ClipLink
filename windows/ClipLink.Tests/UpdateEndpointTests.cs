using ClipLink.Updates;
using Xunit;

namespace ClipLink.Tests;

// The Debug-only test hooks (CLIPLINK_UPDATE_API_URL and
// CLIPLINK_UPDATE_CHECK_DELAY_SECONDS), and that a Release build has none.
public class UpdateEndpointTests
{
    private static Func<string, string?> Variables(params (string Name, string Value)[] variables) =>
        name => variables.Where(v => v.Name == name).Select(v => v.Value).FirstOrDefault();

    [Fact]
    public void WithoutAnyVariablesItIsGitHub()
    {
        var endpoint = UpdateEndpoint.FromEnvironment(Variables());
        Assert.Equal("https://api.github.com/repos/Colour1205/ClipLink/releases?per_page=15", endpoint.ApiUrl.AbsoluteUri);
        Assert.Same(UpdateUrlPolicy.Strict, endpoint.Policy);
        Assert.False(endpoint.IsTestOverride);
        Assert.Equal(TimeSpan.FromSeconds(10), UpdateEndpoint.StartupDelay(Variables()));
    }

    [Fact]
    public void TheDefaultEndpointIsStrict()
    {
        Assert.Same(UpdateUrlPolicy.Strict, UpdateEndpoint.Default.Policy);
        Assert.False(UpdateEndpoint.Default.Policy.IsAllowed(new Uri("http://127.0.0.1:8080/releases")));
    }

#if DEBUG
    [Fact]
    public void DebugBuildsHonourTheTestAddress()
    {
        var endpoint = UpdateEndpoint.FromEnvironment(Variables(("CLIPLINK_UPDATE_API_URL", "http://127.0.0.1:49555/releases")));
        Assert.True(endpoint.IsTestOverride);
        Assert.Equal("http://127.0.0.1:49555/releases", endpoint.ApiUrl.AbsoluteUri);
        Assert.True(endpoint.Policy.IsAllowed(new Uri("http://127.0.0.1:49555/ClipLink-Setup-2.0.2.exe")));
        Assert.True(endpoint.Policy.IsAllowed(new Uri("https://github.com/x")));
        Assert.False(endpoint.Policy.IsAllowed(new Uri("http://example.com/x")));
    }

    [Theory]
    [InlineData("https://evil.example/releases")]
    [InlineData("http://evil.example/releases")]
    [InlineData("http://localhost:8080/releases")]
    [InlineData("http://192.168.1.2:8080/releases")]
    [InlineData("https://127.0.0.1:8080/releases")]
    [InlineData("file:///C:/releases.json")]
    [InlineData("127.0.0.1:8080")]
    [InlineData("not a url")]
    [InlineData("")]
    public void DebugBuildsIgnoreATestAddressThatIsNotLoopbackHttp(string value)
    {
        var endpoint = UpdateEndpoint.FromEnvironment(Variables(("CLIPLINK_UPDATE_API_URL", value)));
        Assert.False(endpoint.IsTestOverride);
        Assert.Equal(UpdateEndpoint.Default.ApiUrl, endpoint.ApiUrl);
        Assert.Same(UpdateUrlPolicy.Strict, endpoint.Policy);
    }

    [Theory]
    [InlineData("0", 0)]
    [InlineData("2", 2)]
    [InlineData("3600", 3600)]
    [InlineData("-1", 10)]
    [InlineData("3601", 10)]
    [InlineData("soon", 10)]
    [InlineData("", 10)]
    public void DebugBuildsHonourAShorterStartupDelay(string value, int expectedSeconds)
    {
        Assert.Equal(TimeSpan.FromSeconds(expectedSeconds), UpdateEndpoint.StartupDelay(Variables(("CLIPLINK_UPDATE_CHECK_DELAY_SECONDS", value))));
    }
#else
    [Fact]
    public void ReleaseBuildsIgnoreTheTestHooks()
    {
        var variables = Variables(("CLIPLINK_UPDATE_API_URL", "http://127.0.0.1:49555/releases"), ("CLIPLINK_UPDATE_CHECK_DELAY_SECONDS", "1"));
        var endpoint = UpdateEndpoint.FromEnvironment(variables);
        Assert.False(endpoint.IsTestOverride);
        Assert.Equal(UpdateEndpoint.Default.ApiUrl, endpoint.ApiUrl);
        Assert.Same(UpdateUrlPolicy.Strict, endpoint.Policy);
        Assert.Equal(TimeSpan.FromSeconds(10), UpdateEndpoint.StartupDelay(variables));
    }
#endif
}
