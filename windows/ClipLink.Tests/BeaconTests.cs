using ClipboardDaemon.Networking;
using Xunit;

namespace ClipLink.Tests;

// The LAN beacon's wire format - see docs/protocol.md. Its 5th field used to
// say "my pairing screen is open"; it is kept in place so old and new builds
// parse each other's beacons, always "-" when written and ignored when read.
public class BeaconTests
{
    [Fact]
    public void Encode_always_writes_a_dash_in_the_fifth_field()
    {
        string[] full = Discovery.EncodeBeacon(49000, "DEVICE", "proof", "100.64.0.1", "Desk PC").Split(':');
        string[] bare = Discovery.EncodeBeacon(49000, "DEVICE", null, null, null).Split(':');

        Assert.Equal(6, full.Length);
        Assert.Equal("-", full[4]);
        Assert.Equal(6, bare.Length);
        Assert.Equal("-", bare[4]);
    }

    [Fact]
    public void Encode_keeps_the_other_fields_where_they_were()
    {
        string[] parts = Discovery.EncodeBeacon(41700, "DEVICE", "proof", "100.64.0.1", "Desk PC").Split(':');

        Assert.Equal("41700", parts[0]);
        Assert.Equal("DEVICE", parts[1]);
        Assert.Equal("proof", parts[2]);
        Assert.Equal("100.64.0.1", parts[3]);
        Assert.Equal(Discovery.EncodeName("Desk PC"), parts[5]);
        Assert.Equal("Desk PC", Discovery.DecodeName(parts[5]));
    }

    [Fact]
    public void A_beacon_round_trips()
    {
        Assert.True(Discovery.TryParseBeacon(Discovery.EncodeBeacon(49000, "DEVICE", "proof", "100.64.0.1", "Desk PC"), out var beacon));

        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", "proof", "100.64.0.1", "Desk PC"), beacon);
    }

    [Fact]
    public void A_beacon_with_nothing_optional_round_trips()
    {
        Assert.True(Discovery.TryParseBeacon(Discovery.EncodeBeacon(49000, "DEVICE", null, null, null), out var beacon));

        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", null, null, null), beacon);
    }

    // An older build sends "1" while its pairing screen is open.
    [Fact]
    public void An_old_builds_pairing_flag_is_ignored()
    {
        string name = Discovery.EncodeName("Old phone");

        Assert.True(Discovery.TryParseBeacon($"49000:DEVICE:proof:100.64.0.2:1:{name}", out var open));
        Assert.True(Discovery.TryParseBeacon($"49000:DEVICE:proof:100.64.0.2:-:{name}", out var closed));

        Assert.Equal(closed, open);
        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", "proof", "100.64.0.2", "Old phone"), open);
    }

    [Fact]
    public void Anything_in_the_fifth_field_is_ignored()
    {
        Assert.True(Discovery.TryParseBeacon("49000:DEVICE:-:-:garbage:-", out var beacon));

        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", null, null, null), beacon);
    }

    [Fact]
    public void A_five_field_beacon_has_no_name()
    {
        Assert.True(Discovery.TryParseBeacon("49000:DEVICE:proof:100.64.0.3:1", out var withFlag));
        Assert.True(Discovery.TryParseBeacon("49000:DEVICE:proof:100.64.0.3:-", out var withoutFlag));

        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", "proof", "100.64.0.3", null), withFlag);
        Assert.Equal(withFlag, withoutFlag);
    }

    [Fact]
    public void A_three_field_beacon_has_no_address_and_no_name()
    {
        Assert.True(Discovery.TryParseBeacon("49000:DEVICE:proof", out var beacon));

        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", "proof", null, null), beacon);
    }

    [Fact]
    public void An_unusable_name_does_not_drop_the_beacon()
    {
        Assert.True(Discovery.TryParseBeacon("49000:DEVICE:-:-:-:not base64!", out var beacon));

        Assert.Equal(new Discovery.Beacon(49000, "DEVICE", null, null, null), beacon);
    }

    [Theory]
    [InlineData("")]
    [InlineData("49000")]
    [InlineData("49000:DEVICE")]
    [InlineData("HELLO:DEVICE:-:-:-:-")]
    public void Something_that_is_not_a_beacon_is_refused(string message)
    {
        Assert.False(Discovery.TryParseBeacon(message, out _));
    }
}
