using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using WinForms = System.Windows.Forms;

namespace ClipLink;

// The ClipLink icon (windows/ClipLink.ico: 16-256 px frames), as the tray
// and the title bar need it - each picks the frame drawn for its size
// rather than scaling a big one down, which blurs.
internal static class AppIcon
{
    // At the notification area's size (SmallIconSize: 16 px at 100% scaling,
    // 24 at 150%...).
    public static System.Drawing.Icon Tray { get; } = LoadTray();

    // For the title bar: the frame closest to 16 px at the screen's scaling.
    public static ImageSource TitleBar { get; } = LoadFrame(WinForms.SystemInformation.SmallIconSize.Width);

    private static Stream Open() =>
        typeof(AppIcon).Assembly.GetManifestResourceStream("ClipLink.ico")
            ?? throw new InvalidOperationException("ClipLink.ico is not embedded");

    private static System.Drawing.Icon LoadTray()
    {
        using var stream = Open();
        return new System.Drawing.Icon(stream, WinForms.SystemInformation.SmallIconSize);
    }

    private static ImageSource LoadFrame(int pixels)
    {
        using var stream = Open();
        var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        // The smallest frame at least this big, else the biggest there is.
        var frame = decoder.Frames
            .OrderBy(f => f.PixelWidth < pixels ? 1 : 0)
            .ThenBy(f => f.PixelWidth < pixels ? -f.PixelWidth : f.PixelWidth)
            .First();
        frame.Freeze();
        return frame;
    }
}
