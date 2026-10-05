// The process the interop tests launch: `dotnet ClipboardDaemonHarness.dll
// <label> <tcpPort> [trustedKey]`. It runs the REAL Windows engine
// (windows/ClipLink/Engine's ClipLinkEngine - in the app it runs in-process, with no
// control pipe) and, for the tests, serves the old tray's named-pipe
// commands ("ClipboardDaemonIPC_<label>", one JSON request per connection,
// {"Success","Data"} back) by mapping each onto the engine's typed methods,
// the same way the old daemon answered them. Discovery's UDP port comes
// from CLIPLINK_UDP_PORT; the clipboard is FakeClipboardSync (stdin/stdout).
using System.IO.Pipes;
using System.Text.Json;
using ClipboardDaemon.Engine;

namespace ClipboardDaemon.Harness;

public record IpcRequest(string Command, string? Payload = null);
public record IpcResponse(bool Success, string? Data = null);

public static class HarnessHost
{
    public static async Task<int> Main(string[] args)
    {
        string label = args.Length > 0 ? args[0] : ClipLinkEngine.DefaultLabel;
        int port = args.Length > 1 ? int.Parse(args[1]) : ClipLinkEngine.DefaultPort;
        var options = new EngineOptions { DiscoveryPort = int.Parse(Environment.GetEnvironmentVariable("CLIPLINK_UDP_PORT") ?? "49000") };

        var engine = new ClipLinkEngine();
        engine.StatusChanged += status => Console.WriteLine($"[harness] engine {status.State}{(status.Error != null ? ": " + status.Error : "")}");
        if (!engine.Start(label, port, options))
        {
            return 1;
        }
        if (args.Length > 2)
        {
            engine.TrustPairingPayload(args[2]);
        }

        string pipeName = $"ClipboardDaemonIPC_{label}";
        while (true)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await pipe.WaitForConnectionAsync();
                using var reader = new StreamReader(pipe);
                using var writer = new StreamWriter(pipe) { AutoFlush = true };
                string? line = await reader.ReadLineAsync();
                var request = line == null ? null : JsonSerializer.Deserialize<IpcRequest>(line);
                if (request == null) continue;
                var response = await Handle(engine, request);
                await writer.WriteLineAsync(JsonSerializer.Serialize(response));
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[ipc] pipe error, still serving: {ex.Message}");
                await Task.Delay(100);
            }
        }
    }

    private static async Task<IpcResponse> Handle(ClipLinkEngine engine, IpcRequest request)
    {
        string? payload = request.Payload;
        switch (request.Command)
        {
            case "get_public_key":
                return new IpcResponse(true, engine.DeviceId);
            case "get_pairing_info":
                return new IpcResponse(true, await engine.GetPairingPayloadAsync());
            case "get_device_name":
                return new IpcResponse(true, engine.DeviceName);
            case "set_device_name":
                return new IpcResponse(true, engine.SetDeviceName(payload));
            case "has_passphrase":
                return new IpcResponse(true, engine.HasPasscode.ToString());
            case "set_passphrase":
                try
                {
                    return await engine.SetPasscodeAsync(payload ?? "")
                        ? new IpcResponse(true, "passphrase set")
                        : new IpcResponse(false, "passphrase is empty");
                }
                catch (Exception ex)
                {
                    return new IpcResponse(false, $"could not save passphrase: {ex.Message}");
                }
            case "clear_passphrase":
                try
                {
                    engine.ClearPasscode();
                    return new IpcResponse(true, "passphrase cleared");
                }
                catch (Exception ex)
                {
                    return new IpcResponse(false, $"could not clear passphrase: {ex.Message}");
                }
            case "trust_device" when payload != null:
                engine.TrustPairingPayload(payload);
                return new IpcResponse(true, "trusted");
            case "list_connections":
                return new IpcResponse(true, JsonSerializer.Serialize(engine.GetConnections()));
            case "list_trusted":
                return new IpcResponse(true, JsonSerializer.Serialize(engine.GetTrustedDevices()));
            case "list_devices":
                return new IpcResponse(true, JsonSerializer.Serialize(engine.GetDevices()));
            case "untrust_device" when payload != null:
                engine.UntrustDevice(payload);
                return new IpcResponse(true, "untrusted");
            case "set_pairing_mode" when payload != null:
                engine.SetPairingMode(payload == "1");
                return new IpcResponse(true, engine.PairingMode.ToString());
            case "get_pending_pairing":
                return new IpcResponse(true, engine.GetPendingPairing()?.DeviceId ?? "");
            case "get_pending_pairing_info":
                var pending = engine.GetPendingPairing();
                return new IpcResponse(true, pending == null ? "" : JsonSerializer.Serialize(new { PublicKey = pending.DeviceId, pending.Name, pending.Address }));
            case "accept_pairing":
                return engine.AcceptPairing() ? new IpcResponse(true, "paired") : new IpcResponse(false, "nothing pending");
            case "reject_pairing":
                engine.RejectPairing();
                return new IpcResponse(true, "rejected");
            case "pair_by_address" when payload != null:
                // Fire-and-forget, as before: callers poll get_pending_pairing.
                _ = engine.PairByAddressAsync(payload);
                return new IpcResponse(true, "connecting");
            case "get_history":
                return new IpcResponse(true, JsonSerializer.Serialize(engine.GetHistory()));
            case "delete_history_entry" when !string.IsNullOrEmpty(payload):
                bool deleted = engine.DeleteHistoryEntry(payload);
                return new IpcResponse(deleted, deleted ? "deleted" : "not in history");
            case "clear_history":
                engine.ClearHistory();
                return new IpcResponse(true, "cleared");
            default:
                return new IpcResponse(false, "unknown command");
        }
    }
}
