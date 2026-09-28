using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace ClipLink;

// How a second launch reaches the running ClipLink. Only one runs per user
// session and label (Program's mutex); a later ClipLink.exe - started again
// from the Start menu, by the sign-in entry after a manual start, or by
// Explorer's "Share" (batch 7) - sends one message here and exits.
// Commands: "activate" (show the window) and "share" (Paths: files to
// send). This pipe is the app's only one: the engine has no control pipe,
// and this one can't reach it. CurrentUserOnly, so other users' processes
// can't connect; the name carries the session id because pipe names are
// machine-wide while the mutex is per session.
internal static class InstancePipe
{
    public sealed record Message(string Command, IReadOnlyList<string>? Paths = null);

    public const string Activate = "activate";
    public const string Share = "share";

    // One JSON line; anything longer isn't one of ours.
    private const int MaxMessageChars = 256 * 1024;

    private static string NameFor(string label) =>
        $"ClipLink_{Process.GetCurrentProcess().SessionId}_{label}";

    // From the second launch. False if the running copy didn't take it
    // (it's hung, or quitting right now).
    public static bool Send(string label, Message message)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", NameFor(label), PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(3000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
            writer.WriteLine(JsonSerializer.Serialize(message));
            return true;
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or UnauthorizedAccessException)
        {
            Console.WriteLine($"[instance] couldn't reach the running ClipLink: {ex.Message}");
            return false;
        }
    }

    // In the running copy, until token is cancelled. onMessage runs on a
    // background thread.
    public static async Task ListenAsync(string label, Action<Message> onMessage, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(NameFor(label), PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(token);
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                string? line = await ReadLineAsync(reader, token);
                Message? message = null;
                try
                {
                    message = line == null ? null : JsonSerializer.Deserialize<Message>(line);
                }
                catch (JsonException) { }
                if (message?.Command is not { } command)
                {
                    Console.WriteLine("[instance] ignored a message that isn't one of ours");
                    continue;
                }
                Console.WriteLine($"[instance] another launch asked to {command}");
                onMessage(message);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                // e.g. a client that connected and vanished - keep listening.
                Console.WriteLine($"[instance] pipe error, still listening: {ex.GetType().Name}: {ex.Message}");
                try { await Task.Delay(500, token); } catch (OperationCanceledException) { return; }
            }
        }
    }

    private static async Task<string?> ReadLineAsync(StreamReader reader, CancellationToken token)
    {
        var line = new StringBuilder();
        var buffer = new char[4096];
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(5)); // a client that connects and says nothing
        while (line.Length <= MaxMessageChars)
        {
            int read = await reader.ReadAsync(buffer, timeout.Token);
            if (read == 0) break;
            line.Append(buffer, 0, read);
            int newline = line.ToString().IndexOf('\n');
            if (newline >= 0) return line.ToString(0, newline).TrimEnd('\r');
        }
        return line.Length is > 0 and <= MaxMessageChars ? line.ToString() : null;
    }
}
