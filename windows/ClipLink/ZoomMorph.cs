namespace ClipLink;

// The arithmetic of the zoom a card opens into its full view with, and closes
// back by (CardZoom runs it). Plain C# on purpose (no WinUI), so ClipLink.Tests
// can link this file in and run it.
//
// The full view is laid out once, at its full size, and the whole of it is
// scaled down onto the tapped card and up again: its text grows with the card
// instead of being uncovered by a shape that grows over it (what the old morph
// did). One uniform scale, so nothing is ever squashed: the scale follows the
// card's width, and the view's height is cut to the card's at the start and
// grows to the page's. p is how far it is: 0 on the card, 1 the full view. A
// picture card's picture flies on its own, from where it sits on the card to
// where it sits in the full view. The same zoom as on the phones (HarmonyOS
// stack/ZoomMorph.ets).
internal static class ZoomMorph
{
    // A rectangle in DIPs, from the top-left of where the full view is laid out.
    internal readonly record struct Rect(double X, double Y, double W, double H)
    {
        public double CenterX => X + W / 2;
        public double CenterY => Y + H / 2;
    }

    // The corners: a card's (ControlCornerRadius) at the start, the window's
    // own (OverlayCornerRadius) once the view fills the page, so it never shows
    // a sharp corner on its way.
    public const double CardRadius = 4;
    public const double PageRadius = 8;

    // The list behind, at full strength: dimmed to this brightness (a black
    // layer of 1 - this over it) as well as blurred. Never faded.
    public const double BackdropBrightness = 0.85;

    public static double Lerp(double from, double to, double p) => from + (to - from) * p;

    public static Rect Lerp(Rect from, Rect to, double p) =>
        new(Lerp(from.X, to.X, p), Lerp(from.Y, to.Y, p), Lerp(from.W, to.W, p), Lerp(from.H, to.H, p));

    // The card's width over the page's: the scale the full view starts at.
    public static double StartScale(Rect card, double pageW) =>
        pageW <= 0 || card.W <= 0 ? 1 : card.W / pageW;

    public static double Scale(Rect card, double pageW, double p) => Lerp(StartScale(card, pageW), 1, p);

    // The view's height before it is scaled: the card's height at the start (in
    // the view's own, unscaled DIPs), the page's at the end.
    public static double StartHeight(Rect card, double pageW) => card.H / StartScale(card, pageW);

    public static double Height(Rect card, double pageW, double pageH, double p) =>
        Lerp(StartHeight(card, pageW), pageH, p);

    // The corner radius before it is scaled, so that on screen it is the
    // card's at the start and the page's at the end.
    public static double StartRadius(Rect card, double pageW) => CardRadius / StartScale(card, pageW);

    public static double Radius(Rect card, double pageW, double p) => Lerp(StartRadius(card, pageW), PageRadius, p);

    // How far the view's content is moved down while the zoom is small, so its
    // first line sits inset in from the card's top (where the card's own first
    // line is) at the start and in its own place, the view's top, at the end.
    public static double StartShift(Rect card, double pageW, double inset) => inset / StartScale(card, pageW);

    public static double Shift(Rect card, double pageW, double inset, double p) =>
        Lerp(StartShift(card, pageW, inset), 0, p);

    // Where a card that is gone (or could not be found) is taken to be: the
    // middle of the page, which the view shrinks toward as it fades.
    public static Rect VanishCard(double pageW, double pageH) =>
        new(pageW * 0.3, pageH * 0.35, pageW * 0.4, pageH * 0.3);

    // The rectangle a picture of this width-over-height ratio is drawn in when
    // it is fitted whole into box (Stretch Uniform): centred, as big as fits.
    public static Rect Contain(Rect box, double ratio)
    {
        if (ratio <= 0 || box.W <= 0 || box.H <= 0) return box;
        if (box.W / box.H > ratio)
        {
            double w = box.H * ratio;
            return new(box.X + (box.W - w) / 2, box.Y, w, box.H);
        }
        double h = box.W / ratio;
        return new(box.X, box.Y + (box.H - h) / 2, box.W, h);
    }

    // The flying picture is drawn at its size in the full view (rest) and
    // scaled by this, uniformly, so that it covers the box it flies through
    // (cropped to it, as the list's thumbnail is): never squashed.
    public static double CoverScale(Rect box, double restW, double restH) =>
        restW <= 0 || restH <= 0 ? 1 : Math.Max(box.W / restW, box.H / restH);
}
