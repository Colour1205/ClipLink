namespace ClipboardDaemon.Clipboard;

using System.Runtime.InteropServices;
using System.Text;

// The Win32 clipboard, used directly - what ClipboardSync used WinForms for.
// WinForms (and the System.Windows.Forms assemblies it brought into every
// install, about 30 MB of them) did nothing here but open the clipboard,
// read or write these same formats and run a message loop. The formats
// written are the ones WinForms wrote: CF_UNICODETEXT for text (Windows makes
// CF_TEXT and CF_OEMTEXT from it), CF_HDROP with "FileNameW" and "FileName"
// for files, and a screen-compatible CF_BITMAP (Windows makes CF_DIB and
// CF_DIBV5 from it) and the "PNG" format for a picture.
//
// Every call that reads or writes the contents needs the clipboard open (see
// Open), and must come from the thread that opened it.
internal static class Win32Clipboard
{
    public const uint CF_BITMAP = 2;
    public const uint CF_WAVE = 12;
    public const uint CF_UNICODETEXT = 13;
    public const uint CF_HDROP = 15;

    public static readonly uint PngFormat = RegisterClipboardFormatW("PNG");
    private static readonly uint FileNameWFormat = RegisterClipboardFormatW("FileNameW");
    private static readonly uint FileNameFormat = RegisterClipboardFormatW("FileName");

    // The clipboard's sequence number: changes with every write to it, by
    // ClipLink or anything else. Any thread, clipboard open or not.
    public static uint Sequence => GetClipboardSequenceNumber();

    // The clipboard, open until disposed.
    public readonly struct Session : IDisposable
    {
        public void Dispose() => CloseClipboard();
    }

    // Opens the clipboard for owner (a window on this thread - see
    // MessageWindow), trying again while another app has it open: ten tries
    // 100 ms apart, as WinForms did. Throws ExternalException if it stays
    // busy.
    public static Session Open(nint owner)
    {
        for (int attempt = 1; ; attempt++)
        {
            if (OpenClipboard(owner)) return new Session();
            if (attempt >= 10) throw new ExternalException("The clipboard is in use by another app.", Marshal.GetLastPInvokeError());
            Thread.Sleep(100);
        }
    }

    // Whether the clipboard has (or Windows can make) this format. Needs no
    // Open.
    public static bool Has(uint format) => IsClipboardFormatAvailable(format);

    // ---- reading (clipboard open) ----

    // The text, up to its terminating NUL; null if there is none to read.
    public static string? GetText()
    {
        nint handle = GetClipboardData(CF_UNICODETEXT);
        if (handle == 0) return null;
        nint data = GlobalLock(handle);
        if (data == 0) return null;
        try
        {
            int chars = (int)Math.Min((long)GlobalSize(handle) / 2, int.MaxValue);
            var buffer = new char[chars];
            Marshal.Copy(data, buffer, 0, chars);
            int end = Array.IndexOf(buffer, '\0');
            return new string(buffer, 0, end < 0 ? chars : end);
        }
        finally
        {
            GlobalUnlock(handle);
        }
    }

    // The files' paths; null if there is no list to read.
    public static List<string>? GetFiles()
    {
        nint drop = GetClipboardData(CF_HDROP);
        if (drop == 0) return null;
        uint count = DragQueryFileW(drop, uint.MaxValue, null, 0);
        var files = new List<string>((int)Math.Min(count, 1024));
        for (uint i = 0; i < count; i++)
        {
            uint length = DragQueryFileW(drop, i, null, 0);
            var buffer = new char[length + 1];
            if (DragQueryFileW(drop, i, buffer, length + 1) > 0) files.Add(new string(buffer, 0, (int)length));
        }
        return files;
    }

    // The bitmap's handle, or 0. The clipboard's own: copy it (Bitmap.FromHbitmap), never delete it.
    public static nint GetBitmap() => GetClipboardData(CF_BITMAP);

    // ---- writing (clipboard open) ----

    // Empties the clipboard and makes the open session's window its owner -
    // before anything is set.
    public static void Empty()
    {
        if (!EmptyClipboard()) throw new ExternalException("Couldn't empty the clipboard.", Marshal.GetLastPInvokeError());
    }

