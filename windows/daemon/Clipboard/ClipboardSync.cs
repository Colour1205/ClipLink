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
    private readonly string label; // whose received images these are - see ReceivedFiles
    private const int MaxApplyAttempts = 5;

    BlockingCollection<(string content, string type, int attempts)> _pendingSets = new BlockingCollection<(string content, string type, int attempts)>();
    private string? _lastKnownHash;
    private volatile bool _stopRequested;

    // sourceFilePath is only ever set for type == "file" — it's the local path
    // to read the actual bytes from when streaming to peers. ClipLinkEngine uses
    // it; nothing else in this class needs it once the event has fired.
    public event Action<(string content, string type, string? sourceFilePath)>? ClipboardChanged;

    public ClipboardSync(FileStore fileStore, string label)
    {
        this.fileStore = fileStore;
        this.label = label;
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
            if (_stopRequested)
            {
                // Only this thread's message loop - never Application.Exit(),
                // which ends every thread's (the app's UI thread's too, if it
                // runs one).
                timer.Stop();
                timer.Dispose();
                System.Windows.Forms.Application.ExitThread();
                return;
            }
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

    // Ends Watch() (from any thread): its loop exits on the next tick, and
    // nothing queued after that is applied. The engine stopping.
    public void Stop()
    {
        _stopRequested = true;
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
            // not into an Explorer folder, which only accepts files. Named by
            // its content, so applying it again reuses the file (see
            // ReceivedFiles.SaveImage). If it can't be saved, the picture
            // still goes on, without the file.
            SetImageAndFile(imageBytes, ReceivedFiles.SaveImage(imageBytes, label));
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

            // The sender's name for it, but only as a name: joined on as it
            // came, a rooted or "..\" one put the file anywhere.
            string destPath = GetNonCollidingPath(ReceivedFiles.Folder(), FileNames.Safe(payload.FileName, "file"));
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

    // One clipboard item carrying the picture AND the file it's saved as:
    // apps that paste images (Word, Paint, chat apps) take the bitmap - or
    // the "PNG" format, which keeps transparency, for the ones that look for
    // it - while Explorer takes the file. If the bytes aren't an image GDI+
    // can decode (e.g. WebP or HEIC from a phone), the file alone still pastes.
    // No filePath (it couldn't be saved): the picture alone.
    private static void SetImageAndFile(byte[] imageBytes, string? filePath)
    {
        var data = new System.Windows.Forms.DataObject();
        if (filePath != null)
        {
            data.SetFileDropList(new System.Collections.Specialized.StringCollection { filePath });
        }
        System.Drawing.Image? image = null;
        try
        {
            image = System.Drawing.Image.FromStream(new MemoryStream(imageBytes));
            bool turned = TurnUpright(image);
            data.SetImage(image);
            if (ImageFiles.Extension(imageBytes) == ".png")
            {
                data.SetData("PNG", turned ? PngOf(image) : new MemoryStream(imageBytes));
            }
        }
        catch (ArgumentException)
        {
            if (filePath == null)
            {
                image?.Dispose();
                Console.WriteLine("image format not decodable here, and it couldn't be saved as a file - nothing to put on the clipboard");
                return;
            }
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

    private const int ExifOrientation = 0x0112;

    // GDI+ ignores a photo's EXIF orientation - a phone saves a portrait
    // photo sideways, with a tag saying how to turn it - so JPEG and TIFF
    // photos pasted sideways. Turns the bitmap itself the way the tag says
    // and drops the tag, so nothing turns it again. True if it turned it.
    private static bool TurnUpright(System.Drawing.Image image)
    {
        bool turned = false;
        try
        {
            if (!image.PropertyIdList.Contains(ExifOrientation)) return false;
            byte[]? value = image.GetPropertyItem(ExifOrientation)?.Value;
            int orientation = value is { Length: >= 2 } ? BitConverter.ToUInt16(value, 0) : value is { Length: 1 } ? value[0] : 1;
            System.Drawing.RotateFlipType? turn = orientation switch
            {
                2 => System.Drawing.RotateFlipType.RotateNoneFlipX,
                3 => System.Drawing.RotateFlipType.Rotate180FlipNone,
                4 => System.Drawing.RotateFlipType.Rotate180FlipX,
                5 => System.Drawing.RotateFlipType.Rotate90FlipX,
                6 => System.Drawing.RotateFlipType.Rotate90FlipNone,
                7 => System.Drawing.RotateFlipType.Rotate270FlipX,
                8 => System.Drawing.RotateFlipType.Rotate270FlipNone,
                _ => null,
            };
            if (turn == null) return false;
            image.RotateFlip(turn.Value);
            turned = true;
            image.RemovePropertyItem(ExifOrientation);
        }
        catch (Exception ex) when (ex is ArgumentException or System.Runtime.InteropServices.ExternalException)
        {
            Console.WriteLine($"couldn't apply the image's EXIF orientation: {ex.Message}");
        }
        return turned;
    }

    // The turned bitmap as PNG, for the "PNG" format - the received bytes
    // would paste it unturned.
    private static MemoryStream PngOf(System.Drawing.Image image)
    {
        var png = new MemoryStream();
        image.Save(png, System.Drawing.Imaging.ImageFormat.Png);
        png.Position = 0;
        return png;
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
