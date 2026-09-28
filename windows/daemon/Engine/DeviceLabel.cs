using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Engine;

// How to name a device anywhere the UI shows one: its display name, or the
// shortened id while it hasn't told us one (an older build).
public static class DeviceLabel
{
    // The name is whatever the other device chose to send, so it's shown on
    // one line and as it reads: control characters (a newline would split a
    // list row, or push the pairing prompt's "only accept if you expect
    // this" out of view) and the invisible bidi and zero-width characters
    // (which could visually reorder the address shown next to it, or make
    // two different names look the same) are dropped - the same set as
    // received file names, see FileNames.IsUnsafeChar.
    public static string Of(string deviceId, string? name)
    {
        string shown = name == null ? "" : new string(name.Where(c => !FileNames.IsUnsafeChar(c)).ToArray()).Trim();
        return shown.Length == 0 ? ShortId(deviceId) : shown;
    }

    public static string ShortId(string deviceId) =>
        deviceId.Length > 12 ? deviceId[..12] + "…" : deviceId;
}
