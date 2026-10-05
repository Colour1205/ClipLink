using System.Runtime.InteropServices.WindowsRuntime;
using ClipboardDaemon.Engine;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;
using Windows.Storage.Streams;
using Windows.System;

namespace ClipLink;

// Paired and nearby devices (the engine's stable order), plus the pairing
// view ("Add device"): this PC's QR code, its pairing info and pair by
// address. Pairing mode is on exactly while that view is on screen - as on
// the phones' Pair screens - and goes off when you go back, leave the page,
// hide the window or minimise it.
public sealed partial class DevicesPage : Page
{
    private readonly EngineHost host = App.Host;
    private bool pairViewOpen;
    private string? pairingPayload;
    private bool pairing; // a pair-by-address is in progress

    public DevicesPage()
    {
        InitializeComponent();
        EngineBanner.Track(StatusBanner, host);
        WheelScroll.Attach(DeviceList);
        WheelScroll.Attach(PairView);
        PairTitle.ItemsSource = new[] { "Devices", "Add a device" };
        Loaded += (_, _) =>
        {
            App.MainAppWindow.OnScreenChanged += UpdatePairingMode;
            UpdatePairingMode();
        };
        Unloaded += (_, _) =>
        {
            // Navigated to another page: back to the list, pairing off.
            App.MainAppWindow.OnScreenChanged -= UpdatePairingMode;
            ShowPairView(false);
        };
        QrCard.SizeChanged += (_, e) => LayOutQrCard(e.NewSize.Width);
    }

