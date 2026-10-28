namespace ClipboardDaemon.Engine;

// Whether this PC dials a device whose beacon it just heard (ClipLinkEngine.OnPeerDiscovered).
// Apart from the engine so the rule can be tested without one.
//
// Only a trusted device is ever dialled. A beacon says who is there and where, never "dial
// me": nothing in it - whatever an older build puts in its 5th field - gets a stranger
// dialled. A stranger that wants this PC dials it, and is answered with a pairing request.
// The same rule is in every platform's engine: change them together.
internal static class DialDecision
{
    // blocked: the device is on the block list (OnPeerDiscovered has already stopped at it).
    // connected: there is a live connection to it. trusted: after the passphrase auto-trust.
    //
    // connect only when the other device's public key is "smaller" than this device's public key (to avoid duplicate connections)
    // CompareOrdinal, not CompareTo: CompareTo is culture-sensitive
    // (it sorts 'a' before 'B'), while HarmonyOS and Android compare
    // keys by character code ('B' before 'a'). For keys that first
    // differ in letter case the two sides disagreed about who dials,
    // so after an off-LAN (Tailscale) pairing neither side would
    // reconnect - or both would.
    // (Or, for a trusted device that should have dialled this one and has not after
    // a while - one that does not trust this PC - dial it anyway: see DialFallback.)
    //
    // fallbackDue and claimDial have effects (the fallback counts a true as the dial, the claim
    // reserves the device), so they are asked only when everything before them says yes, and
    // claimDial last: false means a dial to this device is already running.
    public static bool ShouldDial(bool blocked, bool connected, bool trusted, string otherId, string ownId,
        Func<bool> fallbackDue, Func<bool> claimDial)
    {
        return !blocked && !connected && trusted
            && (string.CompareOrdinal(otherId, ownId) < 0 || fallbackDue())
            && claimDial();
    }
}
