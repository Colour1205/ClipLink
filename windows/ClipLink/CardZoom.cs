using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;

namespace ClipLink;

// A card zooming into its full view, and the full view zooming back onto its
// card - a Synced item or a device, the same on both pages (ZoomMorph has the
// shape of it). The list stays on screen behind it all the way, just as it
// is - not blurred, not dimmed (the user found both looked bad on Windows), and
// never faded out or left blank behind the card.
//
// It runs on the compositor: one number, P (0 on the card, 1 the full view),
// is animated, and everything else - the view's scale, place, height and
// corners, how far its content rides down, a flying picture - follows P by
// expressions, so it all moves on the one curve.
//
// What it works on, laid out over each other where the list is:
//   view      the full view, laid out at its own size (it scales and moves)
//   fill      inside it, under the content: the page's own colour, so the
//             view covers the list while it zooms (shown only then: at rest
//             the page shows through, as before)
//   content   inside it, over the fill: what fades in after the card's picture
//   cover     inside it, over the content: holds the card's picture of itself
//   flying    in a Canvas laid out where the view is, over it: a picture card's
//             picture (null on a page without pictures)
internal sealed class CardZoom
{
    // One zoom. Card: the tapped card, on the view's layout (null when it is
    // gone or off screen: the view shrinks toward the middle and fades). Face:
    // the card's element, a live picture of which covers the view while it is
    // small. Inset: how far in from the card's top its first line is, for the
    // view's content to ride there (0: it stays put). Offset: where the view
    // rests relative to where it is laid out now (the header above it may have
    // changed height as the page switched). Flight: a picture card's picture.
    internal sealed record Plan(ZoomMorph.Rect? Card, FrameworkElement? Face, double Inset, Vector2 Offset, Flight? Flight);

    // A picture's flight: from its place on the card (From) to its place in
    // the full view (To), both on the view's layout. The card's own picture
    // and the view's are hidden while it flies; the view's takes over where it
    // lands, in the same place. RadiusFrom: the card picture's corners.
    internal sealed record Flight(ZoomMorph.Rect From, ZoomMorph.Rect To, ImageSource Source, double RadiusFrom,
        UIElement CardPicture, UIElement ViewPicture);

    // About as long as the phones' spring (critically damped, stiffness 328)
    // takes to settle, on a curve fitted to it (within 1.2%): no slow start,
    // most of the way at once, then a gentle settle.
    private static readonly TimeSpan Duration = TimeSpan.FromMilliseconds(350);

    private readonly FrameworkElement view, fill, content, cover;
    private readonly Image? flying;
    private readonly Compositor compositor;
    private readonly CompositionPropertySet zoom;
    private readonly CompositionEasingFunction ease, sharp;
    // Bumped by every start and stop: a zoom that was taken over (a close
    // started while it opened, a card tapped while it closed) lands nowhere.
    private int generation;
    // What the running zoom does when it lands (the page's own part: the list
    // put away once the view covers it, the view put away once it is back on
    // its card).
    private Action? landing;
    private readonly List<Visual> hidden = new();
    // The card's live picture of itself over the view, made per zoom and let
    // go of (disposed, not left to the collector) as soon as it is not shown:
    // a live surface keeps drawing the card for as long as it exists.
    private SpriteVisual? coverSprite;
    private CompositionVisualSurface? coverSurface;

    public CardZoom(FrameworkElement view, FrameworkElement fill, FrameworkElement content, FrameworkElement cover,
        Image? flying)
    {
        this.view = view;
        this.fill = fill;
        this.content = content;
        this.cover = cover;
        this.flying = flying;
        compositor = VisualOf(view).Compositor;
        zoom = compositor.CreatePropertySet();
        zoom.InsertScalar("P", 1f);
        // Moved by Translation, on top of where XAML lays them out (which
        // stays theirs). Turned on now: Reset stops it before any zoom ran.
        ElementCompositionPreview.SetIsTranslationEnabled(view, true);
        ElementCompositionPreview.SetIsTranslationEnabled(content, true);
        if (flying != null) ElementCompositionPreview.SetIsTranslationEnabled(flying, true);
        ease = compositor.CreateCubicBezierEasingFunction(new Vector2(0.2f, 0.1f), new Vector2(0.2f, 1f));
        sharp = compositor.CreateCubicBezierEasingFunction(new Vector2(0.33f, 0f), new Vector2(0.67f, 1f));
    }

