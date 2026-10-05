using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace ClipLink;

// The synced history as cards, newest first - text, images and files from
// every paired device and this PC - in a list or a grid, as on the phones.
// Copy / Open / Delete on each; selecting a card shows it in full (all of
// its text, the image as big as fits), as tapping one does on the phones.
public sealed partial class SyncedPage : Page
{
    private readonly EngineHost host = App.Host;
    // The card shown in full, if any.
    private HistoryCard? detail;
    private bool wheelAttached;

    // A text is shown in full up to this long (Copy copies all of it).
    private const int MaxDetailChars = 100_000;

    public SyncedPage()
    {
        InitializeComponent();
        Cards.ItemsSource = host.History;
        EngineBanner.Track(StatusBanner, host);
        WheelScroll.Attach(DetailView);
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
        // Navigated to another page: back to the cards for next time.
        Unloaded += (_, _) => ShowList();
        // New items arrive at the top: the view must stay where it is, not
        // follow the card that used to be first (the default anchoring).
        Loaded += (_, _) =>
        {
            if (wheelAttached || Cards.ScrollView is not { } scroll) return;
            scroll.VerticalAnchorRatio = double.NaN;
            WheelScroll.Attach(scroll);
            wheelAttached = true;
        };
        ShowAsGrid(App.Settings.SyncedGridView);
        UpdatePasscodeTip();
    }

