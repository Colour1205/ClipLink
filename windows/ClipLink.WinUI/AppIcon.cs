using System.IO;
using System.Runtime.InteropServices;

namespace ClipLink;

// The ClipLink icon (windows/ClipLink.ico: 16-256 px frames), as the tray
// and the title bar need it - each picks the frame drawn for its size
// rather than scaling a big one down, which blurs. The file sits next to
// the exe (the project copies it there).
internal static class AppIcon
{
    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();
    private const int SM_CXSMICON = 49;

    public static string Path { get; } = System.IO.Path.Combine(AppContext.BaseDirectory, "ClipLink.ico");

    // At the notification area's size (16 px at 100% scaling, 24 at 150%...).
    public static System.Drawing.Icon Tray()
    {
        int size = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForSystem());
        using var stream = File.OpenRead(Path);
        return new System.Drawing.Icon(stream, new System.Drawing.Size(size, size));
    }
}
