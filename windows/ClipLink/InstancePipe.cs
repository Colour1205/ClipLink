using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace ClipLink;

// How a second launch reaches the running ClipLink. Only one runs per user
// session and label (Program's mutex); a later ClipLink.exe - started again
// from the Start menu, by the sign-in entry after a manual start, or by File
// Explorer's "Share to ClipLink" - sends one message here and exits.
// Commands: "activate" (show the window), "share" (Paths: files to send) and
// "unregister" (ClipLink.exe --unregister: take "Share to ClipLink" out of
// File Explorer and turn its setting off) and "quit" (ClipLink.exe --quit). This pipe is the app's only one:
// the engine has no control pipe, and this one can't reach it.
// CurrentUserOnly, so other users' processes can't connect; the name carries
// the session id because pipe names are machine-wide while the mutex is per
// session.
// Explorer's menu starts one ClipLink per selected file, up to 100 at once -
// and on a cold start, while the first of them is still starting up to be
// the running copy. So there are several listeners (pipe instances), and a
// sender keeps trying, backing off, until its timeout.
internal static class InstancePipe
{
    public sealed record Message(string Command, IReadOnlyList<string>? Paths = null);

    public const string Activate = "activate";
    public const string Share = "share";
    public const string Unregister = "unregister";
    public const string Quit = "quit";

    // One JSON line; anything longer isn't one of ours. (Send To's command
    // line tops out around 32,000 characters.)
    private const int MaxMessageChars = 256 * 1024;

    // Pipe instances listening at once. Each takes one message and is
    // replaced, so a few are plenty - a sender finding them all busy waits
    // its turn.
    private const int Listeners = 4;

    private static string NameFor(string label) =>
        $"ClipLink_{Process.GetCurrentProcess().SessionId}_{label}";

    // From the second launch. False if the running copy didn't take it
    // within timeout (it's hung, quitting right now, or never got going).
    public static bool Send(string label, Message message, TimeSpan timeout)
    {
        string line = JsonSerializer.Serialize(message);
        var clock = Stopwatch.StartNew();
        int delayMs = 20;
        while (true)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", NameFor(label), PipeDirection.Out, PipeOptions.CurrentUserOnly);
                // One try: returns at once if there's no pipe (yet), or after
                // a moment if every instance is busy - the waiting is below.
                pipe.Connect(0);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
                writer.WriteLine(line);
                return true;
            }
            catch (Exception ex) when (ex is IOException or TimeoutException or UnauthorizedAccessException)
            {
                // IOException: the instance went away as we connected, or
                // before it read the line (then it never saw it) - try again.
                if (clock.Elapsed + TimeSpan.FromMilliseconds(delayMs) > timeout)
                {
                    Console.WriteLine($"[instance] couldn't reach the running ClipLink: {ex.Message}");
                    return false;
                }
            }
            // Jittered, so a hundred senders don't all come back at once.
            Thread.Sleep(delayMs + Random.Shared.Next(delayMs));
            delayMs = Math.Min(delayMs * 2, 400);
        }
    }

    // In the running copy, until token is cancelled. onMessage runs on a
    // background thread (several at once, one per listener).
    public static Task ListenAsync(string label, Action<Message> onMessage, CancellationToken token) =>
        // Each creates its pipe instance before returning, so senders can
        // connect as soon as this returns.
        Task.WhenAll(Enumerable.Range(0, Listeners).Select(_ => ListenLoopAsync(label, onMessage, token)));

    private static async Task ListenLoopAsync(string label, Action<Message> onMessage, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(NameFor(label), PipeDirection.In,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                // Off the caller's (UI) thread from here on.
                await pipe.WaitForConnectionAsync(token).ConfigureAwait(false);
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                string? line = await ReadLineAsync(reader, token).ConfigureAwait(false);
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
                Console.WriteLine($"[instance] another launch asked to {command}{(message.Paths is { } paths ? $" ({paths.Count} path(s))" : "")}");
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
                try { await Task.Delay(500, token).ConfigureAwait(false); } catch (OperationCanceledException) { return; }
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
            int read = await reader.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
            if (read == 0) break;
            line.Append(buffer, 0, read);
            int newline = line.ToString().IndexOf('\n');
            if (newline >= 0) return line.ToString(0, newline).TrimEnd('\r');
        }
        return line.Length is > 0 and <= MaxMessageChars ? line.ToString() : null;
    }
}
