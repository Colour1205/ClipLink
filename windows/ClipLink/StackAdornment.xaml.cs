using System.ComponentModel;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace ClipLink;

// What makes a card a stack (see BatchGrouping), laid over the card: the
// layers behind it, the "+4" badge and the handle. Drag the handle down, or
// click it (or press Enter on it), and the stack opens - the cards inside
// become ordinary ones (SyncedPage.StackExpand). It follows the card's
// state: stacked or not, how many are folded in.
//
// The movement is composition animation (off the UI thread) except while
// the pointer is down, when the layers follow it directly. If any of it
// fails the stack still opens: it is only decoration.
public sealed partial class StackAdornment : UserControl
{
    public static readonly DependencyProperty CardProperty = DependencyProperty.Register(
        nameof(Card), typeof(HistoryCard), typeof(StackAdornment),
        new PropertyMetadata(null, (d, e) => ((StackAdornment)d).CardChanged((HistoryCard?)e.OldValue, (HistoryCard?)e.NewValue)));

    public HistoryCard? Card
    {
        get => (HistoryCard?)GetValue(CardProperty);
        set => SetValue(CardProperty, value);
    }

    // How far down the handle is dragged to open the stack all the way (dp).
    private const double OpenDistance = 96;
    // Past a third of it on release, or this fast (dp per second), opens it.
    private const double OpenFraction = 1.0 / 3;
    private const double OpenVelocity = 600;
    // Movement under this is a click, not a drag.
    private const double DragSlop = 4;
    // How far the two layers slide down when fully open (dp).
    private const double Layer1Travel = 20, Layer2Travel = 40;

    private HistoryCard? attached;
    // The stack is opening: kept on screen to fade out, though the card is
    // not a stack any more.
    private bool closing;

    private uint pointerId;
    private bool pressed;
    private bool dragging;
    private bool suppressClick;
    private double startY;
    private double progress;
    // Recent pointer samples (time in ms, y) for the speed of the release.
    private readonly Queue<(long Time, double Y)> samples = new();

    public StackAdornment()
    {
        InitializeComponent();
        ElementCompositionPreview.SetIsTranslationEnabled(Layer1, true);
        ElementCompositionPreview.SetIsTranslationEnabled(Layer2, true);
        // The button takes the pointer's press and release for its own click,
        // so these are listened to even though they are handled.
        Handle.AddHandler(PointerPressedEvent, new PointerEventHandler(Handle_PointerPressed), true);
        Handle.AddHandler(PointerMovedEvent, new PointerEventHandler(Handle_PointerMoved), true);
        Handle.AddHandler(PointerReleasedEvent, new PointerEventHandler(Handle_PointerReleased), true);
        Handle.AddHandler(PointerCanceledEvent, new PointerEventHandler(Handle_PointerEnded), true);
        Handle.AddHandler(PointerCaptureLostEvent, new PointerEventHandler(Handle_PointerEnded), true);
        Loaded += (_, _) => Attach(Card);
        Unloaded += (_, _) => Attach(null);
    }

    private void CardChanged(HistoryCard? old, HistoryCard? card)
    {
        // A container reused for another card starts from the plain state.
        closing = false;
        pressed = dragging = false;
        ResetVisuals();
        Attach(IsLoaded ? card : null);
        Refresh();
    }

    private void Attach(HistoryCard? card)
    {
        if (attached == card) return;
        if (attached != null) attached.PropertyChanged -= Card_PropertyChanged;
        attached = card;
        if (card != null) card.PropertyChanged += Card_PropertyChanged;
        Refresh();
    }

