using Microsoft.UI.Xaml.Controls;

namespace ClipLink;

// A message across the top of a page that shows what's wrong with the
// engine, if anything, and hides itself otherwise: Faulted (nothing syncs -
// e.g. the port is taken) as an error with "Try again", Running with an
// Error (e.g. no LAN discovery) as a warning.
internal static class EngineBanner
{
    public static void Track(InfoBar bar, EngineHost host)
    {
        var retry = new Button { Content = "Try again" };
        retry.Click += (_, _) =>
        {
            host.Retry();
            // (The banner itself still says why.)
            if (host.IsFaulted) App.MainAppWindow.ToastError("Still can't sync");
            else App.MainAppWindow.Toast("ClipLink is syncing again");
        };
        bar.ActionButton = retry;
        bar.IsClosable = false;

        void Update()
        {
            if (host.IsFaulted)
            {
                bar.Severity = InfoBarSeverity.Error;
                bar.Title = "ClipLink can't sync.";
                bar.Message = host.Status.Error ?? "";
                retry.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
            }
            else if (host.HasWarning)
            {
                bar.Severity = InfoBarSeverity.Warning;
                bar.Title = "Not everything is working.";
                bar.Message = host.Status.Error ?? "";
                retry.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            }
            bar.IsOpen = host.IsFaulted || host.HasWarning;
        }
        host.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(EngineHost.Status)) Update();
        };
        Update();
    }
}