    private void Escape_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!pairViewOpen) return;
        ShowPairView(false);
        args.Handled = true;
    }

    private void AddDevice_Click(object sender, RoutedEventArgs e) => ShowPairView(true);

    private void PairTitle_ItemClicked(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (args.Index == 0) ShowPairView(false);
    }

    private void ShowPairView(bool open)
    {
        if (open != pairViewOpen)
        {
            pairViewOpen = open;
            DeviceList.Visibility = ListTitle.Visibility = AddDeviceButton.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
            PairView.Visibility = PairTitle.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
            if (open)
            {
                PairView.ChangeView(null, 0, null, disableAnimation: true);
                _ = LoadPairingInfoAsync();
                AddressBox.Focus(FocusState.Programmatic);
            }
            else
            {
                PairResult.IsOpen = false;
            }
        }
        UpdatePairingMode();
    }

    private void UpdatePairingMode()
    {
        bool onScreen = IsLoaded && App.MainAppWindow.IsOnScreen;
        host.SetPairingUiActive(pairViewOpen && onScreen);
    }

    // ---- this PC's code ---------------------------------------------------

    private async Task LoadPairingInfoAsync()
    {
        QrProgress.Visibility = Visibility.Visible;
        CopyPairingButton.IsEnabled = false;
        PairingName.Text = host.Engine.DeviceName;
        _ = ShowOwnAddressesAsync();
        try
        {
            // Looks up the Tailscale address afresh (runs its CLI).
            string payload = await host.Engine.GetPairingPayloadAsync();
            byte[] png = await Task.Run(() => MakeQr(payload));
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(png.AsBuffer());
            stream.Seek(0);
            var image = new BitmapImage();
            await image.SetSourceAsync(stream);
            pairingPayload = payload;
            QrImage.Source = image;
            CopyPairingButton.IsEnabled = true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't make the pairing code: {ex.Message}");
            App.MainAppWindow.ToastError("Couldn't make the pairing code", ex.Message);
        }
        finally
        {
            QrProgress.Visibility = Visibility.Collapsed;
        }
    }

    // "This PC's address: ..." under Pair by address - what to type into
    // the other device when pairing that way from there.
    private async Task ShowOwnAddressesAsync()
    {
        var addresses = await Task.Run(LanAddresses);
        if (host.Engine.TailscaleAddress is { } tailscale && !addresses.Contains(tailscale)) addresses.Add(tailscale);
        OwnAddresses.Text = addresses.Count == 0 ? ""
            : $"This PC's {(addresses.Count == 1 ? "address is" : "addresses are")} {string.Join(" · ", addresses)} - enter {(addresses.Count == 1 ? "it" : "one")} on the other device to pair from there.";
        OwnAddresses.Visibility = addresses.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    // This PC's IPv4 addresses on the networks it's really on: adapters that
    // are up and have a default gateway (so not Hyper-V/WSL's internal
    // switches or the loopback), link-local ones left out.
    private static List<string> LanAddresses()
    {
        var found = new List<string>();
        try
        {
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up
                    || nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                var ip = nic.GetIPProperties();
                if (!ip.GatewayAddresses.Any(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
                    && !g.Address.Equals(System.Net.IPAddress.Any))) continue;
                foreach (var unicast in ip.UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                    byte[] b = address.GetAddressBytes();
                    if (b[0] == 169 && b[1] == 254) continue;
                    string text = address.ToString();
                    if (!found.Contains(text)) found.Add(text);
                }
            }
        }
        catch (System.Net.NetworkInformation.NetworkInformationException ex)
        {
            Console.WriteLine($"[app] couldn't list this PC's addresses: {ex.Message}");
        }
        return found;
    }

    // QRCoder's PNG writer needs no System.Drawing. Error correction M, as
    // on Android: the payload is long, and Q's denser code is harder for a
    // phone to read off a screen.
    private static byte[] MakeQr(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        return new PngByteQRCode(data).GetGraphic(8);
    }

    // Side by side when there's room, the text under the code when not.
    private void LayOutQrCard(double width)
    {
        bool narrow = width < 480;
        Grid.SetRow(QrText, narrow ? 1 : 0);
        Grid.SetColumn(QrText, narrow ? 0 : 1);
        Grid.SetColumnSpan(QrText, narrow ? 2 : 1);
        QrText.Margin = narrow ? new Thickness(0, 16, 0, 0) : new Thickness(24, 4, 0, 0);
    }

    private void CopyPairingInfo_Click(object sender, RoutedEventArgs e)
    {
        if (pairingPayload == null) return;
        if (host.CopyText(pairingPayload)) App.MainAppWindow.Toast("Pairing info copied");
        else App.MainAppWindow.ToastError("Couldn't copy", "Another app is using the clipboard. Try again.");
    }

    // ---- pair by address ----------------------------------------------------

    private void AddressBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            Connect_Click(sender, e);
        }
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (pairing) return;
        string address = AddressBox.Text.Trim();
        if (address.Length == 0)
        {
            ShowResult(InfoBarSeverity.Warning, "Enter an address first.", "The other device's IP address, or its pairing info.");
            AddressBox.Focus(FocusState.Programmatic);
            return;
        }
        pairing = true;
        ConnectButton.IsEnabled = false;
        Connecting.Visibility = Visibility.Visible;
        PairResult.IsOpen = false;
        try
        {
            // Never throws; up to ~20 s when nothing answers.
            var outcome = await host.Engine.PairByAddressAsync(address);
            Console.WriteLine($"[app] pair by address: {outcome}");
            var (severity, title, message) = Describe(outcome);
            ShowResult(severity, title, message);
        }
        finally
        {
            pairing = false;
            ConnectButton.IsEnabled = true;
            Connecting.Visibility = Visibility.Collapsed;
        }
    }

    private static (InfoBarSeverity, string, string) Describe(PairOutcome outcome) => outcome switch
    {
        PairOutcome.Connected => (InfoBarSeverity.Success, "Connected.",
            "That device was already paired - it's syncing now."),
        PairOutcome.PairedByPasscode => (InfoBarSeverity.Success, "Paired.",
            "Both devices have the same passcode, so they trust each other. Syncing now."),
        PairOutcome.Pending => (InfoBarSeverity.Informational, "Found it.",
            "Accept the pairing request here, and on the other device too."),
        PairOutcome.Busy => (InfoBarSeverity.Warning, "Another request is waiting.",
            "Accept or reject that one first, then try again."),
        PairOutcome.Refused => (InfoBarSeverity.Error, "The other device said no.",
            "Open its pairing screen too (or give both the same passcode), then try again."),
        PairOutcome.Unreachable => (InfoBarSeverity.Error, "Nothing answered.",
            "Check the address, that ClipLink is running there, and that both devices are on the same network or on Tailscale."),
        PairOutcome.InvalidAddress => (InfoBarSeverity.Error, "That isn't an address.",
            "Enter an IP address or host name (a port after a colon if it isn't 49000), or paste the other device's pairing info."),
        PairOutcome.ThisDevice => (InfoBarSeverity.Warning, "That's this PC.",
            "Enter the other device's address."),
        _ => (InfoBarSeverity.Error, "ClipLink isn't syncing right now.",
            "See the message at the top of the page."),
    };

    private void ShowResult(InfoBarSeverity severity, string title, string message)
    {
        PairResult.Severity = severity;
        PairResult.Title = title;
        PairResult.Message = message;
        PairResult.IsOpen = true;
        // It can be below the fold on a small window.
        PairResult.StartBringIntoView();
    }

    // ---- device rows --------------------------------------------------------

    private static DeviceRow? RowOf(object sender) => (sender as FrameworkElement)?.DataContext as DeviceRow;

    private void CopyId_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        CopyId(row);
    }

    private void CopyId(DeviceRow row)
    {
        if (host.CopyText(row.PublicKey)) App.MainAppWindow.Toast("Device ID copied");
        else App.MainAppWindow.ToastError("Couldn't copy", "Another app is using the clipboard. Try again.");
    }

    // Right-click or Shift+F10 on a row.
    private void Device_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (RowOf(sender) is not { } row) return;
        var copy = new MenuFlyoutItem { Text = "Copy device ID", Icon = new SymbolIcon(Symbol.Copy) };
        copy.Click += (_, _) => CopyId(row);
        var flyout = new MenuFlyout();
        flyout.Items.Add(copy);
        if (args.TryGetPosition(sender, out var position)) flyout.ShowAt(sender, new FlyoutShowOptions { Position = position });
        else flyout.ShowAt((FrameworkElement)sender);
        args.Handled = true;
    }

    private void Trust_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        if (host.Engine.TrustDevice(row.PublicKey))
            App.MainAppWindow.Toast($"{row.Title} is trusted", $"It connects once {row.Title} trusts this PC too.");
    }

    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        string name = row.Title;
        bool confirmed = await App.MainAppWindow.ConfirmAsync($"Remove {name}?",
            $"This PC stops syncing with {name} and won't trust it any more. To sync again, pair them again.",
            "Remove");
        if (!confirmed) return;
        host.Engine.UntrustDevice(row.PublicKey);
        App.MainAppWindow.Toast($"Removed {name}");
    }
}