    public static void SetText(string text) => SetGlobal(CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0"));

    // A file list (CF_HDROP: a DROPFILES header, then each path in UTF-16
    // with its NUL, then one more NUL), and the first path alone in the older
    // "FileNameW" and "FileName" formats, as WinForms put them.
    public static void SetFiles(IReadOnlyList<string> paths)
    {
        const int headerSize = 20; // DROPFILES: pFiles, pt.x, pt.y, fNC, fWide
        var list = new StringBuilder();
        foreach (string path in paths) list.Append(path).Append('\0');
        list.Append('\0');
        byte[] names = Encoding.Unicode.GetBytes(list.ToString());
        byte[] drop = new byte[headerSize + names.Length];
        BitConverter.TryWriteBytes(drop.AsSpan(0, 4), headerSize); // pFiles: where the names start
        BitConverter.TryWriteBytes(drop.AsSpan(16, 4), 1);         // fWide: they're UTF-16
        names.CopyTo(drop, headerSize);
        SetGlobal(CF_HDROP, drop);
        if (paths.Count > 0)
        {
            SetGlobal(FileNameWFormat, Encoding.Unicode.GetBytes(paths[0] + "\0"));
            SetGlobal(FileNameFormat, AnsiBytes(paths[0]));
        }
    }

    public static void SetBytes(uint format, byte[] bytes) => SetGlobal(format, bytes);

    // A bitmap: the clipboard owns it from here on, whether it went on or
    // not (one that didn't is deleted).
    public static void SetBitmap(nint bitmap)
    {
        if (SetClipboardData(CF_BITMAP, bitmap) != 0) return;
        int error = Marshal.GetLastPInvokeError();
        DeleteObject(bitmap);
        throw new ExternalException("Couldn't put the picture on the clipboard.", error);
    }

    // A copy of bitmap compatible with the screen - the CF_BITMAP WinForms
    // made (a device-dependent bitmap, which every app pasting a bitmap
    // reads; Windows makes the DIB formats from it). The caller still owns
    // bitmap; the copy is the caller's too until SetBitmap takes it.
    public static nint ScreenCompatibleCopy(nint bitmap, int width, int height)
    {
        nint screen = GetDC(0);
        nint source = CreateCompatibleDC(screen);
        nint target = CreateCompatibleDC(screen);
        nint copy = CreateCompatibleBitmap(screen, width, height);
        try
        {
            if (copy == 0) throw new ExternalException("Couldn't make a bitmap for the clipboard.", Marshal.GetLastPInvokeError());
            nint oldSource = SelectObject(source, bitmap);
            nint oldTarget = SelectObject(target, copy);
            bool copied = BitBlt(target, 0, 0, width, height, source, 0, 0, SRCCOPY);
            SelectObject(source, oldSource);
            SelectObject(target, oldTarget);
            if (!copied)
            {
                DeleteObject(copy);
                throw new ExternalException("Couldn't make a bitmap for the clipboard.", Marshal.GetLastPInvokeError());
            }
            return copy;
        }
        finally
        {
            DeleteDC(source);
            DeleteDC(target);
            ReleaseDC(0, screen);
        }
    }

    public static void DeleteBitmap(nint bitmap) => DeleteObject(bitmap);

    // Bytes in a global memory block the clipboard takes - or, if it won't,
    // freed again.
    private static void SetGlobal(uint format, byte[] bytes)
    {
        nint global = GlobalAlloc(GMEM_MOVEABLE, (nuint)Math.Max(bytes.Length, 1));
        if (global == 0) throw new OutOfMemoryException("Couldn't allocate memory for the clipboard.");
        nint data = GlobalLock(global);
        if (data == 0)
        {
            GlobalFree(global);
            throw new OutOfMemoryException("Couldn't allocate memory for the clipboard.");
        }
        Marshal.Copy(bytes, 0, data, bytes.Length);
        GlobalUnlock(global);
        if (SetClipboardData(format, global) == 0)
        {
            int error = Marshal.GetLastPInvokeError();
            GlobalFree(global);
            throw new ExternalException("Couldn't write the clipboard.", error);
        }
    }

    // A path in the system's ANSI code page, NUL-terminated.
    private static byte[] AnsiBytes(string text)
    {
        nint ansi = Marshal.StringToHGlobalAnsi(text);
        try
        {
            int length = 0;
            while (Marshal.ReadByte(ansi, length) != 0) length++;
            var bytes = new byte[length + 1];
            Marshal.Copy(ansi, bytes, 0, length);
            return bytes;
        }
        finally
        {
            Marshal.FreeHGlobal(ansi);
        }
    }

    // ---- interop ----

    private const uint GMEM_MOVEABLE = 0x0002;
    private const uint SRCCOPY = 0x00CC0020;

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(nint hWndNewOwner);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();
    [DllImport("user32.dll")]
    private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint GetClipboardData(uint format);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetClipboardData(uint format, nint hMem);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterClipboardFormatW(string format);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint DragQueryFileW(nint hDrop, uint iFile, char[]? lpszFile, uint cch);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalAlloc(uint uFlags, nuint dwBytes);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalLock(nint hMem);
    [DllImport("kernel32.dll")]
    private static extern bool GlobalUnlock(nint hMem);
    [DllImport("kernel32.dll")]
    private static extern nuint GlobalSize(nint hMem);
    [DllImport("kernel32.dll")]
    private static extern nint GlobalFree(nint hMem);
    [DllImport("user32.dll")]
    private static extern nint GetDC(nint hWnd);
    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint hWnd, nint hDC);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint CreateCompatibleDC(nint hdc);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern nint CreateCompatibleBitmap(nint hdc, int width, int height);
    [DllImport("gdi32.dll")]
    private static extern nint SelectObject(nint hdc, nint h);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool BitBlt(nint hdc, int x, int y, int cx, int cy, nint hdcSrc, int x1, int y1, uint rop);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(nint hdc);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint ho);
}

