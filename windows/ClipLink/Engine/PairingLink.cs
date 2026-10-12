using System.Text;
using System.Text.RegularExpressions;

namespace ClipboardDaemon.Engine;

// A pairing code as a link: https://cliplink.uaena.io/pair/#<the pairing info>.
// The QR code carries this instead of the bare JSON, so a phone's own camera or
// any scanner app that reads it opens the ClipLink app if it is installed (the
// platforms' app-link settings claim /pair) and the website, with the downloads,
// if it is not. The pairing info - the same {PublicKey, Address, Name} JSON as
// ever - is the part after the #, base64url without padding. A fragment is never
// sent to a server, so the website never sees a device's address.
//
// Everything that takes pairing text in (the pair-by-address box, a pasted
// code, a scan) accepts both the link and the bare JSON, via Unwrap. "Copy
// pairing info" still copies the bare JSON. The same format is in every
// platform's app (Android PairingLink.kt, HarmonyOS PairingLink.ets, iOS
// PairingLink.swift): change them together.
public static class PairingLink
{
    public const string Prefix = "https://cliplink.uaena.io/pair/#";

    // http or https, with or without the slash after /pair; the host in any case.
    private static readonly Regex Link = new(@"^https?://cliplink\.uaena\.io/pair/?#(?<info>.+)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string Wrap(string pairingJson)
    {
        string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(pairingJson))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return Prefix + encoded;
    }

    // The pairing info inside a link, or the text as it was: not a ClipLink
    // pairing link, or one whose info cannot be read.
    public static string Unwrap(string? text)
    {
        string trimmed = text?.Trim() ?? "";
        var match = Link.Match(trimmed);
        if (!match.Success) return text ?? "";
        try
        {
            string base64 = match.Groups["info"].Value.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight(base64.Length + (4 - base64.Length % 4) % 4, '=');
            string json = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(base64));
            return json.Length > 0 ? json : text ?? "";
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException)
        {
            return text ?? "";
        }
    }
}
