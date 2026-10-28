using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using ClipboardDaemon.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace ClipLink;

// This PC (name, device ID and fingerprint, Tailscale address), the
// passcode, starting at sign-in, "Share to ClipLink" in File Explorer,
// clearing the synced history, About (with the updater) - and Quit, the only
// way to end ClipLink.
public sealed partial class SettingsPage : Page
{
    private readonly EngineHost host = App.Host;
    private bool loadingToggle;
    // The update button that had the focus went away (Check -> Cancel,
    // Download -> Retry...): the focus moves to the next one that's there
    // instead of being lost - unless the user has moved it elsewhere meanwhile.
    private bool restoreUpdateFocus;
    // Where WinUI left the focus when the button went away (on the next
    // control that can have it): as long as it is still there, the user
    // hasn't moved it.
    private object? focusLeftAt;
    private UpdatePhase announcedPhase;

    public SettingsPage()
    {
        InitializeComponent();
        EngineBanner.Track(StatusBanner, host);
        WheelScroll.Attach(Scroller);
        DeviceNameBox.PlaceholderText = ComputerName();
        AboutCard.Description = $"Version {App.Version}. Syncs your clipboard between your devices, directly - no cloud."
            + (App.Options.IsDefaultLabel ? "" : $" Test copy \"{App.Options.Label}\" on port {App.Options.Port}.");
        // (On Windows 11 both are under Show more options.)
        ShareMenuCard.Description = "Right-click files and choose Share to ClipLink or Send to > ClipLink"
            + (IsWindows11 ? " (under Show more options)" : "") + " to send them to your devices.";
        Loaded += (_, _) =>
        {
            Refresh();
            App.Instance.ExplorerShareMenuChanged += UpdateShareMenuToggle;
            App.Updates.State.PropertyChanged += OnUpdateStateChanged;
        };
        Unloaded += (_, _) =>
        {
            App.Instance.ExplorerShareMenuChanged -= UpdateShareMenuToggle;
            App.Updates.State.PropertyChanged -= OnUpdateStateChanged;
            restoreUpdateFocus = false;
        };
    }

    private static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;

    // Each time the page is shown: things can change behind its back (a
    // rename can't, but Tailscale coming up, or the sign-in entry being
    // switched off in Task Manager, can).
    private void Refresh()
    {
        DeviceNameBox.Text = host.Engine.DeviceName;
        string id = host.Engine.DeviceId;
        DeviceIdCard.Description = id.Length > 40 ? id[..40] + "…" : id;
        ToolTipService.SetToolTip(DeviceIdCard, new TextBlock { Text = id, TextWrapping = TextWrapping.Wrap, MaxWidth = 360 });
        FingerprintText.Text = DeviceLabel.Fingerprint(id);
        UpdateTailscale(host.Engine.TailscaleAddress);
        _ = RefreshTailscaleAsync();
        UpdatePasscode();

        loadingToggle = true;
        try
        {
            SignInToggle.IsOn = SignInStartup.IsEnabled(App.Options);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[startup] couldn't read the sign-in entry: {ex.Message}");
        }
        finally
        {
            loadingToggle = false;
        }
        UpdateShareMenuToggle();
        loadingToggle = true;
        NotifyReceivedToggle.IsOn = App.Settings.NotifyReceivedItems;
        AutoUpdateToggle.IsOn = App.Updates.AutomaticChecks;
        loadingToggle = false;
        announcedPhase = App.Updates.State.Phase;
        ShowUpdateState();
    }

    private static string ComputerName()
    {
        try
        {
            return Dns.GetHostName();
        }
        catch (Exception)
        {
            return Environment.MachineName;
        }
    }

    // ---- this PC -----------------------------------------------------------

