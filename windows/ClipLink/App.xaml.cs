using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using ClipboardDaemon.Engine;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
using WinForms = System.Windows.Forms;

namespace ClipLink;

// The app: the engine, the tray icon and the window, all in one process.
// Lives in the tray from start to Quit - the window comes and goes (closing
// it only hides it); only Settings > Quit ends it.
public partial class App : Application
{
    private readonly AppOptions options;
    private readonly CancellationTokenSource quitting = new();
    private AppSettings settings = new();
    private EngineHost? host;
    private WinForms.NotifyIcon? tray;
    private MainWindow? window;
    private ShareBatcher? shares;

    internal App(AppOptions options)
    {
        this.options = options;
    }

    internal static App Instance => (App)Current;
    internal static AppOptions Options => Instance.options;
    internal static AppSettings Settings => Instance.settings;
    internal static EngineHost Host => Instance.host ?? throw new InvalidOperationException("The engine isn't set up yet.");
    internal static MainWindow MainAppWindow => Instance.window ?? throw new InvalidOperationException("The window isn't set up yet.");

    public static bool IsQuitting { get; private set; }

    public static string Version { get; } =
        typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(App).Assembly.GetName().Version?.ToString(3) ?? "";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandledUiException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Console.WriteLine($"[app] fatal error: {args.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Console.WriteLine($"[app] unobserved task error: {args.Exception.GetBaseException()}");
            args.SetObserved();
        };

        ApplyTheme();
        settings = AppSettings.Load(options);

        // Files to share arrive one by one (File Explorer starts a ClipLink
        // per selected file) - gathered, then shared together on this thread.
        shares = new ShareBatcher(paths => Dispatcher.BeginInvoke(() => ShareNow(paths)));

        // Listening before anything slow, so a second launch right now
        // gets through sooner (it keeps trying for a while).
        _ = InstancePipe.ListenAsync(options.Label, message => Dispatcher.BeginInvoke(() => OnInstanceMessage(message)), quitting.Token);

        host = new EngineHost(Dispatcher);
        bool running;
        try
        {
            running = host.Start(options);
        }
        catch (Exception ex)
        {
            // The stores couldn't be loaded (e.g. the data folder can't be
            // written) - nothing works without them.
            Console.WriteLine($"[app] couldn't start the engine: {ex}");
            System.Windows.MessageBox.Show($"ClipLink couldn't start.\n\n{ex.Message}", "ClipLink",
                System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Error);
            Shutdown(1);
            return;
        }

        CreateTrayIcon();
        SetUpSignInStartup();
        SetUpShellIntegration();

        window = new MainWindow(host);
        // A share that found no ClipLink running started this one: it stays
        // in the tray, as at sign-in, and says what it shared from there.
        if (!options.Background && options.SharePaths == null)
        {
            ShowMainWindow();
        }
        else if (!running)
        {
            // Started at sign-in with nobody looking: say so from the tray.
            tray!.ShowBalloonTip(10_000, "ClipLink can't sync", host.Status.Error ?? "Open ClipLink to see why.", WinForms.ToolTipIcon.Warning);
        }

