using System.Numerics;
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
// address. Opening it ends any quiet time for devices whose requests were
// ignored or removed (ClipLinkEngine.LiftRequestQuiet).
public sealed partial class DevicesPage : Page
{
    private readonly EngineHost host = App.Host;
    private bool pairViewOpen;
    private string? pairingPayload;
    private bool pairing; // a pair-by-address is in progress

    public DevicesPage()
    {
        InitializeComponent();
        zoom = new CardZoom(DetailZoom, DetailFill, DetailView, DeviceList, ListBackdrop, DetailCover, null);
        EngineBanner.Track(StatusBanner, host);
        WheelScroll.Attach(DeviceList);
        WheelScroll.Attach(PairView);
        PairTitle.ItemsSource = new[] { "Devices", "Add a device" };
        Loaded += (_, _) =>
        {
            // A device's detail view follows its row: renamed, connected,
            // blocked, gone.
            host.PairedDevices.CollectionChanged += Devices_Changed;
            host.NearbyDevices.CollectionChanged += Devices_Changed;
            host.BlockedDevices.CollectionChanged += Devices_Changed;
        };
        Unloaded += (_, _) =>
        {
            // Navigated to another page: back to the list.
            host.PairedDevices.CollectionChanged -= Devices_Changed;
            host.NearbyDevices.CollectionChanged -= Devices_Changed;
            host.BlockedDevices.CollectionChanged -= Devices_Changed;
            CloseDetail();
            zoom.Finish(); // one still closing
            ShowPairView(false);
        };
        QrCard.SizeChanged += (_, e) => LayOutQrCard(e.NewSize.Width);
    }

