using System.Diagnostics;
using System.IO;
using System.Net;
using ClipboardDaemon.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace ClipLink;

// This PC (name, device ID and fingerprint, Tailscale address), the
// passcode, starting at sign-in, "Share to ClipLink" in File Explorer,
// clearing the synced history, About - and Quit, the only way to end ClipLink.
public sealed partial class SettingsPage : Page
{
    private readonly EngineHost host = App.Host;
    private bool loadingToggle;

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
        };
        Unloaded += (_, _) => App.Instance.ExplorerShareMenuChanged -= UpdateShareMenuToggle;
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
        string now = host.Engine.SetDeviceName(DeviceNameBox.Text);
        DeviceNameBox.Text = now;
        App.MainAppWindow.Toast("Device name saved", $"Your other devices will see \"{now}\".");
    }

    private void CopyId_Click(object sender, RoutedEventArgs e) =>
        CopyText(host.Engine.DeviceId, "Device ID copied");

    private void CopyTailscale_Click(object sender, RoutedEventArgs e)
    {
        if (host.Engine.TailscaleAddress is { } address) CopyText(address, "Tailscale address copied");
    }

    private void CopyText(string text, string done)
    {
        if (host.CopyText(text)) App.MainAppWindow.Toast(done);
        else App.MainAppWindow.ToastError("Couldn't copy", "Another app is using the clipboard. Try again.");
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
            App.MainAppWindow.Toast(hadOne ? "Passcode changed" : "Passcode set",
                "Set the same one on your other devices and they pair automatically.");
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
            App.MainAppWindow.Toast("Passcode cleared");
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
            if (on)
            {
                App.MainAppWindow.Toast("Added to File Explorer", "Right-click files and choose Share to ClipLink"
                    + (IsWindows11 ? " - it's under Show more options." : "."));
            }
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
        App.MainAppWindow.Toast("Synced history cleared");
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

    private void Quit_Click(object sender, RoutedEventArgs e) => App.Instance.Quit();
}
