using System.Text.Json;
using ClipLink.Updates;
using Xunit;
using static ClipLink.Tests.TestReleases;

namespace ClipLink.Tests;

public class ReleaseSelectorTests
{
    [Fact]
    public void OffersTheNewestReleaseWithTheInstaller()
    {
        string json = List(WithInstaller("v2.0.2"), WithInstaller("v2.0.1"), WithInstaller("v2.0.0"));
        var offer = Find(json, "2.0.1");

        Assert.NotNull(offer);
        Assert.Equal("2.0.2", offer.Version.Text);
        Assert.Equal("ClipLink-Setup-2.0.2.exe", offer.InstallerFileName);
        Assert.Equal(55_907_797, offer.Asset.Size);
        Assert.Equal(GoodDigest["sha256:".Length..], offer.Asset.Sha256);
        Assert.Equal("https://github.com/Colour1205/ClipLink/releases/download/v2.0.2/ClipLink-Setup-2.0.2.exe", offer.Asset.Url!.AbsoluteUri);
        Assert.Equal("https://github.com/Colour1205/ClipLink/releases/tag/v2.0.2", offer.PageUrl.AbsoluteUri);
        Assert.True(offer.CanInstallInApp);
    }

    [Fact]
    public void TheOrderOfTheListDoesNotMatter()
    {
        string json = List(WithInstaller("v2.0.0"), WithInstaller("v2.0.3"), WithInstaller("v2.0.1"), WithInstaller("v2.0.2"));
        Assert.Equal("2.0.3", Find(json, "2.0.1")!.Version.Text);
    }

    [Fact]
    public void NothingNewerMeansNoUpdate()
    {
        string json = List(WithInstaller("v2.0.1"), WithInstaller("v2.0.0"));
        Assert.Null(Find(json, "2.0.1"));
        Assert.Null(Find(json, "2.0.1+abc"));
        Assert.Null(Find(json, "2.0.2"));
        Assert.Null(Find(json, "10.0"));
    }

    [Fact]
    public void ARunningPreReleaseIsOlderThanItsRelease()
    {
        Assert.Equal("2.1.0", Find(List(WithInstaller("v2.1.0")), "2.1.0-rc.1")!.Version.Text);
    }

    [Fact]
    public void SkipsDrafts()
    {
        string json = List(WithInstaller("v2.0.3", draft: true), WithInstaller("v2.0.2"));
        Assert.Equal("2.0.2", Find(json, "2.0.1")!.Version.Text);
        Assert.Null(Find(List(WithInstaller("v2.0.3", draft: true)), "2.0.1"));
    }

    [Fact]
    public void SkipsPreReleases()
    {
        string json = List(WithInstaller("v2.1.0", prerelease: true), WithInstaller("v2.0.2"));
        Assert.Equal("2.0.2", Find(json, "2.0.1")!.Version.Text);
        Assert.Null(Find(List(WithInstaller("v2.1.0", prerelease: true)), "2.0.1"));
    }

    [Fact]
    public void SkipsATagThatIsAPreReleaseEvenIfGitHubDoesNotMarkIt()
    {
        string json = List(WithInstaller("v2.1.0-rc.1"), WithInstaller("v2.0.2"));
        Assert.Equal("2.0.2", Find(json, "2.0.1")!.Version.Text);
    }

    [Fact]
    public void SkipsReleasesWithoutTheWindowsInstaller_AndKeepsLooking()
    {
        // The Android build's release: newer, but nothing for Windows in it.
        var androidOnly = Release("v2.1.0", Asset("ClipLink-2.1.0.apk", tag: "v2.1.0"));
        var noAssets = Release("v2.2.0");
        string json = List(noAssets, androidOnly, WithInstaller("v2.0.1"));

        Assert.Equal("2.0.1", Find(json, "2.0.0")!.Version.Text);
        // ... and that is no reason to think there is an update when there isn't one.
        Assert.Null(Find(json, "2.0.1"));
    }

    [Fact]
    public void ANewerReleaseWithTheInstallerBeatsAnOlderOne()
    {
        var androidOnly = Release("v2.1.0", Asset("ClipLink-2.1.0.apk", tag: "v2.1.0"));
        string json = List(androidOnly, WithInstaller("v2.0.2"), WithInstaller("v2.0.1"));
        Assert.Equal("2.0.2", Find(json, "2.0.0")!.Version.Text);
    }

    [Fact]
    public void ShortVersionsMatchLongOnes()
    {
        string json = List(WithInstaller("v2.0"));
        Assert.Null(Find(json, "2.0.0"));
        var offer = Find(json, "1.9.9");
        Assert.NotNull(offer);
        Assert.Equal("ClipLink-Setup-2.0.exe", offer.InstallerFileName);
    }

