using System.IO;
using System.Text.RegularExpressions;
using ClipboardDaemon.Engine;

namespace ClipLink;

// The command line. Normal use is none at all, or --background (how the
// sign-in entry starts it: tray icon only, no window).
//   --background            start hidden in the tray
//   --share <path>...       share these files (File Explorer's "Share to
//                           ClipLink" and Send To > ClipLink run this): the
//                           running ClipLink does it, or this one starts -
//                           in the tray - and does
//   --unregister            take "Share to ClipLink" out of File Explorer
//                           (and turn its setting off), then exit
//   --quit                  quit the running ClipLink, then exit (what the
//                           installer does before it updates or removes it)
// The rest run a second, separate ClipLink next to the real one, for
// testing: its own data (label), ports, and nothing that reaches the
// network or the clipboard - so no Windows Firewall prompt either.
//   --label <name>          data files suffixed <name> instead of "default":
//                           another identity, history, trust list, ...
//   --port <n>              TCP port to listen on (default 49000)
//   --discovery-port <n>    UDP port for LAN discovery (default 49000)
//   --loopback-only         listen on 127.0.0.1 only, no LAN discovery
//   --no-clipboard          never read or write the system clipboard
//   --theme light|dark      fixed theme instead of following Windows
public sealed record AppOptions
{
    public bool Background { get; init; }
    // Absolute (resolved against this process's working folder), so the
    // running copy can use them.
    public IReadOnlyList<string>? SharePaths { get; init; }
    public bool Unregister { get; init; }
    public bool Quit { get; init; }
    public string Label { get; init; } = ClipLinkEngine.DefaultLabel;
    public int Port { get; init; } = ClipLinkEngine.DefaultPort;
    public int DiscoveryPort { get; init; } = ClipLinkEngine.DefaultPort;
    public bool LoopbackOnly { get; init; }
    public bool NoClipboard { get; init; }
    public string? Theme { get; init; }

    public bool IsDefaultLabel => Label == ClipLinkEngine.DefaultLabel;

    public EngineOptions EngineOptions => new()
    {
        DiscoveryPort = DiscoveryPort,
        WatchClipboard = !NoClipboard,
        LoopbackOnly = LoopbackOnly,
    };

    // The label ends up in file names, a mutex name and a pipe name.
    private static readonly Regex SafeLabel = new("^[A-Za-z0-9_-]{1,32}$");

    // Null (with error saying why) if the command line doesn't make sense -
    // better than quietly falling back to the real "default" data.
    public static AppOptions? Parse(string[] args, out string? error)
    {
        var options = new AppOptions();
        error = null;
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            string name = arg.ToLowerInvariant();
            string? Value()
            {
                if (i + 1 < args.Length) return args[++i];
                return null;
            }
            switch (name)
            {
                case "--background":
                    options = options with { Background = true };
                    break;
                case "--share":
                    // Everything after it is a path.
                    options = options with { SharePaths = args[(i + 1)..].Select(FullPath).ToList() };
                    i = args.Length;
                    break;
                case "--unregister":
                    options = options with { Unregister = true };
                    break;
                case "--quit":
                    options = options with { Quit = true };
                    break;
                case "--label":
                    string? label = Value();
                    if (label == null || !SafeLabel.IsMatch(label))
                    {
                        error = "--label needs a name of up to 32 letters, digits, '-' or '_'.";
                        return null;
                    }
                    options = options with { Label = label };
                    break;
                case "--port":
                case "--discovery-port":
                    if (!int.TryParse(Value(), out int port) || port is < 1 or > 65535)
                    {
                        error = $"{arg} needs a port number (1-65535).";
                        return null;
                    }
                    options = name == "--port" ? options with { Port = port } : options with { DiscoveryPort = port };
                    break;
                case "--loopback-only":
                    options = options with { LoopbackOnly = true };
                    break;
                case "--no-clipboard":
                    options = options with { NoClipboard = true };
                    break;
                case "--theme":
                    string? theme = Value()?.ToLowerInvariant();
                    if (theme is not ("light" or "dark"))
                    {
                        error = "--theme needs light or dark.";
                        return null;
                    }
                    options = options with { Theme = theme };
                    break;
                default:
                    error = $"Unknown option: {arg}";
                    return null;
            }
        }
        return options;
    }

    private static string FullPath(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return path; // not a path at all - it's reported as not found
        }
    }

    // The options that pick which ClipLink this is (everything but
    // --background, --share, --unregister and --quit), to start the same one again
    // at sign-in - and from File Explorer's "Share to ClipLink".
    public string IdentityArguments()
    {
        var parts = new List<string>();
        if (!IsDefaultLabel) parts.Add($"--label {Label}");
        if (Port != ClipLinkEngine.DefaultPort) parts.Add($"--port {Port}");
        if (DiscoveryPort != ClipLinkEngine.DefaultPort) parts.Add($"--discovery-port {DiscoveryPort}");
        if (LoopbackOnly) parts.Add("--loopback-only");
        if (NoClipboard) parts.Add("--no-clipboard");
        return string.Join(' ', parts);
    }
}
