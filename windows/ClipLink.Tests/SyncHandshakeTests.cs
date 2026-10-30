using System.Text.Json;
using ClipboardDaemon.Networking;
using Xunit;

namespace ClipLink.Tests;

// The handshake's "Protocol" field: 2 on every build from sync version 2 on,
// absent from older ones, which also ignore it. A connection speaks 2 only when
// both sides sent 2.
public class SyncHandshakeTests
{
    // The handshake as the released builds define it (no Protocol): what an
    // older ClipLink does with the line a new one sends.
    private sealed record OldHandshake(string EphemeralPublicKey, string IdentityPublicKey, string Signature, string? PassphraseProof = null, string? DeviceName = null);

    private static HandshakeMessage Parse(string json) => JsonSerializer.Deserialize<HandshakeMessage>(json)!;

    [Fact]
    public void The_handshake_carries_the_protocol()
    {
        var message = new HandshakeMessage("eph", "id", "sig", null, "Desk PC", HandshakeMessage.CurrentProtocol);

        string json = JsonSerializer.Serialize(message);

        using var document = JsonDocument.Parse(json);
        Assert.Equal(2, document.RootElement.GetProperty("Protocol").GetInt32());
        Assert.Equal("{\"EphemeralPublicKey\":\"eph\",\"IdentityPublicKey\":\"id\",\"Signature\":\"sig\",\"PassphraseProof\":null,\"DeviceName\":\"Desk PC\",\"Protocol\":2}", json);
    }

    [Fact]
    public void The_protocol_is_read_from_a_peers_handshake()
    {
        var message = Parse("{\"EphemeralPublicKey\":\"e\",\"IdentityPublicKey\":\"i\",\"Signature\":\"s\",\"DeviceName\":\"Pixel\",\"Protocol\":2}");

        Assert.Equal(2, message.Protocol);
        Assert.Equal("Pixel", message.DeviceName);
        Assert.Equal(2, HandshakeMessage.Normalize(message.Protocol));
    }

    [Fact]
    public void An_older_handshake_without_the_field_still_parses_and_means_protocol_1()
    {
        // As Windows 2.0.0 and the Android alpha write it.
        var message = Parse("{\"EphemeralPublicKey\":\"e\",\"IdentityPublicKey\":\"i\",\"Signature\":\"s\",\"PassphraseProof\":null,\"DeviceName\":\"Old PC\"}");

        Assert.Null(message.Protocol);
        Assert.Equal("Old PC", message.DeviceName);
        Assert.Equal(1, HandshakeMessage.Normalize(message.Protocol));
        Assert.Equal(1, HandshakeMessage.Negotiate(message.Protocol));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("\"2\"")]
    [InlineData("2.5")]
    [InlineData("true")]
    [InlineData("{\"v\":2}")]
    [InlineData("[2]")]
    [InlineData("1")]
    [InlineData("0")]
    [InlineData("-3")]
    [InlineData("99999999999")]
    public void A_protocol_that_is_not_a_number_of_2_or_more_means_1_and_never_fails_the_handshake(string value)
    {
        var message = Parse("{\"EphemeralPublicKey\":\"e\",\"IdentityPublicKey\":\"i\",\"Signature\":\"s\",\"DeviceName\":\"X\",\"Protocol\":" + value + "}");

        Assert.Equal("X", message.DeviceName); // the rest of the line was read
        Assert.Equal(1, HandshakeMessage.Negotiate(message.Protocol));
    }

    [Theory]
    [InlineData(null, 1)]
    [InlineData(0, 1)]
    [InlineData(1, 1)]
    [InlineData(2, 2)]
    [InlineData(3, 2)]
    [InlineData(100, 2)]
    [InlineData(-1, 1)]
    public void A_connection_speaks_the_lower_of_the_two(int? peer, int expected)
    {
        Assert.Equal(expected, HandshakeMessage.Negotiate(peer));
        // (A peer's own number is kept as it said it, apart from "less than 2".)
        Assert.Equal(peer is >= 2 ? peer.Value : 1, HandshakeMessage.Normalize(peer));
    }

    [Fact]
    public void An_older_build_ignores_the_new_field()
    {
        string line = JsonSerializer.Serialize(new HandshakeMessage("eph", "id", "sig", "proof", "Desk PC", HandshakeMessage.CurrentProtocol));

        var old = JsonSerializer.Deserialize<OldHandshake>(line)!;

        Assert.Equal(new OldHandshake("eph", "id", "sig", "proof", "Desk PC"), old);
    }
}
