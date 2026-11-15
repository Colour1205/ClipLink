// STEP 4:
// Generate (or load, if one already exists on disk) this device's permanent
// keypair — its identity. This is the foundation pairing/trust/signing all
// build on.

using System.Security.Cryptography;

namespace ClipboardDaemon.Identity;

public class DeviceIdentity
{
    private ECDsa key = ECDsa.Create();
    // TODO
    public DeviceIdentity() : this(""){}
    public DeviceIdentity(string deviceID)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string key_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"identity{deviceID}.key");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));
        bool loaded = false;
        if (File.Exists(key_path))
        {
            // A file that can't be read right now (a virus scanner or backup
            // tool holding it as Windows signs in) throws from here after a
            // few tries, and ClipLink says it couldn't start - it used to be
            // taken for corrupt and replaced, a new identity that every
            // paired device then stopped trusting.
            byte[] protectedBytes = ReadKeyFile(key_path);
            try
            {
                byte[] pkcs8Bytes = System.Security.Cryptography.ProtectedData.Unprotect(protectedBytes, null, System.Security.Cryptography.DataProtectionScope.CurrentUser);
                key.ImportPkcs8PrivateKey(pkcs8Bytes, out _);
                loaded = true;
            }
            catch (CryptographicException ex)
            {
                // corrupt file, DPAPI blob from a different user/machine, etc. —
                // regenerate rather than crash the whole daemon on startup.
                // Note: this does change the device's public key, so any existing
                // pairings would need to be redone. The old file is kept as
                // "<file>.bad" (for whoever wants to look at it).
                Console.WriteLine($"Could not load identity key ({ex.Message}) — generating a new one.");
                try { File.Move(key_path, key_path + ".bad", overwrite: true); }
                catch (Exception moveEx) when (moveEx is IOException or UnauthorizedAccessException) { }
            }
        }
        if (!loaded)
        {
            key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            byte[] pkcs8Bytes = key.ExportPkcs8PrivateKey();
            // DPAPI-encrypted at rest, tied to this Windows user — a copied file
            // is useless to anyone who isn't logged in as this same user on this machine.
            byte[] protectedBytes = System.Security.Cryptography.ProtectedData.Protect(pkcs8Bytes, null, System.Security.Cryptography.DataProtectionScope.CurrentUser);
            WriteKeyFile(key_path, protectedBytes);
        }
    }

    // The key file's bytes, tried a few times while something else holds it.
    private static byte[] ReadKeyFile(string path)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                return File.ReadAllBytes(path);
            }
            catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && attempt < 5)
            {
                Thread.Sleep(300);
            }
        }
    }

    // Written to "<file>.tmp", flushed, then moved into place: written
    // straight onto the file, a crash or power cut during the first run left
    // a cut-off key, thrown away as corrupt at the next start.
    private static void WriteKeyFile(string path, byte[] bytes)
    {
        string temp = path + ".tmp";
        using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temp, path, overwrite: true);
    }
    /*
    return the base64 publickey
    */
    public string GetPublicKey(){
        return Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
    }
    public byte[] SignData(byte[] data)
    {
        return key.SignData(data, HashAlgorithmName.SHA256);
    }

    // Whether id is the public key canonicalId names - canonicalId as
    // GetPublicKey writes it - however id is spelt. Convert.FromBase64String
    // skips whitespace, so a space inside id still decodes to the same key:
    // comparing the text only proves two ids are different text. So id's
    // key is re-encoded canonically (its DER SubjectPublicKeyInfo, as
    // standard Base64) and compared. False when id isn't a public key at all.
    public static bool IsSameKey(string? id, string canonicalId)
    {
        if (id == null) return false;
        if (id == canonicalId) return true;
        try
        {
            using var decoded = ECDsa.Create();
            decoded.ImportSubjectPublicKeyInfo(Convert.FromBase64String(id), out _);
            return Convert.ToBase64String(decoded.ExportSubjectPublicKeyInfo()) == canonicalId;
        }
        catch (Exception ex) when (ex is FormatException or CryptographicException)
        {
            return false;
        }
    }
}
