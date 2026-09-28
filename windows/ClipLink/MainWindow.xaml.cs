using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using ClipboardDaemon.Engine;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
using TextBlock = System.Windows.Controls.TextBlock;

namespace ClipLink;

public partial class MainWindow : FluentWindow
{
    private readonly EngineHost host;
    // Only one dialog at a time: a new one replaces whatever is showing.
    private ContentDialog? openDialog;
    // The Accept/Reject prompt showing now, and whose request it is.
    private (string DeviceId, ContentDialog Dialog)? pairingPrompt;

    internal MainWindow(EngineHost host)
    {
        this.host = host;
        InitializeComponent();
        TitleBarIcon.Source = AppIcon.TitleBar;
        if (!App.Options.IsDefaultLabel)
        {
            // A test copy - make it obvious which one this is.
            Title = AppTitleBar.Title = $"ClipLink ({App.Options.Label})";
        }
        if (App.Options.Theme == null)
        {
            // Light/dark and the accent colour follow Windows, live.
            SystemThemeWatcher.Watch(this, WindowBackdropType.Mica, updateAccents: true);
        }

        host.PairingRequested += OnPairingRequested;
        host.PairingResolved += OnPairingResolved;
        Loaded += (_, _) => RootNavigation.Navigate(typeof(SyncedPage));
    }

    public bool Navigate(Type page) => RootNavigation.Navigate(page);

    // A short message at the bottom of the window.
    public void Toast(string title, string? message = null, ControlAppearance appearance = ControlAppearance.Secondary,
        SymbolRegular icon = SymbolRegular.CheckmarkCircle24)
    {
        var snackbar = new Snackbar(Snackbars)
        {
            // Our type ramp (Body Strong / Body) rather than the control's 16 px title.
            Title = new TextBlock { Text = title, Style = (Style)FindResource("BodyStrongText"), TextWrapping = TextWrapping.Wrap },
            Content = message == null ? null
                : new TextBlock { Text = message, Style = (Style)FindResource("BodyText"), TextWrapping = TextWrapping.Wrap },
            Appearance = appearance,
            Icon = new SymbolIcon(icon) { Filled = true, FontSize = 20 },
            Timeout = TimeSpan.FromSeconds(message == null ? 3 : 6),
        };
        if (message == null) snackbar.MinHeight = 0; // one line: no empty second row
        snackbar.Show(true);
    }

    public void ToastError(string title, string? message = null) =>
        Toast(title, message, ControlAppearance.Danger, SymbolRegular.ErrorCircle24);

    public async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        openDialog?.Hide(ContentDialogResult.None);
        openDialog = dialog;
        try
        {
            return await dialog.ShowAsync(CancellationToken.None);
        }
        finally
        {
            if (openDialog == dialog) openDialog = null;
        }
    }

    // "Delete this item?" and the like. True if confirmed.
    public async Task<bool> ConfirmAsync(string title, string message, string confirmText)
    {
        var dialog = new ContentDialog(DialogHost)
        {
            Title = title,
            Content = Paragraph(message),
            PrimaryButtonText = confirmText,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await ShowDialogAsync(dialog) == ContentDialogResult.Primary;
    }

    private static TextBlock Paragraph(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.FindResource("BodyText"),
    };

    // ---- pairing requests -------------------------------------------------

    private async void OnPairingRequested(PendingPairing pending)
    {
        if (!host.PairingUiActive)
        {
            // Pairing was closed while this request was on its way (e.g. a
            // pair-by-address that finished after the window was hidden):
            // nobody is here to answer it - let it go.
            host.Engine.SetPairingMode(false);
            return;
        }
        if (pairingPrompt?.DeviceId == pending.DeviceId) return; // already asking

        string name = DeviceLabel.Of(pending.DeviceId, pending.Name);
        // Where it's asking from, as the phones say it. (No short device ID:
        // every device's starts with the same characters, so it tells you
        // nothing.)
        string from = pending.Address != null ? $"{name} at {pending.Address}" : name;

        var dialog = new ContentDialog(DialogHost)
        {
            Title = $"Pair with {name}?",
            Content = Paragraph($"{from} wants to pair with this PC. Only accept if you're pairing it right now."),
            PrimaryButtonText = "Accept",
            CloseButtonText = "Reject",
            // Enter doesn't pair by accident.
            DefaultButton = ContentDialogButton.Close,
        };
        pairingPrompt = (pending.DeviceId, dialog);
        if (!IsVisible) App.Instance.ShowMainWindow();
        var result = await ShowDialogAsync(dialog);
        if (pairingPrompt?.Dialog != dialog)
        {
            return; // resolved elsewhere (OnPairingResolved closed it)
        }
        pairingPrompt = null;

        if (result == ContentDialogResult.Primary)
        {
            // (It may have accepted this PC already, or not yet.)
            if (host.Engine.AcceptPairing())
                Toast($"Accepted {name}", $"If {name} is still asking, accept this PC there too - syncing starts once both have.");
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
        if (pairingPrompt is { } prompt && prompt.DeviceId == deviceId)
        {
            pairingPrompt = null;
            prompt.Dialog.Hide(ContentDialogResult.None);
        }
    }

    // ---- window ----------------------------------------------------------

    // The close button only hides the window (ClipLink keeps syncing from
    // the tray); Settings > Quit really closes it.
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!App.IsQuitting)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }
}
