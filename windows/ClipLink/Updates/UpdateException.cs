namespace ClipLink.Updates;

internal enum UpdateFailure
{
    // No answer: offline, a timeout, a dropped connection. Worth trying again soon.
    Network,
    // GitHub answered, but with an error (including "too many requests").
    Server,
    // An answer that isn't a list of releases, or is absurdly big.
    BadResponse,
    // An address the updater isn't allowed to use (UpdateUrlPolicy).
    Untrusted,
    // The download isn't what GitHub lists for the release - or GitHub lists
    // nothing to compare it with.
    Verification,
    // The download couldn't be saved or read back.
    Disk,
    // Windows didn't let the installer start because the permission prompt
    // was declined.
    Declined,
    // The installer couldn't be started.
    Launch,
}

// Anything that goes wrong in an update that the updater understands. The
// message is short and plain: it is what Settings shows.
internal sealed class UpdateException : Exception
{
    public UpdateException(UpdateFailure kind, string message, Exception? inner = null) : base(message, inner)
    {
        Kind = kind;
    }

    public UpdateFailure Kind { get; }
}