    // Grows the view out of the card. The view must already be laid out (and
    // visible) at its full size, with the list still showing under it. False
    // when there is no zoom (animations are off, or it failed): the page just
    // switches, as it did before.
    public bool Open(Plan plan, Action opened)
    {
        Finish();
        if (!MotionPreference.Enabled || plan.Card is null || view.ActualWidth <= 0 || view.ActualHeight <= 0) return false;
        try
        {
            zoom.InsertScalar("P", 0f);
            Show();
            Bind(plan, opening: true);
            Run(1f, opening: true, opened);
            return true;
        }
        catch (Exception ex)
        {
            // Only the movement is lost.
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
            Reset();
            return false;
        }
    }

    // The first half of closing, done at once when the user goes back: the
    // view covers the list (which the page shows again, taking taps right away
    // - the view no longer does) while the page finds where the card is. Then
    // Shrink. closed runs once the view is back on its card, or at once if it
    // never gets there (Finish).
    public void Hold(Action closed)
    {
        // An open still running lands nowhere now: this takes it over.
        generation++;
        landing = closed;
        view.IsHitTestVisible = false;
        try
        {
            Show();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
            Finish();
        }
    }

    // Shrinks the held view back onto its card (or toward the middle, fading,
    // when plan.Card is null), from wherever it is - an open taken over halfway
    // closes from there.
    public void Shrink(Plan plan)
    {
        if (landing == null) return;
        if (!MotionPreference.Enabled || view.ActualWidth <= 0 || view.ActualHeight <= 0)
        {
            Finish();
            return;
        }
        try
        {
            Bind(plan, opening: false);
            Run(0f, opening: false, landing);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
            Finish();
        }
    }

    // Ends whatever is running as if it had run to the end, now.
    public void Finish()
    {
        generation++;
        var done = landing;
        landing = null;
        Reset();
        done?.Invoke();
    }

    // ---- where things are -----------------------------------------------------------

