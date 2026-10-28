using ClipboardDaemon.Engine;
using ClipboardDaemon.Networking;
using Xunit;

namespace ClipLink.Tests;

// Who this PC dials when it hears a beacon: only a trusted device, never a
// stranger - see DialDecision and docs/protocol.md.
public class DialDecisionTests
{
    // This PC's id, with ids that sort before and after it.
    private const string Own = "MMM";
    private const string Smaller = "AAA";
    private const string Larger = "ZZZ";

    // A call to ShouldDial that counts how often the two delegates, which have
    // effects in the engine, were asked.
    private sealed class Dial
    {
        public bool FallbackDue;
        public bool ClaimWorks = true;
        public int FallbackAsked;
        public int Claimed;

        public bool Decide(string otherId, bool trusted, bool blocked = false, bool connected = false, string ownId = Own) =>
            DialDecision.ShouldDial(blocked, connected, trusted, otherId, ownId,
                () => { FallbackAsked++; return FallbackDue; },
                () => { Claimed++; return ClaimWorks; });
    }

    [Fact]
    public void A_trusted_device_with_the_smaller_id_is_dialled()
    {
        var dial = new Dial();

        Assert.True(dial.Decide(Smaller, trusted: true));
        Assert.Equal(1, dial.Claimed);
        Assert.Equal(0, dial.FallbackAsked); // not needed: its id sorts first
    }

    [Fact]
    public void A_trusted_device_with_the_larger_id_is_left_to_dial_this_pc()
    {
        var dial = new Dial();

        Assert.False(dial.Decide(Larger, trusted: true));
        Assert.Equal(1, dial.FallbackAsked);
        Assert.Equal(0, dial.Claimed);
    }

    [Fact]
    public void The_dial_fallback_dials_a_trusted_device_with_the_larger_id()
    {
        var dial = new Dial { FallbackDue = true };

        Assert.True(dial.Decide(Larger, trusted: true));
        Assert.Equal(1, dial.Claimed);
    }

    // The real DialFallback: a device that should have dialled this one is
    // given Wait to do so, then dialled once, then again after Every.
    [Fact]
    public void The_dial_fallback_comes_due_after_its_wait_and_then_every_so_often()
    {
        var fallback = new DialFallback();
        DateTime start = new(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        bool At(DateTime now) => DialDecision.ShouldDial(false, false, true, Larger, Own,
            () => fallback.Due(Larger, now), () => true);

        Assert.False(At(start));
        Assert.False(At(start + DialFallback.Wait - TimeSpan.FromSeconds(1)));
        Assert.True(At(start + DialFallback.Wait));
        Assert.False(At(start + DialFallback.Wait + DialFallback.Every - TimeSpan.FromSeconds(1)));
        Assert.True(At(start + DialFallback.Wait + DialFallback.Every));
    }

    // Ids are compared by character code (CompareOrdinal), as HarmonyOS and
    // Android do; a culture-sensitive compare sorts "a1" before "B1".
    [Fact]
    public void The_tie_break_compares_ids_by_character_code()
    {
        Assert.True(new Dial().Decide("B1", trusted: true, ownId: "a1"));
        Assert.False(new Dial().Decide("a1", trusted: true, ownId: "B1"));
    }

    [Fact]
    public void A_trusted_device_with_this_pcs_own_id_is_not_dialled()
    {
        Assert.False(new Dial().Decide(Own, trusted: true));
    }

    [Theory]
    [InlineData(Smaller, false)]
    [InlineData(Smaller, true)]
    [InlineData(Larger, false)]
    [InlineData(Larger, true)]
    public void A_stranger_is_never_dialled(string otherId, bool fallbackDue)
    {
        var dial = new Dial { FallbackDue = fallbackDue };

        Assert.False(dial.Decide(otherId, trusted: false));
        // Not even asked: the fallback would start counting the stranger's wait.
        Assert.Equal(0, dial.FallbackAsked);
        Assert.Equal(0, dial.Claimed);
    }

    // What a stranger's beacon says decides nothing: an old build's 5th field
    // is read as nothing, and the decision has no input to put it in. (A
    // beacon's passphrase proof is turned into trust before the decision, in
    // OnPeerDiscovered, so it arrives here as trusted; one that doesn't verify
    // leaves a stranger.)
    [Theory]
    [InlineData("1")]
    [InlineData("-")]
    [InlineData("0")]
    [InlineData("pairing")]
    public void A_strangers_beacon_never_gets_it_dialled(string fifthField)
    {
        Assert.True(Discovery.TryParseBeacon($"49000:{Smaller}:proof:100.64.0.9:{fifthField}:{Discovery.EncodeName("Old phone")}", out var beacon));
        var dial = new Dial { FallbackDue = true };

        Assert.False(dial.Decide(beacon.DeviceId, trusted: false));
        Assert.Equal(0, dial.FallbackAsked);
        Assert.Equal(0, dial.Claimed);
    }

    [Theory]
    [InlineData(Smaller, false)]
    [InlineData(Smaller, true)]
    [InlineData(Larger, false)]
    [InlineData(Larger, true)]
    public void A_blocked_device_is_never_dialled(string otherId, bool fallbackDue)
    {
        var dial = new Dial { FallbackDue = fallbackDue };

        // Trusted too: the block list wins over a trust record that is still there.
        Assert.False(dial.Decide(otherId, trusted: true, blocked: true));
        Assert.Equal(0, dial.FallbackAsked);
        Assert.Equal(0, dial.Claimed);
    }

    [Theory]
    [InlineData(Smaller, false)]
    [InlineData(Smaller, true)]
    [InlineData(Larger, false)]
    [InlineData(Larger, true)]
    public void A_connected_device_is_not_dialled_again(string otherId, bool fallbackDue)
    {
        var dial = new Dial { FallbackDue = fallbackDue };

        Assert.False(dial.Decide(otherId, trusted: true, connected: true));
        Assert.Equal(0, dial.FallbackAsked);
        Assert.Equal(0, dial.Claimed);
    }

    [Theory]
    [InlineData(Smaller, false)]
    [InlineData(Larger, true)]
    public void A_dial_already_in_flight_is_not_started_again(string otherId, bool fallbackDue)
    {
        var dial = new Dial { FallbackDue = fallbackDue, ClaimWorks = false };

        Assert.False(dial.Decide(otherId, trusted: true));
        Assert.Equal(1, dial.Claimed); // asked, and it said a dial is running
    }
}
