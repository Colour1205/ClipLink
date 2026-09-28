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
    // passphrase set later via the tray (the normal flow: daemon starts first,
    // then the user sets a passcode) must take effect without a restart.
    // Result lets a peer that knows the same passphrase auto-trust this device
    // without any manual QR/key exchange — see Crypto/PassphraseAuth.cs.
    // "-" means "no passphrase configured", since the beacon is plain-text UDP.
    //
    // ownAddress is this device's off-LAN (Tailscale) address, if any — carried
    // so passphrase auto-trust can cache it too, same as QR/manual pairing does,
    // so passphrase-paired devices still get found later when off-LAN.
    //
    // getPairingOpen (fresh on every beacon, same reasoning as getProof) is
    // the sender's own "my pairing dialog is open" signal - see PairingState.
    // A receiver only attempts a pairing handshake with an untrusted device
    // whose beacon carries this, instead of trying one with every stranger's
    // beacon on the LAN.
    //
    // getName (also fresh on every beacon, so a rename shows up on the next
    // one) is this device's display name - the 6th field, see EncodeName.
    // The pairing field is always sent, so the name is always at index 5.
    public async Task Start(string deviceID, int tcpPort, Func<string?>? getProof = null, string? ownAddress = null, Func<bool>? getPairingOpen = null, Func<string?>? getName = null)
    {
        UdpClient client = new UdpClient();
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
            while (true)
            {
                try
                {
                    string? proof = getProof?.Invoke();
                    string pairing = (getPairingOpen?.Invoke() ?? false) ? "1" : "-";
                    string name = EncodeName(getName?.Invoke());
                    await Send(client, $"{tcpPort}:{deviceID}:{proof ?? "-"}:{ownAddress ?? "-"}:{pairing}:{name}");
                    if (failing)
                    {
                        Console.WriteLine("[discovery] beacons sending again");
                        failing = false;
                    }
                }
                catch (Exception ex)
                {
                    // Logged once per outage, not every 2s while offline.
                    if (!failing)
                    {
                        Console.WriteLine($"[discovery] beacon send failed, retrying: {ex.Message}");
                        failing = true;
                    }
                }
                await Task.Delay(2000);
            }
        });

        Task receiveTask = Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    var result = await Receive(client);
                    string message = result.message;
                    IPAddress sender = result.sender;
                    string[] parts = message.Split(':');
                    if (parts.Length < 3) continue; // malformed/old-format beacon, ignore
                    if (!int.TryParse(parts[0], out int other_port)) continue; // not a beacon

                    string other_device_id = parts[1];
                    string? receivedProof = parts[2] == "-" ? null : parts[2];
                    string? receivedAddress = parts.Length > 3 && parts[3] != "-" ? parts[3] : null;
                    bool receivedPairing = parts.Length > 4 && parts[4] == "1";
                    string? receivedName = parts.Length > 5 ? DecodeName(parts[5]) : null;

                    PeerDiscovered?.Invoke(other_device_id, sender, other_port, receivedProof, receivedAddress, receivedPairing, receivedName);
                }
                catch (Exception ex)
                {
                    // e.g. a SocketException from an ICMP "port unreachable"
                    // bounced back at this UDP socket. Brief pause so a
                    // persistent error can't spin.
                    Console.WriteLine($"[discovery] receive failed, still listening: {ex.Message}");
                    await Task.Delay(200);
                }
            }
        });

        await Task.WhenAll(sendTask, receiveTask);
    }

    // (deviceId, sender, tcpPort, proof, address, pairingOpen, name) - name is
    // null when the beacon doesn't carry a usable one.
    public event Action<string, IPAddress, int, string?, string?, bool, string?>? PeerDiscovered;

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

    private async Task<(string message, IPAddress sender)> Receive(UdpClient client)
    {
        while (true)
        {
            var result = await client.ReceiveAsync();
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
