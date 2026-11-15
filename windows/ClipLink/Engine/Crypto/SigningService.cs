// STEP 7:
// Sign a clipboard entry with the local private key, and verify a signature
// on an entry that came from a peer, using that peer's public key.

using System.Security.Cryptography;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Crypto;

public class SigningService
{
    // The UTF-8 of "<content>:<type>:<deviceId>:<timestamp, round-trip>" -
    // the same bytes as encoding that string, which every platform signs, but
    // written part by part: for a picture the joined string was another copy
    // of its Base64, twice its size. (Each part is encoded on its own, and a
    // surrogate cut off at a part's end becomes U+FFFD either way: the ':'
    // after it never completes a pair.)
    public byte[] getSignableData(ClipboardEntry entry)
    {
        var utf8 = System.Text.Encoding.UTF8;
        string[] parts = { entry.Content ?? "", entry.Type ?? "", entry.DeviceId ?? "", entry.Timestamp.ToString("o") };
        int length = parts.Length - 1;
        foreach (string part in parts) length += utf8.GetByteCount(part);
        byte[] data = new byte[length];
        int at = 0;
        for (int i = 0; i < parts.Length; i++)
        {
            if (i > 0) data[at++] = (byte)':';
            at += utf8.GetBytes(parts[i], data.AsSpan(at));
        }
        return data;
    }

    public static ClipboardEntry Sign(ClipboardEntry entry, DeviceIdentity identity)
    {
        byte[] signableData = new SigningService().getSignableData(entry);
        byte[] signature = identity.SignData(signableData);
        return entry with {Signature = Convert.ToBase64String(signature)};
    }

    public static bool Verify(ClipboardEntry entry, string publicKey)
    {
        if (entry.Signature == null)
        {
            return false;
        }
        byte[] signableData = new SigningService().getSignableData(entry);
        byte[] signature = Convert.FromBase64String(entry.Signature);
        var ecdsa = ECDsa.Create();
        ecdsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKey), out _);
        return ecdsa.VerifyData(signableData, signature, HashAlgorithmName.SHA256);
    }
}

