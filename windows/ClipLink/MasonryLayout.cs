using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace ClipLink;

// The Synced page's cards. Grid view: as many equal columns as fit (each at
// least MinColumnWidth wide, at most MaxColumns), every card going into the
// column that's shortest so far - so cards of different heights pack like
// the phones' staggered grid, and still read newest-first, left to right.
// List view is the same with MaxColumns 1 (and MaxWidth, so a card doesn't
// stretch across a wide window). Not virtualising: history holds at most 25
// items.
public sealed class MasonryLayout : NonVirtualizingLayout
{
    private double minColumnWidth = 280;
    private int maxColumns = int.MaxValue;
    private double spacing = 8;
    private double maxWidth = double.PositiveInfinity;

    public double MinColumnWidth { get => minColumnWidth; set => Set(ref minColumnWidth, value); }
    public int MaxColumns { get => maxColumns; set => Set(ref maxColumns, value); }
    // Between columns, and between cards in a column.
    public double Spacing { get => spacing; set => Set(ref spacing, value); }
    // The whole layout is at most this wide, from the left.
    public double MaxWidth { get => maxWidth; set => Set(ref maxWidth, value); }

    private void Set<T>(ref T field, T value)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        InvalidateMeasure();
    }

    // Where Measure put each child, for Arrange.
    private Rect[] slots = Array.Empty<Rect>();

    protected override Size MeasureOverride(NonVirtualizingLayoutContext context, Size available)
    {
        double width = double.IsInfinity(available.Width) ? minColumnWidth : Math.Min(available.Width, maxWidth);
        int columns = Math.Clamp((int)((width + spacing) / (minColumnWidth + spacing)), 1, Math.Max(1, maxColumns));
        double columnWidth = Math.Max(0, (width - spacing * (columns - 1)) / columns);
        var heights = new double[columns];
        var children = context.Children;
        slots = new Rect[children.Count];
        for (int i = 0; i < children.Count; i++)
        {
            UIElement child = children[i];
            child.Measure(new Size(columnWidth, double.PositiveInfinity));
            if (child.Visibility == Visibility.Collapsed) continue;
            int column = Array.IndexOf(heights, heights.Min());
            double top = heights[column] == 0 ? 0 : heights[column] + spacing;
            slots[i] = new Rect(column * (columnWidth + spacing), top, columnWidth, child.DesiredSize.Height);
            heights[column] = top + child.DesiredSize.Height;
        }
        return new Size(width, heights.Max());
    }

    protected override Size ArrangeOverride(NonVirtualizingLayoutContext context, Size final)
    {
        var children = context.Children;
        for (int i = 0; i < children.Count && i < slots.Length; i++)
        {
            children[i].Arrange(slots[i]);
        }
        return final;
    }
}
