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

        // Listening before anything slow, so a second launch right now
        // still gets through (it waits up to 3 s).
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

        window = new MainWindow(host);
        if (!options.Background)
        {
            ShowMainWindow();
        }
        else if (!running)
        {
            // Started at sign-in with nobody looking: say so from the tray.
            tray!.ShowBalloonTip(10_000, "ClipLink can't sync", host.Status.Error ?? "Open ClipLink to see why.", WinForms.ToolTipIcon.Warning);
        }

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
            default:
                Console.WriteLine($"[instance] unknown command \"{message.Command}\" - ignored");
                break;
        }
    }

    // Explorer's "Share to ClipLink" arrives in batch 7.
    private static void OnShare(IReadOnlyList<string> paths)
    {
        Console.WriteLine($"[app] asked to share {paths.Count} file(s) - not supported yet, ignored");
    }

    // Settings > Quit - the only way out.
    public void Quit()
    {
        if (IsQuitting) return;
        IsQuitting = true;
        Console.WriteLine("[app] quitting");
        quitting.Cancel();
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
