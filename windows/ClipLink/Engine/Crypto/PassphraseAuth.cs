using System.Security.Cryptography;

namespace ClipboardDaemon.Crypto;

// Lets devices that know the same passphrase auto-trust each other, as an
// alternative to manual QR/key pairing for "these are all my own devices".
// The passphrase itself is never transmitted — only an HMAC proof computed
// from a key derived from it, so a LAN eavesdropper who doesn't know the
// passphrase can't reconstruct it or forge a valid proof for a different key.
public static class PassphraseAuth
{
    private const int Pbkdf2Iterations = 210_000; // deliberately slow, resists offline guessing

    // A random salt makes this key useless to anyone who doesn't also know the
    // passphrase, even if they see the salt (it's not secret, just unique).
    public static byte[] DeriveKey(string passphrase, byte[] salt)
    {
        return Rfc2898DeriveBytes.Pbkdf2(passphrase, salt, Pbkdf2Iterations, HashAlgorithmName.SHA256, 32);
    }

    // Proves "I know the same passphrase" without ever sending the passphrase
    // or the derived key — only this HMAC, tied to a specific device id so it
    // can't be replayed to vouch for a different key.
    public static string ComputeProof(byte[] key, string deviceId)
    {
        byte[] proofBytes = HMACSHA256.HashData(key, System.Text.Encoding.UTF8.GetBytes(deviceId));
        return Convert.ToBase64String(proofBytes);
    }

    public static bool VerifyProof(byte[] key, string deviceId, string proof)
    {
        try
        {
            string expected = ComputeProof(key, deviceId);
            // fixed-time comparison — a naive == would leak timing info about how
            // many leading bytes matched, letting an attacker guess the proof byte by byte
            return CryptographicOperations.FixedTimeEquals(
                Convert.FromBase64String(expected),
                Convert.FromBase64String(proof));
        }
        catch (FormatException)
        {
            return false; // malformed proof from a peer — treat as "doesn't verify", not a crash
        }
    }
}
