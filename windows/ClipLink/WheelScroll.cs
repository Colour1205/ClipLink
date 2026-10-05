using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace ClipLink;

// Mouse-wheel scrolling that's quick. WinUI moves a mouse notch only a few
// lines (about 48 px) and animates it slowly, and has no setting for either.
// A notch (a wheel delta that's a whole 120) is scrolled here instead: by
// Windows' "lines to scroll" setting (3 by default) at 36 px a line, and
// moved frame by frame - each frame covers most of what's left, so a notch
// settles in about 130 ms like a browser's, and notches that come quickly
// add up smoothly. A precision touchpad sends smaller deltas: those scroll by
// exactly the distance the fingers moved, as WinUI does, at once - the
// touchpad's own momentum arrives as more small deltas.
internal static class WheelScroll
{
    [DllImport("user32.dll")]
    private static extern bool SystemParametersInfo(uint action, uint param, out uint value, uint winIni);
    private const uint SPI_GETWHEELSCROLLLINES = 0x0068;
    private const double LineHeight = 36;
    // "One screen at a time" is reported as this.
    private const uint WheelPageScroll = uint.MaxValue;
    // How far WinUI itself scrolls for a delta of 120, in screen pixels;
    // small deltas keep that scale.
    private const double DefaultNotchPixels = 48;

    // How quickly the view closes on its target: after this long, about two
    // thirds of the way there; after three times this, 95%.
    private const double TimeConstantMs = 30;

    // A ScrollViewer hands the wheel to XAML, so listening on its content is enough.
    public static void Attach(ScrollViewer scroller)
    {
        if (scroller.Content is not UIElement content) return;
        var motion = new Motion(
            () => scroller.VerticalOffset, () => scroller.ScrollableHeight, () => scroller.ViewportHeight,
            offset => scroller.ChangeView(null, offset, null, disableAnimation: true),
            () => content.XamlRoot?.RasterizationScale ?? 1, handlesSmallDeltas: false);
        // On the content, not the scroller: the scroller handles the wheel
        // itself and marks it handled, so it would never get here.
        content.PointerWheelChanged += (_, e) => motion.OnWheel(e);
    }

    // A ScrollView (what ItemsView scrolls with) takes the wheel before XAML
    // ever sees it, in the composition layer. Telling it to ignore the wheel
    // makes the events arrive; the touch and keyboard handling stays its own.
    public static void Attach(ScrollView scroller)
    {
        scroller.IgnoredInputKinds = ScrollingInputKinds.MouseWheel;
        // Listening on the ScrollView itself, with a background so that the
        // gaps and margins around the content count as being over it too.
        scroller.Background ??= new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        var motion = new Motion(
            () => scroller.VerticalOffset, () => scroller.ScrollableHeight, () => scroller.ViewportHeight,
            offset => scroller.ScrollTo(scroller.HorizontalOffset, offset, new ScrollingScrollOptions(ScrollingAnimationMode.Disabled)),
            () => scroller.XamlRoot?.RasterizationScale ?? 1, handlesSmallDeltas: true);
        scroller.PointerWheelChanged += (_, e) => motion.OnWheel(e);
    }

    // One scroller's wheel scrolling.
    private sealed class Motion(Func<double> offset, Func<double> scrollable, Func<double> viewport, Action<double> scrollTo,
        Func<double> scale, bool handlesSmallDeltas)
    {
        private double current;          // where the view was last put
        private double target;           // where it's heading
        private long lastFrame;
        private bool running;
        private long lastDirect;         // when a touchpad delta last moved the view
        private double direct;           // where it put it (the scroller's own offset lags a frame behind)

        public void OnWheel(PointerRoutedEventArgs e)
        {
            var properties = e.GetCurrentPoint(null).Properties;
            int delta = properties.MouseWheelDelta;
            // A sideways wheel, or zooming: not ours.
            if (properties.IsHorizontalMouseWheel || delta == 0) return;
            if ((e.KeyModifiers & (VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift)) != 0) return;
            if (scrollable() <= 0) return;

            if (delta % 120 != 0)
            {
                // Not a mouse notch: the fingers' distance, at once. (A
                // ScrollViewer still does this itself.)
                if (!handlesSmallDeltas) return;
                long now = Environment.TickCount64;
                if (running) { direct = current; Stop(); }
                else if (now - lastDirect > 200) direct = offset();
                direct = Math.Clamp(direct - delta / 120.0 * DefaultNotchPixels / scale(), 0, scrollable());
                lastDirect = now;
                scrollTo(direct);
                e.Handled = true;
                return;
            }

            if (!running)
            {
                // From wherever the view is now (it may have been moved by
                // a touchpad, the scroll bar or the keyboard since).
                current = target = (Environment.TickCount64 - lastDirect > 200) ? offset() : direct;
            }
            target = Math.Clamp(target - delta / 120.0 * NotchDistance(viewport()), 0, scrollable());
            e.Handled = true;
            if (running) return;
            running = true;
            lastFrame = Environment.TickCount64;
            CompositionTarget.Rendering += OnFrame;
        }

        private void OnFrame(object? sender, object e)
        {
            long now = Environment.TickCount64;
            double dt = Math.Clamp(now - lastFrame, 1, 100);
            lastFrame = now;

            target = Math.Clamp(target, 0, scrollable());
            // Moved by something else meanwhile (touchpad, scroll bar): let go.
            if (Math.Abs(offset() - current) > 3 && Math.Abs(current - target) < 0.5) { Stop(); return; }

            current += (target - current) * (1 - Math.Exp(-dt / TimeConstantMs));
            if (Math.Abs(target - current) < 0.5) current = target;
            scrollTo(current);
            if (current == target) Stop();
        }

        private void Stop()
        {
            running = false;
            CompositionTarget.Rendering -= OnFrame;
        }
    }

    // How far one notch scrolls, in device-independent pixels.
    private static double NotchDistance(double viewportHeight)
    {
        if (!SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, out uint lines, 0)) lines = 3;
        if (lines == WheelPageScroll) return Math.Max(LineHeight, viewportHeight * 0.9);
        return Math.Max(1, lines) * LineHeight;
    }
}
