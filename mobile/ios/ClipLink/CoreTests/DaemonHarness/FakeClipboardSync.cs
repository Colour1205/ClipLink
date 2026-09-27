// Test double for windows/daemon/Clipboard/ClipboardSync.cs (WinForms is
// Windows-only). Same public surface and the same echo-suppression rules
// (UPPERCASE SHA-256; files hashed as the UTF-8 of their FileHash), but a
// "copy" arrives as a stdin command and every clipboard write is printed:
//   stdin : copytext <base64 utf8> | copyimage <path> | copyfile <path>
//   stdout: APPLY text <base64 utf8> | APPLY image <SHA256> <len> | APPLY file <name> <FileHash> <SHA256 of stored bytes>
namespace ClipboardDaemon.Clipboard;

using System.Security.Cryptography;
using System.Text;
using ClipboardDaemon.Storage;

public class ClipboardSync
{
    private readonly FileStore fileStore;
    private string? _lastKnownHash;

    public event Action<(string content, string type, string? sourceFilePath)>? ClipboardChanged;

    public ClipboardSync(FileStore fileStore)
    {
        this.fileStore = fileStore;
    }

    private static string ComputeHash(byte[] data) => Convert.ToHexString(SHA256.HashData(data));

    public void Watch()
    {
        string? line;
        while ((line = Console.In.ReadLine()) != null)
        {
            var parts = line.Split(' ', 2);
            try
            {
                switch (parts[0])
                {
                    case "copytext":
                    {
                        string text = Encoding.UTF8.GetString(Convert.FromBase64String(parts[1]));
                        string hash = ComputeHash(Encoding.UTF8.GetBytes(text));
                        if (hash == _lastKnownHash) { Console.WriteLine("ECHO-SUPPRESSED text"); break; }
                        _lastKnownHash = hash;
                        ClipboardChanged?.Invoke((text, "text", null));
                        break;
                    }
                    case "copyimage":
                    {
                        byte[] bytes = File.ReadAllBytes(parts[1]);
                        string hash = ComputeHash(bytes);
                        if (hash == _lastKnownHash) { Console.WriteLine("ECHO-SUPPRESSED image"); break; }
                        _lastKnownHash = hash;
                        ClipboardChanged?.Invoke((Convert.ToBase64String(bytes), "image", null));
                        break;
                    }
                    case "copyfile":
                    {
                        var info = new FileInfo(parts[1]);
                        string fileHash;
                        using (var stream = File.OpenRead(info.FullName)) fileHash = Convert.ToHexString(SHA256.HashData(stream));
                        var payload = new FilePayload(info.Name, fileHash, info.Length);
                        string combined = ComputeHash(Encoding.UTF8.GetBytes(fileHash));
                        if (combined == _lastKnownHash) { Console.WriteLine("ECHO-SUPPRESSED file"); break; }
                        _lastKnownHash = combined;
                        ClipboardChanged?.Invoke((System.Text.Json.JsonSerializer.Serialize(payload), "file", info.FullName));
                        break;
                    }
                    case "recopy":
                    {
                        // Simulates the real 500 ms poll re-reading what setContent just
                        // wrote: text/file hashes match (suppressed); an image is re-encoded
                        // by GDI+ on Windows, so the real daemon re-broadcasts it.
                        Console.WriteLine("RECOPY lastHash=" + _lastKnownHash);
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("HARNESS-ERROR " + ex.GetType().Name + ": " + ex.Message);
            }
        }
    }

    public void addToQueue(string content, string type = "text") => setContent(content, type);

    public void setContent(string content, string type = "text")
    {
        if (type == "text")
        {
            _lastKnownHash = ComputeHash(Encoding.UTF8.GetBytes(content));
            Console.WriteLine("APPLY text " + Convert.ToBase64String(Encoding.UTF8.GetBytes(content)));
        }
        else if (type == "image")
        {
            byte[] bytes = Convert.FromBase64String(content);
            _lastKnownHash = ComputeHash(bytes);
            Console.WriteLine($"APPLY image {ComputeHash(bytes)} {bytes.Length}");
        }
        else if (type == "file")
        {
            var payload = System.Text.Json.JsonSerializer.Deserialize<FilePayload>(content);
            if (payload == null) return;
            if (!fileStore.Exists(payload.FileHash))
            {
                Console.WriteLine("APPLY-WAITING file " + payload.FileHash);
                return;
            }
            string stored;
            using (var s = File.OpenRead(fileStore.GetPath(payload.FileHash))) stored = Convert.ToHexString(SHA256.HashData(s));
            _lastKnownHash = ComputeHash(Encoding.UTF8.GetBytes(payload.FileHash));
            Console.WriteLine($"APPLY file {payload.FileName} {payload.FileHash} {stored}");
        }
    }
}
