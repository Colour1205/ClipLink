using System.Windows.Input;
using H.NotifyIcon;
using H.NotifyIcon.Core;
using Microsoft.UI.Xaml.Controls;

namespace ClipLink;

// The notification-area icon: a left click opens the window, a right click
// shows a small Fluent menu with Open and Quit, and it carries the balloon
// notifications (what a share did, a sync that can't start).
internal sealed class Tray : IDisposable
{
    private readonly TaskbarIcon icon;

    public Tray(string toolTip, Action open, Action quit)
    {
        var openItem = new MenuFlyoutItem { Text = "Open ClipLink", Icon = new SymbolIcon(Symbol.OpenWith) };
        openItem.Click += (_, _) => open();
        var quitItem = new MenuFlyoutItem { Text = "Quit ClipLink", Icon = new SymbolIcon(Symbol.Cancel) };
        quitItem.Click += (_, _) => quit();

        var menu = new MenuFlyout();
        menu.Items.Add(openItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(quitItem);

        icon = new TaskbarIcon
        {
            ToolTipText = toolTip,
            Icon = AppIcon.Tray(),
            // The menu is a real WinUI flyout (in a window of its own), so it
            // follows the theme and looks like the rest of the app.
            ContextMenuMode = ContextMenuMode.SecondWindow,
            ContextFlyout = menu,
            NoLeftClickDelay = true,
            LeftClickCommand = new Command(open),
        };
        // false: no Efficiency Mode - the engine syncs while the window is
        // hidden, and Windows must not throttle it.
        icon.ForceCreate(false);
    }

    // A Windows notification from the icon (clicking it opens the window).
    // Windows cuts the text at 255 characters.
    public void Notify(string title, string text, bool warning)
    {
        if (text.Length > 250) text = text[..249] + "…";
        icon.ShowNotification(title, text, warning ? NotificationIcon.Warning : NotificationIcon.Info);
    }

    public void Dispose() => icon.Dispose();

    private sealed class Command(Action action) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => action();
    }
}
