using System.Windows.Input;
using H.NotifyIcon;
using H.NotifyIcon.Core;
using Microsoft.UI.Xaml.Controls;

namespace ClipLink;

internal enum TraySyncState { Syncing, Paused, Unavailable }

// The notification-area icon: a left click opens the window, a right click
// shows a small Fluent menu with Open, the sync switch and Quit. It carries
// notifications (what a share did, a sync that can't start).
internal sealed class Tray : IDisposable
{
    private readonly TaskbarIcon icon;
    private readonly ToggleMenuFlyoutItem syncItem;
    private readonly System.Drawing.Icon syncingIcon = AppIcon.Tray(TraySyncState.Syncing);
    private readonly System.Drawing.Icon pausedIcon = AppIcon.Tray(TraySyncState.Paused);
    private readonly System.Drawing.Icon unavailableIcon = AppIcon.Tray(TraySyncState.Unavailable);
    private readonly string name;

    public Tray(string name, Action open, Action toggleSync, Action quit)
    {
        this.name = name;
        var openItem = new MenuFlyoutItem { Text = "Open", Icon = new SymbolIcon(Symbol.OpenWith) };
        openItem.Click += (_, _) => open();
        syncItem = new ToggleMenuFlyoutItem { Text = "Auto-sync clipboard" };
        syncItem.Click += (_, _) => toggleSync();
        var quitItem = new MenuFlyoutItem { Text = "Quit", Icon = new SymbolIcon(Symbol.Cancel) };
        quitItem.Click += (_, _) => quit();

        // Short labels: the flyout's own window is sized from its items, and
        // a long one ("Quit ClipLink") is cut short.
        var menu = new MenuFlyout();
        menu.Items.Add(openItem);
        menu.Items.Add(syncItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(quitItem);

        icon = new TaskbarIcon
        {
            ToolTipText = name,
            // The menu is a real WinUI flyout (in a window of its own), so it
            // follows the theme and looks like the rest of the app.
            ContextMenuMode = ContextMenuMode.SecondWindow,
            ContextFlyout = menu,
            NoLeftClickDelay = true,
            LeftClickCommand = new Command(open),
        };
        // false: no Efficiency Mode - the engine syncs while the window is
        // hidden, and Windows must not throttle it.
        icon.UpdateIcon(unavailableIcon);
        icon.ForceCreate(false);
    }

    public void SetSyncState(bool enabled, bool available, string? shortcut)
    {
        syncItem.IsChecked = enabled;
        var (badge, state) = !enabled ? (pausedIcon, "Clipboard sync paused")
            : available ? (syncingIcon, "Clipboard sync on")
            : (unavailableIcon, "Clipboard sync unavailable");
        // Setting TaskbarIcon.Icon disposes the previous icon. Keep ownership of
        // these badges so we can switch back to them on the next toggle.
        if (!icon.UpdateIcon(badge))
            Console.WriteLine($"[tray] couldn't update the icon: {state}");
        icon.ToolTipText = $"{name} — {state} ({shortcut ?? "Shortcut unavailable"})";
    }

    // A Windows notification from the icon (clicking it opens the window).
    // Windows cuts the text at 255 characters.
    public void Notify(string title, string text, bool warning)
    {
        if (text.Length > 250) text = text[..249] + "…";
        icon.ShowNotification(title, text, warning ? NotificationIcon.Warning : NotificationIcon.Info);
    }

    public void Dispose()
    {
        icon.Dispose();
        syncingIcon.Dispose();
        pausedIcon.Dispose();
        unavailableIcon.Dispose();
    }

    private sealed class Command(Action action) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => action();
    }
}