    [Fact]
    public void ATagWithoutTheVWorks()
    {
        var release = Release("2.0.2", Asset("ClipLink-Setup-2.0.2.exe", tag: "2.0.2"));
        Assert.Equal("2.0.2", Find(List(release), "2.0.1")!.Version.Text);
    }

    [Theory]
    [InlineData("clipLink-setup-2.0.2.exe")]
    [InlineData("CLIPLINK-SETUP-2.0.2.EXE")]
    [InlineData("ClipLink-Setup-2.0.1.exe")] // another version's
    [InlineData("ClipLink-Setup-2.0.2.exe.sig")]
    [InlineData("ClipLink-Setup-2.0.2.exe ")]
    [InlineData(" ClipLink-Setup-2.0.2.exe")]
    [InlineData("ClipLink-Setup-2.0.2.zip")]
    [InlineData("ClipLink-Setup-2.0.2")]
    [InlineData("ClipLink-Setup-2.0.2.0.exe")]
    [InlineData("setup.exe")]
    [InlineData("")]
    public void TheInstallerMustHaveExactlyItsName(string name)
    {
        var release = Release("v2.0.2", Asset(name, tag: "v2.0.2"));
        Assert.Null(Find(List(release), "2.0.1"));
    }

    [Theory]
    [InlineData(@"..\..\evil.exe")]
    [InlineData("../../evil.exe")]
    [InlineData(@"C:\Windows\System32\evil.exe")]
    [InlineData(@"ClipLink-Setup-2.0.2.exe\..\..\evil.exe")]
    [InlineData("ClipLink-Setup-2.0.2.exe\0.txt")]
    public void AHostileAssetNameIsNeverUsed(string hostile)
    {
        var release = Release("v2.0.2", Asset(hostile, tag: "v2.0.2"), Asset("ClipLink-Setup-2.0.2.exe", tag: "v2.0.2"));
        var offer = Find(List(release), "2.0.1");

        // Only the properly named file counts, and it is saved under a name
        // made from the version, whatever the JSON said.
        Assert.NotNull(offer);
        Assert.Equal("ClipLink-Setup-2.0.2.exe", offer.InstallerFileName);
        Assert.Equal(offer.InstallerFileName, Path.GetFileName(offer.InstallerFileName));
        string folder = Path.Combine(Path.GetTempPath(), "ClipLink-update");
        Assert.Equal(folder, Path.GetDirectoryName(Path.Combine(folder, offer.InstallerFileName)));
    }

    [Theory]
    [InlineData(@"v2.0.2\..\..\x")]
    [InlineData("v2.0.2/../../x")]
    [InlineData("v2.0.2 beta")]
    [InlineData("release-2.0.2")]
    [InlineData("latest")]
    [InlineData("")]
    public void AHostileOrOddTagIsSkipped(string tag)
    {
        var release = Release(tag, Asset($"ClipLink-Setup-{tag.TrimStart('v')}.exe", tag: tag));
        Assert.Null(Find(List(release), "2.0.1"));
    }

    [Fact]
    public void SkipsAnInstallerThatIsStillBeingUploaded()
    {
        var release = Release("v2.0.2", Asset("ClipLink-Setup-2.0.2.exe", state: "open", tag: "v2.0.2"));
        Assert.Null(Find(List(release), "2.0.1"));
    }

    [Fact]
    public void AMissingStateIsFine()
    {
        var release = Release("v2.0.2", Asset("ClipLink-Setup-2.0.2.exe", state: null, tag: "v2.0.2"));
        Assert.NotNull(Find(List(release), "2.0.1"));
    }

    [Fact]
    public void NoDigestStillOffersTheUpdate_ButNotAnInAppInstall()
    {
        var offer = Find(List(WithInstaller("v2.0.2", digest: null)), "2.0.1");
        Assert.NotNull(offer);
        Assert.Null(offer.Asset.Sha256);
        Assert.False(offer.CanInstallInApp);
    }

    [Theory]
    [InlineData("sha256:xyz")]
    [InlineData("sha256:")]
    [InlineData("sha1:0123456789abcdef0123456789abcdef01234567")]
    [InlineData("sha512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")]
    [InlineData("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")] // no algorithm
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde")] // 63
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0")] // 65
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg")]
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")]
    [InlineData("sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")]
    [InlineData("SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")]
    [InlineData("")]
    public void AMalformedDigestMeansNoInAppInstall(string digest)
    {
        var offer = Find(List(WithInstaller("v2.0.2", digest: digest)), "2.0.1");
        Assert.NotNull(offer);
        Assert.Null(offer.Asset.Sha256);
        Assert.False(offer.CanInstallInApp);
    }

