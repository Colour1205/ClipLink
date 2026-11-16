using Xunit;
using Rect = ClipLink.ZoomMorph.Rect;

namespace ClipLink.Tests;

// The zoom a card opens into its full view with (ZoomMorph; CardZoom runs it
// on the compositor with the same arithmetic).
public class ZoomMorphTests
{
    // A grid card 300 x 240 at (420, 180) on a 1200 x 800 page.
    private static readonly Rect Card = new(420, 180, 300, 240);
    private const double PageW = 1200, PageH = 800;

    private static void Close(double expected, double actual) => Assert.Equal(expected, actual, 6);

    [Fact]
    public void Starts_exactly_on_the_card()
    {
        double s0 = ZoomMorph.StartScale(Card, PageW);
        Close(0.25, s0);
        Close(0.25, ZoomMorph.Scale(Card, PageW, 0));
        // On screen: the card's own width, height and corners.
        Close(Card.W, PageW * ZoomMorph.Scale(Card, PageW, 0));
        Close(Card.H, ZoomMorph.Height(Card, PageW, PageH, 0) * s0);
        Close(ZoomMorph.CardRadius, ZoomMorph.Radius(Card, PageW, 0) * s0);
        // The first line sits as far in from the card's top as the card's own.
        Close(12, ZoomMorph.Shift(Card, PageW, 12, 0) * s0);
    }

    [Fact]
    public void Ends_filling_the_page_with_round_corners()
    {
        Close(1, ZoomMorph.Scale(Card, PageW, 1));
        Close(PageH, ZoomMorph.Height(Card, PageW, PageH, 1));
        Close(ZoomMorph.PageRadius, ZoomMorph.Radius(Card, PageW, 1));
        Close(0, ZoomMorph.Shift(Card, PageW, 12, 1));
    }

    [Fact]
    public void Never_lets_the_corners_go_sharp_on_the_way()
    {
        for (int i = 0; i <= 20; i++)
        {
            double p = i / 20.0;
            double onScreen = ZoomMorph.Radius(Card, PageW, p) * ZoomMorph.Scale(Card, PageW, p);
            Assert.True(onScreen >= ZoomMorph.CardRadius - 1e-9, $"{onScreen} at {p}");
        }
    }

    [Fact]
    public void Is_never_squashed_and_stays_over_the_card_sideways()
    {
        // One scale for both directions, so the width on screen follows the
        // card's straight to the page's; the view never leaves the card's sides.
        for (int i = 0; i <= 20; i++)
        {
            double p = i / 20.0;
            double left = ZoomMorph.Lerp(Card.X, 0, p);
            double width = PageW * ZoomMorph.Scale(Card, PageW, p);
            Close(ZoomMorph.Lerp(Card.W, PageW, p), width);
            Assert.True(left <= Card.X + 1e-9 && left + width >= Card.X + Card.W - 1e-9);
        }
    }

    [Fact]
    public void A_card_with_no_size_or_no_page_does_not_divide_by_zero()
    {
        Close(1, ZoomMorph.StartScale(new Rect(0, 0, 0, 10), PageW));
        Close(1, ZoomMorph.StartScale(Card, 0));
    }

    [Fact]
    public void A_gone_card_is_the_middle_of_the_page()
    {
        var middle = ZoomMorph.VanishCard(PageW, PageH);
        Close(PageW / 2, middle.CenterX);
        Close(PageH / 2, middle.CenterY);
        Close(0.4, middle.W / PageW);
    }

    [Fact]
    public void Fits_a_picture_whole_and_centred()
    {
        // Wide: full width, centred down.
        var wide = ZoomMorph.Contain(new Rect(0, 0, 200, 200), 2);
        Close(200, wide.W);
        Close(100, wide.H);
        Close(50, wide.Y);
        // Tall: full height, centred across.
        var tall = ZoomMorph.Contain(new Rect(10, 0, 200, 200), 0.5);
        Close(100, tall.W);
        Close(60, tall.X);
        // Nothing to go by: the box itself.
        Assert.Equal(new Rect(1, 2, 3, 4), ZoomMorph.Contain(new Rect(1, 2, 3, 4), 0));
    }

    [Fact]
    public void The_flying_picture_covers_its_box_and_lands_at_its_own_size()
    {
        // A 400 x 300 picture in the full view, from a 60 x 60 list thumbnail.
        var from = new Rect(50, 100, 60, 60);
        var to = new Rect(36, 60, 400, 300);
        // At the start it is cropped to the square: scaled to cover its height.
        Close(0.2, ZoomMorph.CoverScale(from, to.W, to.H));
        Assert.True(to.W * ZoomMorph.CoverScale(from, to.W, to.H) >= from.W);
        // Where it lands: exactly its own size, nothing cut.
        Close(1, ZoomMorph.CoverScale(ZoomMorph.Lerp(from, to, 1), to.W, to.H));
        // On the way it always covers the box.
        for (int i = 0; i <= 10; i++)
        {
            var box = ZoomMorph.Lerp(from, to, i / 10.0);
            double k = ZoomMorph.CoverScale(box, to.W, to.H);
            Assert.True(to.W * k >= box.W - 1e-9 && to.H * k >= box.H - 1e-9);
        }
        // From a grid card, which shows it whole: the same shape all the way, never cut.
        var grid = ZoomMorph.Contain(new Rect(400, 200, 280, 280), to.W / to.H);
        Close(grid.W / to.W, ZoomMorph.CoverScale(grid, to.W, to.H));
        Close(grid.H / to.H, ZoomMorph.CoverScale(grid, to.W, to.H));
    }
}
