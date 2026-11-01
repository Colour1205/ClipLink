using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Runtime.InteropServices;
using ClipboardDaemon.Engine;
using ClipboardDaemon.Storage;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

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
        // (Handled ones too: the card's container handles the press.)
        Cards.AddHandler(PointerPressedEvent, new PointerEventHandler(Cards_PointerPressed), true);
        Cards.AddHandler(PointerMovedEvent, new PointerEventHandler(Cards_PointerMoved), true);
        Cards.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => pressedCard = null), true);
        // A drag that ended without a drop or a leave (it happens): the hint
        // goes once the pointer moves over the page again.
        AddHandler(PointerMovedEvent, new PointerEventHandler((_, _) => ShowDropHint(false)), true);
        // Let go before a drag got going (see StartDrag). Once it has, Windows
        // has the pointer: this page hears nothing more of it.
        AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => releasedWhileStarting = true), true);
        // Items are about to be added to the cards (a stack arriving, or one
        // opened): the ones already there glide to their new places.
        host.CardsWillShift += BeginLayoutGlide;
        // Navigated to another page: back to the cards for next time.
        Unloaded += (_, _) =>
        {
            ShowList();
            ShowDropHint(false);
        };
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
        ShowList(animate: true);
        args.Handled = true;
    }

    private void Page_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (detail == null || !e.GetCurrentPoint(this).Properties.IsXButton1Pressed) return;
        ShowList(animate: true);
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
            // The release that ended a drag still starting (once: a click after it opens the card).
            if (dragging && dragReleaseUnseen)
            {
                dragReleaseUnseen = false;
                return;
            }
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

    // A new item, or a new stack (one card however many items are in it):
    // it fades in and grows from small with a spring, as on the phones,
    // while the cards around it glide aside (BeginLayoutGlide).
    private static void ScaleIn(FrameworkElement element)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        var compositor = visual.Compositor;
        visual.CenterPoint = new Vector3((float)element.ActualWidth / 2, (float)element.ActualHeight / 2, 0);
        FadeIn(element, 0, 200);
        var scale = compositor.CreateSpringVector3Animation();
        scale.InitialValue = new Vector3(0.6f, 0.6f, 1f);
        scale.FinalValue = Vector3.One;
        scale.DampingRatio = 0.85f;
        scale.Period = TimeSpan.FromMilliseconds(48);
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
        // The card that is tapped grows into the full view (and back): its
        // picture is taken now, while the list is still showing.
        var morph = PrepareMorph(OpenMorphKey, card);
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
        StartMorph(morph, DetailCard);
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

    // Back to the cards: the full view shrinks back into its card (not when it
    // is the page being left, or the card that is gone).
    private void ShowList(bool animate = false)
    {
        if (detail is not { } card) return;
        var morph = animate && host.History.Contains(card) ? PrepareMorph(CloseMorphKey, card, DetailCard) : null;
        card.PropertyChanged -= Detail_PropertyChanged;
        detail = null;
        DetailText.Text = "";
        DetailImage.Source = null;
        DetailFile.Content = null;

        DetailTitle.Visibility = DetailOrigin.Visibility = DetailView.Visibility = Visibility.Collapsed;
        ListTitle.Visibility = ListSubtitle.Visibility = ViewSwitch.Visibility = Cards.Visibility = PasscodeTip.Visibility = Visibility.Visible;
        EmptyState.Visibility = host.HistoryIsEmpty ? Visibility.Visible : Visibility.Collapsed;
        if (morph != null) StartMorphBack(morph, card);
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => Cards.Focus(FocusState.Programmatic));
    }

    // ---- a card growing into the full view, and back --------------------------------

    private const string OpenMorphKey = "cardOpen";
    private const string CloseMorphKey = "cardClose";
    private static readonly TimeSpan MorphDuration = TimeSpan.FromMilliseconds(250);

    // The list's element for a card, if it has one on screen (the list only
    // makes elements for the cards near the view).
    private FrameworkElement? ElementOf(HistoryCard card)
    {
        if (FindRepeater(Cards) is not { } repeater) return null;
        int index = host.History.IndexOf(card);
        return index < 0 ? null : repeater.TryGetElement(index) as FrameworkElement;
    }

    // Takes the picture of what is about to grow or shrink. Null when there
    // is nothing to animate (animations are off, the card is not on screen).
    private ConnectedAnimation? PrepareMorph(string key, HistoryCard card, FrameworkElement? source = null)
    {
        if (!MotionPreference.Enabled) return null;
        try
        {
            source ??= ElementOf(card);
            if (source is not { ActualWidth: > 0, ActualHeight: > 0 }) return null;
            var service = ConnectedAnimationService.GetForCurrentView();
            // Strongly easing out: most of the way at once, then a long, gentle settle.
            service.DefaultDuration = MorphDuration;
            service.DefaultEasingFunction = ElementCompositionPreview.GetElementVisual(this).Compositor
                .CreateCubicBezierEasingFunction(new Vector2(0.05f, 0.7f), new Vector2(0.1f, 1f));
            var animation = service.PrepareToAnimate(key, source);
            animation.Configuration = new BasicConnectedAnimationConfiguration();
            return animation;
        }
        catch (Exception ex)
        {
            // Only the movement is lost.
            Console.WriteLine($"[app] card morph failed: {ex.Message}");
            return null;
        }
    }

    // The card grows into the full view; the buttons stay where they are.
    private void StartMorph(ConnectedAnimation? animation, UIElement target)
    {
        if (animation == null) return;
        try
        {
            // Laid out now, so the card's place and size are known.
            DetailView.UpdateLayout();
            animation.TryStart(target);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card morph failed: {ex.Message}");
        }
    }

    // The full view shrinks into the card's place in the list, once the list
    // has been laid out again.
    private void StartMorphBack(ConnectedAnimation animation, HistoryCard card)
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            try
            {
                Cards.UpdateLayout();
                if (ElementOf(card) is { } element) animation.TryStart(element);
                else animation.Cancel();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[app] card morph failed: {ex.Message}");
            }
        });
    }

    private void DetailTitle_ItemClicked(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        if (args.Index == 0) ShowList(animate: true);
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

    // ---- dragging an item out ----------------------------------------------------

    // A card - or the picture or file in the full view - dragged into another
    // app or a folder carries the item itself, as on the phones: the text, or
    // the file (the same copy Open opens, marked as from elsewhere).
    // A press on a card, where it was: moved far enough with the button still
    // down, the card is dragged. Started here rather than by the card's own
    // CanDrag alone, which never sees the move: the list's container takes
    // the pointer when it is pressed.
    private (FrameworkElement Card, Windows.Foundation.Point At)? pressedCard;
    private const double DragDistance = 6;

    private void Cards_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        pressedCard = null;
        var point = e.GetCurrentPoint(Cards);
        if (!point.Properties.IsLeftButtonPressed) return;
        // A card's buttons (and the stack's handle, which isn't in the card) don't drag.
        for (var at = e.OriginalSource as DependencyObject; at != null && at != Cards; at = VisualTreeHelper.GetParent(at))
        {
            if (at is ButtonBase) return;
            if (at is FrameworkElement { CanDrag: true, DataContext: HistoryCard } card)
            {
                pressedCard = (card, point.Position);
                return;
            }
        }
    }

    private async void Cards_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (pressedCard is not var (card, from)) return;
        // One at a time: an earlier one may still be waiting for its file.
        if (dragging)
        {
            pressedCard = null;
            return;
        }
        var point = e.GetCurrentPoint(Cards);
        if (!point.Properties.IsLeftButtonPressed)
        {
            pressedCard = null;
            return;
        }
        if (Math.Abs(point.Position.X - from.X) < DragDistance && Math.Abs(point.Position.Y - from.Y) < DragDistance) return;
        pressedCard = null;
        // Until the drag is over (dropped, or never started): letting go
        // meanwhile is not a click on the card.
        dragging = dragReleaseUnseen = true;
        try
        {
            await card.StartDragAsync(e.GetCurrentPoint(card));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't start dragging an item: {ex.Message}");
        }
        finally
        {
            dragging = dragReleaseUnseen = draggingOut = false;
            ActionClicked();
        }
    }

    private bool dragging, dragReleaseUnseen;

    private void Card_DragStarting(UIElement sender, DragStartingEventArgs args)
    {
        pressedCard = null;
        ActionClicked();
        StartDrag(CardOf(sender), args);
    }

    private void Detail_DragStarting(UIElement sender, DragStartingEventArgs args) => StartDrag(detail, args);

    // Let go over another app: that is not a click on the card.
    private void Item_DropCompleted(UIElement sender, DropCompletedEventArgs args)
    {
        draggingOut = false;
        ActionClicked();
    }

    // An item of ours is being dragged: let go over this page, it is not
    // something new to send.
    private bool draggingOut;

    // The first drag of a big file waits for its copy out of ClipLink's
    // store: one let go of meanwhile (mouse, pen or finger) isn't dragged -
    // it would drop wherever the pointer had got to. The copy is kept for
    // the next drag (see DragCopyAsync).
    private bool releasedWhileStarting;

    // Copies made for dragging, by item: one still as it was made is dragged
    // again at once (GetFileToOpen reads a big one through to check it).
    private readonly Dictionary<string, (string Path, long Length, DateTime Written)> dragCopies = new();

    private async Task<string?> DragCopyAsync(HistoryCard card)
    {
        if (dragCopies.TryGetValue(card.Key, out var made))
        {
            var info = new FileInfo(made.Path);
            if (info.Exists && info.Length == made.Length && info.LastWriteTimeUtc == made.Written) return made.Path;
        }
        // As for Open: the first time copies the file out of ClipLink's store.
        string? path = await Task.Run(() =>
        {
            string? copy = host.Engine.GetFileToOpen(card.Key);
            if (copy != null) FileOpener.MarkAsFromElsewhere(copy);
            return copy;
        });
        if (path != null)
        {
            var info = new FileInfo(path);
            dragCopies[card.Key] = (path, info.Length, info.LastWriteTimeUtc);
        }
        return path;
    }

    private async void StartDrag(HistoryCard? card, DragStartingEventArgs args)
    {
        // A file that hasn't arrived yet has nothing to carry.
        if (card == null || !(card.IsText || card.CanOpen))
        {
            args.Cancel = true;
            return;
        }
        draggingOut = true;
        releasedWhileStarting = false;
        Console.WriteLine($"[app] dragging out an item ({card.KindText})");
        var data = args.Data;
        data.RequestedOperation = DataPackageOperation.Copy;
        if (card.IsText)
        {
            // All of it - the card only has the first 1000 characters.
            string text = host.Engine.GetText(card.Key) ?? card.Text ?? "";
            data.SetText(text);
            if (card.IsLink && Uri.TryCreate(text.Trim(), UriKind.Absolute, out var link)) data.SetWebLink(link);
            return;
        }
        var deferral = args.GetDeferral();
        try
        {
            string? path = await DragCopyAsync(card);
            var file = path == null ? null : await StorageFile.GetFileFromPathAsync(path);
            if (file == null)
            {
                draggingOut = false;
                args.Cancel = true;
                return;
            }
            // (Nothing is awaited from here on: no release can come in between.)
            if (releasedWhileStarting)
            {
                draggingOut = false;
                args.Cancel = true;
                App.MainAppWindow.ToastError("Drag it again", "The file had to be copied out of ClipLink first - it's ready now.");
                return;
            }
            data.SetStorageItems(new[] { file }, true);
            // A picture also drops into an app that takes pictures, not files.
            if (card.ShowsPicture) data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't start dragging an item: {ex.Message}");
            draggingOut = false;
            args.Cancel = true;
        }
        finally
        {
            deferral.Complete();
        }
    }

    // ---- dropping something in ---------------------------------------------------

    // Files, a picture or text dragged here from another app or a folder go to
    // your devices, as "Share to ClipLink" does: into Synced and out to every
    // device, without touching this PC's clipboard.
    private static bool CanTake(DataPackageView data) =>
        data.Contains(StandardDataFormats.StorageItems) || data.Contains(StandardDataFormats.Bitmap)
        || data.Contains(StandardDataFormats.Text) || data.Contains(StandardDataFormats.WebLink);

    private void Page_DragOver(object sender, DragEventArgs e)
    {
        dropLeaveTimer?.Stop();
        if (draggingOut || !CanTake(e.DataView))
        {
            e.AcceptedOperation = DataPackageOperation.None;
            ShowDropHint(false);
            return;
        }
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Send to your devices";
        ShowDropHint(true);
    }

    // Also raised moving from one element on the page to the next, just
    // before that one's DragEnter: the hint goes only if none follows.
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? dropLeaveTimer;

    private void Page_DragLeave(object sender, DragEventArgs e)
    {
        if (dropLeaveTimer == null)
        {
            dropLeaveTimer = DispatcherQueue.CreateTimer();
            dropLeaveTimer.Interval = TimeSpan.FromMilliseconds(80);
            dropLeaveTimer.IsRepeating = false;
            dropLeaveTimer.Tick += (_, _) => ShowDropHint(false);
        }
        dropLeaveTimer.Stop();
        dropLeaveTimer.Start();
    }

    private async void Page_Drop(object sender, DragEventArgs e)
    {
        dropLeaveTimer?.Stop();
        ShowDropHint(false);
        if (draggingOut || !CanTake(e.DataView)) return;
        var data = e.DataView;
        var deferral = e.GetDeferral();
        // Files that are only in another app (an attachment, say) are copied
        // out first, and deleted once they have been shared.
        string? copies = null;
        try
        {
            var items = data.Contains(StandardDataFormats.StorageItems) ? await data.GetStorageItemsAsync() : null;
            // A link dragged from a browser also comes as a shortcut file
            // ("Page title.url") that is only in the browser: it goes as the link.
            bool linkShortcut = items is { Count: > 0 }
                && items.All(item => string.IsNullOrEmpty(item.Path) && item.Name.EndsWith(".url", StringComparison.OrdinalIgnoreCase))
                && (data.Contains(StandardDataFormats.WebLink) || data.Contains(StandardDataFormats.Text));
            // Files before a picture or text: a file brings its own name.
            if (items != null && !linkShortcut)
            {
                var paths = new List<string>();
                // (One with a path that can't be shared is the share's to report.)
                var skipped = new List<SkippedShare>();
                foreach (var item in items)
                {
                    if (!string.IsNullOrEmpty(item.Path)) paths.Add(item.Path);
                    else if (item is StorageFile file)
                    {
                        // Not copied out at all when it couldn't be shared anyway.
                        if ((long)(await file.GetBasicPropertiesAsync()).Size > LocalFiles.MaxFileBytes)
                        {
                            skipped.Add(new SkippedShare(file.Name, FileSkipReason.TooLarge, null));
                            continue;
                        }
                        copies ??= Path.Combine(Path.GetTempPath(), "ClipLink", "dropped", Guid.NewGuid().ToString("N"));
                        Directory.CreateDirectory(copies);
                        var folder = await StorageFolder.GetFolderFromPathAsync(copies);
                        paths.Add((await file.CopyAsync(folder, file.Name, NameCollisionOption.GenerateUniqueName)).Path);
                    }
                    // A folder that is only in another app (on a phone, in a zip).
                    else skipped.Add(new SkippedShare(item.Name, FileSkipReason.Folder, null));
                }
                await App.Instance.ShareAsync(paths, skipped);
            }
            else if (data.Contains(StandardDataFormats.Bitmap))
            {
                var bitmap = await data.GetBitmapAsync();
                using var stream = await bitmap.OpenReadAsync();
                byte[] png = await ToPngAsync(stream);
                await Task.Run(() => host.Engine.ShareImage(png));
            }
            else
            {
                string text = data.Contains(StandardDataFormats.Text) ? await data.GetTextAsync()
                    : (await data.GetWebLinkAsync()).ToString();
                await Task.Run(() => host.Engine.ShareText(text));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't send what was dropped: {ex}");
            App.MainAppWindow.ToastError("Couldn't send that", ex.Message);
        }
        finally
        {
            deferral.Complete();
            if (copies != null)
            {
                try { Directory.Delete(copies, recursive: true); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
        }
    }

    // ---- the drop hint ----------------------------------------------------------

    // At once: the cards under acrylic, and the hint's text over it.
    private bool dropHintShown;

    private void ShowDropHint(bool show)
    {
        if (show == dropHintShown) return;
        dropHintShown = show;
        if (show)
        {
            DropHint.Visibility = Visibility.Visible;
            WatchDrag();
        }
        else
        {
            dropWatch?.Stop();
            DropHint.Visibility = Visibility.Collapsed;
        }
    }

    // A drag can leave without the page hearing of it (no DragLeave, and no
    // pointer events while another app drags): while the hint shows, it
    // goes as soon as no button is down or the pointer isn't over the page.
    // (Read as Windows' drag does: the buttons themselves, either one, and
    // the window under the pointer.)
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? dropWatch;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    private const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02;

    private static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")]
    private static extern bool ScreenToClient(nint hwnd, ref NativePoint point);
    [DllImport("user32.dll")]
    private static extern nint WindowFromPoint(NativePoint point);
    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint hwnd, uint flags);
    private const uint GA_ROOT = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X, Y;
    }

    private void WatchDrag()
    {
        if (dropWatch == null)
        {
            dropWatch = DispatcherQueue.CreateTimer();
            dropWatch.Interval = TimeSpan.FromMilliseconds(100);
            dropWatch.IsRepeating = true;
            dropWatch.Tick += (_, _) =>
            {
                if (!(IsDown(VK_LBUTTON) || IsDown(VK_RBUTTON)) || !PointerOverPage()) ShowDropHint(false);
            };
        }
        dropWatch.Start();
    }

    private bool PointerOverPage()
    {
        try
        {
            if (XamlRoot is not { } root || !GetCursorPos(out var at)) return false;
            nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainAppWindow);
            // Another window in front of this one there isn't over the page.
            if (GetAncestor(WindowFromPoint(at), GA_ROOT) != hwnd) return false;
            if (!ScreenToClient(hwnd, ref at)) return false;
            double scale = root.RasterizationScale;
            var page = PageRoot.TransformToVisual(null).TransformBounds(new Windows.Foundation.Rect(0, 0, PageRoot.ActualWidth, PageRoot.ActualHeight));
            return page.Contains(new Windows.Foundation.Point(at.X / scale, at.Y / scale));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't tell where the pointer is: {ex.Message}");
            return false;
        }
    }

    // A dropped picture comes in whatever form the app had it (often a
    // bitmap): stored and sent as PNG, as a copied one is.
    private static async Task<byte[]> ToPngAsync(IRandomAccessStream source)
    {
        var decoder = await BitmapDecoder.CreateAsync(source);
        using var pixels = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetSoftwareBitmap(pixels);
        await encoder.FlushAsync();
        output.Seek(0);
        using var bytes = new MemoryStream();
        await output.AsStreamForRead().CopyToAsync(bytes);
        return bytes.ToArray();
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