    // An element's place in the window. Null when it is not laid out. This
    // takes in where a Translation or Scale has moved it and its parents (they
    // must be at rest: the list's cards, measured once the zoom is stopped).
    public static ZoomMorph.Rect? WindowRect(FrameworkElement? element)
    {
        if (element is not { ActualWidth: > 0, ActualHeight: > 0 }) return null;
        try
        {
            var r = element.TransformToVisual(null).TransformBounds(new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            return new ZoomMorph.Rect(r.X, r.Y, r.Width, r.Height);
        }
        catch (Exception)
        {
            return null;
        }
    }

    // Where an element is laid out in the window, wherever a zoom has it now
    // (its parent never moves).
    public static Vector2 LayoutOrigin(FrameworkElement element) =>
        (VisualTreeHelper.GetParent(element) is UIElement parent ? WindowPoint(parent) : Vector2.Zero)
        + new Vector2(element.ActualOffset.X, element.ActualOffset.Y);

    // An element's place inside an ancestor that a zoom may be moving (the
    // full view): in the ancestor's own layout.
    public static ZoomMorph.Rect? RectIn(FrameworkElement? element, UIElement ancestor)
    {
        if (element is not { ActualWidth: > 0, ActualHeight: > 0 }) return null;
        try
        {
            var r = element.TransformToVisual(ancestor).TransformBounds(new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            return new ZoomMorph.Rect(r.X, r.Y, r.Width, r.Height);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static Vector2 WindowPoint(UIElement element)
    {
        try
        {
            var p = element.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
            return new Vector2((float)p.X, (float)p.Y);
        }
        catch (Exception)
        {
            return Vector2.Zero;
        }
    }

    public static ZoomMorph.Rect Relative(ZoomMorph.Rect rect, Vector2 origin) =>
        rect with { X = rect.X - origin.X, Y = rect.Y - origin.Y };

    // Moves an element by this much on top of its layout (the list behind an
    // opening card, kept where it was when the header above it changed).
    public static void Nudge(UIElement element, Vector2 by)
    {
        try
        {
            ElementCompositionPreview.SetIsTranslationEnabled(element, true);
            VisualOf(element).Properties.InsertVector3("Translation", new Vector3(by, 0));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
        }
    }

    // The first descendant of at with this x:Name (one inside a template).
    public static FrameworkElement? FindNamed(DependencyObject at, string name)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(at); i++)
        {
            var child = VisualTreeHelper.GetChild(at, i);
            if (child is FrameworkElement element && element.Name == name) return element;
            if (FindNamed(child, name) is { } found) return found;
        }
        return null;
    }

    // ---- the zoom -------------------------------------------------------------------

    private static Visual VisualOf(UIElement element) => ElementCompositionPreview.GetElementVisual(element);

    // A value that follows P. "z.P" in text is P; the scalars are its constants.
    private ExpressionAnimation Expr(string text, params (string Name, double Value)[] scalars)
    {
        var expression = compositor.CreateExpressionAnimation(text);
        expression.SetReferenceParameter("z", zoom);
        foreach (var (name, value) in scalars) expression.SetScalarParameter(name, (float)value);
        return expression;
    }

    // The fill under the view. The list behind is left as it is.
    private void Show()
    {
        var f = VisualOf(fill);
        f.StopAnimation("Opacity");
        f.Opacity = 1;
        fill.Visibility = Visibility.Visible;
    }

    private void Bind(Plan plan, bool opening)
    {
        double pageW = view.ActualWidth, pageH = view.ActualHeight;
        var card = plan.Card ?? ZoomMorph.VanishCard(pageW, pageH);
        double s0 = ZoomMorph.StartScale(card, pageW);

        // The view: scaled from its top-left, from the card's width to its own,
        // and moved from the card's place to its own.
        var v = VisualOf(view);
        v.CenterPoint = Vector3.Zero;
        const string scale = "(s0 + (1 - s0) * z.P)";
        v.StartAnimation("Scale", Expr($"Vector3({scale}, {scale}, 1)", ("s0", s0)));
        v.StartAnimation("Translation", Expr("Vector3(cx + (ox - cx) * z.P, cy + (oy - cy) * z.P, 0)",
            ("cx", card.X), ("cy", card.Y), ("ox", plan.Offset.X), ("oy", plan.Offset.Y)));

        // Cut to the card's height at the start, the page's at the end, with
        // round corners all the way (set before the scale, so divided by it).
        var outline = compositor.CreateRoundedRectangleGeometry();
        outline.StartAnimation("Size", Expr("Vector2(w, h0 + (h1 - h0) * z.P)",
            ("w", pageW), ("h0", ZoomMorph.StartHeight(card, pageW)), ("h1", pageH)));
        const string radius = "(r0 + (r1 - r0) * z.P)";
        outline.StartAnimation("CornerRadius", Expr($"Vector2({radius}, {radius})",
            ("r0", ZoomMorph.StartRadius(card, pageW)), ("r1", ZoomMorph.PageRadius)));
        v.Clip = compositor.CreateGeometricClip(outline);

        // Going back to a card that is not there: it fades as it shrinks.
        if (plan.Card is null) v.StartAnimation("Opacity", Expr("z.P"));
        else
        {
            v.StopAnimation("Opacity");
            v.Opacity = 1;
        }

        // The content rides on the card's top while the zoom is small (not a
        // picture's: its picture is the one flying, to the content's own place).
        var c = VisualOf(content);
        if (plan.Inset > 0 && plan.Flight is null)
        {
            c.StartAnimation("Translation", Expr("Vector3(0, sh * (1 - z.P), 0)", ("sh", ZoomMorph.StartShift(card, pageW, plan.Inset))));
        }
        else
        {
            c.StopAnimation("Translation");
            c.Properties.InsertVector3("Translation", Vector3.Zero);
        }

        // The card's picture of itself, over the view while it is small: live
        // (its own visual, drawn again here), at the view's top-left and the
        // card's size there before the scale, so on screen it is the card.
        // Over the content when opening; coming back over it when closing.
        DropCover();
        if (plan.Face is { ActualWidth: > 0, ActualHeight: > 0 } face && plan.Card is not null)
        {
            var surface = compositor.CreateVisualSurface();
            surface.SourceVisual = VisualOf(face);
            surface.SourceSize = new Vector2((float)face.ActualWidth, (float)face.ActualHeight);
            var brush = compositor.CreateSurfaceBrush(surface);
            brush.Stretch = CompositionStretch.Fill;
            var sprite = compositor.CreateSpriteVisual();
            sprite.Brush = brush;
            sprite.Size = new Vector2((float)(card.W / s0), (float)(card.H / s0));
            sprite.Opacity = opening ? 1 : 0;
            ElementCompositionPreview.SetElementChildVisual(cover, sprite);
            coverSprite = sprite;
            coverSurface = surface;
        }

        BindFlight(plan.Flight);
    }

    // The picture flies on its own, not clipped by the view: drawn at its size
    // in the full view and scaled (uniformly) and cut so that it covers a box
    // moving from its place on the card to its place in the view.
    private void BindFlight(Flight? flight)
    {
        if (flying == null) return;
        if (flight is null)
        {
            flying.Visibility = Visibility.Collapsed;
            return;
        }
        var to = flight.To;
        flying.Source = flight.Source;
        flying.Width = to.W;
        flying.Height = to.H;
        Canvas.SetLeft(flying, to.X);
        Canvas.SetTop(flying, to.Y);
        flying.Visibility = Visibility.Visible;

        var from = flight.From;
        (string, double)[] scalars =
        {
            ("fx", from.X), ("fy", from.Y), ("fw", from.W), ("fh", from.H),
            ("tx", to.X), ("ty", to.Y), ("w0", to.W), ("h0", to.H), ("rf", flight.RadiusFrom),
        };
        const string bx = "(fx + (tx - fx) * z.P)";
        const string by = "(fy + (ty - fy) * z.P)";
        const string bw = "(fw + (w0 - fw) * z.P)";
        const string bh = "(fh + (h0 - fh) * z.P)";
        const string k = $"Max({bw} / w0, {bh} / h0)";
        const string r = "(rf * (1 - z.P))";

        var f = VisualOf(flying);
        f.CenterPoint = new Vector3((float)(to.W / 2), (float)(to.H / 2), 0);
        f.StartAnimation("Scale", Expr($"Vector3({k}, {k}, 1)", scalars));
        f.StartAnimation("Translation", Expr($"Vector3({bx} + {bw} / 2 - (tx + w0 / 2), {by} + {bh} / 2 - (ty + h0 / 2), 0)", scalars));
        var box = compositor.CreateRoundedRectangleGeometry();
        box.StartAnimation("Offset", Expr($"Vector2((w0 - {bw} / {k}) / 2, (h0 - {bh} / {k}) / 2)", scalars));
        box.StartAnimation("Size", Expr($"Vector2({bw} / {k}, {bh} / {k})", scalars));
        box.StartAnimation("CornerRadius", Expr($"Vector2({r} / {k}, {r} / {k})", scalars));
        f.Clip = compositor.CreateGeometricClip(box);

        Hide(flight.CardPicture);
        Hide(flight.ViewPicture);
    }

    private void Hide(UIElement element)
    {
        var visual = VisualOf(element);
        visual.Opacity = 0;
        hidden.Add(visual);
    }

    // Runs P to target. One after the other, never a long crossfade of the
    // two (they are laid out at different widths and do not line up):
    // opening, the card's picture goes first and the view's content comes in
    // after it; closing, the content goes and the card's picture comes back
    // for it to land as.
    private void Run(float target, bool opening, Action? landed)
    {
        var move = compositor.CreateScalarKeyFrameAnimation();
        move.InsertExpressionKeyFrame(0f, "this.StartingValue");
        move.InsertKeyFrame(1f, target, ease);
        move.Duration = Duration;

        var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        zoom.StartAnimation("P", move);
        var sprite = ElementCompositionPreview.GetElementChildVisual(cover);
        if (opening)
        {
            if (sprite != null) Fade(sprite, 1f, 0f, 110, 0);
            Fade(VisualOf(content), 0f, 1f, 170, 70);
        }
        else
        {
            Fade(VisualOf(content), null, 0f, 110, 0);
            if (sprite != null) Fade(sprite, null, 1f, 140, 80);
        }
        batch.End();

        int run = ++generation;
        landing = landed;
        batch.Completed += (_, _) =>
        {
            if (run != generation) return;
            var done = landing;
            landing = null;
            Reset(keepFill: opening);
            done?.Invoke();
            if (opening) LetFillGo();
        };
    }

    // Opened, the list put away under it: the fill goes too, quickly, rather
    // than at once - it is the page's colour without the window's own Mica
    // tint, which shows through again once it has gone.
    private void LetFillGo()
    {
        try
        {
            var f = VisualOf(fill);
            var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
            Fade(f, 1f, 0f, 150, 0);
            batch.End();
            int run = generation;
            batch.Completed += (_, _) =>
            {
                if (run != generation) return;
                fill.Visibility = Visibility.Collapsed;
                f.Opacity = 1;
            };
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
            fill.Visibility = Visibility.Collapsed;
        }
    }

    private void DropCover()
    {
        ElementCompositionPreview.SetElementChildVisual(cover, null);
        coverSprite?.Brush?.Dispose();
        coverSprite?.Dispose();
        coverSurface?.Dispose();
        coverSprite = null;
        coverSurface = null;
    }

    // From (null: from wherever it is now) to, after delay.
    private void Fade(Visual visual, float? from, float to, int durationMs, int delayMs)
    {
        var fade = compositor.CreateScalarKeyFrameAnimation();
        if (from is { } start) fade.InsertKeyFrame(0f, start);
        else fade.InsertExpressionKeyFrame(0f, "this.StartingValue");
        fade.InsertKeyFrame(1f, to, sharp);
        fade.Duration = TimeSpan.FromMilliseconds(durationMs);
        if (delayMs > 0)
        {
            fade.DelayTime = TimeSpan.FromMilliseconds(delayMs);
            fade.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
        }
        visual.StartAnimation("Opacity", fade);
    }

    // Everything back at rest: the view at its own place and size, unclipped,
    // the fill (unless it is let go of next) and the cover gone, the
    // pictures shown again.
    private void Reset(bool keepFill = false)
    {
        try
        {
            zoom.StopAnimation("P");
            zoom.InsertScalar("P", 1f);

            var v = VisualOf(view);
            v.StopAnimation("Scale");
            v.Scale = Vector3.One;
            v.StopAnimation("Translation");
            v.Properties.InsertVector3("Translation", Vector3.Zero);
            v.StopAnimation("Opacity");
            v.Opacity = 1;
            v.Clip = null;
            view.IsHitTestVisible = true;

            var c = VisualOf(content);
            c.StopAnimation("Opacity");
            c.Opacity = 1;
            c.StopAnimation("Translation");
            c.Properties.InsertVector3("Translation", Vector3.Zero);

            if (!keepFill)
            {
                var f = VisualOf(fill);
                f.StopAnimation("Opacity");
                f.Opacity = 1;
                fill.Visibility = Visibility.Collapsed;
            }
            DropCover();

            if (flying != null)
            {
                var f = VisualOf(flying);
                f.StopAnimation("Scale");
                f.Scale = Vector3.One;
                f.StopAnimation("Translation");
                f.Properties.InsertVector3("Translation", Vector3.Zero);
                f.Clip = null;
                flying.Visibility = Visibility.Collapsed;
                flying.Source = null;
            }

            foreach (var visual in hidden) visual.Opacity = 1;
            hidden.Clear();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] card zoom failed: {ex.Message}");
        }
    }
}
