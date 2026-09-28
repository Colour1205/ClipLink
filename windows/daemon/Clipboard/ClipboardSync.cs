// STEP 2 & 3:
// - Step 2: read the current Windows clipboard content and print it.
// - Step 3: detect when the clipboard CHANGES (event-driven, not polling),
//   and fire your own event/callback with the new content.

namespace ClipboardDaemon.Clipboard;

using System.Collections.Concurrent;
using ClipboardDaemon.Storage;

public class ClipboardSync
{
    private const long MaxFileBytes = 1024L * 1024 * 1024; // 1GB — a ceiling against something absurd, not a memory constraint anymore now that this streams

    private readonly FileStore fileStore;
    private const int MaxApplyAttempts = 5;

    BlockingCollection<(string content, string type, int attempts)> _pendingSets = new BlockingCollection<(string content, string type, int attempts)>();
    private string? _lastKnownHash;

    // sourceFilePath is only ever set for type == "file" — it's the local path
    // to read the actual bytes from when streaming to peers. Program.cs uses
    // it; nothing else in this class needs it once the event has fired.
    public event Action<(string content, string type, string? sourceFilePath)>? ClipboardChanged;

    public ClipboardSync(FileStore fileStore)
    {
        this.fileStore = fileStore;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetClipboardSequenceNumber();

    public void Watch()
    {
        long last_sequence_num = GetClipboardSequenceNumber();

        var timer = new System.Windows.Forms.Timer();
        timer.Interval = 500;
        timer.Tick += (s, e) =>
        {
                        long curr_sequence_num = GetClipboardSequenceNumber();
            if (curr_sequence_num != last_sequence_num)
            {
                try{
                    bool is_img = System.Windows.Forms.Clipboard.ContainsImage();
                    bool is_text = System.Windows.Forms.Clipboard.ContainsText();
                    bool is_aud = System.Windows.Forms.Clipboard.ContainsAudio();
                    bool is_drop_lst = System.Windows.Forms.Clipboard.ContainsFileDropList();

                    last_sequence_num = curr_sequence_num;

                    // check image before text: a copied bitmap is the thing the
                    // user actually wants synced, even if Windows also exposes
                    // some auto-generated text representation alongside it
                    if (is_img)
                    {
                        using var image = System.Windows.Forms.Clipboard.GetImage();
                        if (image != null)
                        {
                            using var ms = new MemoryStream();
                            image.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                            byte[] imageBytes = ms.ToArray();
                            string hash = ComputeHash(imageBytes);
                            if (hash != _lastKnownHash)
                            {
                                _lastKnownHash = hash;
                                ClipboardChanged?.Invoke((Convert.ToBase64String(imageBytes), "image", null));
                            }
                        }
                    }
                    else if (is_text)
                    {
                        string text = System.Windows.Forms.Clipboard.GetText();
                        string hash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(text));
                        if (hash != _lastKnownHash)
                        {
                            _lastKnownHash = hash;
                            ClipboardChanged?.Invoke((System.Windows.Forms.Clipboard.GetText(), "text", null));
                        }
                    }
                    else if (is_drop_lst)
                    {
                        HandleFileDropList();
                    }
                    else
                    {
                        // Audio has no meaningful cross-device representation the same
                        // way files/images do — skip rather than half-implement it.
                        Console.WriteLine($"unsupported clipboard change: audio={is_aud}");
                    }
                } catch (Exception)
                {
                    Console.WriteLine($"clipboard busy, will retry next poll");
                }
            }
            // push content from the queue to the clipboard
            if (_pendingSets.TryTake(out var pendingSet))
            {
                try
                {
                    setContent(pendingSet.content, pendingSet.type);
                    // Our own write bumps the sequence number too - take it as
                    // already seen, or the next tick reads it back as a fresh
                    // local copy and sends it straight back out. The hash
                    // check alone misses that for images: the bitmap re-reads
                    // and re-encodes to different PNG bytes than were written.
                    last_sequence_num = GetClipboardSequenceNumber();
                }
                catch (Exception)
                {
                    // TryTake already removed it — if we don't put it back, a
                    // transient failure (e.g. clipboard contention) silently
                    // loses this peer update forever instead of just retrying
                    // once the contention clears, the way local detection already does.
                    int nextAttempt = pendingSet.attempts + 1;
                    if (nextAttempt < MaxApplyAttempts)
                    {
                        Console.WriteLine($"clipboard busy, will retry this peer update (attempt {nextAttempt}/{MaxApplyAttempts})");
                        _pendingSets.Add((pendingSet.content, pendingSet.type, nextAttempt));
                    }
                    else
                    {
                        Console.WriteLine($"clipboard busy, giving up on this peer update after {MaxApplyAttempts} attempts");
                    }
                }
            }
        };

        timer.Start();
        System.Windows.Forms.Application.Run();
    }

