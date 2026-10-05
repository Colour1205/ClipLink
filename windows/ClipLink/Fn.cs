using Microsoft.UI.Xaml;

namespace ClipLink;

// Static helpers for x:Bind function bindings: the Visibility conversions
// x:Bind doesn't do by itself (it only converts a plain bool).
public static class Fn
{
    public static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility VisibleIfNot(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    // Visible when the value isn't null (or an empty string).
    public static Visibility VisibleIfSet(object? value) =>
        value == null || value is string { Length: 0 } ? Visibility.Collapsed : Visibility.Visible;
}
