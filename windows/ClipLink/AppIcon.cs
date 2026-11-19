using System.Drawing;
using System.Drawing.Drawing2D;
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
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);
    private const int SM_CXSMICON = 49;

    public static string Path { get; } = System.IO.Path.Combine(AppContext.BaseDirectory, "ClipLink.ico");

    // At the notification area's size (16 px at 100% scaling, 24 at 150%...).
    public static Icon Tray(TraySyncState state)
    {
        int size = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForSystem());
        using var stream = File.OpenRead(Path);
        using var original = new Icon(stream, new Size(size, size));
        using var bitmap = original.ToBitmap();
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float badge = size * 0.59f;
        float corner = size - badge;
        using var fill = new SolidBrush(state switch
        {
            TraySyncState.Syncing => Color.FromArgb(16, 110, 72),
            TraySyncState.Paused => Color.FromArgb(105, 75, 25),
            _ => Color.FromArgb(76, 82, 92),
        });
        graphics.FillEllipse(Brushes.White, corner, corner, badge, badge);
        graphics.FillEllipse(fill, corner + 1, corner + 1, badge - 2, badge - 2);
        using var stroke = new Pen(Color.White, size / 13f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        PointF Point(float x, float y) => new(corner + x * badge, corner + y * badge);
        switch (state)
        {
            case TraySyncState.Syncing:
                graphics.DrawLines(stroke, new[] { Point(0.29f, 0.51f), Point(0.44f, 0.66f), Point(0.71f, 0.35f) });
                break;
            case TraySyncState.Paused:
                graphics.DrawLine(stroke, Point(0.39f, 0.33f), Point(0.39f, 0.67f));
                graphics.DrawLine(stroke, Point(0.61f, 0.33f), Point(0.61f, 0.67f));
                break;
            case TraySyncState.Unavailable:
                graphics.DrawLine(stroke, Point(0.32f, 0.5f), Point(0.68f, 0.5f));
                break;
        }
        nint handle = bitmap.GetHicon();
        try
        {
            using var icon = Icon.FromHandle(handle);
            return (Icon)icon.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }
}