    // Escape, Alt+Left or the mouse's back button: from one item back to
    // the cards.
    private void Back_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (detail == null) return;
        ShowList();
        args.Handled = true;
    }

    private void Page_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (detail == null || !e.GetCurrentPoint(this).Properties.IsXButton1Pressed) return;
        ShowList();
        e.Handled = true;
    }

    // ---- list or grid ----------------------------------------------------------

    private void ShowAsGrid(bool grid)
    {
        // The list is at most as wide as the other pages' content; the grid
        // takes as many columns as fit.
        Cards.Layout = grid
            ? new MasonryLayout { MinColumnWidth = 260, Spacing = 12 }
            : new MasonryLayout { MaxColumns = 1, Spacing = 8, MaxWidth = (double)Application.Current.Resources["PageMaxWidth"] };
        Cards.ItemTemplate = (DataTemplate)Resources[grid ? "GridCard" : "ListCard"];
        ViewSwitch.SelectedIndex = grid ? 1 : 0;
    }

    private void ViewSwitch_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        bool grid = ViewSwitch.SelectedIndex == 1;
        if (ViewSwitch.SelectedIndex < 0 || Cards.ItemTemplate == Resources[grid ? "GridCard" : "ListCard"]) return;
        ShowAsGrid(grid);
        App.Settings.SyncedGridView = grid;
        App.Settings.Save();
    }

    private void UpdatePasscodeTip() =>
        PasscodeTip.IsOpen = !(host.HasPasscode || App.Settings.PasscodeTipDismissed);

    private void PasscodeTip_Action(object sender, RoutedEventArgs e) => App.MainAppWindow.Navigate(typeof(SettingsPage));

    private void PasscodeTip_Closed(InfoBar sender, object args)
    {
        App.Settings.PasscodeTipDismissed = true;
        App.Settings.Save();
        UpdatePasscodeTip();
    }

    // The grid's thumbnail: as wide as the card, as high as the image (a
    // very tall one cropped at the border's MaxHeight, like the phones' grid).
    private void GridThumb_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is not Border { DataContext: HistoryCard { AspectRatio: > 0 } card } border) return;
        double height = Math.Min(border.MaxHeight, Math.Round(e.NewSize.Width * card.AspectRatio));
        if (double.IsNaN(border.Height) || Math.Abs(border.Height - height) > 0.5) border.Height = height;
    }

    private static HistoryCard? CardOf(object sender) => (sender as FrameworkElement)?.DataContext as HistoryCard;

    // ---- a card -------------------------------------------------------------

    // A click on the card itself, or Enter / Space on it (its buttons handle
    // their own clicks).
    private void Cards_ItemInvoked(ItemsView sender, ItemsViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is HistoryCard card) ShowDetail(card);
    }

    // Right-click or Shift+F10 on a card - the mobile apps' long-press menu.
    private void Cards_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        DependencyObject? at = args.OriginalSource as DependencyObject;
        HistoryCard? card = null;
        while (at != null && card == null)
        {
            card = (at as FrameworkElement)?.DataContext as HistoryCard;
            at = VisualTreeHelper.GetParent(at);
        }
        if (card == null) return;

        var flyout = new MenuFlyout();
        flyout.Items.Add(MenuItem("View", Symbol.View, () => ShowDetail(card)));
        if (card.CanCopy) flyout.Items.Add(MenuItem("Copy", Symbol.Copy, () => Copy(card)));
        if (card.CanOpen)
        {
            flyout.Items.Add(MenuItem("Open", Symbol.OpenFile, () => _ = OpenAsync(card, showInFolder: false)));
            flyout.Items.Add(MenuItem("Show in folder", Symbol.Folder, () => _ = OpenAsync(card, showInFolder: true)));
        }
        flyout.Items.Add(new MenuFlyoutSeparator());
        flyout.Items.Add(MenuItem("Delete", Symbol.Delete, () => _ = DeleteAsync(card)));

        if (args.TryGetPosition(sender, out var position)) flyout.ShowAt(sender, new FlyoutShowOptions { Position = position });
        else flyout.ShowAt((FrameworkElement)sender);
        args.Handled = true;
    }

    private static MenuFlyoutItem MenuItem(string text, Symbol symbol, Action click)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new SymbolIcon(symbol) };
        item.Click += (_, _) => click();
        return item;
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) Copy(card);
    }

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) await OpenAsync(card, showInFolder: false);
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

        DetailTitle.ItemsSource = new[] { "Synced", card.KindText };
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

        ListTitle.Visibility = ListSubtitle.Visibility = ViewSwitch.Visibility = Cards.Visibility = PasscodeTip.Visibility = Visibility.Collapsed;
        EmptyState.Visibility = Visibility.Collapsed;
        DetailTitle.Visibility = DetailOrigin.Visibility = DetailView.Visibility = Visibility.Visible;
        DetailView.ChangeView(null, 0, null, disableAnimation: true);
        // Keyboard users land on the first action.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () => (DetailCopy.Visibility == Visibility.Visible ? DetailCopy : DetailDelete).Focus(FocusState.Programmatic));
    }

    // Back to the cards.
    private void ShowList()
    {
        if (detail is not { } card) return;
        card.PropertyChanged -= Detail_PropertyChanged;
        detail = null;
        DetailText.Text = "";
        DetailImage.Source = null;
        DetailFile.Content = null;

        DetailTitle.Visibility = DetailOrigin.Visibility = DetailView.Visibility = Visibility.Collapsed;
        ListTitle.Visibility = ListSubtitle.Visibility = ViewSwitch.Visibility = Cards.Visibility = PasscodeTip.Visibility = Visibility.Visible;
        EmptyState.Visibility = host.HistoryIsEmpty ? Visibility.Visible : Visibility.Collapsed;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Cards.Focus(FocusState.Programmatic));
    }

    private void DetailTitle_ItemClicked(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (args.Index == 0) ShowList();
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
        // Shrunk to fit, never enlarged past its own size.
        DetailImage.MaxWidth = card.PixelWidth > 0 ? card.PixelWidth : double.PositiveInfinity;
        var image = await host.LoadImageAsync(card.Key);
        if (detail == card && image != null) DetailImage.Source = image;
    }

    // A whole image fits in the view, under the buttons.
    private void DetailView_SizeChanged(object sender, SizeChangedEventArgs e) =>
        DetailImage.MaxHeight = Math.Max(160, e.NewSize.Height - 120);

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
            var dialog = new ContentDialog
            {
                Title = $"Open {Path.GetFileName(path)}?",
                // (The source ends the clause, not the sentence: a short id ends in "…".)
                Content = MainWindow.Paragraph($"It's a program or script from {(card.Item.FromThisDevice ? "this PC" : card.Source)} - opening it runs it on this PC. Only do that if you trust it."),
                // Not the accent colour: opening isn't the suggested choice here.
                PrimaryButtonText = "Open",
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

    protected override DataTemplate? SelectTemplateCore(object item) => item switch
    {
        HistoryCard { IsImage: true } => ImageTemplate,
        HistoryCard { IsFile: true } => FileTemplate,
        _ => TextTemplate,
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
