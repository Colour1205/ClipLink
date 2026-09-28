using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Wpf.Ui.Controls;

namespace ClipLink;

// A message across the top of a page - InfoBar-style, with an optional
// action button (e.g. "Try again") and close button.
public partial class Banner : UserControl
{
    public static readonly DependencyProperty SeverityProperty = DependencyProperty.Register(
        nameof(Severity), typeof(InfoBarSeverity), typeof(Banner), new PropertyMetadata(InfoBarSeverity.Informational, Changed));
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(
        nameof(Title), typeof(string), typeof(Banner), new PropertyMetadata(null, Changed));
    public static readonly DependencyProperty MessageProperty = DependencyProperty.Register(
        nameof(Message), typeof(string), typeof(Banner), new PropertyMetadata(null, Changed));
    public static readonly DependencyProperty ActionTextProperty = DependencyProperty.Register(
        nameof(ActionText), typeof(string), typeof(Banner), new PropertyMetadata(null, Changed));
    public static readonly DependencyProperty IsClosableProperty = DependencyProperty.Register(
        nameof(IsClosable), typeof(bool), typeof(Banner), new PropertyMetadata(false, Changed));

    public InfoBarSeverity Severity
    {
        get => (InfoBarSeverity)GetValue(SeverityProperty);
        set => SetValue(SeverityProperty, value);
    }

    public string? Title
    {
        get => (string?)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public string? Message
    {
        get => (string?)GetValue(MessageProperty);
        set => SetValue(MessageProperty, value);
    }

    public string? ActionText
    {
        get => (string?)GetValue(ActionTextProperty);
        set => SetValue(ActionTextProperty, value);
    }

    public bool IsClosable
    {
        get => (bool)GetValue(IsClosableProperty);
        set => SetValue(IsClosableProperty, value);
    }

    public event RoutedEventHandler? ActionClick;
    public event RoutedEventHandler? Closed;

    public Banner()
    {
        InitializeComponent();
        Refresh();
    }

    private static void Changed(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((Banner)d).Refresh();

    private void Refresh()
    {
        (string background, string iconBrush, SymbolRegular icon) = Severity switch
        {
            InfoBarSeverity.Error => ("InfoBarErrorSeverityBackgroundBrush", "InfoBarErrorSeverityIconBackground", SymbolRegular.ErrorCircle24),
            InfoBarSeverity.Warning => ("InfoBarWarningSeverityBackgroundBrush", "InfoBarWarningSeverityIconBackground", SymbolRegular.Warning24),
            InfoBarSeverity.Success => ("InfoBarSuccessSeverityBackgroundBrush", "InfoBarSuccessSeverityIconBackground", SymbolRegular.CheckmarkCircle24),
            _ => ("InfoBarInformationalSeverityBackgroundBrush", "InfoBarInformationalSeverityIconBackground", SymbolRegular.Info24),
        };
        Root.SetResourceReference(Border.BackgroundProperty, background);
        SeverityIcon.SetResourceReference(ForegroundProperty, iconBrush);
        SeverityIcon.Symbol = icon;

        TitleRun.Text = Title ?? "";
        MessageRun.Text = Message ?? "";
        Gap.Text = string.IsNullOrEmpty(Title) || string.IsNullOrEmpty(Message) ? "" : "  ";
        ActionButton.Content = ActionText;
        ActionButton.Visibility = string.IsNullOrEmpty(ActionText) ? Visibility.Collapsed : Visibility.Visible;
        CloseButton.Visibility = IsClosable ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(this, $"{Title} {Message}".Trim());
    }

    // Shows what's wrong with the engine, if anything, and hides itself
    // otherwise: Faulted (nothing syncs - e.g. the port is taken) as an
    // error with "Try again", Running with an Error (e.g. no LAN discovery)
    // as a warning.
    internal void TrackEngine(EngineHost host)
    {
        void Update()
        {
            if (host.IsFaulted)
            {
                Severity = InfoBarSeverity.Error;
                Title = "ClipLink can't sync.";
                Message = host.Status.Error;
                ActionText = "Try again";
            }
            else if (host.HasWarning)
            {
                Severity = InfoBarSeverity.Warning;
                Title = "Not everything is working.";
                Message = host.Status.Error;
                ActionText = null;
            }
            Visibility = host.IsFaulted || host.HasWarning ? Visibility.Visible : Visibility.Collapsed;
        }
        host.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(EngineHost.Status)) Update();
        };
        ActionClick += (_, _) =>
        {
            host.Retry();
            // (The banner itself still says why.)
            if (host.IsFaulted) App.MainAppWindow.ToastError("Still can't sync");
            else App.MainAppWindow.Toast("ClipLink is syncing again");
        };
        Update();
    }

    private void Action_Click(object sender, RoutedEventArgs e) => ActionClick?.Invoke(this, e);

    private void Close_Click(object sender, RoutedEventArgs e) => Closed?.Invoke(this, e);
}
