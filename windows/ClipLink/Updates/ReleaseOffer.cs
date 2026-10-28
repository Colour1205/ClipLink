namespace ClipLink.Updates;

// The Windows installer attached to a release, as GitHub describes it. Url is
// null if the release's address for it isn't one the updater may use
// (UpdateUrlPolicy); Sha256 (lowercase hex) is null if GitHub gave no usable
// digest. Its name isn't kept: the file is only ever called what
// ReleaseOffer.InstallerFileName says.
internal sealed record UpdateAsset(Uri? Url, long Size, string? Sha256);

// A release newer than the running version, with the installer to get it.
internal sealed record ReleaseOffer(ReleaseVersion Version, Uri PageUrl, UpdateAsset Asset)
{
    // Nothing bigger is downloaded (the installer is about 55 MB).
    public const long MaxInstallerBytes = 512L * 1024 * 1024;

    // What publish.ps1 names the installer, and so what a release has to
    // call it for the updater to see it.
    public static string AssetName(ReleaseVersion version) => $"ClipLink-Setup-{version.Text}.exe";

    // The installer's name on this PC. Built from the version we parsed (only
    // digits and dots), never from the release's own text, so it can't point
    // anywhere but the update folder.
    public string InstallerFileName => AssetName(Version);

    // Downloaded and run by ClipLink itself: only with an address it may use,
    // a size to expect and a SHA-256 to check against. Without them the
    // release page is all that is offered.
    public bool CanInstallInApp =>
        Asset.Url != null && Asset.Size is > 0 and <= MaxInstallerBytes && Asset.Sha256 != null;
}