    [Fact]
    public void ADigestInCapitalsIsReadAsLowercase()
    {
        string upper = "sha256:" + GoodDigest["sha256:".Length..].ToUpperInvariant();
        var offer = Find(List(WithInstaller("v2.0.2", digest: upper)), "2.0.1");
        Assert.Equal(GoodDigest["sha256:".Length..], offer!.Asset.Sha256);
        Assert.True(offer.CanInstallInApp);
    }

    [Theory]
    [InlineData("http://github.com/Colour1205/ClipLink/releases/download/v2.0.2/ClipLink-Setup-2.0.2.exe")]
    [InlineData("https://evil.example/ClipLink-Setup-2.0.2.exe")]
    [InlineData("https://github.com.evil.example/ClipLink-Setup-2.0.2.exe")]
    [InlineData("file:///C:/Windows/System32/cmd.exe")]
    [InlineData(@"\\attacker\share\ClipLink-Setup-2.0.2.exe")]
    [InlineData("ClipLink-Setup-2.0.2.exe")]
    [InlineData("")]
    public void ADownloadAddressThatIsNotGitHubsIsNotUsed(string url)
    {
        var release = Release("v2.0.2", Asset("ClipLink-Setup-2.0.2.exe", url: url, tag: "v2.0.2"));
        var offer = Find(List(release), "2.0.1");
        Assert.NotNull(offer);
        Assert.Null(offer.Asset.Url);
        Assert.False(offer.CanInstallInApp);
    }

    [Fact]
    public void TheReleasePageFallsBackToTheTagsPage()
    {
        var release = WithInstaller("v2.0.2");
        release["html_url"] = "https://evil.example/phish";
        Assert.Equal("https://github.com/Colour1205/ClipLink/releases/tag/v2.0.2", Find(List(release), "2.0.1")!.PageUrl.AbsoluteUri);

        release.Remove("html_url");
        Assert.Equal("https://github.com/Colour1205/ClipLink/releases/tag/v2.0.2", Find(List(release), "2.0.1")!.PageUrl.AbsoluteUri);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-5")]
    [InlineData("\"55907797\"")] // a string, not a number
    [InlineData("1.5")]
    [InlineData("null")]
    [InlineData("99999999999999999999")]
    [InlineData("1000000000")] // bigger than anything ClipLink downloads
    public void ASizeThatMakesNoSenseMeansNoInAppInstall(string size)
    {
        string json = List(WithInstaller("v2.0.2")).Replace("55907797", size);
        var offer = Find(json, "2.0.1");
        Assert.NotNull(offer);
        Assert.False(offer.CanInstallInApp);
    }

    [Fact]
    public void FlagsThatAreNotPlainFalseAreNotTrusted()
    {
        // (A release that doesn't say it isn't a draft or a pre-release is skipped.)
        var noFlags = WithInstaller("v2.0.2");
        noFlags.Remove("draft");
        noFlags.Remove("prerelease");
        var stringFlags = WithInstaller("v2.0.3");
        stringFlags["draft"] = "false";
        stringFlags["prerelease"] = "false";
        var nullFlags = WithInstaller("v2.0.4");
        nullFlags["draft"] = null;

        Assert.Null(Find(List(noFlags, stringFlags, nullFlags), "2.0.1"));
    }

    [Fact]
    public void AnEmptyListMeansNoUpdate()
    {
        Assert.Null(Find("[]", "2.0.1"));
    }

    [Fact]
    public void ReadsThePartsItCanAndIgnoresTheRest()
    {
        // Some of everything wrong in one list, then a good release.
        string json = """
            [ 1, "two", null, true, [], {}, {"tag_name": 5}, {"tag_name": "v9.9.9"},
              {"tag_name": "v9.9.9", "draft": false, "prerelease": false},
              {"tag_name": "v9.9.9", "draft": false, "prerelease": false, "assets": {}},
              {"tag_name": "v9.9.9", "draft": false, "prerelease": false, "assets": [1, null, "x", {"name": 5}, {"name": null}]},
              {"tag_name": "v2.0.2", "draft": false, "prerelease": false, "assets": [{"name": "ClipLink-Setup-2.0.2.exe", "size": 10,
                 "browser_download_url": "https://github.com/x/y/releases/download/v2.0.2/ClipLink-Setup-2.0.2.exe", "digest": 5}] } ]
            """;
        var offer = Find(json, "2.0.1");
        Assert.NotNull(offer);
        Assert.Equal("2.0.2", offer.Version.Text);
        Assert.Null(offer.Asset.Sha256);
    }
}

public class ReleaseJsonRobustnessTests
{
    private static readonly string[] NotAList =
    {
        "",
        " ",
        "not json at all",
        "<html><body>Rate limited</body></html>",
        "{",
        "[",
        "[1,",
        "[{\"tag_name\":",
        "null",
        "true",
        "42",
        "\"a string\"",
        "{}",
        "{\"message\":\"API rate limit exceeded\",\"documentation_url\":\"https://docs.github.com\"}",
        "[1,2,]",
        "[/* comment */]",
        "\uFEFF[",
        "[\"\\uD800\"]x",
    };

