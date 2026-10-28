using System.ComponentModel;
using System.Diagnostics;
using ClipLink.Updates;
using Microsoft.UI.Dispatching;

namespace ClipLink;

// The Windows updater: looks on GitHub for a newer ClipLink - by itself about
// ten seconds after start and then once a day, or when asked - and, only when
// the user clicks "Download and install", downloads the installer, checks it
// and runs it. It asks nothing else of GitHub and sends nothing else. The
// logic lives in Updates\ (plain C#, unit-tested); this is the part that
// belongs to the app: when to check, the state Settings shows, starting the
// installer. UI thread only.
internal sealed class UpdateService : IDisposable
{
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);
    // A check that couldn't reach GitHub at all (no network yet at sign-in,
    // say) doesn't count: it is tried again after this, not tomorrow.
    private static readonly TimeSpan RetryAfterNoAnswer = TimeSpan.FromHours(1);

    private readonly DispatcherQueue dispatcher;
    private readonly AppOptions options;
    private readonly AppSettings settings;
    private readonly UpdateEndpoint endpoint = UpdateEndpoint.FromEnvironment();
    private readonly DispatcherQueueTimer timer;
    // Cancelled when ClipLink quits, which also ends a download in progress.
    private readonly CancellationTokenSource quitting = new();
    private UpdateClient? client;
    private CancellationTokenSource? operation;
    // The installer that is running, held (VerifiedInstaller) until it ends.
    private VerifiedInstaller? runningInstaller;
    private bool disposed;

    public UpdateService(DispatcherQueue dispatcher, AppOptions options, AppSettings settings)
    {
        this.dispatcher = dispatcher;
        this.options = options;
        this.settings = settings;
        State.SetLastChecked(settings.LastUpdateCheckUtc);
        timer = dispatcher.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += OnTimer;
    }

    public UpdateState State { get; } = new();

    private UpdateClient Client => client ??= new UpdateClient(endpoint, App.Version);

    // Settings > About > "Check for updates automatically".
    public bool AutomaticChecks
    {
        get => settings.CheckForUpdates;
        set
        {
            if (settings.CheckForUpdates == value) return;
            settings.CheckForUpdates = value;
            settings.Save();
            Console.WriteLine($"[update] automatic checks {(value ? "on" : "off")}");
            ScheduleNext();
        }
    }

    // A test copy with --loopback-only promises that nothing reaches the
    // network: it doesn't look by itself (the Check button still works),
    // unless a Debug build has been pointed at a stand-in server.
    private bool AutomaticChecksAllowed => settings.CheckForUpdates && (!options.LoopbackOnly || endpoint.IsTestOverride);

    // Called once the window is up. The first look waits a few seconds, so
    // none of this is on the startup path.
    public void Start()
    {
        TimeSpan delay = UpdateEndpoint.StartupDelay();
        Console.WriteLine($"[update] automatic checks {(AutomaticChecksAllowed ? "on" : "off")}"
            + (AutomaticChecksAllowed ? $", the first one is due in {Math.Max(delay.TotalSeconds, DueIn().TotalSeconds):0} s" : ""));
        Schedule(delay);
    }

    // How long until a check is due: a day after the last answer.
    private TimeSpan DueIn()
    {
        if (settings.LastUpdateCheckUtc is not { } last) return TimeSpan.Zero;
        TimeSpan wait = last + CheckInterval - DateTime.UtcNow;
        // (A clock that was set back must not postpone it for longer than a day.)
        return wait < TimeSpan.Zero ? TimeSpan.Zero : wait > CheckInterval ? CheckInterval : wait;
    }

    private void ScheduleNext(TimeSpan? after = null)
    {
        timer.Stop();
        if (disposed || !AutomaticChecksAllowed) return;
        Schedule(after ?? DueIn());
    }

    private void Schedule(TimeSpan wait)
    {
        if (disposed) return;
        timer.Stop();
        timer.Interval = wait < TimeSpan.FromMilliseconds(100) ? TimeSpan.FromMilliseconds(100) : wait;
        timer.Start();
    }

    private async void OnTimer(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        TimeSpan? next = null;
        try
        {
            // The first time round, and quietly: what earlier updates left in %TEMP%.
            if (!State.IsBusy && runningInstaller == null) _ = Task.Run(() => UpdateFolder.Clear(UpdateFolder.DefaultPath));

            if (AutomaticChecksAllowed && !State.IsBusy)
            {
                // The first look after start waits for the startup delay and
                // is due only if a day has passed since the last answer.
                TimeSpan due = DueIn();
                if (due > TimeSpan.Zero) next = due;
                else if (!await CheckCoreAsync()) next = RetryAfterNoAnswer;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[update] automatic check failed: {ex}");
        }
        finally
        {
            ScheduleNext(next);
        }
    }

    // ---- looking ------------------------------------------------------------

    // "Check for updates": always asks, whatever the switch says.
    public async Task CheckAsync()
    {
        if (!await CheckCoreAsync()) return;
        ScheduleNext();
    }

    // False when GitHub didn't answer at all.
    private async Task<bool> CheckCoreAsync()
    {
        if (disposed || State.IsBusy) return true;
        if (!ReleaseVersion.TryParse(App.Version, out var current))
        {
            Console.WriteLine($"[update] can't tell which version this is (\"{App.Version}\")");
            Fail("Couldn't check for updates: this build doesn't know its own version.");
            return true;
        }

        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(quitting.Token);
        operation = cancel;
        State.Set(UpdatePhase.Checking);
        try
        {
            Console.WriteLine($"[update] looking for a version newer than {App.Version}");
            // On a pool thread, so the work between the awaits stays off the UI thread.
            var updates = Client;
            var offer = await Task.Run(() => updates.CheckAsync(current, cancel.Token), CancellationToken.None);
            RememberCheck();
            State.SetOffer(offer);
            if (offer == null)
            {
                Console.WriteLine("[update] up to date");
                State.Set(UpdatePhase.UpToDate);
            }
            else
            {
                Console.WriteLine($"[update] version {offer.Version.Text} is available"
                    + (offer.CanInstallInApp ? "" : " (no checksum listed: the download page only)"));
                State.Set(UpdatePhase.Available);
            }
            return true;
        }
        catch (OperationCanceledException)
        {
            if (!disposed) State.Set(UpdatePhase.Idle);
            return true;
        }
        catch (UpdateException ex)
        {
            LogFailure("check", ex);
            if (ex.Kind != UpdateFailure.Network) RememberCheck();
            Fail($"Couldn't check for updates. {ex.Message}");
            return ex.Kind != UpdateFailure.Network;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[update] check failed: {ex}");
            RememberCheck();
            Fail("Couldn't check for updates.");
            return true;
        }
        finally
        {
            if (operation == cancel) operation = null;
        }
    }

    private void RememberCheck()
    {
        DateTime now = DateTime.UtcNow;
        settings.LastUpdateCheckUtc = now;
        settings.Save();
        State.SetLastChecked(now);
    }

    // ---- installing ---------------------------------------------------------

    // "Download and install": download, check, run. ClipLink doesn't quit by
    // itself: the installer asks it to, and starts it again afterwards.
    public async Task InstallAsync()
    {
        if (disposed || State.IsBusy || State.Offer is not { CanInstallInApp: true } offer) return;

        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(quitting.Token);
        operation = cancel;
        State.SetProgress(0, offer.Asset.Size);
        State.Set(UpdatePhase.Downloading);
        VerifiedInstaller? installer = null;
        try
        {
            Console.WriteLine($"[update] downloading version {offer.Version.Text} ({offer.Asset.Size:N0} bytes)");
            var progress = new DispatcherProgress(dispatcher, OnProgress);
            var updates = Client;
            installer = await Task.Run(() => updates.DownloadAsync(offer, UpdateFolder.DefaultPath, progress, cancel.Token), CancellationToken.None);
            Console.WriteLine($"[update] {offer.InstallerFileName} matches GitHub's size and SHA-256");

            State.Set(UpdatePhase.Installing);
            Console.WriteLine($"[update] starting the installer: {offer.InstallerFileName} {string.Join(' ', InstallerLauncher.Arguments)}");
            // (Off the UI thread: Windows may be asking for permission.)
            string path = installer.FilePath;
            var process = await Task.Run(() => InstallerLauncher.Start(path), CancellationToken.None);
            runningInstaller = installer;
            installer = null;
            process.EnableRaisingEvents = true;
            process.Exited += (_, _) => dispatcher.TryEnqueue(() => OnInstallerExited(process));
        }
        catch (OperationCanceledException)
        {
            if (disposed) return;
            Console.WriteLine("[update] download cancelled");
            State.Set(UpdatePhase.Available);
        }
        catch (UpdateException ex) when (ex.Kind == UpdateFailure.Declined)
        {
            Console.WriteLine($"[update] the installer wasn't allowed to run: {ex.InnerException?.Message}");
            State.Set(UpdatePhase.Available, ex.Message);
        }
        catch (UpdateException ex)
        {
            LogFailure("install", ex);
            Fail(ex.Message, failedToInstall: true);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[update] install failed: {ex}");
            Fail("Something went wrong while updating. ClipLink wasn't changed.", failedToInstall: true);
        }
        finally
        {
            installer?.Dispose();
            if (operation == cancel) operation = null;
        }
    }

    public void Cancel() => operation?.Cancel();

    private void OnProgress(UpdateProgress progress)
    {
        if (State.Phase is not (UpdatePhase.Downloading or UpdatePhase.Verifying)) return;
        if (progress.Stage == UpdateStage.Verifying)
        {
            State.SetProgress(progress.Total, progress.Total);
            State.Set(UpdatePhase.Verifying);
        }
        else
        {
            State.SetProgress(progress.Done, progress.Total);
        }
    }

    // The installer ended and this ClipLink is still here: when it works it
    // asks this one to quit first, so something went wrong (or it was
    // closed). Said plainly, with the way out.
    private void OnInstallerExited(Process process)
    {
        int code;
        try
        {
            code = process.ExitCode;
        }
        catch (InvalidOperationException)
        {
            code = -1;
        }
        process.Dispose();
        runningInstaller?.Dispose();
        runningInstaller = null;
        if (disposed) return;
        Console.WriteLine($"[update] the installer ended (exit code {code}) and ClipLink is still running");
        Fail(code == 0
            ? "The installer finished, but this ClipLink is still running. Quit it and start it again to use the new version."
            : $"The installer stopped before it finished (code {code}). ClipLink wasn't changed.", failedToInstall: true);
    }

    // "What's new" and "Open download page": the release's page on GitHub.
    public void OpenReleasePage()
    {
        Uri page = State.Offer?.PageUrl ?? new Uri(UpdateEndpoint.ReleasesPageUrl);
        // Only an address the updater may use: https, on GitHub.
        if (!endpoint.Policy.IsAllowed(page)) return;
        try
        {
            Process.Start(new ProcessStartInfo(page.AbsoluteUri) { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            App.MainAppWindow.ToastError("Couldn't open the page", ex.Message);
        }
    }

    // ---- helpers ------------------------------------------------------------

    private void Fail(string message, bool failedToInstall = false)
    {
        if (disposed) return;
        State.Set(UpdatePhase.Error, message, failedToInstall);
    }

    private static void LogFailure(string what, UpdateException ex) =>
        Console.WriteLine($"[update] {what} failed ({ex.Kind}): {ex.Message}"
            + (ex.InnerException != null ? $" ({ex.InnerException.GetType().Name}: {ex.InnerException.Message})" : ""));

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        timer.Stop();
        quitting.Cancel();
        runningInstaller?.Dispose();
        runningInstaller = null;
        client?.Dispose();
    }

    // Progress reports come from the download's thread; the state belongs to the UI thread's.
    private sealed class DispatcherProgress(DispatcherQueue dispatcher, Action<UpdateProgress> handle) : IProgress<UpdateProgress>
    {
        public void Report(UpdateProgress value) => dispatcher.TryEnqueue(() => handle(value));
    }
}
