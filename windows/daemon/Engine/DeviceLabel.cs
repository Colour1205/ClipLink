using System.Security.Cryptography;
using System.Text;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Engine;

// How to name a device anywhere the UI shows one: its display name, or its
// short id (a fingerprint) while it hasn't told us one.
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

    // "Device BA78·16BF" - the id's Fingerprint. For an unnamed device, and
    // for log lines.
    public static string ShortId(string deviceId) => $"Device {Fingerprint(deviceId)}";

    // The first 4 bytes of the SHA-256 of the id's UTF-8 bytes, as uppercase
    // hex split by a middle dot (U+00B7): "BA78·16BF" for the id "abc". Not
    // the id's first characters - every id is a Base64 P-256 public key
    // whose first 36 characters are the same key header on every device.
    // Every platform computes exactly this (iOS DeviceLabel.fingerprint,
    // Android fingerprintOf), so the one a pairing prompt shows can be
    // checked against the other device's own Settings / Me screen.
    public static string Fingerprint(string deviceId)
    {
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(deviceId));
        return $"{Convert.ToHexString(hash, 0, 2)}·{Convert.ToHexString(hash, 2, 2)}";
    }
}
