using System.Globalization;

namespace ClipLink;

// Short human-readable text for times and sizes, in the user's culture.
internal static class Format
{
    // "Just now", "5 min ago", "3 hr ago", "Yesterday 14:05", "21 Sep 14:05",
    // "21 Sep 2025". Relative only while it's short.
    public static string When(DateTime utc, DateTime nowUtc)
    {
        TimeSpan age = nowUtc - utc;
        DateTime local = utc.ToLocalTime();
        DateTime today = nowUtc.ToLocalTime().Date;
        string time = local.ToString("t", CultureInfo.CurrentCulture);
        if (age < TimeSpan.FromMinutes(1)) return "Just now";
        if (age < TimeSpan.FromHours(1)) return $"{(int)age.TotalMinutes} min ago";
        if (local.Date == today) return age < TimeSpan.FromHours(6) ? $"{(int)age.TotalHours} hr ago" : $"Today {time}";
        if (local.Date == today.AddDays(-1)) return $"Yesterday {time}";
        string monthDay = CultureInfo.CurrentCulture.DateTimeFormat.MonthDayPattern;
        if (local.Year == today.Year) return $"{local.ToString(monthDay, CultureInfo.CurrentCulture)} {time}";
        return local.ToString("d", CultureInfo.CurrentCulture);
    }

    // For a tooltip: the full date and time.
    public static string Exactly(DateTime utc) => utc.ToLocalTime().ToString("F", CultureInfo.CurrentCulture);

    // "512 bytes", "12.3 KB", "4.5 MB", "1.2 GB" (1 KB = 1024 bytes, as
    // Explorer shows sizes).
    public static string Size(long bytes)
    {
        if (bytes < 1024) return bytes == 1 ? "1 byte" : $"{bytes} bytes";
        string[] units = { "KB", "MB", "GB", "TB" };
        double value = bytes;
        int unit = -1;
        do
        {
            value /= 1024;
            unit++;
        } while (value >= 1024 && unit < units.Length - 1);
        return value < 10
            ? $"{value.ToString("0.#", CultureInfo.CurrentCulture)} {units[unit]}"
            : $"{value.ToString("0", CultureInfo.CurrentCulture)} {units[unit]}";
    }

    public static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n} {many}";
}
