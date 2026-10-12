namespace ClipboardDaemon.Engine;

// Trusting a device is one-sided: it only decides whether THIS device accepts it. To keep two
// devices that hear each other from opening two connections, only one of them dials - the one
// whose key sorts after the other's. When both trust each other that is fine. But when only one
// does - the user just tapped Trust here, and the other device has not been asked yet - and
// the other's key is the larger, nobody dials: the other never trusts this device, so it does not
// dial, and this one waits for it to. The pairing request never reaches the other device.
//
// So a trusted device that should have dialled this one, but has not connected after a few
// seconds, is dialled by this one after all (and again every half minute while it stays
// unconnected). If it does trust this device it has long since connected and this never fires; if
// it does not, the dial is what raises the pairing request there. The same rule is in every
// platform's engine: change them together.
internal sealed class DialFallback
{
    // How long a trusted device that should dial this one is given to do so.
    public static readonly TimeSpan Wait = TimeSpan.FromSeconds(8);
    // How often it is dialled after that while it stays unconnected.
    public static readonly TimeSpan Every = TimeSpan.FromSeconds(30);

    private readonly object gate = new();
    private readonly Dictionary<string, DateTime> since = new();
    private readonly Dictionary<string, DateTime> lastDial = new();

    // True when a trusted device that should have dialled this one has waited long
    // enough, and was not dialled in the last Every. Counts the call as the dial.
    public bool Due(string deviceId, DateTime? now = null)
    {
        DateTime t = now ?? DateTime.UtcNow;
        lock (gate)
        {
            if (!since.TryGetValue(deviceId, out var first)) since[deviceId] = first = t;
            if (t - first < Wait) return false;
            if (lastDial.TryGetValue(deviceId, out var last) && t - last < Every) return false;
            lastDial[deviceId] = t;
            return true;
        }
    }

    // It is connected (or gone): start counting again next time.
    public void Connected(string deviceId)
    {
        lock (gate)
        {
            since.Remove(deviceId);
            lastDial.Remove(deviceId);
        }
    }
}
