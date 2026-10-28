using System.Text.Json;

namespace ClipLink.Updates;

// Picks the release to update to out of GitHub's list of releases (the JSON
// of GET /repos/.../releases). The list is data from the network: it is read
// defensively, and whatever doesn't look right is skipped, never trusted.
internal static class ReleaseSelector
{
    // The request asks for 15; a longer list isn't read past this.
    private const int MaxReleases = 100;
    private const int MaxAssets = 200;

    // The newest release that is higher than `current`, or null if there is
    // none. A release counts only if it is published (not a draft), not a
    // pre-release, has a plain version as its tag, and carries the Windows
    // installer under its exact name - releases for other platforms, with
    // no installer, are skipped, not taken as "nothing newer". Throws an
    // UpdateException (BadResponse) if the text isn't a list of releases.
    public static ReleaseOffer? FindUpdate(string json, ReleaseVersion current, UpdateUrlPolicy policy)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
        }
        catch (JsonException ex)
        {
            throw new UpdateException(UpdateFailure.BadResponse, "GitHub's answer wasn't a list of releases.", ex);
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Array)
                throw new UpdateException(UpdateFailure.BadResponse, "GitHub's answer wasn't a list of releases.");

            ReleaseOffer? newest = null;
            int seen = 0;
            foreach (var release in document.RootElement.EnumerateArray())
            {
                if (++seen > MaxReleases) break;
                ReleaseOffer? offer;
                try
                {
                    offer = ReadRelease(release, policy);
                }
                catch (InvalidOperationException)
                {
                    // A string that isn't text ("\uD800" on its own parses, but
                    // GetString throws on it): this release is skipped, like any
                    // that doesn't look right, and the others are still read.
                    continue;
                }
                if (offer != null && (newest == null || offer.Version > newest.Version))
                    newest = offer;
            }
            return newest != null && newest.Version > current ? newest : null;
        }
    }

    private static ReleaseOffer? ReadRelease(JsonElement release, UpdateUrlPolicy policy)
    {
        if (release.ValueKind != JsonValueKind.Object) return null;
        // Only a release that says, in so many words, that it is neither.
        if (!IsFalse(release, "draft") || !IsFalse(release, "prerelease")) return null;

        string? tag = GetString(release, "tag_name");
        if (!ReleaseVersion.TryParse(tag, out var version) || version.IsPreRelease) return null;

        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;
        string wanted = ReleaseOffer.AssetName(version);
        int seen = 0;
        foreach (var asset in assets.EnumerateArray())
        {
            if (++seen > MaxAssets) break;
            if (asset.ValueKind != JsonValueKind.Object || GetString(asset, "name") != wanted) continue;
            // (Still being uploaded: not a file yet.)
            if (GetString(asset, "state") is { } state && state != "uploaded") continue;
            return new ReleaseOffer(version, PageUrl(release, tag!, policy), ReadAsset(asset, policy));
        }
        return null;
    }

    private static UpdateAsset ReadAsset(JsonElement asset, UpdateUrlPolicy policy)
    {
        Uri? url = null;
        if (Uri.TryCreate(GetString(asset, "browser_download_url"), UriKind.Absolute, out var parsed) && policy.IsAllowed(parsed))
            url = parsed;
        long size = asset.TryGetProperty("size", out var sizeProperty) && sizeProperty.ValueKind == JsonValueKind.Number
            && sizeProperty.TryGetInt64(out long number) ? number : 0;
        return new UpdateAsset(url, size, UpdateVerification.ParseDigest(GetString(asset, "digest")));
    }

    // The release's own page if GitHub gave one we may open, else the page
    // for its tag - the tag only has the characters ReleaseVersion allows.
    private static Uri PageUrl(JsonElement release, string tag, UpdateUrlPolicy policy)
    {
        if (Uri.TryCreate(GetString(release, "html_url"), UriKind.Absolute, out var url) && policy.IsAllowed(url)) return url;
        return new Uri($"{UpdateEndpoint.ReleasesPageUrl}/tag/{Uri.EscapeDataString(tag.Trim())}");
    }

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool IsFalse(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.False;
}
