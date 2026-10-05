using ClipboardDaemon.Crypto;

namespace ClipboardDaemon.Identity;

// Persists the key derived from the user's passcode (never the passcode
// itself) so it only needs to be entered once — same load-or-create-on-disk
// shape as DeviceIdentity's keypair. It can be set, changed or cleared at any
// time: every beacon and handshake reads GetKey() fresh, so a change takes
// effect from the next one without a restart.
public class PassphraseKeyStore
{
    private readonly object gate = new();
    private byte[]? key;
    private readonly string key_path;

    public PassphraseKeyStore(string label)
    {
        string app_data_dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        key_path = Path.Combine(app_data_dir, "ClipboardDaemon", $"passphrasekey{label}.key");
        Directory.CreateDirectory(Path.Combine(app_data_dir, "ClipboardDaemon"));

        if (File.Exists(key_path))
        {
            try
            {
                byte[] protectedBytes = File.ReadAllBytes(key_path);
                key = System.Security.Cryptography.ProtectedData.Unprotect(protectedBytes, null, System.Security.Cryptography.DataProtectionScope.CurrentUser);
            }
            catch (Exception ex)
            {
                // corrupt file — treat as "no passphrase set" rather than crash;
                // the user can just set one again in settings
                Console.WriteLine($"Could not load passphrase key ({ex.Message}) — treating as not set.");
            }
        }
    }

    public bool HasPassphrase
    {
        get { lock (gate) { return key != null; } }
    }

    // Read it once per use (not HasPassphrase then GetKey()!): the passcode
    // can be cleared from another thread in between.
    public byte[]? GetKey()
    {
        lock (gate) { return key; }
    }

    // Deliberately fixed, not random: every device deriving from the same
    // passphrase must land on the same key, or none of them could ever verify
    // each other's proofs. A shared-secret KDF salt doesn't need to be unique
    // per device the way a login-password salt would — it only needs to be
    // the same everywhere this app derives a key from a passphrase.
    private static readonly byte[] FixedSalt = System.Text.Encoding.UTF8.GetBytes("ClipboardDaemonPassphraseSaltV1");

    // False, changing nothing, for a blank passcode - the only rule, same on
    // every platform (no minimum length).
    public bool SetPassphrase(string passphrase)
    {
        // Trimmed like HarmonyOS does - a stray leading/trailing space on
        // only one device derives a different key, and passcode pairing then
        // fails with nothing to show why.
        string trimmed = passphrase.Trim();
        if (trimmed.Length == 0) return false;

        // Derived outside the lock - it's deliberately slow, and every beacon
        // and handshake takes the lock to read the key.
        byte[] newKey = PassphraseAuth.DeriveKey(trimmed, FixedSalt);
        // DPAPI-encrypted at rest, tied to this Windows user — see DeviceIdentity
        // for the same treatment of the identity private key.
        byte[] protectedBytes = System.Security.Cryptography.ProtectedData.Protect(newKey, null, System.Security.Cryptography.DataProtectionScope.CurrentUser);
        lock (gate)
        {
            // Saved first, so a failed write leaves the old key in effect
            // rather than one that's gone on restart.
            File.WriteAllBytes(key_path, protectedBytes);
            key = newKey;
        }
        return true;
    }

    // Back to "no passcode": beacons and handshakes carry no proof from the
    // next one on, and nobody new is auto-trusted by passcode. Devices
    // already trusted stay trusted - that lives in TrustStore, not here.
    public void Clear()
    {
        lock (gate)
        {
            // Deleted first, for the same reason SetPassphrase saves first.
            // A missing file is fine (File.Delete doesn't throw for one).
            File.Delete(key_path);
            key = null;
        }
    }
}