    [Theory]
    [MemberData(nameof(NotAListData))]
    public void ANonListEndsInABadResponse(string json)
    {
        var ex = Assert.Throws<UpdateException>(() => TestReleases.Find(json, "2.0.1"));
        Assert.Equal(UpdateFailure.BadResponse, ex.Kind);
    }

    public static IEnumerable<object[]> NotAListData() => NotAList.Select(json => new object[] { json });

    [Fact]
    public void DeepNestingIsRefusedNotCrashedOn()
    {
        string deep = new string('[', 5000) + new string(']', 5000);
        var ex = Assert.Throws<UpdateException>(() => TestReleases.Find(deep, "2.0.1"));
        Assert.Equal(UpdateFailure.BadResponse, ex.Kind);

        string deepInRelease = "[{\"tag_name\":\"v9.0.0\",\"x\":" + new string('[', 5000) + new string(']', 5000) + "}]";
        ex = Assert.Throws<UpdateException>(() => TestReleases.Find(deepInRelease, "2.0.1"));
        Assert.Equal(UpdateFailure.BadResponse, ex.Kind);
    }

    [Fact]
    public void AHugeListIsOnlyReadSoFar()
    {
        // 50,000 releases (the first 100 are read), the good one last: not found, quickly.
        var releases = new List<object>();
        for (int i = 0; i < 50_000; i++) releases.Add(new Dictionary<string, object?> { ["tag_name"] = "junk" + i });
        releases.Add(TestReleases.WithInstaller("v9.0.0"));
        var started = DateTime.UtcNow;
        Assert.Null(TestReleases.Find(TestReleases.List(releases.ToArray()), "2.0.1"));
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(5));
    }

    [Fact]
    public void AHugeListOfAssetsIsOnlyReadSoFar()
    {
        var assets = new List<object>();
        for (int i = 0; i < 5_000; i++) assets.Add(TestReleases.Asset("other" + i + ".bin"));
        assets.Add(TestReleases.Asset("ClipLink-Setup-2.0.2.exe", tag: "v2.0.2"));
        string json = TestReleases.List(TestReleases.Release("v2.0.2", assets.ToArray()));
        Assert.Null(TestReleases.Find(json, "2.0.1"));
    }

    [Fact]
    public void AVeryLongStringIsNotAProblem()
    {
        var release = TestReleases.WithInstaller("v2.0.2");
        release["body"] = new string('x', 2_000_000);
        release["html_url"] = "https://github.com/" + new string('a', 100_000);
        Assert.NotNull(TestReleases.Find(TestReleases.List(release), "2.0.1"));
    }

    [Fact]
    public void ValuesOfTheWrongTypeAreSkippedWithoutAnException()
    {
        object?[] values = { null, 1, 1.5, "s", true, false, new object[0], new Dictionary<string, object?>() };
        string[] fields = { "tag_name", "draft", "prerelease", "assets", "html_url" };
        foreach (string field in fields)
        {
            foreach (var value in values)
            {
                var release = TestReleases.WithInstaller("v2.0.2");
                release[field] = value;
                // Whatever it finds, it must not throw.
                TestReleases.Find(TestReleases.List(release), "2.0.1");
            }
        }
        foreach (string field in new[] { "name", "size", "browser_download_url", "digest", "state" })
        {
            foreach (var value in values)
            {
                var asset = TestReleases.Asset("ClipLink-Setup-2.0.2.exe", tag: "v2.0.2");
                asset[field] = value;
                TestReleases.Find(TestReleases.List(TestReleases.Release("v2.0.2", asset)), "2.0.1");
            }
        }
    }

    [Fact]
    public void ValidJsonThatIsNotUtf8TextStillEndsCleanly()
    {
        string json = JsonSerializer.Serialize(new[] { new { tag_name = "v2.0.2\uFFFD", draft = false, prerelease = false } });
        Assert.Null(TestReleases.Find(json, "2.0.1"));
    }
}
