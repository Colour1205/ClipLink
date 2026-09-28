namespace ClipboardDaemon.Networking;

// Coordinates the app-driven "pairing mode" gate and the single pending
// pairing candidate connection, shared between the threads that create
// connections (TCP accept loop, discovery beacon handler, pair-by-address)
// and whichever thread the app uses to toggle pairing mode and
// accept/reject a candidate. Mirrors HarmonyOS's Index.ets
// pairingOpen/pendingPairingConn.
public class PairingState
{
    private readonly object gate = new();
    private PeerConnection? pendingConn;
    private string? pendingAddress;

    // Written by ClipLinkEngine.SetPairingMode, read by every
    // connection-creation path (TCP accept, beacon dial, pair-by-address)
    // and by the beacon sender itself - volatile since those are different
    // threads and this needs to be visible immediately, not eventually.
    public volatile bool ModeOpen = false;

    // Returns true if conn was accepted as the pending candidate (caller
    // must NOT register it as a live connection - wait for accept/reject);
    // false means a different candidate was already pending, so this one
    // should just be closed instead of juggling two at once.
    public bool TrySetPending(PeerConnection conn, string? address)
    {
        lock (gate)
        {
            if (pendingConn != null) return false;
            pendingConn = conn;
            pendingAddress = address;
            return true;
        }
    }

    // The pending candidate's id, or null.
    public string? PendingPeerId
    {
        get { lock (gate) { return pendingConn?.PeerDeviceId; } }
    }

    // For GetPendingPairing: the same peer id, plus the display
    // name its handshake carried (null if none) and the address it came from.
    public (string peerId, string? name, string? address)? PendingPeer
    {
        get
        {
            lock (gate)
            {
                if (pendingConn == null) return null;
                return (pendingConn.PeerDeviceId, pendingConn.PeerDeviceName, pendingAddress);
            }
        }
    }

    // Atomically hands over the pending connection (for accept) and clears
    // the slot - null if nothing was pending.
    public (PeerConnection conn, string? address)? TakePending()
    {
        lock (gate)
        {
            if (pendingConn == null) return null;
            var result = (pendingConn, pendingAddress);
            pendingConn = null;
            pendingAddress = null;
            return result;
        }
    }

    public void RejectPending()
    {
        var taken = TakePending();
        taken?.conn.Close();
    }
}
