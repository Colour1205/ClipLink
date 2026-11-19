using System.Runtime.InteropServices;
using ClipboardDaemon.Clipboard;

namespace ClipLink;

// Register on the app's UI thread, whose message loop runs even in the tray.
internal sealed class ClipboardSyncHotkey : IDisposable
{
    private const uint WmHotkey = 0x0312;
    private const int HotkeyId = 1;
    private const uint ModNoRepeat = 0x4000;
    private readonly MessageWindow window;

    private ClipboardSyncHotkey(MessageWindow window) => this.window = window;

    public static ClipboardSyncHotkey? TryRegister(ClipboardShortcut shortcut, Action toggle)
    {
        MessageWindow window;
        try
        {
            window = new MessageWindow((message, id) =>
            {
                if (message != WmHotkey || id != HotkeyId) return false;
                toggle();
                return true;
            });
        }
        catch (ExternalException ex)
        {
            Console.WriteLine($"[hotkey] couldn't create a window for {shortcut}: {ex.Message}");
            return null;
        }
        if (RegisterHotKey(window.Handle, HotkeyId, shortcut.Modifiers | ModNoRepeat, shortcut.Key))
            return new ClipboardSyncHotkey(window);

        Console.WriteLine($"[hotkey] couldn't register {shortcut} (Windows error {Marshal.GetLastPInvokeError()})");
        window.Dispose();
        return null;
    }

    public void Dispose()
    {
        UnregisterHotKey(window.Handle, HotkeyId);
        window.Dispose();
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint window, int id);
}