    private void Card_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(HistoryCard.StackHidden) or nameof(HistoryCard.IsStacked)) Refresh();
    }

    private void Refresh()
    {
        var card = Card;
        bool stacked = card is { IsStacked: true };
        Root.Visibility = stacked || closing ? Visibility.Visible : Visibility.Collapsed;
        if (!stacked || card == null) return;
        Layer1.Visibility = card.StackLayers >= 1 ? Visibility.Visible : Visibility.Collapsed;
        Layer2.Visibility = card.StackLayers >= 2 ? Visibility.Visible : Visibility.Collapsed;
        BadgeText.Text = card.StackBadge;
        string name = card.StackHandleName;
        AutomationProperties.SetName(Handle, name);
        AutomationProperties.SetHelpText(Handle, StackText.ExpandHint);
        ToolTipService.SetToolTip(Handle, name);
    }

    // ---- dragging the handle -------------------------------------------------

    private void Handle_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (Card is not { IsStacked: true } || closing) return;
        var point = e.GetCurrentPoint(Root);
        if (!point.Properties.IsLeftButtonPressed) return;
        pointerId = e.Pointer.PointerId;
        pressed = true;
        dragging = false;
        suppressClick = false;
        progress = 0;
        startY = point.Position.Y;
        samples.Clear();
        samples.Enqueue((Environment.TickCount64, startY));
        Handle.CapturePointer(e.Pointer);
        TellPage();
    }

    private void Handle_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed || e.Pointer.PointerId != pointerId) return;
        double y = e.GetCurrentPoint(Root).Position.Y;
        double down = y - startY;
        if (!dragging)
        {
            if (down < DragSlop) return;
            dragging = true;
            // The click that the release would make is the drag's end instead.
            suppressClick = true;
        }
        long now = Environment.TickCount64;
        samples.Enqueue((now, y));
        while (samples.Count > 1 && now - samples.Peek().Time > 120) samples.Dequeue();
        SetProgress(Math.Clamp(down / OpenDistance, 0, 1));
    }

    private void Handle_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed || e.Pointer.PointerId != pointerId) return;
        EndPress(e.GetCurrentPoint(Root).Position.Y, cancelled: false);
        Handle.ReleasePointerCapture(e.Pointer);
    }

    // Cancelled, or the capture went somewhere else without a release.
    private void Handle_PointerEnded(object sender, PointerRoutedEventArgs e)
    {
        if (!pressed || e.Pointer.PointerId != pointerId) return;
        EndPress(startY, cancelled: true);
    }

    private void EndPress(double y, bool cancelled)
    {
        pressed = false;
        TellPage();
        if (!dragging) return; // a click: Handle_Click opens it
        dragging = false;
        // (The release's own Click has come by now; one that didn't must not
        // swallow the next, from the keyboard.)
        After(200, () => suppressClick = false);

        double speed = 0;
        if (samples.Count > 1)
        {
            var first = samples.Peek();
            double seconds = Math.Max(1, Environment.TickCount64 - first.Time) / 1000.0;
            speed = (y - first.Y) / seconds;
        }
        if (!cancelled && (progress >= OpenFraction || (speed >= OpenVelocity && progress > 0.05)))
            Open();
        else
            SpringBack();
    }

    private void Handle_Click(object sender, RoutedEventArgs e)
    {
        // Press and release on the handle, or Enter / Space / the screen
        // reader's action on it.
        TellPage();
        if (suppressClick)
        {
            suppressClick = false;
            return;
        }
        if (Card is not { IsStacked: true } || closing) return;
        Open();
    }

    // The card under this must not also count the press as a click on itself
    // (which would show the item in full); the page knows how to avoid that.
    private void TellPage() => FindPage()?.StackTouched();

    private SyncedPage? FindPage()
    {
        DependencyObject? at = this;
        while (at != null && at is not SyncedPage) at = VisualTreeHelper.GetParent(at);
        return at as SyncedPage;
    }

    // ---- the movement --------------------------------------------------------

    // Follows the pointer: the layers slide apart, the handle and badge fade.
    private void SetProgress(double p)
    {
        progress = p;
        Layer1.Translation = new Vector3(0, (float)(p * Layer1Travel), 0);
        Layer2.Translation = new Vector3(0, (float)(p * Layer2Travel), 0);
        Handle.Opacity = Badge.Opacity = 1 - p;
    }

    private void ResetVisuals()
    {
        foreach (var element in new UIElement[] { Layer1, Layer2, Badge, Handle })
        {
            ElementCompositionPreview.GetElementVisual(element).StopAnimation("Opacity");
        }
        ElementCompositionPreview.GetElementVisual(Layer1).StopAnimation("Translation");
        ElementCompositionPreview.GetElementVisual(Layer2).StopAnimation("Translation");
        progress = 0;
        Layer1.Translation = Layer2.Translation = Vector3.Zero;
        Handle.Opacity = Badge.Opacity = 1;
        Layer1.Opacity = 0.75;
        Layer2.Opacity = 0.5;
        Root.Opacity = 1;
    }

    private void SpringBack()
    {
        if (!MotionPreference.Enabled)
        {
            ResetVisuals();
            return;
        }
        try
        {
            var compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
            foreach (var layer in new UIElement[] { Layer1, Layer2 })
            {
                var spring = compositor.CreateSpringVector3Animation();
                spring.FinalValue = Vector3.Zero;
                spring.DampingRatio = 0.6f;
                spring.Period = TimeSpan.FromMilliseconds(55);
                ElementCompositionPreview.GetElementVisual(layer).StartAnimation("Translation", spring);
            }
            foreach (var element in new UIElement[] { Handle, Badge })
            {
                var fade = compositor.CreateScalarKeyFrameAnimation();
                fade.InsertKeyFrame(1f, 1f);
                fade.Duration = TimeSpan.FromMilliseconds(160);
                ElementCompositionPreview.GetElementVisual(element).StartAnimation("Opacity", fade);
            }
            // The properties follow the animations' end, for the next drag.
            progress = 0;
            After(700, () =>
            {
                if (!pressed && !closing) ResetVisuals();
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] stack spring-back animation failed: {ex.Message}");
            ResetVisuals();
        }
    }

    // Opens the stack: the layers finish sliding apart while the handle and
    // badge fade out, and the cards come out (SyncedPage.StackExpand).
    private void Open()
    {
        if (Card is not { } card) return;
        closing = true;
        FadeOut();
        var container = FindContainer();
        FindPage()?.StackExpand(card, container);
        // Gone from the screen once the fade is over.
        After(320, () =>
        {
            closing = false;
            ResetVisuals();
            Refresh();
        });
    }

    // Once, on the UI thread, a little later.
    private void After(int milliseconds, Action action)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => action();
        timer.Start();
    }

    private void FadeOut()
    {
        if (!MotionPreference.Enabled)
        {
            Root.Opacity = 0;
            return;
        }
        try
        {
            var compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
            var ease = compositor.CreateCubicBezierEasingFunction(new Vector2(0.2f, 0), new Vector2(0, 1));
            foreach (var (layer, travel) in new[] { (Layer1, Layer1Travel), (Layer2, Layer2Travel) })
            {
                var slide = compositor.CreateVector3KeyFrameAnimation();
                slide.InsertKeyFrame(1f, new Vector3(0, (float)travel, 0), ease);
                slide.Duration = TimeSpan.FromMilliseconds(220);
                var visual = ElementCompositionPreview.GetElementVisual(layer);
                visual.StartAnimation("Translation", slide);
                var dim = compositor.CreateScalarKeyFrameAnimation();
                dim.InsertKeyFrame(1f, 0f, ease);
                dim.Duration = TimeSpan.FromMilliseconds(220);
                visual.StartAnimation("Opacity", dim);
            }
            foreach (var element in new UIElement[] { Handle, Badge })
            {
                var fade = compositor.CreateScalarKeyFrameAnimation();
                fade.InsertKeyFrame(1f, 0f, ease);
                fade.Duration = TimeSpan.FromMilliseconds(160);
                ElementCompositionPreview.GetElementVisual(element).StartAnimation("Opacity", fade);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] stack fade animation failed: {ex.Message}");
        }
    }

    // The card this is on, as the list's element for it (the cards that come
    // out of the stack fly out of its place).
    private FrameworkElement? FindContainer()
    {
        DependencyObject? at = this;
        while (at != null && at is not ItemContainer) at = VisualTreeHelper.GetParent(at);
        return at as FrameworkElement;
    }
}

// The system's "show animations" setting (Settings > Accessibility > Visual
// effects). Off: a stack's movement shrinks to a short fade.
internal static class MotionPreference
{
    private static readonly Windows.UI.ViewManagement.UISettings Settings = new();

    public static bool Enabled
    {
        get
        {
            try { return Settings.AnimationsEnabled; }
            catch (Exception) { return true; }
        }
    }
}