    // Multiple files can be selected and copied together in Explorer — sync
    // every one of them, not just the first, each as its own history entry.
    private void HandleFileDropList()
    {
        var files = System.Windows.Forms.Clipboard.GetFileDropList();
        var fileHashes = new List<string>();
        var readableFiles = new List<(string path, FileInfo info, string hash)>();

        foreach (string? path in files)
        {
            if (path == null) continue;
            var fileInfo = new FileInfo(path);
            if (!fileInfo.Exists)
            {
                Console.WriteLine($"skipping file drop, not a readable file: {path}");
                continue;
            }
            if (fileInfo.Length > MaxFileBytes)
            {
                Console.WriteLine($"skipping file drop, too large to sync ({fileInfo.Length} bytes, limit {MaxFileBytes}): {path}");
                continue;
            }

            using var stream = File.OpenRead(path);
            string hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)); // streams internally — never loads the whole file for hashing
            fileHashes.Add(hash);
            readableFiles.Add((path, fileInfo, hash));
        }

        if (readableFiles.Count == 0) return;

        // echo-suppression covers the WHOLE selection (all files together),
        // not each file individually — a combined discriminator from the
        // sorted set of hashes, so selection order doesn't matter
        string combinedHash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(string.Join(",", fileHashes.OrderBy(h => h))));
        if (combinedHash == _lastKnownHash) return;
        _lastKnownHash = combinedHash;

        foreach (var (path, info, hash) in readableFiles)
        {
            var payload = new FilePayload(info.Name, hash, info.Length);
            ClipboardChanged?.Invoke((System.Text.Json.JsonSerializer.Serialize(payload), "file", path));
        }
    }

    public void addToQueue(string content, string type = "text")
    {
        _pendingSets.Add((content, type, 0));
    }

    public void setContent(String content, string type = "text")
    {
        if (type == "text")
        {
            _lastKnownHash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(content));
            System.Windows.Forms.Clipboard.SetText(content);
        }
        else if (type == "image")
        {
            byte[] imageBytes = Convert.FromBase64String(content);
            _lastKnownHash = ComputeHash(imageBytes);
            // Saved as a real file too, and put on the clipboard both ways (see
            // SetImageAndFile) - a bitmap alone pasted into Word or Paint but
            // not into an Explorer folder, which only accepts files.
            string destPath = GetNonCollidingPath(ReceivedFilesDir(), $"ClipLink image {DateTime.Now:yyyy-MM-dd HHmmss}{ImageExtension(imageBytes)}");
            File.WriteAllBytes(destPath, imageBytes);
            SetImageAndFile(imageBytes, destPath);
        }
        else if (type == "file")
        {
            var payload = System.Text.Json.JsonSerializer.Deserialize<FilePayload>(content);
            if (payload == null) return;
            if (!fileStore.Exists(payload.FileHash))
            {
                // we don't have the bytes yet (chunks still arriving, or this
                // came from history reconciliation rather than a live transfer)
                Console.WriteLine($"can't apply file '{payload.FileName}' yet — content not available locally");
                return;
            }

            string destPath = GetNonCollidingPath(ReceivedFilesDir(), payload.FileName);
            File.Copy(fileStore.GetPath(payload.FileHash), destPath);
            _lastKnownHash = ComputeHash(System.Text.Encoding.UTF8.GetBytes(payload.FileHash)); // suppress our own echo of this apply

            // The same merge the other way round: a received image FILE also
            // goes on as a picture, so it pastes into documents as well as
            // into folders.
            var info = new FileInfo(destPath);
            if (ImageFileExtensions.Contains(info.Extension) && info.Length <= MaxInlineImageBytes)
            {
                SetImageAndFile(File.ReadAllBytes(destPath), destPath);
                return;
            }

            var fileList = new System.Collections.Specialized.StringCollection();
            fileList.Add(destPath);
            System.Windows.Forms.Clipboard.SetFileDropList(fileList);
        }
        else
        {
            throw new NotImplementedException($"Clipboard type '{type}' is not supported yet.");
        }
    }

    private string ComputeHash(byte[] data)
{
    return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data));
}

    // Image files GDI+ can decode, and the largest one worth also putting on
    // the clipboard as a bitmap (a decoded bitmap is far bigger than the file).
    private static readonly HashSet<string> ImageFileExtensions = new(StringComparer.OrdinalIgnoreCase) { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff" };
    private const long MaxInlineImageBytes = 50L * 1024 * 1024;

    private static string ReceivedFilesDir()
    {
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClipboardDaemon", "ReceivedFiles");
        Directory.CreateDirectory(dir);
        return dir;
    }

    // One clipboard item carrying the picture AND the file it's saved as:
    // apps that paste images (Word, Paint, chat apps) take the bitmap - or
    // the "PNG" format, which keeps transparency, for the ones that look for
    // it - while Explorer takes the file. If the bytes aren't an image GDI+
    // can decode (e.g. WebP or HEIC from a phone), the file alone still pastes.
    private static void SetImageAndFile(byte[] imageBytes, string filePath)
    {
        var data = new System.Windows.Forms.DataObject();
        data.SetFileDropList(new System.Collections.Specialized.StringCollection { filePath });
        System.Drawing.Image? image = null;
        try
        {
            image = System.Drawing.Image.FromStream(new MemoryStream(imageBytes));
            data.SetImage(image);
            if (ImageExtension(imageBytes) == ".png")
            {
                data.SetData("PNG", new MemoryStream(imageBytes));
            }
        }
        catch (ArgumentException)
        {
            Console.WriteLine($"image format not decodable here, putting it on the clipboard as a file only: {filePath}");
        }
        try
        {
            // copy: true renders every format now, so the data outlives this call.
            System.Windows.Forms.Clipboard.SetDataObject(data, true);
        }
        finally
        {
            image?.Dispose();
        }
    }

    // From the file's magic bytes - phones send PNG or JPEG, sometimes others.
    private static string ImageExtension(byte[] bytes)
    {
        bool StartsWith(params byte[] magic) => bytes.Length >= magic.Length && bytes.AsSpan(0, magic.Length).SequenceEqual(magic);
        if (StartsWith(0x89, 0x50, 0x4E, 0x47)) return ".png";
        if (StartsWith(0xFF, 0xD8, 0xFF)) return ".jpg";
        if (StartsWith(0x47, 0x49, 0x46, 0x38)) return ".gif";
        if (StartsWith(0x42, 0x4D)) return ".bmp";
        if (bytes.Length >= 12 && StartsWith(0x52, 0x49, 0x46, 0x46) && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) return ".webp";
        return ".png";
    }

    // If "photo.jpg" already exists, try "photo (1).jpg", "photo (2).jpg", etc.
    private string GetNonCollidingPath(string dir, string fileName)
    {
        string candidate = Path.Combine(dir, fileName);
        if (!File.Exists(candidate)) return candidate;

        string nameOnly = Path.GetFileNameWithoutExtension(fileName);
        string ext = Path.GetExtension(fileName);
        int counter = 1;
        do
        {
            candidate = Path.Combine(dir, $"{nameOnly} ({counter}){ext}");
            counter++;
        } while (File.Exists(candidate));

        return candidate;
    }
}