        // With whatever other launches forward meanwhile.
        if (options.SharePaths is { Count: > 0 } paths) OnShare(paths);
    }

    private void ApplyTheme()
    {
        // Before applying, so the first theme is tuned too; SystemThemeWatcher
        // switching later raises it again.
        ApplicationThemeManager.Changed += (theme, _) => TuneSecondaryText(theme);
        if (options.Theme == null)
        {
            ApplicationThemeManager.ApplySystemTheme(updateAccent: true);
        }
        else
        {
            ApplicationThemeManager.Apply(options.Theme == "light" ? ApplicationTheme.Light : ApplicationTheme.Dark,
                WindowBackdropType.Mica, updateAccent: true);
        }
        TuneSecondaryText(ApplicationThemeManager.GetAppTheme());
    }

    // WPF draws small text on Mica (grayscale antialiasing) noticeably
    // lighter than WinUI does: in light theme the Fluent secondary text
    // colour (#9E000000) came out around #8C8C8C - about 3.3:1 on a card,
    // under the 4.5:1 that captions and descriptions need. A darker brush
    // here renders as that token looks in Windows' own apps (about #626262).
    // Dark theme renders brighter than its token, so it keeps Wpf.Ui's.
    private void TuneSecondaryText(ApplicationTheme theme)
    {
        const string key = "TextFillColorSecondaryBrush";
        if (theme == ApplicationTheme.Light)
        {
            var brush = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(0xC4, 0, 0, 0));
            brush.Freeze();
            // App-level keys win over the merged theme dictionaries.
            Resources[key] = brush;
        }
        else
        {
            Resources.Remove(key);
        }
    }

    private void CreateTrayIcon()
    {
        tray = new WinForms.NotifyIcon
        {
            Icon = AppIcon.Tray,
            Text = options.IsDefaultLabel ? "ClipLink" : $"ClipLink ({options.Label})",
            Visible = true,
            // No ContextMenuStrip, on purpose: a right click does nothing.
        };
        tray.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left) ShowMainWindow();
        };
        tray.BalloonTipClicked += (_, _) => ShowMainWindow();
    }

    // On by default the first time the real ClipLink runs; after that it's
    // the user's choice (Settings). A test copy (another --label) never
    // turns it on by itself.
    private void SetUpSignInStartup()
    {
        try
        {
            if (!settings.SignInStartupConfigured)
            {
                if (options.IsDefaultLabel)
                {
                    SignInStartup.Enable(options);
                    Console.WriteLine("[startup] first run: ClipLink now starts when you sign in");
                }
                settings.SignInStartupConfigured = true;
                settings.Save();
            }
            else
            {
                SignInStartup.RepairPath(options);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[startup] couldn't set up the sign-in entry: {ex.Message}");
        }
    }

    // "Show 'Share to ClipLink' in File Explorer": while it's on, every
    // start puts it back if it's missing or points at another exe (moved,
    // or a build somewhere else).
    public bool ExplorerShareMenuOn => settings.ExplorerShareMenuOn(options);

    // The setting changed (Settings, or ClipLink.exe --unregister).
    public event Action? ExplorerShareMenuChanged;

    private void SetUpShellIntegration()
    {
        if (!ExplorerShareMenuOn) return;
        try
        {
            if (ShellIntegration.For(options).EnsureRegistered())
                Console.WriteLine("[shell] \"Share to ClipLink\" added to File Explorer (or pointed at this exe)");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[shell] couldn't add \"Share to ClipLink\" to File Explorer: {ex.GetType().Name}: {ex.Message}");
        }
    }

    // Turns it on or off, and remembers that. Throws if File Explorer's
    // entries couldn't be written or removed - the setting is then left as
    // it was.
    public void SetExplorerShareMenu(bool on)
    {
        var shell = ShellIntegration.For(options);
        if (on) shell.EnsureRegistered();
        else shell.Unregister();
        Console.WriteLine($"[shell] \"Share to ClipLink\" {(on ? "on" : "off")}");
        settings.ExplorerShareMenu = on;
        settings.Save();
        ExplorerShareMenuChanged?.Invoke();
    }

    public void ShowMainWindow()
    {
        if (window == null || IsQuitting) return;
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    private void OnInstanceMessage(InstancePipe.Message message)
    {
        switch (message.Command)
        {
            case InstancePipe.Activate:
                ShowMainWindow();
                break;
            case InstancePipe.Share:
                OnShare(message.Paths ?? Array.Empty<string>());
                break;
            case InstancePipe.Unregister:
                // ClipLink.exe --unregister (which removed the entries
                // itself): the setting goes off here too, so it isn't saved
                // back on.
                try
                {
                    SetExplorerShareMenu(false);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[shell] couldn't remove \"Share to ClipLink\": {ex.Message}");
                }
                break;
            default:
                Console.WriteLine($"[instance] unknown command \"{message.Command}\" - ignored");
                break;
        }
    }

    // File Explorer's "Share to ClipLink" / Send To > ClipLink, from this
    // launch's command line or forwarded by another: into the batch.
    private void OnShare(IReadOnlyList<string> paths)
    {
        if (IsQuitting || host == null) return;
        shares?.Add(paths);
    }

    private async void ShareNow(IReadOnlyList<string> paths)
    {
        if (IsQuitting || host == null) return;
        Console.WriteLine($"[share] sharing {paths.Count} path(s)");
        ShareResult result;
        try
        {
            result = await host.Engine.ShareFilesAsync(paths);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[share] failed: {ex}");
            Notify(new ShareSummary("Couldn't share", ex.Message, IsError: true));
            return;
        }
        if (IsQuitting || result.Shared.Count + result.Skipped.Count == 0) return;
        Notify(ShareSummary.Of(result, host.ConnectedCount));
    }

    // In the window if it's the one in front, else from the tray icon (as a
    // Windows notification; clicking it opens the window) - a share comes
    // from File Explorer, so ClipLink's window, even if open, is usually
    // behind it.
    private void Notify(ShareSummary summary)
    {
        if (window is { IsVisible: true, IsActive: true } && window.WindowState != WindowState.Minimized)
        {
            if (summary.IsError) window.ToastError(summary.Title, summary.Message);
            else window.Toast(summary.Title, summary.Message);
        }
        else
        {
            // (Windows cuts a notification's text at 255 characters.)
            string text = summary.Message.Length > 0 ? summary.Message : summary.Title;
            if (text.Length > 250) text = text[..249] + "…";
            tray?.ShowBalloonTip(5000, summary.Title, text, summary.IsError ? WinForms.ToolTipIcon.Warning : WinForms.ToolTipIcon.Info);
        }
    }

    // Settings > Quit - the only way out.
    public void Quit()
    {
        if (IsQuitting) return;
        IsQuitting = true;
        Console.WriteLine("[app] quitting");
        quitting.Cancel();
        shares?.Dispose();
        // First, so peers see this device go right away.
        host?.Stop();
        if (tray != null)
        {
            // Or its icon lingers in the tray until the mouse passes over it.
            tray.Visible = false;
            tray.Dispose();
        }
        window?.Close();
        Shutdown();
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        base.OnSessionEnding(e);
        if (!e.Cancel) Quit(); // signing out or shutting down
    }

    // A bug in the UI mustn't take the engine (and syncing) down with it.
    private void OnUnhandledUiException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Console.WriteLine($"[app] unexpected error (kept running): {e.Exception}");
        e.Handled = true;
    }
}
