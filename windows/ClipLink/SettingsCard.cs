using System.Windows;
using System.Windows.Controls;
using Wpf.Ui.Controls;

namespace ClipLink;

// A Windows Settings-style row: icon, header and description on the left,
// its control (the Content) on the right - or under the text once the card
// is narrower than NarrowWidth. Template: App.xaml.
public class SettingsCard : ContentControl
{
    public static readonly DependencyProperty HeaderProperty = DependencyProperty.Register(
        nameof(Header), typeof(string), typeof(SettingsCard));
    public static readonly DependencyProperty DescriptionProperty = DependencyProperty.Register(
        nameof(Description), typeof(string), typeof(SettingsCard));
    public static readonly DependencyProperty IconProperty = DependencyProperty.Register(
        nameof(Icon), typeof(SymbolRegular), typeof(SettingsCard), new PropertyMetadata(SymbolRegular.Empty));
    public static readonly DependencyProperty NarrowWidthProperty = DependencyProperty.Register(
        nameof(NarrowWidth), typeof(double), typeof(SettingsCard), new PropertyMetadata(520.0));
    private static readonly DependencyPropertyKey IsNarrowKey = DependencyProperty.RegisterReadOnly(
        nameof(IsNarrow), typeof(bool), typeof(SettingsCard), new PropertyMetadata(false));
    public static readonly DependencyProperty IsNarrowProperty = IsNarrowKey.DependencyProperty;

    static SettingsCard()
    {
        FocusableProperty.OverrideMetadata(typeof(SettingsCard), new FrameworkPropertyMetadata(false));
    }

    public SettingsCard()
    {
        SizeChanged += (_, e) => SetValue(IsNarrowKey, e.NewSize.Width < NarrowWidth);
    }

    public string? Header
    {
        get => (string?)GetValue(HeaderProperty);
        set => SetValue(HeaderProperty, value);
    }

    public string? Description
    {
        get => (string?)GetValue(DescriptionProperty);
        set => SetValue(DescriptionProperty, value);
    }

    public SymbolRegular Icon
    {
        get => (SymbolRegular)GetValue(IconProperty);
        set => SetValue(IconProperty, value);
    }

    public double NarrowWidth
    {
        get => (double)GetValue(NarrowWidthProperty);
        set => SetValue(NarrowWidthProperty, value);
    }

    public bool IsNarrow => (bool)GetValue(IsNarrowProperty);
}
