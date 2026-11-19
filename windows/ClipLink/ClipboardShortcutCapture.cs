using System.Runtime.InteropServices;

namespace ClipLink;

// Windows routes already registered shortcuts away from normal KeyDown events.
// While this editor has focus, capture one combination before that routing so
// the editor can ask Windows whether the combination is available.
internal sealed class ClipboardShortcutCapture : IDisposable
{
    private const int KeyboardHook = 13;
    private const int Escape = 0x1b;
    private readonly nint owner;
    private readonly Action<ClipboardShortcut?> captured;
    private readonly HookProc callback;
    private nint hook;
    private int pendingKey;
    private ClipboardShortcut? pendingShortcut;

    public ClipboardShortcutCapture(nint owner, Action<ClipboardShortcut?> captured)
    {
        this.owner = owner;
        this.captured = captured;
        callback = OnKeyboard;
        hook = SetWindowsHookExW(KeyboardHook, callback, GetModuleHandleW(null), 0);
        if (hook == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError());
    }

    public void Dispose()
    {
        if (hook == 0) return;
        UnhookWindowsHookEx(hook);
        hook = 0;
        GC.KeepAlive(callback);
    }

    private nint OnKeyboard(int code, nint message, nint data)
    {
        if (code != 0 || GetForegroundWindow() != owner)
            return CallNextHookEx(hook, code, message, data);

        int key = Marshal.ReadInt32(data);
        bool down = (int)message is 0x0100 or 0x0104;
        bool up = (int)message is 0x0101 or 0x0105;
        if (pendingKey != 0 && key == pendingKey)
        {
            if (up)
            {
                pendingKey = 0;
                // Finish on release so a held key cannot trigger its new global shortcut.
                captured(pendingShortcut);
            }
            return 1;
        }

        // Let Tab move focus and let modifier presses reach the normal keyboard state.
        if (!down || pendingKey != 0 || key is 0x09 or 0x10 or 0x11 or 0x12 or 0x5b or 0x5c
            or >= 0xa0 and <= 0xa5)
            return CallNextHookEx(hook, code, message, data);

        pendingKey = key;
        uint modifiers = (IsDown(0x12) ? 1u : 0) | (IsDown(0x11) ? 2u : 0) | (IsDown(0x10) ? 4u : 0)
            | (IsDown(0x5b) || IsDown(0x5c) ? 8u : 0);
        pendingShortcut = key == Escape ? null : new ClipboardShortcut(modifiers, (uint)key);
        return 1;
    }

    private static bool IsDown(int key) => GetAsyncKeyState(key) < 0;
    private delegate nint HookProc(int code, nint message, nint data);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookExW(int id, HookProc callback, nint module, uint thread);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? name);
}
