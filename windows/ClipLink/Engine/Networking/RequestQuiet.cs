namespace ClipboardDaemon.Engine;

// Devices whose pairing requests are held back for a while.
//
// A device this one does not trust still gets here whenever the other end
// trusts this one and dials it: the other end redials for as long as it keeps
// its trust record, and each connection used to raise a new pairing request. So a
// request that was ignored (or never answered), or a device that was removed, came
// back again and again - the same device, a prompt every few minutes, for ever.
//
// The cure is in two parts. Removing a device (or tapping Ignore on its request)
// sends it an "unpair" message, so the other end drops its trust record and
// stops redialling (HandleUnpair). And this: a device whose request was ignored
// or expired, or that was removed, is quiet for a while - its connection is
// closed without a prompt - which covers a peer that was offline when the message
// went, or is an older build that ignores it. A device that was removed is told
// again whenever it connects while it is quiet. Blocking is the permanent
// version (BlockStore).
//
// Lifted early by what asks for it: opening the pairing screen, pairing by
// address or QR code, trusting the device. In memory only: a restart starts
// fresh. The same rule is in every platform's engine (ClipLinkEngine.kt,
// Index.ets, SyncEngine.swift): change them together.
internal sealed class RequestQuiet
{
    // After an ignored request, or one nobody answered.
    public static readonly TimeSpan AfterIgnored = TimeSpan.FromMinutes(30);
    // After the user removed the device: it is not coming back on its own.
    public static readonly TimeSpan AfterRemoved = TimeSpan.FromHours(6);

    private readonly object gate = new();
    private readonly Dictionary<string, (DateTime End, bool Removed)> until = new();

    public void Quiet(string deviceId, TimeSpan span, bool removed = false, DateTime? now = null)
    {
        if (string.IsNullOrEmpty(deviceId)) return;
        lock (gate) until[deviceId] = ((now ?? DateTime.UtcNow) + span, removed);
    }

    // Whether the device is quiet; removed says it was removed (as against ignored).
    public bool IsQuiet(string deviceId, out bool removed, DateTime? now = null)
    {
        lock (gate)
        {
            removed = false;
            if (!until.TryGetValue(deviceId, out var entry)) return false;
            if (entry.End <= (now ?? DateTime.UtcNow))
            {
                until.Remove(deviceId); // over
                return false;
            }
            removed = entry.Removed;
            return true;
        }
    }

    public void Release(string deviceId)
    {
        lock (gate) until.Remove(deviceId);
    }

    public void Clear()
    {
        lock (gate) until.Clear();
    }
}
