using System.IO;
using System.Runtime.InteropServices;
using ClipboardDaemon.Engine;

namespace ClipLink;

// Own entry point (App.xaml is an ordinary page): the single-instance check
// runs before WPF starts. One ClipLink runs per user session (and label); a
// second launch hands its request to that one (InstancePipe) and exits.
public static class Program
{
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int processId);
    private const int ASFW_ANY = -1;

    [STAThread]
    public static int Main(string[] args)
    {
        var options = AppOptions.Parse(args, out string? error);
        if (options == null)
        {
            System.Windows.MessageBox.Show(error, "ClipLink", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error);
            return 2;
        }

        using var mutex = new Mutex(initiallyOwned: true, $"Local\\ClipLink_{options.Label}", out bool firstInstance);
        if (!firstInstance)
        {
            // This launch came from the user, so it may bring a window to
            // the front - pass that on, or the running copy's Activate()
            // would only flash its taskbar button.
            AllowSetForegroundWindow(ASFW_ANY);
            var message = options.SharePaths is { Count: > 0 } paths
                ? new InstancePipe.Message(InstancePipe.Share, paths)
                : new InstancePipe.Message(InstancePipe.Activate);
            // (Not logged: the log file is the running copy's.)
            return InstancePipe.Send(options.Label, message) ? 0 : 1;
        }

        // Before anything else, so all of it (the engine included) is
        // logged. A test copy logs to its own file.
        string logPath = options.IsDefaultLabel
            ? ConsoleLog.DefaultPath
            : Path.Combine(Path.GetDirectoryName(ConsoleLog.DefaultPath)!, $"cliplink-{options.Label}.log");
        ConsoleLog.RedirectToFile(logPath);

        Console.WriteLine($"[app] ClipLink {App.Version} starting (pid {Environment.ProcessId}, label {options.Label}{(options.Background ? ", in the background" : "")})");
        var app = new App(options);
        app.InitializeComponent();
        int exitCode = app.Run();
        Console.WriteLine($"[app] exited ({exitCode})");
        return exitCode;
    }
}
