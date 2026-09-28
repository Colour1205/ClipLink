using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace ClipLink;

// Visible when the bound bool is false (the opposite of BooleanToVisibilityConverter).
public sealed class VisibleIfNotConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

// Visible when the bound value isn't null (or an empty string).
public sealed class VisibleIfSetConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value == null || value is string { Length: 0 } ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

// The grid's thumbnail height: its width (values[0]) times the image's
// height/width (values[1]), at most MaxHeight (a taller image is cropped to
// that, like the phones' grid); Placeholder until the size is known.
public sealed class AspectHeightConverter : IMultiValueConverter
{
    public double MaxHeight { get; set; } = 320;
    public double Placeholder { get; set; } = 120;

    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture) =>
        values is [double width, double ratio, ..] && width > 0 && ratio > 0
            ? Math.Min(MaxHeight, Math.Round(width * ratio))
            : Placeholder;

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
