using ClipLink.Updates;
using Xunit;

namespace ClipLink.Tests;

public class ReleaseVersionTests
{
    private static ReleaseVersion V(string text)
    {
        Assert.True(ReleaseVersion.TryParse(text, out var version), $"\"{text}\" should parse");
        return version;
    }

    [Theory]
    [InlineData("2.0.1", "2.0.1")]
    [InlineData("v2.0.1", "2.0.1")]
    [InlineData("V2.0.1", "2.0.1")]
    [InlineData("  v2.0.1 ", "2.0.1")]
    [InlineData("2.0", "2.0")]
    [InlineData("2", "2")]
    [InlineData("1.2.3.4", "1.2.3.4")]
    [InlineData("2.0.1+abc123", "2.0.1")]
    [InlineData("v2.0.1+build.5", "2.0.1")]
    [InlineData("2.1.0-rc.1", "2.1.0-rc.1")]
    [InlineData("2.1.0-rc.1+sha", "2.1.0-rc.1")]
    [InlineData("007.01", "7.1")]
    public void Parses(string text, string expectedText)
    {
        Assert.Equal(expectedText, V(text).Text);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("v")]
    [InlineData("latest")]
    [InlineData("1.x")]
    [InlineData("1..2")]
    [InlineData(".1")]
    [InlineData("1.")]
    [InlineData("1.2.3.4.5")]
    [InlineData("-1.0")]
    [InlineData("1.0-")]
    [InlineData("1.0-a..b")]
    [InlineData("1.0-a b")]
    [InlineData("1.0 beta")]
    [InlineData("vv1.0")]
    [InlineData("1.0.0\\..\\..\\evil")]
    [InlineData("1.0/../x")]
    [InlineData("99999999999.0")]
    [InlineData("1.0.-1")]
    [InlineData("２.０")] // full-width digits
    [InlineData("٢.٠")] // Arabic-Indic digits
    public void Rejects(string? text)
    {
        Assert.False(ReleaseVersion.TryParse(text, out _));
    }

    [Fact]
    public void ShortAndLongFormsAreTheSameVersion()
    {
        Assert.Equal(V("2.0"), V("2.0.0"));
        Assert.Equal(V("2"), V("2.0.0.0"));
        Assert.Equal(V("v2.0.1"), V("2.0.1+other"));
        Assert.Equal(V("2.0").GetHashCode(), V("2.0.0").GetHashCode());
    }

    [Theory]
    [InlineData("2.0", "2.0.1")]
    [InlineData("2.0.9", "2.0.10")]
    [InlineData("2.9", "2.10")]
    [InlineData("9.9", "10.0")]
    [InlineData("1.99.99", "2.0.0")]
    [InlineData("2.0.1", "2.0.1.1")]
    [InlineData("v1.0.0", "v1.0.1")]
    public void LowerComesFirst(string lower, string higher)
    {
        Assert.True(V(lower) < V(higher));
        Assert.True(V(higher) > V(lower));
        Assert.True(V(lower) <= V(higher));
        Assert.True(V(higher) >= V(lower));
        Assert.NotEqual(V(lower), V(higher));
    }

    [Theory]
    [InlineData("2.1.0-rc.1", "2.1.0")]
    [InlineData("2.1.0-alpha", "2.1.0-beta")]
    [InlineData("2.1.0-rc.1", "2.1.0-rc.2")]
    [InlineData("2.1.0-rc.2", "2.1.0-rc.10")]
    [InlineData("2.1.0-alpha", "2.1.0-alpha.1")]
    [InlineData("2.1.0-1", "2.1.0-alpha")]
    [InlineData("2.0.9", "2.1.0-alpha")]
    public void PreReleaseComesBeforeItsRelease(string lower, string higher)
    {
        Assert.True(V(lower) < V(higher));
        Assert.True(V(higher) > V(lower));
    }

    [Fact]
    public void PreReleasesAreMarked()
    {
        Assert.True(V("2.1.0-rc.1").IsPreRelease);
        Assert.False(V("2.1.0").IsPreRelease);
        Assert.False(V("2.1.0+meta").IsPreRelease);
    }

    [Fact]
    public void BuildMetadataDoesNotCount()
    {
        Assert.Equal(V("2.0.1+aaa"), V("2.0.1+bbb"));
        Assert.False(V("2.0.1+zzz") > V("2.0.1"));
    }
}
