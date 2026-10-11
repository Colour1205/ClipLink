using System.Runtime.InteropServices;
using ClipboardDaemon.Engine;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using WinRT.Interop;

namespace ClipLink;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);

    private readonly EngineHost host;
    private readonly nint hwnd;
    private bool isActive;
    // Only one dialog at a time: a new one replaces whatever is showing.
    private ContentDialog? openDialog;
    // The Trust/Ignore prompt showing now, and whose request it is.
    private (string DeviceId, ContentDialog Dialog)? pairingPrompt;
    // The same prompt as a notification, for when the window isn't in front.
    private readonly PairingNotifications notifications;

    internal MainWindow(EngineHost host)
    {
        this.host = host;
        InitializeComponent();
        hwnd = WindowNative.GetWindowHandle(this);

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        Root.RequestedTheme = App.ThemeOverride;
        AppWindow.SetIcon(AppIcon.Path);
        AppTitleBar.IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri(AppIcon.Path)) { DecodePixelWidth = 32 } };
        if (!App.Options.IsDefaultLabel)
        {
            // A test copy - make it obvious which one this is.
            Title = AppTitleBar.Title = $"ClipLink ({App.Options.Label})";
        }
        SetSize();

        // The close button only hides the window (ClipLink keeps syncing
        // from the tray); Quit really closes it.
        AppWindow.Closing += (_, e) =>
        {
            if (!App.IsQuitting)
            {
                e.Cancel = true;
                AppWindow.Hide();
            }
        };
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidVisibilityChange || e.DidPresenterChange) OnScreenChanged?.Invoke();
        };
        Activated += (_, e) =>
        {
            isActive = e.WindowActivationState != WindowActivationState.Deactivated;
            // Brought to the front (by the notification, or by hand) with a
            // request still waiting: it is a dialog now.
            if (isActive) ShowPendingPairing();
        };

        notifications = new PairingNotifications((answer, deviceId) => DispatcherQueue.TryEnqueue(() => OnNotificationAnswered(answer, deviceId)));
        notifications.Register();
        host.PairingRequested += OnPairingRequested;
        host.PairingResolved += OnPairingResolved;
        RootNavigation.IsPaneOpen = !App.Settings.NavPaneCollapsed;
        UpdateToastMargin();
        RootNavigation.SelectedItem = RootNavigation.MenuItems[0];
    }

    // Open (icons and labels) or collapsed to icons only: remembered.
    private void RootNavigation_PaneChanged(NavigationView sender, object args)
    {
        UpdateToastMargin();
        if (App.Settings.NavPaneCollapsed == !sender.IsPaneOpen) return;
        App.Settings.NavPaneCollapsed = !sender.IsPaneOpen;
        App.Settings.Save();
    }

    // Toasts sit centred under the content, not under the pane.
    private void UpdateToastMargin() =>
        ToastHost.Margin = new Thickness(RootNavigation.IsPaneOpen ? RootNavigation.OpenPaneLength : RootNavigation.CompactPaneLength, 0, 0, 16);

    // 960 x 680 (in device-independent pixels), in the middle of the screen
    // it opens on.
    private void SetSize()
    {
        double scale = GetDpiForWindow(hwnd) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        int width = Math.Min((int)(960 * scale), area.Width);
        int height = Math.Min((int)(680 * scale), area.Height);
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(560 * scale);
            presenter.PreferredMinimumHeight = (int)(480 * scale);
        }
    }

    // On the screen and not minimised: what pairing mode needs to know.
    public bool IsOnScreen => AppWindow.IsVisible
        && AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };

    // ... and also the window in front of the others.
    public bool IsInFront => IsOnScreen && isActive;

    public event Action? OnScreenChanged;

    // Brings the window to the front, from the tray or a second launch.
    public void Present()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        AppWindow.Show();
        Activate();
        SetForegroundWindow(hwnd);
    }

    // ---- pages ----------------------------------------------------------------

    private void RootNavigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        Type? page = (args.SelectedItemContainer?.Tag as string) switch
        {
            "synced" => typeof(SyncedPage),
            "devices" => typeof(DevicesPage),
            "settings" => typeof(SettingsPage),
            _ => null,
        };
        if (page != null && ContentFrame.CurrentSourcePageType != page) ContentFrame.Navigate(page);
    }

    public void Navigate(Type page)
    {
        string tag = page == typeof(DevicesPage) ? "devices" : page == typeof(SettingsPage) ? "settings" : "synced";
        foreach (var item in RootNavigation.MenuItems.Concat(RootNavigation.FooterMenuItems).OfType<NavigationViewItem>())
        {
            if ((item.Tag as string) == tag) RootNavigation.SelectedItem = item;
        }
    }

    // ---- toasts and dialogs -----------------------------------------------------

    // A short message at the bottom of the window.
    public void Toast(string title, string? message = null, InfoBarSeverity severity = InfoBarSeverity.Success)
    {
        var bar = new InfoBar
        {
            Title = title,
            Message = message ?? "",
            Severity = severity,
            IsOpen = true,
            IsClosable = false,
            MaxWidth = 560,
            Margin = new Thickness(0, 8, 0, 0),
        };
        ToastHost.Children.Add(bar);
        while (ToastHost.Children.Count > 3) ToastHost.Children.RemoveAt(0);

        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(message == null ? 3 : 6);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => ToastHost.Children.Remove(bar);
        timer.Start();
    }

    public void ToastError(string title, string? message = null) => Toast(title, message, InfoBarSeverity.Error);

    public async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        dialog.XamlRoot = Root.XamlRoot;
        dialog.RequestedTheme = Root.RequestedTheme;
        openDialog?.Hide();
        openDialog = dialog;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            if (openDialog == dialog) openDialog = null;
        }
    }

    // "Delete this item?" and the like. True if confirmed.
    public async Task<bool> ConfirmAsync(string title, string message, string confirmText)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = Paragraph(message),
            PrimaryButtonText = confirmText,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await ShowDialogAsync(dialog) == ContentDialogResult.Primary;
    }

    internal static TextBlock Paragraph(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
    };

    // ---- pairing requests -------------------------------------------------------

    // A request from any device on the network, at any time. In front: a dialog
    // over whatever page is open. Otherwise a notification with Trust and
    // Ignore - the window is not forced up. Never a page of its own.
    private async void OnPairingRequested(PendingPairing pending)
    {
        if (pairingPrompt?.DeviceId == pending.DeviceId) return; // already asking
        if (IsInFront)
        {
            await AskAboutPairingAsync(pending);
            return;
        }
        if (!notifications.Show(pending))
        {
            // No notifications here: bring the window up so it can be answered.
            if (!IsOnScreen) App.Instance.ShowMainWindow();
            await AskAboutPairingAsync(pending);
        }
    }

    // The window came to the front with a request waiting (its notification
    // may have been clicked, or ignored): ask here instead.
    private async void ShowPendingPairing()
    {
        if (pairingPrompt != null) return;
        if (host.Engine.GetPendingPairing() is not { } pending) return;
        await AskAboutPairingAsync(pending);
    }

    private async Task AskAboutPairingAsync(PendingPairing pending)
    {
        if (pairingPrompt?.DeviceId == pending.DeviceId) return;
        // Being asked here, so the notification for it goes.
        notifications.Remove();

        string name = DeviceLabel.Of(pending.DeviceId, pending.Name);
        // Where it's asking from, as the phones say it.
        string from = pending.Address != null ? $"{name} at {pending.Address}" : name;
        // The name is whatever that device chose; its fingerprint comes from
        // its id, and it shows the same one for itself (as this PC does in
        // Settings), so a copied name can't pass for a device you know.
        var fingerprint = Paragraph(
            $"ID {DeviceLabel.Fingerprint(pending.DeviceId)} - check that it matches the fingerprint that device shows for itself (in Settings on a PC, on the Me tab on a phone).");
        fingerprint.Margin = new Thickness(0, 12, 0, 0);

        var dialog = new ContentDialog
        {
            Title = $"Pair with {name}?",
            Content = new StackPanel
            {
                Children =
                {
                    Paragraph($"{from} wants to pair with this PC. Only trust it if you're pairing it right now."),
                    fingerprint,
                },
            },
            // Trust or Ignore, and only those: Ignore closes this one request
            // and remembers nothing, so the device can ask again. Blocking is
            // a deliberate act on the Devices page, not something to do by
            // accident from a prompt.
            PrimaryButtonText = "Trust",
            CloseButtonText = "Ignore",
            // Enter doesn't pair by accident.
            DefaultButton = ContentDialogButton.Close,
        };
        pairingPrompt = (pending.DeviceId, dialog);
        var result = await ShowDialogAsync(dialog);
        if (pairingPrompt?.Dialog != dialog)
        {
            return; // resolved elsewhere (OnPairingResolved closed it)
        }
        pairingPrompt = null;

        if (result == ContentDialogResult.Primary)
        {
            // (It may have trusted this PC already, or not yet.)
            if (host.Engine.AcceptPairing())
                Toast($"Trusted {name}", $"Syncing starts once {name} trusts this PC too.");
            else
                ToastError("That pairing request has gone", "The other device may have cancelled it. Try again from both devices.");
        }
        else
        {
            host.Engine.RejectPairing();
        }
    }

    private void OnPairingResolved(string deviceId, PairingDecision decision)
    {
        // Settled - here, from the notification, by expiry or by blocking: the
        // dialog and the notification both go.
        notifications.Remove();
        if (pairingPrompt is { } prompt && prompt.DeviceId == deviceId)
        {
            pairingPrompt = null;
            prompt.Dialog.Hide();
        }
    }

    // A button (or the body) of the notification was clicked. Each button names
    // the request it was posted for, and acts only if that is still the one
    // waiting: a stale one can't answer whoever asked next.
    private void OnNotificationAnswered(PairingNotifications.Answer answer, string? deviceId)
    {
        if (answer == PairingNotifications.Answer.Open)
        {
            App.Instance.ShowMainWindow(); // the dialog follows once it is in front
            return;
        }
        if (host.Engine.GetPendingPairing()?.DeviceId != deviceId) return;
        if (answer == PairingNotifications.Answer.Trust) host.Engine.AcceptPairing();
        else host.Engine.RejectPairing();
    }
}
