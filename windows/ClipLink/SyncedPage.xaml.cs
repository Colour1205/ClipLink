using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Wpf.Ui.Controls;

namespace ClipLink;

// The synced history as cards, newest first - text, images and files from
// every paired device and this PC - in a list or a grid, as on the phones.
// Copy / Open / Delete on each; selecting a card shows it in full (all of
// its text, the image as big as fits), as tapping one does on the phones.
public partial class SyncedPage : Page
{
    private readonly EngineHost host = App.Host;
    // The card shown in full, if any.
    private HistoryCard? detail;
    private Window? window;

    // A text is shown in full up to this long (Copy copies all of it).
    private const int MaxDetailChars = 100_000;

    public SyncedPage()
    {
        InitializeComponent();
        DataContext = host;
        StatusBanner.TrackEngine(host);
        host.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(EngineHost.HasPasscode)) UpdatePasscodeTip();
        };
        // Deleted (here or by "Clear synced history") or trimmed away while
        // it's open: back to the list.
        host.History.CollectionChanged += (_, _) =>
        {
            if (detail != null && !host.History.Contains(detail)) ShowList();
        };
        Loaded += (_, _) =>
        {
            // At the window, so Escape works even while nothing on the page
            // has keyboard focus (as when the tray icon has just opened it).
            window = Window.GetWindow(this);
            if (window != null)
            {
                window.KeyDown += Window_KeyDown;
                window.MouseUp += Window_MouseUp;
            }
        };
        Unloaded += (_, _) =>
        {
            if (window != null)
            {
                window.KeyDown -= Window_KeyDown;
                window.MouseUp -= Window_MouseUp;
            }
            // Navigated to another page: back to the cards for next time.
            ShowList();
        };
        // A whole image fits in the view, under the buttons.
        DetailView.SizeChanged += (_, e) => DetailImage.MaxHeight = Math.Max(160, e.NewSize.Height - 120);
        ShowAsGrid(App.Settings.SyncedGridView);
        UpdatePasscodeTip();
    }

    // Escape, Alt+Left or the mouse's back button: from one item back to
    // the cards. Not a key pressed in a dialog (dialogs aren't on the page).
    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        bool back = e.Key == Key.Escape || (e.Key == Key.System && e.SystemKey == Key.Left && Keyboard.Modifiers == ModifierKeys.Alt);
        if (!back || e.Handled || detail == null || !IsVisible) return;
        if (e.OriginalSource == window || (e.OriginalSource is DependencyObject source && IsAncestorOf(source)))
        {
            ShowList();
            e.Handled = true;
        }
    }

    private void Window_MouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.XButton1 || detail == null || !IsVisible) return;
        ShowList();
        e.Handled = true;
    }

    // ---- list or grid ----------------------------------------------------------

    private void ShowAsGrid(bool grid)
    {
        Cards.ItemsPanel = (ItemsPanelTemplate)FindResource(grid ? "GridPanel" : "ListPanel");
        Cards.ItemTemplate = (DataTemplate)FindResource(grid ? "GridCard" : "ListCard");
        // (Raises ViewButton_Checked, which then has nothing to change.)
        (grid ? GridViewButton : ListViewButton).IsChecked = true;
    }

    private void ViewButton_Checked(object sender, RoutedEventArgs e)
    {
        bool grid = sender == GridViewButton;
        if (Cards.ItemTemplate == FindResource(grid ? "GridCard" : "ListCard")) return;
        ShowAsGrid(grid);
        App.Settings.SyncedGridView = grid;
        App.Settings.Save();
    }

    private void UpdatePasscodeTip() =>
        PasscodeTip.Visibility = host.HasPasscode || App.Settings.PasscodeTipDismissed ? Visibility.Collapsed : Visibility.Visible;

    private void PasscodeTip_Action(object sender, RoutedEventArgs e) => App.MainAppWindow.Navigate(typeof(SettingsPage));

    private void PasscodeTip_Closed(object sender, RoutedEventArgs e)
    {
        App.Settings.PasscodeTipDismissed = true;
        App.Settings.Save();
        UpdatePasscodeTip();
    }

    private static HistoryCard? CardOf(object sender) => (sender as FrameworkElement)?.DataContext as HistoryCard;

    // ---- a card -------------------------------------------------------------

    // A click on the card itself (its buttons handle their own clicks).
    private void Card_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (CardOf(sender) is { } card) ShowDetail(card);
    }

    private void Card_KeyDown(object sender, KeyEventArgs e)
    {
        // Only when the card itself has focus, not one of its buttons.
        if (e.OriginalSource != sender || e.Key is not (Key.Enter or Key.Space)) return;
        if (CardOf(sender) is { } card)
        {
            e.Handled = true;
            ShowDetail(card);
        }
    }

    private void View_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) ShowDetail(card);
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) Copy(card);
    }

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) await OpenAsync(card, showInFolder: false);
    }

    private async void ShowInFolder_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) await OpenAsync(card, showInFolder: true);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) await DeleteAsync(card);
    }

    // ---- one item in full ------------------------------------------------------

    private void ShowDetail(HistoryCard card)
    {
        if (detail != null) detail.PropertyChanged -= Detail_PropertyChanged;
        detail = card;
        card.PropertyChanged += Detail_PropertyChanged;

        DetailKind.Text = card.KindText;
        DetailOrigin.Text = card.Origin;
        DetailText.Visibility = card.IsImage || card.IsFile ? Visibility.Collapsed : Visibility.Visible;
        DetailImage.Visibility = card.IsImage ? Visibility.Visible : Visibility.Collapsed;
        DetailFile.Visibility = card.IsFile ? Visibility.Visible : Visibility.Collapsed;
        DetailFile.Content = card.IsFile ? card : null;
        DetailText.Text = "";
        DetailImage.Source = null;
        if (card.IsImage)
        {
            _ = LoadDetailImageAsync(card);
        }
        else if (!card.IsFile)
        {
            // All of it - the card only had the first 1000 characters.
            string text = card.IsText ? host.Engine.GetText(card.Key) ?? card.Text ?? "" : card.Text ?? "";
            DetailText.Text = text.Length > MaxDetailChars ? text[..MaxDetailChars] : text;
        }
        UpdateDetail();

        ListTitle.Visibility = ListSubtitle.Visibility = ViewSwitch.Visibility = CardsView.Visibility = Visibility.Collapsed;
        DetailTitle.Visibility = DetailOrigin.Visibility = DetailView.Visibility = Visibility.Visible;
        DetailView.ScrollToTop();
        // Keyboard users land on the first action.
        Dispatcher.BeginInvoke(() => (DetailCopy.IsVisible ? DetailCopy : (Control)DetailDelete).Focus(),
            System.Windows.Threading.DispatcherPriority.Loaded);
    }

    // Back to the cards, with the one that was open focused again.
    private void ShowList()
    {
        if (detail is not { } card) return;
        card.PropertyChanged -= Detail_PropertyChanged;
        detail = null;
        DetailText.Text = "";
        DetailImage.Source = null;
        DetailFile.Content = null;

        DetailTitle.Visibility = DetailOrigin.Visibility = DetailView.Visibility = Visibility.Collapsed;
        ListTitle.Visibility = ListSubtitle.Visibility = ViewSwitch.Visibility = CardsView.Visibility = Visibility.Visible;
        Dispatcher.BeginInvoke(() =>
        {
            if (Cards.ItemContainerGenerator.ContainerFromItem(card) is ListBoxItem item && IsVisible) item.Focus();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    // A file's bytes arriving, a device's new name, ...
    private void Detail_PropertyChanged(object? sender, PropertyChangedEventArgs e) => UpdateDetail();

    private void UpdateDetail()
    {
        if (detail is not { } card) return;
        DetailOrigin.Text = card.Origin;
        DetailCopy.Visibility = card.CanCopy ? Visibility.Visible : Visibility.Collapsed;
        DetailOpen.Visibility = DetailShowInFolder.Visibility = card.CanOpen ? Visibility.Visible : Visibility.Collapsed;
        DetailFacts.Text = card.IsImage ? card.ImageDetail
            : card.IsFile ? ""
            : card.IsText ? Format.Count(card.Item.TextLength, "character", "characters")
                + (card.Item.TextLength > MaxDetailChars ? $" - showing the first {MaxDetailChars:N0}. Copy copies all of it." : "")
            : "";
        DetailFacts.Visibility = DetailFacts.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task LoadDetailImageAsync(HistoryCard card)
    {
        // The card's thumbnail at once, then the full-size decode.
        DetailImage.Source = card.Thumbnail;
        var image = await host.LoadImageAsync(card.Key);
        if (detail == card && image != null) DetailImage.Source = image;
    }

    private void BackToList_Click(object sender, RoutedEventArgs e) => ShowList();

    private void DetailCopy_Click(object sender, RoutedEventArgs e)
    {
        if (detail is { } card) Copy(card);
    }

    private async void DetailOpen_Click(object sender, RoutedEventArgs e)
    {
        if (detail is { } card) await OpenAsync(card, showInFolder: false);
    }

    private async void DetailShowInFolder_Click(object sender, RoutedEventArgs e)
    {
        if (detail is { } card) await OpenAsync(card, showInFolder: true);
    }

    private async void DetailDelete_Click(object sender, RoutedEventArgs e)
    {
        if (detail is { } card) await DeleteAsync(card);
    }

    // ---- the actions ------------------------------------------------------------

    private void Copy(HistoryCard card)
    {
        if (host.IsFaulted)
        {
            // Its clipboard watcher (which does the copying) isn't running.
            App.MainAppWindow.ToastError("Can't copy right now", "ClipLink isn't running - see the message at the top.");
            return;
        }
        // Through the engine, never straight from here: its clipboard
        // watcher then knows the copy came from ClipLink and doesn't send
        // it back out as something new.
        if (host.Engine.CopyToClipboard(card.Key))
            App.MainAppWindow.Toast("Copied to the clipboard");
        else
            App.MainAppWindow.ToastError("Couldn't copy that", card.IsFile ? "The file hasn't arrived on this PC." : "It's no longer in the synced history.");
    }

    private async Task DeleteAsync(HistoryCard card)
    {
        bool confirmed = await App.MainAppWindow.ConfirmAsync("Delete this item?",
            "It's deleted from this PC, and won't come back from your other devices. They keep their own copies.",
            "Delete");
        if (confirmed && !host.Engine.DeleteHistoryEntry(card.Key))
        {
            App.MainAppWindow.ToastError("It was already gone");
        }
    }

    private async Task OpenAsync(HistoryCard card, bool showInFolder)
    {
        var window = App.MainAppWindow;
        string? path;
        try
        {
            // The first open copies the file out of ClipLink's store - maybe
            // a big one, so not on the UI thread.
            path = await Task.Run(() =>
            {
                string? copy = host.Engine.GetFileToOpen(card.Key);
                if (copy != null) FileOpener.MarkAsFromElsewhere(copy);
                return copy;
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't prepare a file to open: {ex.Message}");
            window.ToastError("Couldn't open it", ex.Message);
            return;
        }
        if (path == null)
        {
            window.ToastError("Couldn't open it", "The file hasn't arrived on this PC.");
            return;
        }

        if (!showInFolder && FileOpener.IsProgram(path))
        {
            // Opening a program or script runs it - never without asking.
            var dialog = new ContentDialog(window.DialogHost)
            {
                Title = $"Open {Path.GetFileName(path)}?",
                Content = new System.Windows.Controls.TextBlock
                {
                    // (The source ends the clause, not the sentence: a short id ends in "…".)
                    Text = $"It's a program or script from {(card.Item.FromThisDevice ? "this PC" : card.Source)} - opening it runs it on this PC. Only do that if you trust it.",
                    TextWrapping = TextWrapping.Wrap,
                    Style = (Style)FindResource("BodyText"),
                },
                PrimaryButtonText = "Open",
                // Not the accent colour: opening isn't the suggested choice here.
                PrimaryButtonAppearance = ControlAppearance.Secondary,
                SecondaryButtonText = "Show in folder",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            var choice = await window.ShowDialogAsync(dialog);
            if (choice == ContentDialogResult.None) return;
            showInFolder = choice == ContentDialogResult.Secondary;
        }

        try
        {
            if (showInFolder) FileOpener.ShowInFolder(path);
            else Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or IOException)
        {
            // e.g. no app is set up for this kind of file.
            Console.WriteLine($"[app] couldn't open {path}: {ex.Message}");
            window.ToastError("Couldn't open it", ex.Message);
        }
    }
}

// Picks a history card's content template by its kind.
public sealed class HistoryContentSelector : DataTemplateSelector
{
    public DataTemplate? TextTemplate { get; set; }
    public DataTemplate? ImageTemplate { get; set; }
    public DataTemplate? FileTemplate { get; set; }

    public override DataTemplate? SelectTemplate(object item, DependencyObject container) => item switch
    {
        HistoryCard { IsImage: true } => ImageTemplate,
        HistoryCard { IsFile: true } => FileTemplate,
        _ => TextTemplate,
    };
}
