using System.Text.RegularExpressions;

namespace ClipLink.Updates;

internal enum VerifyResult
{
    Ok,
    // GitHub gave no SHA-256 to compare with.
    NoDigest,
    SizeMismatch,
    HashMismatch,
}

// Whether a downloaded file is the one GitHub lists for the release. This
// proves the file is what GitHub publishes for that release - not who
// published it (the installer isn't code-signed).
internal static class UpdateVerification
{
    private static readonly Regex Sha256Digest = new(@"\Asha256:([0-9a-fA-F]{64})\z", RegexOptions.CultureInvariant);

    // The asset's "digest" field ("sha256:<64 hex digits>") as lowercase hex;
    // null for anything else - another algorithm, the wrong length, junk.
    public static string? ParseDigest(string? digest)
    {
        if (digest == null) return null;
        var match = Sha256Digest.Match(digest);
        return match.Success ? match.Groups[1].Value.ToLowerInvariant() : null;
    }

    public static string ToHex(byte[] hash) => Convert.ToHexStringLower(hash);

    public static VerifyResult Check(long actualSize, string actualSha256Hex, UpdateAsset asset)
    {
        if (asset.Sha256 == null) return VerifyResult.NoDigest;
        if (actualSize != asset.Size) return VerifyResult.SizeMismatch;
        return string.Equals(actualSha256Hex, asset.Sha256, StringComparison.OrdinalIgnoreCase)
            ? VerifyResult.Ok
            : VerifyResult.HashMismatch;
    }
}
