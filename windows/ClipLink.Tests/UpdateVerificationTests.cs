using ClipLink.Updates;
using Xunit;

namespace ClipLink.Tests;

public class UpdateVerificationTests
{
    private const string Hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    private static UpdateAsset Asset(string? sha256 = Hex, long size = 1000) =>
        new(new Uri("https://github.com/x/y/releases/download/v1/ClipLink-Setup-1.exe"), size, sha256);

    [Fact]
    public void ParsesTheDigest()
    {
        Assert.Equal(Hex, UpdateVerification.ParseDigest("sha256:" + Hex));
        Assert.Equal(Hex, UpdateVerification.ParseDigest("sha256:" + Hex.ToUpperInvariant()));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("sha256:")]
    [InlineData("sha256:abc")]
    [InlineData("md5:d41d8cd98f00b204e9800998ecf8427e")]
    [InlineData("sha1:da39a3ee5e6b4b0d3255bfef95601890afd80709")]
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdez")]
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")]
    [InlineData("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")]
    [InlineData("xsha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")]
    public void RefusesAnythingElse(string? digest)
    {
        Assert.Null(UpdateVerification.ParseDigest(digest));
    }

    [Fact]
    public void AMatchingFileIsOk()
    {
        Assert.Equal(VerifyResult.Ok, UpdateVerification.Check(1000, Hex, Asset()));
        Assert.Equal(VerifyResult.Ok, UpdateVerification.Check(1000, Hex.ToUpperInvariant(), Asset()));
    }

    [Fact]
    public void AWrongHashIsRefused()
    {
        string other = "f" + Hex[1..];
        Assert.Equal(VerifyResult.HashMismatch, UpdateVerification.Check(1000, other, Asset()));
        Assert.Equal(VerifyResult.HashMismatch, UpdateVerification.Check(1000, "", Asset()));
    }

    [Fact]
    public void AWrongSizeIsRefused()
    {
        Assert.Equal(VerifyResult.SizeMismatch, UpdateVerification.Check(999, Hex, Asset()));
        Assert.Equal(VerifyResult.SizeMismatch, UpdateVerification.Check(1001, Hex, Asset()));
        Assert.Equal(VerifyResult.SizeMismatch, UpdateVerification.Check(0, Hex, Asset()));
    }

    [Fact]
    public void WithoutADigestNothingIsOk()
    {
        Assert.Equal(VerifyResult.NoDigest, UpdateVerification.Check(1000, Hex, Asset(sha256: null)));
        Assert.Equal(VerifyResult.NoDigest, UpdateVerification.Check(1000, "", Asset(sha256: null)));
    }

    [Fact]
    public void HexIsLowercase()
    {
        Assert.Equal("00ff10", UpdateVerification.ToHex(new byte[] { 0x00, 0xFF, 0x10 }));
    }
}
