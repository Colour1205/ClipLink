namespace ClipboardTray;

// How the tray names a device anywhere it shows one: its display name, or
// the shortened id while it hasn't told us one (an older build).
public static class DeviceLabel
{
    // The name is whatever the other device chose to send, so it's shown on
    // one line: control characters (a newline would split a list row, or
    // push the pairing prompt's "only accept if you expect this" out of
    // view) and bidi overrides (which could visually reorder the address
    // shown next to it) become spaces.
    public static string Of(string deviceId, string? name)
    {
        string shown = name == null ? "" : new string(name.Select(c => IsUnsafe(c) ? ' ' : c).ToArray()).Trim();
        return shown.Length == 0 ? ShortId(deviceId) : shown;
    }

    public static string ShortId(string deviceId) =>
        deviceId.Length > 12 ? deviceId[..12] + "…" : deviceId;

    private static bool IsUnsafe(char c) =>
        char.IsControl(c) || c is (>= '‪' and <= '‮') or (>= '⁦' and <= '⁩');
}
