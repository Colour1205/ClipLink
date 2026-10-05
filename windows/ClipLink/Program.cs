using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using ClipboardDaemon.Engine;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace ClipLink;

// Own entry point (App.xaml's generated Main is off): the single-instance
// check runs before WinUI starts. One ClipLink runs per user session (and
// label); a second launch hands its request to that one (InstancePipe) and
// exits.
public static class Program
{
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int processId);
    private const int ASFW_ANY = -1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(nint hWnd, string text, string caption, uint type);
    private const uint MB_OK_ICONERROR = 0x10;

    // How long a second launch keeps trying to reach the running copy. A
    // share waits longest: File Explorer may have started a hundred of them
    // at once, and on a cold start the first one is itself still starting up.
    private static readonly TimeSpan ActivateTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ShareTimeout = TimeSpan.FromSeconds(30);

    private static string MutexName(string label) => $"Local\\ClipLink_{label}";

    [STAThread]
    public static int Main(string[] args)
    {
        var options = AppOptions.Parse(args, out string? error);
        if (options == null)
        {
            ShowError(error);
            return 2;
        }

        if (options.Unregister) return Unregister(options);
        if (options.Quit) return QuitRunning(options);

        using var mutex = new Mutex(initiallyOwned: false, MutexName(options.Label));
        if (!TryOwn(mutex))
        {
            // (Not logged: the log file is the running copy's.)
            if (options.SharePaths is { } paths)
            {
                // No window: the running copy says what it shared from the
                // tray (or in its window, if that's showing).
                return paths.Count == 0 || InstancePipe.Send(options.Label, new InstancePipe.Message(InstancePipe.Share, paths), ShareTimeout) ? 0 : 1;
            }
            // This launch came from the user, so it may bring a window to
            // the front - pass that on, or the running copy's Activate()
            // would only flash its taskbar button.
            AllowSetForegroundWindow(ASFW_ANY);
            return InstancePipe.Send(options.Label, new InstancePipe.Message(InstancePipe.Activate), ActivateTimeout) ? 0 : 1;
        }

        try
        {
            return RunApp(options);
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }

    // Whether this launch is the running ClipLink: owning the mutex, not
    // just being first to create it - every second launch holds it open
    // too (a share's for up to ShareTimeout), and that mustn't stop the
    // next ClipLink from starting once this one has quit. (Then those
    // still trying hand their files to that one.)
    private static bool TryOwn(Mutex mutex)
    {
        try
        {
            return mutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            return true; // the last one ended without letting go: ours now
        }
    }

    // Kept out of Main, so a second launch - the many "Share to ClipLink"
    // ones especially - never loads WinUI.
    [MethodImpl(MethodImplOptions.NoInlining)]
    internal static void ShowError(string? error) =>
        MessageBoxW(0, error ?? "", "ClipLink", MB_OK_ICONERROR);

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static int RunApp(AppOptions options)
    {
        // Started by File Explorer's "Share to ClipLink", this process's
        // working folder is the shared file's. Kept, that folder would be in
        // use - can't be renamed, deleted or ejected - for as long as ClipLink
        // runs, and a program ClipLink runs by name (the Tailscale CLI) would
        // be looked for in it before PATH. The share's paths are absolute
        // already (AppOptions), and nothing else uses relative paths.
        Environment.CurrentDirectory = Environment.SystemDirectory;

        // Before anything else, so all of it (the engine included) is
        // logged. A test copy logs to its own file.
        string logPath = options.IsDefaultLabel
            ? ConsoleLog.DefaultPath
            : Path.Combine(Path.GetDirectoryName(ConsoleLog.DefaultPath)!, $"cliplink-{options.Label}.log");
        ConsoleLog.RedirectToFile(logPath);

        Console.WriteLine($"[app] ClipLink {App.Version} starting (pid {Environment.ProcessId}, label {options.Label}"
            + (options.Background ? ", in the background" : "")
            + (options.SharePaths is { } paths ? $", to share {paths.Count} file(s)" : "") + ")");

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callbackParams =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(options);
        });
        Console.WriteLine($"[app] exited ({App.ExitCode})");
        return App.ExitCode;
    }

    // ClipLink.exe --quit: asks the running ClipLink to quit - what the
    // installer does before it updates or removes it. Nothing running is
    // fine: that's the state the caller wants.
    private static int QuitRunning(AppOptions options)
    {
        bool running = Mutex.TryOpenExisting(MutexName(options.Label), out var existing);
        existing?.Dispose();
        if (!running) return 0;
        return InstancePipe.Send(options.Label, new InstancePipe.Message(InstancePipe.Quit), ActivateTimeout) ? 0 : 1;
    }

    // ClipLink.exe --unregister: "Share to ClipLink" out of File Explorer,
    // and its setting off so the next start doesn't put it back (Settings
    // can). Done here either way - it's this user's registry and SendTo
    // folder - and a running copy is told too, so it doesn't hold on to the
    // setting (and its Settings page shows it). No UI: it's for scripts.
    private static int Unregister(AppOptions options)
    {
        int exitCode = 0;
        try
        {
            ShellIntegration.For(options).Unregister();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[shell] couldn't remove Share to ClipLink: {ex.Message}");
            exitCode = 1;
        }

        bool running = Mutex.TryOpenExisting(MutexName(options.Label), out var existing);
        existing?.Dispose();
        if (!running || !InstancePipe.Send(options.Label, new InstancePipe.Message(InstancePipe.Unregister), ActivateTimeout))
        {
            var settings = AppSettings.Load(options);
            settings.ExplorerShareMenu = false;
            settings.Save();
        }
        return exitCode;
    }
}
