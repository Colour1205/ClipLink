using System.IO.Pipes;
using System.Text.Json;

namespace ClipboardTray;

// Matches ClipboardDaemon.Networking.IpcRequest/IpcResponse's JSON shape —
// duplicated here rather than shared, since these are two small separate
// projects and the shape is tiny enough that a shared library isn't worth it yet.
public record IpcRequest(string Command, string? Payload = null);
public record IpcResponse(bool Success, string? Data = null);
public record PairingInfo(string PublicKey, string? Address = null, string? Name = null);
public record TrustedDevice(string PublicKey, string? Address = null, string? Name = null);
// "list_devices" rows (already in display order) and "get_pending_pairing_info".
public record DeviceListing(string PublicKey, string? Name, bool Trusted, bool Connected, bool PairingOpen, List<string> Addresses);
public record PendingPairingInfo(string PublicKey, string? Name, string? Address);

public class IpcClient
{
    private readonly string pipeName;

    public IpcClient(string label)
    {
        pipeName = $"ClipboardDaemonIPC_{label}";
    }

    public async Task<IpcResponse?> Send(IpcRequest request, int timeoutMs = 3000)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(timeoutMs);

            using var reader = new StreamReader(pipe);
            using var writer = new StreamWriter(pipe) { AutoFlush = true };

            await writer.WriteLineAsync(JsonSerializer.Serialize(request));
            string? line = await reader.ReadLineAsync();
            if (line == null) return null;

            return JsonSerializer.Deserialize<IpcResponse>(line);
        }
        catch (Exception)
        {
            // daemon not running / not reachable — every caller already treats
            // a null response as "couldn't reach it", same as any other failure
            return null;
        }
    }
}
