// STEP 5:
// UDP broadcast discovery. Send a periodic "HELLO" beacon (device id + name)
// to the LAN, and listen for beacons from other devices.
//
// We'll test this by running two instances of the daemon on this same PC
// (different ports) and watching them find each other.

using System.Net;
using System.Net.Sockets;
using System.Text;
using ClipboardDaemon.Identity;

namespace ClipboardDaemon.Networking;

public class Discovery
{
    // TODO
    public int PORT = 49000;

    // getProof is called fresh on every beacon, not just once at startup — a
    // passphrase set later in the app's settings (the normal flow: the engine
    // starts first, then the user sets a passcode), or changed or cleared
    // later, must take effect without a restart.
    // Result lets a peer that knows the same passphrase auto-trust this device
    // without any manual QR/key exchange — see Crypto/PassphraseAuth.cs.
    // "-" means "no passphrase configured", since the beacon is plain-text UDP.
    //
    // ownAddress is this device's off-LAN (Tailscale) address, if any — carried
    // so passphrase auto-trust can cache it too, same as QR/manual pairing does,
    // so passphrase-paired devices still get found later when off-LAN.
    //
    // getName (also fresh on every beacon, so a rename shows up on the next
    // one) is this device's display name - the 6th field, see EncodeName.
    // The 5th field is always sent (see EncodeBeacon), so the name is always
    // at index 5.
    //
    // Runs until cancellationToken is cancelled (the engine stopping), then
    // closes the socket.
    public async Task Start(string deviceID, int tcpPort, Func<string?>? getProof = null, string? ownAddress = null, Func<string?>? getName = null, CancellationToken cancellationToken = default)
    {
        using UdpClient client = new UdpClient();
        client.EnableBroadcast = true;
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        client.Client.Bind(new System.Net.IPEndPoint(IPAddress.Any, PORT));

        // Both loops catch per iteration. Before, one exception ended a loop
        // for the rest of the daemon's life with nothing logged: a single
        // send failure (no network for a moment - Wi-Fi switching, VPN
        // reconnecting, waking from sleep) stopped this PC's beacons, and a
        // single stray datagram on this port with a non-numeric first field
        // stopped it hearing anyone else's. Either way, LAN discovery quietly
        // died while everything else looked fine.
        Task sendTask = Task.Run(async () =>
        {
            bool failing = false;
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await Send(client, EncodeBeacon(tcpPort, deviceID, getProof?.Invoke(), ownAddress, getName?.Invoke()));
                    if (failing)
                    {
                        Console.WriteLine("[discovery] beacons sending again");
                        failing = false;
                    }
                }
                catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
                {
                    // Logged once per outage, not every 2s while offline.
                    if (!failing)
                    {
                        Console.WriteLine($"[discovery] beacon send failed, retrying: {ex.Message}");
                        failing = true;
                    }
                }
                catch (Exception) { break; } // stopping
                try { await Task.Delay(2000, cancellationToken); }
                catch (OperationCanceledException) { break; }
            }
        });

        Task receiveTask = Task.Run(async () =>
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    var result = await Receive(client, cancellationToken);
                    IPAddress sender = result.sender;
                    if (!TryParseBeacon(result.message, out Beacon beacon)) continue; // malformed/old-format beacon, or not a beacon

                    PeerDiscovered?.Invoke(beacon.DeviceId, sender, beacon.TcpPort, beacon.Proof, beacon.Address, beacon.Name);
                }
                catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
                {
                    // e.g. a SocketException from an ICMP "port unreachable"
                    // bounced back at this UDP socket. Brief pause so a
                    // persistent error can't spin.
                    Console.WriteLine($"[discovery] receive failed, still listening: {ex.Message}");
                    await Task.Delay(200);
                }
                catch (Exception) { break; } // stopping
            }
        });

        await Task.WhenAll(sendTask, receiveTask);
    }

    // (deviceId, sender, tcpPort, proof, address, name) - name is null when
    // the beacon doesn't carry a usable one.
    public event Action<string, IPAddress, int, string?, string?, string?>? PeerDiscovered;

    // One beacon as TryParseBeacon reads it. Name is null when the beacon
    // doesn't carry a usable one.
    public readonly record struct Beacon(int TcpPort, string DeviceId, string? Proof, string? Address, string? Name);

    // tcpPort:deviceId:proof:address:-:name. The 5th field used to be "1"
    // while the sender's pairing screen was open; it stays in its place,
    // always "-", so builds that still read it and builds that no longer do
    // parse each other's beacons.
    public static string EncodeBeacon(int tcpPort, string deviceId, string? proof, string? address, string? name) =>
        $"{tcpPort}:{deviceId}:{proof ?? "-"}:{address ?? "-"}:-:{EncodeName(name)}";

    // False for a datagram that is not a beacon: fewer than three fields, or a
    // first one that is not a port. A beacon with five fields (no name) parses
    // too, and the 5th field's value is ignored, whatever it says: an older
    // build sends "1" there while its pairing screen is open.
    public static bool TryParseBeacon(string message, out Beacon beacon)
    {
        beacon = default;
        string[] parts = message.Split(':');
        if (parts.Length < 3) return false;
        if (!int.TryParse(parts[0], out int tcpPort)) return false;

        beacon = new Beacon(
            tcpPort,
            DeviceId: parts[1],
            Proof: parts[2] == "-" ? null : parts[2],
            Address: parts.Length > 3 && parts[3] != "-" ? parts[3] : null,
            Name: parts.Length > 5 ? DecodeName(parts[5]) : null);
        return true;
    }

    // Beacon field 6: standard Base64 (with padding) of the UTF-8 name, or
    // "-" when unknown. Base64's alphabet has no ':', so the colon split
    // stays safe.
    public static string EncodeName(string? name)
    {
        string? normalized = DeviceNameStore.Normalize(name);
        return normalized == null ? "-" : Convert.ToBase64String(Encoding.UTF8.GetBytes(normalized));
    }

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    // "-", empty, bad Base64 or bad UTF-8 all just mean "no name" - never a
    // reason to drop the beacon itself.
    public static string? DecodeName(string field)
    {
        if (field.Length == 0 || field == "-") return null;
        try
        {
            return DeviceNameStore.Normalize(StrictUtf8.GetString(Convert.FromBase64String(field)));
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException) // DecoderFallbackException is an ArgumentException
        {
            return null;
        }
    }

    private async Task Send(UdpClient client, string message)
    {
        byte[] data = strToByte(message);
        await client.SendAsync(data, data.Length, new IPEndPoint(IPAddress.Broadcast, PORT));
    }

    private async Task<(string message, IPAddress sender)> Receive(UdpClient client, CancellationToken cancellationToken)
    {
        while (true)
        {
            var result = await client.ReceiveAsync(cancellationToken);
            string message = byteToStr(result.Buffer);
            return (message, result.RemoteEndPoint.Address);
        }
    }

    private byte[] strToByte(string str)
    {
        return System.Text.Encoding.UTF8.GetBytes(str);
    }
    private string byteToStr(byte[] bytes)
    {
        return System.Text.Encoding.UTF8.GetString(bytes);
    }
}