    private void Escape_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (detailKey != null)
        {
            CloseDetail(animate: true);
            args.Handled = true;
            return;
        }
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
            // A device still zooming back is put away first: the list it was
            // landing on is about to be hidden under the pairing view.
            if (open) zoom.Finish();
            pairViewOpen = open;
            DeviceList.Visibility = ListTitle.Visibility = AddDeviceButton.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
            PairView.Visibility = PairTitle.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
            if (open)
            {
                host.Engine.LiftRequestQuiet();
                PairView.ChangeView(null, 0, null, disableAnimation: true);
                _ = LoadPairingInfoAsync();
                // After the view has been laid out: a control that has only
                // just become visible can't take focus yet.
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                    () => AddressBox.Focus(FocusState.Programmatic));
            }
            else
            {
                PairResult.IsOpen = false;
            }
        }
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
            // The code is a link to the website's /pair page with the pairing
            // info in it (see PairingLink): a phone's own scanner opens its
            // ClipLink app, or the website when it has none. Copy still copies
            // the bare info.
            byte[] png = await Task.Run(() => MakeQr(PairingLink.Wrap(payload)));
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
        if (!host.CopyText(pairingPayload)) App.MainAppWindow.ToastError("Couldn't copy", "Another app is using the clipboard. Try again.");
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
            "Trust the pairing request here, and on the other device too."),
        PairOutcome.Busy => (InfoBarSeverity.Warning, "Another request is waiting.",
            "Trust or ignore that one first, then try again."),
        PairOutcome.Refused => (InfoBarSeverity.Error, "The other device said no.",
            "It may have blocked this PC. Otherwise try again, or give both devices the same passcode."),
        PairOutcome.Unreachable => (InfoBarSeverity.Error, "Nothing answered.",
            "Check the address, that ClipLink is running there, and that both devices are on the same network or on Tailscale."),
        PairOutcome.InvalidAddress => (InfoBarSeverity.Error, "That isn't an address.",
            "Enter an IP address or host name (a port after a colon if it isn't 49000), or paste the other device's pairing info."),
        PairOutcome.ThisDevice => (InfoBarSeverity.Warning, "That's this PC.",
            "Enter the other device's address."),
        PairOutcome.Blocked => (InfoBarSeverity.Warning, "That device is blocked.",
            "Unblock it on the Devices page first."),
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

    private void CopyId(DeviceRow row)
    {
        if (!host.CopyText(row.PublicKey)) App.MainAppWindow.ToastError("Couldn't copy", "Another app is using the clipboard. Try again.");
    }

    // The menu on a card's three dots, and on its right-click: block it (or,
    // for a blocked one, unblock it), and copy its id.
    private MenuFlyout MenuFor(DeviceRow row)
    {
        var flyout = new MenuFlyout();
        if (row.Blocked)
        {
            var unblock = new MenuFlyoutItem { Text = "Unblock", Icon = new FontIcon { Glyph = "\uE785" } };
            unblock.Click += (_, _) => Unblock(row);
            flyout.Items.Add(unblock);
        }
        else
        {
            var block = new MenuFlyoutItem { Text = "Block", Icon = new FontIcon { Glyph = "\uE72E" } };
            block.Click += async (_, _) => await BlockAsync(row);
            flyout.Items.Add(block);
        }
        flyout.Items.Add(new MenuFlyoutSeparator());
        var copy = new MenuFlyoutItem { Text = "Copy device ID", Icon = new SymbolIcon(Symbol.Copy) };
        copy.Click += (_, _) => CopyId(row);
        flyout.Items.Add(copy);
        return flyout;
    }

    private void More_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is not { } row) return;
        MenuFor(row).ShowAt((FrameworkElement)sender);
    }

    // Right-click or Shift+F10 on a row.
    private void Device_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (RowOf(sender) is not { } row) return;
        var flyout = MenuFor(row);
        if (args.TryGetPosition(sender, out var position)) flyout.ShowAt(sender, new FlyoutShowOptions { Position = position });
        else flyout.ShowAt((FrameworkElement)sender);
        args.Handled = true;
    }

    // A click anywhere on the card opens the device - except on one of its
    // own buttons, which do their own thing.
    private void Device_Tapped(object sender, TappedRoutedEventArgs e)
    {
        for (var element = e.OriginalSource as DependencyObject; element != null && !ReferenceEquals(element, sender); element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element))
        {
            if (element is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return;
        }
        if (RowOf(sender) is { } row) ShowDetail(row);
    }

    private void OpenDetail_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is { } row) ShowDetail(row);
    }

    // Blocking a trusted device also removes it, so that one asks first.
    private async Task BlockAsync(DeviceRow row)
    {
        string name = row.Title;
        if (row.Trusted)
        {
            bool confirmed = await App.MainAppWindow.ConfirmAsync($"Block {name}?",
                $"{name} is removed from your paired devices and stops syncing with this PC. It can't ask to pair again, and nothing from it is shown, until you unblock it.",
                "Block");
            if (!confirmed) return;
        }
        host.Engine.BlockDevice(row.PublicKey);
    }

    // (An unblocked device is not paired again: it has to pair like any other.)
    private void Unblock(DeviceRow row)
    {
        host.Engine.UnblockDevice(row.PublicKey);
    }

    // ---- one device in full -------------------------------------------------------

    private string? detailKey;
    private DeviceRow? detailRow;

    private DeviceRow? FindRow(string key) =>
        host.PairedDevices.Concat(host.NearbyDevices).Concat(host.BlockedDevices).FirstOrDefault(row => row.PublicKey == key);

    private void ShowDetail(DeviceRow row)
    {
        // Already open, or opening (a second click on it).
        if (detailKey == row.PublicKey) return;
        // One still closing is put away at once: the list takes taps while a
        // device closes, and the one tapped opens now.
        zoom.Finish();
        // The tapped card zooms into the detail view, as a Synced card does:
        // where it is, is taken now, while the list is still showing.
        var face = MotionPreference.Enabled ? CardOf(row.PublicKey) : null;
        var at = CardZoom.WindowRect(face);
        var listWas = CardZoom.LayoutOrigin(DeviceList);
        detailKey = row.PublicKey;
        // The header is the device's at once (nothing slides in). The list stays
        // on screen behind the card that grows, until the detail covers it.
        ListTitle.Visibility = AddDeviceButton.Visibility = Visibility.Collapsed;
        DetailTitle.Visibility = DetailZoom.Visibility = Visibility.Visible;
        RefreshDetail();
        DetailView.ChangeView(null, 0, null, disableAnimation: true);
        if (face == null || at is not { } from || !ZoomIn(face, from, listWas)) DeviceList.Visibility = Visibility.Collapsed;
        // Keyboard users land on the first action.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () => (DetailTrust.Visibility == Visibility.Visible ? DetailTrust : DetailBlock).Focus(FocusState.Programmatic));
    }

    // Back to the list: the detail zooms back onto its card (not when it is
    // the page being left or the device that went away). The list is back at
    // once and takes taps while it does: a device tapped meanwhile opens at once.
    private void CloseDetail(bool animate = false)
    {
        if (detailKey is not { } key) return;
        bool zoomBack = animate && MotionPreference.Enabled && !pairViewOpen && DetailZoom.ActualWidth > 0;
        // (Before the list is shown: an open still running would put it away as it ends.)
        if (!zoomBack) zoom.Finish();
        detailKey = null;
        if (detailRow != null) detailRow.PropertyChanged -= DetailRow_Changed;
        detailRow = null;
        var viewWas = CardZoom.LayoutOrigin(DetailZoom);
        DetailTitle.Visibility = Visibility.Collapsed;
        if (!pairViewOpen)
        {
            ListTitle.Visibility = AddDeviceButton.Visibility = DeviceList.Visibility = Visibility.Visible;
        }
        CardZoom.Nudge(DeviceList, Vector2.Zero);
        if (zoomBack)
        {
            zoom.Hold(() => DetailZoom.Visibility = Visibility.Collapsed);
            ZoomBack(key, viewWas);
        }
        else
        {
            DetailZoom.Visibility = Visibility.Collapsed;
        }
    }

    // ---- a card zooming into the detail view, and back -------------------------------

    private CardZoom zoom = null!;

    // A device card's first line is this far in from its top (its content's
    // padding), for the detail's first line to ride there as it zooms.
    private const double CardInset = 12;

    // The card on screen for a device, if it has one.
    private FrameworkElement? CardOf(string key)
    {
        if (FindRow(key) is not { } row) return null;
        foreach (var list in new[] { PairedList, NearbyList, BlockedList })
        {
            if (list.ContainerFromItem(row) is DependencyObject container && CardZoom.FindNamed(container, "CardFace") is { } face) return face;
        }
        return null;
    }

    // Starts the zoom out of the card, the detail now laid out over the list.
    // False when there is none.
    private bool ZoomIn(FrameworkElement face, ZoomMorph.Rect at, Vector2 listWas)
    {
        try
        {
            UpdateLayout();
            var origin = CardZoom.LayoutOrigin(DetailZoom);
            // The list stays where it was, though the header above it may have
            // changed height.
            CardZoom.Nudge(DeviceList, listWas - CardZoom.LayoutOrigin(DeviceList));
            var plan = new CardZoom.Plan(CardZoom.Relative(at, origin), face, CardInset, Vector2.Zero, null);
            bool zooming = zoom.Open(plan, () =>
            {
                // Covered by the detail now.
                DeviceList.Visibility = Visibility.Collapsed;
                CardZoom.Nudge(DeviceList, Vector2.Zero);
            });
            if (zooming) return true;
        }
        catch (Exception ex)
        {
            // Only the movement is lost.
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
        }
        CardZoom.Nudge(DeviceList, Vector2.Zero);
        return false;
    }

    // Shrinks the held detail back onto the device's card, once the list has
    // been laid out again (its cards are all made: it is not virtualized).
    // viewWas: where the detail was in the window before the header changed back.
    private void ZoomBack(string key, Vector2 viewWas)
    {
        try
        {
            UpdateLayout();
            var origin = CardZoom.LayoutOrigin(DetailZoom);
            var face = CardOf(key);
            ZoomMorph.Rect? at = CardZoom.WindowRect(face) is { } rect ? CardZoom.Relative(rect, origin) : null;
            // Not on screen (gone): toward the middle, fading.
            zoom.Shrink(new CardZoom.Plan(at, at != null ? face : null, CardInset, viewWas - origin, null));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
            zoom.Finish();
        }
    }

    private void DetailTitle_ItemClicked(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (args.Index == 0) CloseDetail(animate: true);
    }

    // A row can move between the lists (trusted, blocked) - a new row - or go
    // altogether (a discovered device that went quiet).
    private void Devices_Changed(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (detailKey != null) RefreshDetail();
    }

    private void DetailRow_Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (detailKey != null) RefreshDetail();
    }

    private void RefreshDetail()
    {
        if (detailKey is not { } key) return;
        if (FindRow(key) is not { } row)
        {
            CloseDetail(); // it left the list while its view was open
            return;
        }
        if (!ReferenceEquals(row, detailRow))
        {
            if (detailRow != null) detailRow.PropertyChanged -= DetailRow_Changed;
            detailRow = row;
            row.PropertyChanged += DetailRow_Changed;
        }

        DetailTitle.ItemsSource = new[] { "Devices", row.Title };
        DetailTrust.Visibility = row.CanTrust ? Visibility.Visible : Visibility.Collapsed;
        DetailRemove.Visibility = row.Trusted ? Visibility.Visible : Visibility.Collapsed;
        DetailBlock.Content = row.Blocked ? "Unblock" : "Block";

        // Every address it can be reached at; the one the live connection runs
        // over is marked.
        DetailAddresses.Children.Clear();
        foreach (string address in row.Addresses)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            line.Children.Add(new TextBlock
            {
                Text = address,
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
                IsTextSelectionEnabled = true,
                VerticalAlignment = VerticalAlignment.Center,
            });
            if (address == row.ConnectedAddress)
            {
                line.Children.Add(new TextBlock
                {
                    Text = "In use",
                    Style = (Style)Application.Current.Resources["CaptionSecondary"],
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            DetailAddresses.Children.Add(line);
        }
        DetailNoAddresses.Visibility = row.Addresses.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        // The fingerprint comes from the id, so it is the same on every device
        // that shows it - a name is whatever the device calls itself.
        DetailFacts.Text =
            $"Status: {row.Status}\n" +
            $"Name: {row.Listing.Name ?? "not known yet"}\n" +
            $"Fingerprint: {DeviceLabel.Fingerprint(row.PublicKey)}\n" +
            $"Device ID: {row.PublicKey}";
    }

    private void DetailTrust_Click(object sender, RoutedEventArgs e)
    {
        if (detailRow is { } row) Trust_Click(DetailTrust, e, row);
    }

    private async void DetailRemove_Click(object sender, RoutedEventArgs e)
    {
        if (detailRow is { } row) await RemoveAsync(row);
    }

    private async void DetailBlock_Click(object sender, RoutedEventArgs e)
    {
        if (detailRow is not { } row) return;
        if (row.Blocked) Unblock(row);
        else await BlockAsync(row);
    }

    private void DetailCopyId_Click(object sender, RoutedEventArgs e)
    {
        if (detailRow is { } row) CopyId(row);
    }

    private void Trust_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is { } row) Trust_Click(sender, e, row);
    }

    private void Trust_Click(object sender, RoutedEventArgs e, DeviceRow row)
    {
        // (It connects once it trusts this PC too; its row shows where it stands.)
        host.Engine.TrustDevice(row.PublicKey);
    }

    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is { } row) await RemoveAsync(row);
    }

    private async Task RemoveAsync(DeviceRow row)
    {
        string name = row.Title;
        bool confirmed = await App.MainAppWindow.ConfirmAsync($"Remove {name}?",
            $"This PC stops syncing with {name} and won't trust it any more. To sync again, pair them again.",
            "Remove");
        if (!confirmed) return;
        host.Engine.UntrustDevice(row.PublicKey);
    }
}
