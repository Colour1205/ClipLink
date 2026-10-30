using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace ClipLink;

// The synced history as cards - what just arrived on top, then newest first -
// text, images and files from every paired device and this PC - in a list or a
// grid, as on the phones.
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
            motionPending = true;
        };
        Cards.LayoutUpdated += PlayPlannedMotions;
        // Items are about to be added to the cards (a stack arriving, or one
        // opened): the ones already there glide to their new places.
        host.CardsWillShift += BeginLayoutGlide;
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

    // The grid's thumbnail: as wide as the card, as high as the image is, so
    // the whole picture shows. One taller than 3 times its width gets a box
    // of that height and is fitted into it, never cropped.
    private const double MaxThumbRatio = 3;

    private void GridThumb_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is not Border { DataContext: HistoryCard { AspectRatio: > 0 } card } border) return;
        // (The border's 1 px line is outside the picture, on both sides.)
        double inner = Math.Max(0, e.NewSize.Width - 2);
        double height = Math.Round(inner * Math.Min(card.AspectRatio, MaxThumbRatio)) + 2;
        if (double.IsNaN(border.Height) || Math.Abs(border.Height - height) > 0.5) border.Height = height;
    }

    private static HistoryCard? CardOf(object sender) => (sender as FrameworkElement)?.DataContext as HistoryCard;

    // ---- a card -------------------------------------------------------------

    // When a card's button last ran. The click (or Enter / Space) on a button
    // inside a card also reaches the card, which reports it as the card being
    // invoked - and Copy must not then open the item as well.
    // (Null until one has: a long.MinValue start would overflow the age sum.)
    private long? actionTick;

    // A click on the card itself, or Enter / Space on it. Waits a moment for a
    // button's own Click, which may come either side of this.
    private void Cards_ItemInvoked(ItemsView sender, ItemsViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not HistoryCard card) return;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Normal, () =>
        {
            if (actionTick is not long tick || Environment.TickCount64 - tick > 500) ShowDetail(card);
        });
    }

    private void ActionClicked() => actionTick = Environment.TickCount64;

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
        ActionClicked();
        if (CardOf(sender) is { } card) Copy(card);
    }

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        ActionClicked();
        if (CardOf(sender) is { } card) await OpenAsync(card, showInFolder: false);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        ActionClicked();
        if (CardOf(sender) is { } card) await DeleteAsync(card);
    }

    // ---- stacks ------------------------------------------------------------------

    // The stack card the user opened: the cards that come out of it fly out
    // of its place.
    private FrameworkElement? revealAnchor;

    // A press or click on a stack's handle: it is not a click on the card
    // under it, which would show the item in full.
    internal void StackTouched() => ActionClicked();

    // Opens a stack (the adornment's handle was dragged down or clicked).
    internal void StackExpand(HistoryCard card, FrameworkElement? container)
    {
        ActionClicked();
        if (card.StackBatchId is not { } batch) return;
        revealAnchor = container;
        host.ExpandBatch(batch);
    }

    // The most that a card flies, however far its place is from the stack's
    // (dp): from the stack's side, not from across the window.
    private const double MaxFlight = 140;

    // True from a change to the cards until the cards that move in have been
    // found and started.
    private bool motionPending;

    // After a layout pass: a card that is new on the page, because a stack
    // was shown or opened, moves in. Found by its place in the list rather
    // than by its element being loaded: the list reuses elements, and sizes
    // and places are known only once it has laid them out.
    private void PlayPlannedMotions(object? sender, object e)
    {
        if (!motionPending || FindRepeater(Cards) is not { } repeater) return;
        var waiting = false;
        for (int i = 0; i < host.History.Count; i++)
        {
            var card = host.History[i];
            if (!card.HasPlannedMotion) continue;
            if (repeater.TryGetElement(i) is not FrameworkElement { ActualWidth: > 0 } element)
            {
                waiting = true; // not laid out yet (or the page isn't showing)
                continue;
            }
            var (motion, index) = card.TakeMotion();
            try
            {
                if (!MotionPreference.Enabled) FadeIn(element, 0, 120);
                else if (motion == HistoryCard.Motion.Appear) ScaleIn(element);
                else FlyOut(element, index);
            }
            catch (Exception ex)
            {
                // Only the movement is lost.
                Console.WriteLine($"[app] card animation failed: {ex.Message}");
            }
        }
        motionPending = waiting;
    }

    private static void FadeIn(UIElement element, int delayMs, int durationMs)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        var fade = visual.Compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0f, 0f);
        fade.InsertKeyFrame(1f, 1f);
        fade.Duration = TimeSpan.FromMilliseconds(durationMs);
        fade.DelayTime = TimeSpan.FromMilliseconds(delayMs);
        fade.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
        visual.StartAnimation("Opacity", fade);
    }

    // A new stack: one fade and a small scale-in for the whole card, however
    // many items are in it.
    private static void ScaleIn(FrameworkElement element)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        var compositor = visual.Compositor;
        visual.CenterPoint = new Vector3((float)element.ActualWidth / 2, (float)element.ActualHeight / 2, 0);
        FadeIn(element, 0, 240);
        var scale = compositor.CreateSpringVector3Animation();
        scale.InitialValue = new Vector3(0.95f, 0.95f, 1f);
        scale.FinalValue = Vector3.One;
        scale.DampingRatio = 0.8f;
        scale.Period = TimeSpan.FromMilliseconds(50);
        visual.StartAnimation("Scale", scale);
    }

    // A card coming out of an opened stack: from the stack's place, to its
    // own with a spring, each 30 ms after the one before (all within 400 ms).
    private void FlyOut(FrameworkElement element, int index)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        var compositor = visual.Compositor;
        int delay = Math.Min(30 * index, 400);

        var from = new Vector3(0, -24, 0);
        if (revealAnchor is { XamlRoot: not null } anchor)
        {
            // Where the stack is, as seen from here.
            var at = anchor.TransformToVisual(element).TransformPoint(new Windows.Foundation.Point(0, 0));
            var toStack = new Vector2((float)at.X, (float)at.Y);
            if (!float.IsNaN(toStack.X) && !float.IsNaN(toStack.Y) && toStack.Length() > 1)
            {
                if (toStack.Length() > MaxFlight) toStack *= (float)(MaxFlight / toStack.Length());
                from = new Vector3(toStack, 0);
            }
        }

        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        visual.CenterPoint = new Vector3((float)element.ActualWidth / 2, (float)element.ActualHeight / 2, 0);
        FadeIn(element, delay, 180);

        var move = compositor.CreateSpringVector3Animation();
        move.InitialValue = from;
        move.FinalValue = Vector3.Zero;
        move.DampingRatio = 0.72f;
        move.Period = TimeSpan.FromMilliseconds(55);
        move.DelayTime = TimeSpan.FromMilliseconds(delay);
        move.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
        visual.StartAnimation("Translation", move);

        var scale = compositor.CreateSpringVector3Animation();
        scale.InitialValue = new Vector3(0.94f, 0.94f, 1f);
        scale.FinalValue = Vector3.One;
        scale.DampingRatio = 0.8f;
        scale.Period = TimeSpan.FromMilliseconds(50);
        scale.DelayTime = TimeSpan.FromMilliseconds(delay);
        scale.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
        visual.StartAnimation("Scale", scale);
    }

    // For a moment, a card that is moved by the layout (the ones below a stack
    // that appears or opens) glides there instead of jumping. Only for a
    // moment: otherwise resizing the window would glide too.
    private readonly List<Visual> gliding = new();
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? glideTimer;

    private void BeginLayoutGlide()
    {
        if (!MotionPreference.Enabled || FindRepeater(Cards) is not { } repeater) return;
        try
        {
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(repeater); i++)
            {
                if (VisualTreeHelper.GetChild(repeater, i) is not UIElement child) continue;
                var visual = ElementCompositionPreview.GetElementVisual(child);
                var compositor = visual.Compositor;
                var move = compositor.CreateVector3KeyFrameAnimation();
                move.Target = "Offset";
                move.InsertExpressionKeyFrame(1f, "this.FinalValue", compositor.CreateCubicBezierEasingFunction(new Vector2(0.2f, 0), new Vector2(0, 1)));
                move.Duration = TimeSpan.FromMilliseconds(320);
                var animations = compositor.CreateImplicitAnimationCollection();
                animations["Offset"] = move;
                visual.ImplicitAnimations = animations;
                gliding.Add(visual);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card glide failed: {ex.Message}");
            return;
        }
        glideTimer ??= DispatcherQueue.CreateTimer();
        glideTimer.Stop();
        glideTimer.Interval = TimeSpan.FromMilliseconds(1200);
        glideTimer.IsRepeating = false;
        glideTimer.Tick -= EndLayoutGlide;
        glideTimer.Tick += EndLayoutGlide;
        glideTimer.Start();
    }

    private void EndLayoutGlide(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        foreach (var visual in gliding) visual.ImplicitAnimations = null;
        gliding.Clear();
        revealAnchor = null;
    }

    private static ItemsRepeater? FindRepeater(DependencyObject at)
    {
        if (at is ItemsRepeater repeater) return repeater;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(at); i++)
        {
            if (FindRepeater(VisualTreeHelper.GetChild(at, i)) is { } found) return found;
        }
        return null;
    }

    // ---- one item in full ------------------------------------------------------

    private void ShowDetail(HistoryCard card)
    {
        if (detail != null) detail.PropertyChanged -= Detail_PropertyChanged;
        detail = card;
        card.PropertyChanged += Detail_PropertyChanged;

        DetailOrigin.Text = card.Origin;
        ShowDetailContent(card);
        UpdateDetail();

        ListTitle.Visibility = ListSubtitle.Visibility = ViewSwitch.Visibility = Cards.Visibility = PasscodeTip.Visibility = Visibility.Collapsed;
        EmptyState.Visibility = Visibility.Collapsed;
        DetailTitle.Visibility = DetailOrigin.Visibility = DetailView.Visibility = Visibility.Visible;
        DetailView.ChangeView(null, 0, null, disableAnimation: true);
        // Keyboard users land on the first action.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            () => (DetailCopy.Visibility == Visibility.Visible ? DetailCopy : DetailDelete).Focus(FocusState.Programmatic));
    }

    // A picture file with no picture to show (its bytes haven't arrived, or
    // they won't decode) is shown as a file; UpdateDetail swaps the one for
    // the other as that changes.
    private void ShowDetailContent(HistoryCard card)
    {
        DetailTitle.ItemsSource = new[] { "Synced", card.KindText };
        bool picture = card.ShowsPicture;
        bool file = card.IsFile && !picture;
        DetailText.Visibility = picture || file ? Visibility.Collapsed : Visibility.Visible;
        DetailImage.Visibility = picture ? Visibility.Visible : Visibility.Collapsed;
        DetailFile.Visibility = file ? Visibility.Visible : Visibility.Collapsed;
        DetailFile.Content = file ? card : null;
        DetailText.Text = "";
        DetailImage.Source = null;
        if (picture)
        {
            _ = LoadDetailImageAsync(card);
        }
        else if (!file)
        {
            // All of it - the card only had the first 1000 characters.
            string text = card.IsText ? host.Engine.GetText(card.Key) ?? card.Text ?? "" : card.Text ?? "";
            DetailText.Text = text.Length > MaxDetailChars ? text[..MaxDetailChars] : text;
        }
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
        // A picture file's bytes have just arrived, or turned out not to be one.
        bool picture = card.ShowsPicture;
        if (card.IsFile && picture != (DetailImage.Visibility == Visibility.Visible)) ShowDetailContent(card);
        DetailCopy.Visibility = card.CanCopy ? Visibility.Visible : Visibility.Collapsed;
        DetailOpen.Visibility = DetailShowInFolder.Visibility = card.CanOpen ? Visibility.Visible : Visibility.Collapsed;
        DetailFacts.Text = picture ? card.ImageDetail
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
        if (!host.Engine.CopyToClipboard(card.Key))
            App.MainAppWindow.ToastError("Couldn't copy that", card.IsFile ? "The file hasn't arrived on this PC." : "It's no longer in the synced history.");
    }

    private async Task DeleteAsync(HistoryCard card)
    {
        bool confirmed = await App.MainAppWindow.ConfirmAsync("Delete this item?",
            "It's deleted from this PC and from your other devices, and won't come back. A device with an older ClipLink keeps its own copy.",
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
        HistoryCard { IsPicture: true } => ImageTemplate,
        HistoryCard { IsFile: true } => FileTemplate,
        _ => TextTemplate,
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
