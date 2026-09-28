using System.Windows;
using System.Windows.Controls;

namespace ClipLink;

// The Synced page's cards. Grid view: as many equal columns as fit (each at
// least MinColumnWidth wide, at most MaxColumns), every card going into the
// column that's shortest so far - so cards of different heights pack like
// the phones' staggered grid, and still read newest-first, left to right.
// List view is the same with MaxColumns 1. Not virtualising: history holds
// at most 25 items.
public sealed class MasonryPanel : Panel
{
    public static readonly DependencyProperty MinColumnWidthProperty = DependencyProperty.Register(
        nameof(MinColumnWidth), typeof(double), typeof(MasonryPanel),
        new FrameworkPropertyMetadata(280.0, FrameworkPropertyMetadataOptions.AffectsMeasure));
    public static readonly DependencyProperty MaxColumnsProperty = DependencyProperty.Register(
        nameof(MaxColumns), typeof(int), typeof(MasonryPanel),
        new FrameworkPropertyMetadata(int.MaxValue, FrameworkPropertyMetadataOptions.AffectsMeasure));
    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        nameof(Spacing), typeof(double), typeof(MasonryPanel),
        new FrameworkPropertyMetadata(8.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double MinColumnWidth
    {
        get => (double)GetValue(MinColumnWidthProperty);
        set => SetValue(MinColumnWidthProperty, value);
    }

    public int MaxColumns
    {
        get => (int)GetValue(MaxColumnsProperty);
        set => SetValue(MaxColumnsProperty, value);
    }

    // Between columns, and between cards in a column.
    public double Spacing
    {
        get => (double)GetValue(SpacingProperty);
        set => SetValue(SpacingProperty, value);
    }

    // Where Measure put each child, for Arrange.
    private Rect[] slots = Array.Empty<Rect>();

    protected override Size MeasureOverride(Size available)
    {
        double width = double.IsInfinity(available.Width) ? MinColumnWidth : available.Width;
        int columns = Math.Clamp((int)((width + Spacing) / (MinColumnWidth + Spacing)), 1, Math.Max(1, MaxColumns));
        double columnWidth = Math.Max(0, (width - Spacing * (columns - 1)) / columns);
        var heights = new double[columns];
        slots = new Rect[InternalChildren.Count];
        for (int i = 0; i < InternalChildren.Count; i++)
        {
            UIElement child = InternalChildren[i];
            child.Measure(new Size(columnWidth, double.PositiveInfinity));
            if (child.Visibility == Visibility.Collapsed) continue;
            int column = Array.IndexOf(heights, heights.Min());
            double top = heights[column] == 0 ? 0 : heights[column] + Spacing;
            slots[i] = new Rect(column * (columnWidth + Spacing), top, columnWidth, child.DesiredSize.Height);
            heights[column] = top + child.DesiredSize.Height;
        }
        return new Size(width, heights.Max());
    }

    protected override Size ArrangeOverride(Size final)
    {
        for (int i = 0; i < InternalChildren.Count && i < slots.Length; i++)
        {
            InternalChildren[i].Arrange(slots[i]);
        }
        return final;
    }
}
