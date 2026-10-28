using ClipLink.Updates;

namespace ClipLink;

internal enum UpdatePhase
{
    // Nothing happening and nothing known (yet).
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Verifying,
    Installing,
    Error,
}

// What the updater is up to, for Settings and the navigation item to show.
// Only UpdateService changes it, on the UI thread.
internal sealed class UpdateState : Observable
{
    public UpdatePhase Phase { get; private set; }

    // The newer release, once one is found - kept through a failed download
    // or a later failed check, so the update isn't forgotten.
    public ReleaseOffer? Offer { get; private set; }

    // A short line to show: why it failed, or that the installer was declined.
    public string? Message { get; private set; }

    // The failure (Phase = Error) was in downloading or running the
    // installer, not in checking: Retry then means install again.
    public bool FailedToInstall { get; private set; }

    public long BytesDone { get; private set; }
    public long BytesTotal { get; private set; }

    public DateTime? LastCheckedUtc { get; private set; }

    // An update is waiting: what the navigation item's dot shows.
    public bool HasUpdate => Offer != null;

    public bool IsBusy => Phase is UpdatePhase.Checking or UpdatePhase.Downloading or UpdatePhase.Verifying or UpdatePhase.Installing;

    internal void Set(UpdatePhase phase, string? message = null, bool failedToInstall = false)
    {
        Phase = phase;
        Message = message;
        FailedToInstall = failedToInstall;
        Raise(nameof(Phase), nameof(Message), nameof(IsBusy));
    }

    internal void SetOffer(ReleaseOffer? offer)
    {
        Offer = offer;
        Raise(nameof(Offer), nameof(HasUpdate));
    }

    internal void SetProgress(long done, long total)
    {
        BytesDone = done;
        BytesTotal = total;
        Raise(nameof(BytesDone));
    }

    internal void SetLastChecked(DateTime? utc)
    {
        LastCheckedUtc = utc;
        Raise(nameof(LastCheckedUtc));
    }
}