    private void DeviceNameBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        SaveName_Click(sender, e);
    }

    private void SaveName_Click(object sender, RoutedEventArgs e)
    {
        // The box shows the name in effect - the computer's, while no name
        // of your own is set - so Save without an edit saves nothing (it
        // would pin the computer's name). Blank, or the computer's name,
        // goes back to following the computer's name. From the next beacon
        // and handshake on - connections already open keep the old name.
        if (DeviceNameBox.Text.Trim() == host.Engine.DeviceName)
        {
            DeviceNameBox.Text = host.Engine.DeviceName;
            return;
        }
        // The box shows the name that was saved (it may have been tidied).
        DeviceNameBox.Text = host.Engine.SetDeviceName(DeviceNameBox.Text);
    }

    private void CopyId_Click(object sender, RoutedEventArgs e) =>
        CopyText(host.Engine.DeviceId);

    private void CopyTailscale_Click(object sender, RoutedEventArgs e)
    {
        if (host.Engine.TailscaleAddress is { } address) CopyText(address);
    }

    private void CopyText(string text)
    {
        if (!host.CopyText(text)) App.MainAppWindow.ToastError("Couldn't copy", "Another app is using the clipboard. Try again.");
    }

    private async Task RefreshTailscaleAsync()
    {
        try
        {
            UpdateTailscale(await host.Engine.RefreshTailscaleAddressAsync());
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] Tailscale lookup failed: {ex.Message}");
        }
    }

    private void UpdateTailscale(string? address)
    {
        TailscaleCard.Visibility = address == null ? Visibility.Collapsed : Visibility.Visible;
        TailscaleCard.Description = address == null ? ""
            : $"{address} - paired devices reach this PC here when they're away from your network.";
    }

    // ---- passcode ----------------------------------------------------------

    private void UpdatePasscode()
    {
        bool set = host.HasPasscode;
        PasscodeCard.Description = set
            ? "Set. Devices with the same passcode pair with this PC automatically."
            : "Not set. Give your devices the same passcode and they pair automatically, with no code to scan.";
        SetPasscodeButton.Content = set ? "Change" : "Set";
        PasscodeBox.PlaceholderText = set ? "New passcode" : "Passcode";
        ClearPasscodeButton.Visibility = set ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowPasscodeError(string? error)
    {
        PasscodeError.Text = error ?? "";
        PasscodeError.Visibility = error == null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void PasscodeBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        SetPasscode_Click(sender, e);
    }

    private async void SetPasscode_Click(object sender, RoutedEventArgs e)
    {
        if (PasscodeBusy.Visibility == Visibility.Visible) return;
        string passcode = PasscodeBox.Password ?? "";
        // The only rule, on every platform: not blank (it's trimmed).
        if (passcode.Trim().Length == 0)
        {
            ShowPasscodeError("Enter a passcode first.");
            PasscodeBox.Focus(FocusState.Programmatic);
            return;
        }
        ShowPasscodeError(null);
        bool hadOne = host.HasPasscode;
        PasscodeBusy.Visibility = Visibility.Visible;
        SetPasscodeButton.IsEnabled = ClearPasscodeButton.IsEnabled = false;
        try
        {
            // Deriving the key is deliberately slow - off the UI thread.
            if (!await host.Engine.SetPasscodeAsync(passcode))
            {
                ShowPasscodeError("Enter a passcode first.");
                return;
            }
            PasscodeBox.Password = "";
            host.RefreshPasscode();
            UpdatePasscode();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't save the passcode: {ex.Message}");
            ShowPasscodeError($"Couldn't save the passcode: {ex.Message}");
        }
        finally
        {
            PasscodeBusy.Visibility = Visibility.Collapsed;
            SetPasscodeButton.IsEnabled = ClearPasscodeButton.IsEnabled = true;
        }
    }

    private async void ClearPasscode_Click(object sender, RoutedEventArgs e)
    {
        bool confirmed = await App.MainAppWindow.ConfirmAsync("Clear passcode?",
            "New devices will need the QR code or an address to pair with this PC. Devices that are already paired stay paired.",
            "Clear");
        if (!confirmed) return;
        try
        {
            host.Engine.ClearPasscode();
            ShowPasscodeError(null);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't clear the passcode: {ex.Message}");
            ShowPasscodeError($"Couldn't clear the passcode: {ex.Message}");
        }
        host.RefreshPasscode();
        UpdatePasscode();
    }

    // ---- general -----------------------------------------------------------

    private void SignInToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (loadingToggle) return;
        bool on = SignInToggle.IsOn;
        try
        {
            if (on) SignInStartup.Enable(App.Options);
            else SignInStartup.Disable(App.Options);
            App.Settings.SignInStartupConfigured = true;
            App.Settings.Save();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[startup] couldn't change the sign-in entry: {ex.Message}");
            App.MainAppWindow.ToastError("Couldn't change that", ex.Message);
            loadingToggle = true;
            SignInToggle.IsOn = !on;
            loadingToggle = false;
        }
    }

    private void NotifyReceivedToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (loadingToggle) return;
        App.Settings.NotifyReceivedItems = NotifyReceivedToggle.IsOn;
        App.Settings.Save();
    }

    private void UpdateShareMenuToggle()
    {
        loadingToggle = true;
        ShareMenuToggle.IsOn = App.Instance.ExplorerShareMenuOn;
        loadingToggle = false;
    }

    private void ShareMenuToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (loadingToggle) return;
        bool on = ShareMenuToggle.IsOn;
        try
        {
            App.Instance.SetExplorerShareMenu(on);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[shell] couldn't change Share to ClipLink: {ex.Message}");
            App.MainAppWindow.ToastError("Couldn't change that", ex.Message);
            UpdateShareMenuToggle();
        }
    }

    // ---- synced history ----------------------------------------------------

    private async void ClearHistory_Click(object sender, RoutedEventArgs e)
    {
        bool confirmed = await App.MainAppWindow.ConfirmAsync("Clear synced history?",
            "Every synced item is deleted from this PC, and won't come back from your other devices. They keep their own copies.",
            "Clear");
        if (!confirmed) return;
        host.Engine.ClearHistory();
    }

    // ---- about -------------------------------------------------------------

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        string folder = Path.GetDirectoryName(ConsoleLog.DefaultPath)!;
        try
        {
            Directory.CreateDirectory(folder);
            Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            App.MainAppWindow.ToastError("Couldn't open the log folder", ex.Message);
        }
    }

    // ---- updates -----------------------------------------------------------

    private void OnUpdateStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(UpdateState.BytesDone)) ShowUpdateProgress();
        else ShowUpdateState();
    }

    // The card for the updater's state: what it says, and the buttons that
    // make sense now - never more than a couple.
    private void ShowUpdateState()
    {
        var state = App.Updates.State;
        var phase = state.Phase;
        var offer = state.Offer;
        string version = offer?.Version.Text ?? "";
        bool canInstall = offer?.CanInstallInApp == true;

        string description = phase switch
        {
            UpdatePhase.Checking => "Checking for updates...",
            UpdatePhase.UpToDate => $"You're up to date. {LastChecked(state)}",
            UpdatePhase.Available => $"Version {version} is available. "
                + (canInstall
                    ? "Your settings, paired devices and history are kept."
                    : "ClipLink can't check that download itself, so get it from the download page.")
                + (state.Message != null ? " " + state.Message : ""),
            UpdatePhase.Downloading => $"Downloading version {version}...",
            UpdatePhase.Verifying => "Checking the download...",
            UpdatePhase.Installing => "Installing - ClipLink will restart.",
            UpdatePhase.Error => state.Message ?? "Something went wrong.",
            _ => LastChecked(state),
        };
        UpdateCard.Description = description;

        var focused = FocusedUpdateButton();
        // (Without a checksum, "Open download page" is the one: "What's new" would open the same page.)
        WhatsNewButton.Visibility = Show(phase == UpdatePhase.Available && canInstall);
        CheckUpdateButton.Visibility = Show(phase is UpdatePhase.Idle or UpdatePhase.UpToDate or UpdatePhase.Checking);
        CheckUpdateButton.IsEnabled = phase != UpdatePhase.Checking;
        InstallUpdateButton.Visibility = Show(phase == UpdatePhase.Available && canInstall);
        CancelUpdateButton.Visibility = Show(phase == UpdatePhase.Downloading);
        RetryUpdateButton.Visibility = Show(phase == UpdatePhase.Error);
        DownloadPageButton.Visibility = Show((phase == UpdatePhase.Available && !canInstall) || phase == UpdatePhase.Error);
        AutomationProperties.SetName(WhatsNewButton, $"What's new in version {version}");
        ShowUpdateProgress();

        if (focused != null && (focused.Visibility != Visibility.Visible || !focused.IsEnabled))
        {
            restoreUpdateFocus = true;
            focusLeftAt = FocusedElement();
        }
        if (restoreUpdateFocus) FocusAnUpdateButton();
        // (While something is going on there may be no button yet; once it has settled, there is no more waiting.)
        if (!state.IsBusy) restoreUpdateFocus = false;
        if (phase != announcedPhase)
        {
            announcedPhase = phase;
            // Screen readers hear the result of a check, not every step of it.
            if (phase is UpdatePhase.UpToDate or UpdatePhase.Available or UpdatePhase.Error or UpdatePhase.Installing)
                FrameworkElementAutomationPeer.FromElement(UpdateCard)?.RaiseNotificationEvent(
                    AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, description, "ClipLinkUpdate");
        }
    }

    private void ShowUpdateProgress()
    {
        var state = App.Updates.State;
        bool downloading = state.Phase == UpdatePhase.Downloading;
        UpdateProgressPanel.Visibility = Show(downloading || state.Phase is UpdatePhase.Verifying or UpdatePhase.Installing);
        UpdateProgressBar.IsIndeterminate = !downloading;
        UpdateProgressText.Visibility = Show(downloading);
        if (!downloading) return;
        UpdateProgressBar.Maximum = Math.Max(state.BytesTotal, 1);
        UpdateProgressBar.Value = state.BytesDone;
        UpdateProgressText.Text = $"{Format.Size(state.BytesDone)} of {Format.Size(state.BytesTotal)}";
    }

    private static string LastChecked(UpdateState state) =>
        state.LastCheckedUtc is { } checkedAt ? $"Last checked: {Format.When(checkedAt, DateTime.UtcNow)}." : "Not checked yet.";

    private static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    // In the order of what the user most likely wants next.
    private Control[] UpdateButtons() =>
        new Control[] { InstallUpdateButton, RetryUpdateButton, CancelUpdateButton, CheckUpdateButton, DownloadPageButton, WhatsNewButton };

    private object? FocusedElement() => XamlRoot == null ? null : FocusManager.GetFocusedElement(XamlRoot);

    private bool IsUpdateButton(object? element) => UpdateButtons().Any(button => ReferenceEquals(button, element));

    // The update button that has the focus, if one does.
    private Control? FocusedUpdateButton() => FocusedElement() is Control focused && IsUpdateButton(focused) ? focused : null;

    // The first update button that's there.
    private void FocusAnUpdateButton()
    {
        // Not taken from where the user has gone meanwhile (another control, a dialog).
        object? there = FocusedElement();
        if (!ReferenceEquals(there, focusLeftAt) && !IsUpdateButton(there))
        {
            restoreUpdateFocus = false;
            return;
        }
        foreach (var button in UpdateButtons())
        {
            if (button.Visibility != Visibility.Visible || !button.IsEnabled) continue;
            button.Focus(FocusState.Programmatic);
            restoreUpdateFocus = false;
            return;
        }
    }

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
    {
        await App.Updates.CheckAsync();
    }

    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        await App.Updates.InstallAsync();
    }

    private void CancelUpdate_Click(object sender, RoutedEventArgs e)
    {
        App.Updates.Cancel();
    }

    // Again whatever failed: the check, or the download and install.
    private async void RetryUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (App.Updates.State.FailedToInstall) await App.Updates.InstallAsync();
        else await App.Updates.CheckAsync();
    }

    private void WhatsNew_Click(object sender, RoutedEventArgs e) => App.Updates.OpenReleasePage();

    private void OpenDownloadPage_Click(object sender, RoutedEventArgs e) => App.Updates.OpenReleasePage();

    private void AutoUpdateToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (loadingToggle) return;
        App.Updates.AutomaticChecks = AutoUpdateToggle.IsOn;
    }

    private void Quit_Click(object sender, RoutedEventArgs e) => App.Instance.Quit();
}
