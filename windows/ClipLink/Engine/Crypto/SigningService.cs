// STEP 7:
// Sign a clipboard entry with the local private key, and verify a signature
// on an entry that came from a peer, using that peer's public key.

using System.Security.Cryptography;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Storage;

namespace ClipboardDaemon.Crypto;

public class SigningService
{
    public byte[] getSignableData(ClipboardEntry entry)
    {
        string data = $"{entry.Content}:{entry.Type}:{entry.DeviceId}:{entry.Timestamp.ToString("o")}";
        return System.Text.Encoding.UTF8.GetBytes(data);
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

