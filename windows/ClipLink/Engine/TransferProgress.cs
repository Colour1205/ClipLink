using System.Globalization;

namespace ClipboardDaemon.Engine;

// How fast a file is arriving, from how much of it had arrived at a few
// moments (the Synced page looks about 4 times a second). Kept per file by
// the UI, which has the clock; nothing here runs on its own.
//
// The speed is over the last WindowMs, so one slow or quick moment doesn't
// make the number jump about. None is shown for the first HideFirstMs (a
// speed from one or two samples is mostly noise), and a file that has had no
// new bytes for StallMs counts as stalled (the card then says "Waiting").
public sealed class TransferSpeed
{
    public const long WindowMs = 2000;
    public const long HideFirstMs = 750;
    public const long StallMs = 3000;

    // Oldest first. The first one is the newest at or before the window's
    // start, so the speed always spans the whole window once there is data
    // that old.
    private readonly List<(long At, long Received)> samples = new();
    private long firstAt = -1;
    private long grewAt;
    private long received = -1;

    // How much had arrived at nowMs (a millisecond clock, such as
    // Environment.TickCount64). Fewer bytes than before is the file starting
    // over (its sender began again at chunk 0): counted from there.
    public void Add(long nowMs, long receivedBytes)
    {
        if (receivedBytes < received) Reset();
        if (firstAt < 0)
        {
            firstAt = nowMs;
            grewAt = nowMs;
        }
        else if (receivedBytes > received)
        {
            grewAt = nowMs;
        }
        received = receivedBytes;
        samples.Add((nowMs, receivedBytes));
        while (samples.Count > 1 && samples[1].At <= nowMs - WindowMs) samples.RemoveAt(0);
    }

    // Bytes a second over the last WindowMs, up to nowMs; null before there
    // is HideFirstMs of data. Falls as a stalled file gets no new bytes.
    public double? BytesPerSecond(long nowMs)
    {
        if (firstAt < 0 || nowMs - firstAt < HideFirstMs || samples.Count == 0) return null;
        var (at, from) = samples[0];
        long span = Math.Max(1, nowMs - at);
        return Math.Max(0, received - from) * 1000.0 / span;
    }

    // No new bytes for StallMs.
    public bool IsStalled(long nowMs) => firstAt >= 0 && nowMs - grewAt >= StallMs;

    public void Reset()
    {
        samples.Clear();
        firstAt = -1;
        received = -1;
    }
}

// The words and numbers around a file's progress bar, in the user's culture,
// with sizes as Explorer shows them (1 KB = 1024 bytes).
public static class TransferText
{
    // What the card says instead of a speed while no bytes come.
    public const string Stalled = "Waiting";
    // A transfer that broke off (a gap, a bad copy, the link going away) and
    // has been asked for again.
    public const string Retrying = "Interrupted, trying again";
    // Asked for as often as it is asked, or with no device connected to ask.
    public const string NoSender = "Waiting for a device that has it";

    // "8.3 MB/s", "120 MB/s", "512 KB/s", "0.4 KB/s": one decimal under 100,
    // KB/s under 1 MB/s.
    public static string Speed(double bytesPerSecond)
    {
        double kb = Math.Max(0, bytesPerSecond) / 1024;
        return kb < 1024 ? $"{Number(kb)} KB/s" : kb / 1024 < 1024 ? $"{Number(kb / 1024)} MB/s" : $"{Number(kb / 1024 / 1024)} GB/s";
    }

    private static string Number(double value) =>
        value < 100 ? value.ToString("0.0", CultureInfo.CurrentCulture) : value.ToString("0", CultureInfo.CurrentCulture);

    // "43%": rounded down, and never 100% before the file is done.
    public static string Percent(long received, long total, bool done = false)
    {
        if (done) return "100%";
        long percent = total <= 0 ? 0 : Math.Clamp(received * 100 / total, 0, 99);
        return $"{percent}%";
    }

    // "124 of 290 MB": both in the total's unit, and with as many decimals
    // as Size gives the total.
    public static string OfTotal(long received, long total)
    {
        received = Math.Clamp(received, 0, Math.Max(0, total));
        if (total < 1024) return $"{received} of {total} bytes";
        var (unitTotal, unit, scale) = InUnits(total);
        double part = received / scale;
        string format = unitTotal < 10 ? "0.#" : "0";
        string partText = part.ToString(format, CultureInfo.CurrentCulture);
        // (Never "290 of 290" one byte short of the end.)
        if (received < total && partText == unitTotal.ToString(format, CultureInfo.CurrentCulture))
        {
            partText = (Math.Floor(part * (unitTotal < 10 ? 10 : 1)) / (unitTotal < 10 ? 10 : 1)).ToString(format, CultureInfo.CurrentCulture);
        }
        return $"{partText} of {unitTotal.ToString(format, CultureInfo.CurrentCulture)} {unit}";
    }

    // "512 bytes", "12.3 KB", "4.5 MB", "1.2 GB" (one decimal under 10).
    public static string Size(long bytes)
    {
        if (bytes < 1024) return bytes == 1 ? "1 byte" : $"{bytes} bytes";
        var (value, unit, _) = InUnits(bytes);
        return value < 10
            ? $"{value.ToString("0.#", CultureInfo.CurrentCulture)} {unit}"
            : $"{value.ToString("0", CultureInfo.CurrentCulture)} {unit}";
    }

    // bytes (at least 1024) in the biggest unit that keeps it under 1024.
    private static (double Value, string Unit, double Scale) InUnits(long bytes)
    {
        string[] units = { "KB", "MB", "GB", "TB" };
        double value = bytes;
        double scale = 1;
        int unit = -1;
        do
        {
            value /= 1024;
            scale *= 1024;
            unit++;
        } while (value >= 1024 && unit < units.Length - 1);
        return (value, units[unit], scale);
    }
}