// A message-only window on the thread that makes it, with that thread's
// message loop (Run): what tells ClipboardSync the clipboard changed
// (WM_CLIPBOARDUPDATE, once it Listen()s), and what another thread wakes it
// with (Post) - in place of WinForms' loop and a timer polling every 500 ms.
internal sealed class MessageWindow : IDisposable
{
    public const uint WM_TIMER = 0x0113;
    public const uint WM_CLIPBOARDUPDATE = 0x031D;
    public const uint WM_APP = 0x8000;

    private delegate nint WndProc(nint hwnd, uint msg, nint wParam, nint lParam);

    private static int instances;
    // Kept alive as long as the window: Windows calls it.
    private readonly WndProc proc;
    private readonly string className;
    private readonly Func<uint, nint, bool> handle;
    private bool listening;

    public nint Handle { get; }

    // handle(message, wParam) returns whether it dealt with the message. It
    // runs on this thread, from Run, and must not throw - an exception can't
    // pass back through Windows; one that does is logged and dropped.
    public MessageWindow(Func<uint, nint, bool> handle)
    {
        this.handle = handle;
        proc = Dispatch;
        className = $"ClipLinkClipboard{Environment.ProcessId}_{Interlocked.Increment(ref instances)}";
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc),
            hInstance = GetModuleHandleW(null),
            lpszClassName = className,
        };
        if (RegisterClassExW(ref windowClass) == 0) throw new ExternalException("Couldn't register the clipboard window's class.", Marshal.GetLastPInvokeError());
        Handle = CreateWindowExW(0, className, className, 0, 0, 0, 0, 0, HWND_MESSAGE, 0, windowClass.hInstance, 0);
        if (Handle == 0)
        {
            int error = Marshal.GetLastPInvokeError();
            UnregisterClassW(className, windowClass.hInstance);
            throw new ExternalException("Couldn't create the clipboard window.", error);
        }
    }

    // WM_CLIPBOARDUPDATE from now on, after every change to the clipboard.
    public void Listen()
    {
        if (!AddClipboardFormatListener(Handle)) throw new ExternalException("Couldn't listen for clipboard changes.", Marshal.GetLastPInvokeError());
        listening = true;
    }

    // Any thread.
    public void Post(uint message) => PostMessageW(Handle, message, 0, 0);

    // A WM_TIMER (wParam id) in ms, once - unless set again first (it then
    // counts from now) or stopped (StopTimer).
    public void SetTimer(nint id, uint ms) => SetTimerNative(Handle, id, ms, 0);

    public void StopTimer(nint id) => KillTimer(Handle, id);

    // The thread's message loop: runs until Quit.
    public void Run()
    {
        while (GetMessageW(out MSG message, 0, 0, 0) > 0)
        {
            DispatchMessageW(ref message);
        }
    }

    // Ends Run, from its own thread (a handler).
    public static void Quit() => PostQuitMessage(0);

    public void Dispose()
    {
        if (listening) RemoveClipboardFormatListener(Handle);
        DestroyWindow(Handle);
        UnregisterClassW(className, GetModuleHandleW(null));
    }

    private nint Dispatch(nint hwnd, uint msg, nint wParam, nint lParam)
    {
        try
        {
            if (handle(msg, wParam)) return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[clip] clipboard window message 0x{msg:X} failed: {ex.GetType().Name}: {ex.Message}");
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    private static readonly nint HWND_MESSAGE = -3;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public nint lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public nint hInstance;
        public nint hIcon;
        public nint hCursor;
        public nint hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public nint hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public nint hwnd;
        public uint message;
        public nint wParam;
        public nint lParam;
        public uint time;
        public int ptX;
        public int ptY;
        public uint lPrivate;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? moduleName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEXW windowClass);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool UnregisterClassW(string className, nint hInstance);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowExW(uint exStyle, string className, string windowName, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);
    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(nint hwnd);
    [DllImport("user32.dll")]
    private static extern nint DefWindowProcW(nint hwnd, uint msg, nint wParam, nint lParam);
    [DllImport("user32.dll")]
    private static extern int GetMessageW(out MSG msg, nint hwnd, uint filterMin, uint filterMax);
    [DllImport("user32.dll")]
    private static extern nint DispatchMessageW(ref MSG msg);
    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int exitCode);
    [DllImport("user32.dll")]
    private static extern bool PostMessageW(nint hwnd, uint msg, nint wParam, nint lParam);
    [DllImport("user32.dll", EntryPoint = "SetTimer")]
    private static extern nint SetTimerNative(nint hwnd, nint id, uint elapse, nint timerProc);
    [DllImport("user32.dll")]
    private static extern bool KillTimer(nint hwnd, nint id);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AddClipboardFormatListener(nint hwnd);
    [DllImport("user32.dll")]
    private static extern bool RemoveClipboardFormatListener(nint hwnd);
}
