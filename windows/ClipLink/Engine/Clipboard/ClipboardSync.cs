// The clipboard watcher: reads what is copied on this PC and raises it
// (ClipboardChanged, FilesCopied), and writes what the engine queues
// (addToQueue). Event-driven: Windows tells it each time the clipboard
// changes (WM_CLIPBOARDUPDATE, see MessageWindow) - it used to poll every
// 500 ms, two wake-ups a second for the app's whole life, and every copy
// waited up to half a second either way.

namespace ClipboardDaemon.Clipboard;

using System.Collections.Concurrent;
using System.Threading.Channels;
using ClipboardDaemon.Storage;

public class ClipboardSync
{
    private readonly FileStore fileStore;
    private readonly string label; // whose received images these are - see ReceivedFiles
    private readonly Func<int?> activeGeneration;
    private const int MaxApplyAttempts = 5;
    // A copy whose read fails (the app that copied it still holds the
    // clipboard, rendering) is read again RetryMs later, this many times in
    // all, before it is given up on.
    private const int MaxReadAttempts = 3;
    // How long a busy clipboard is left before a read or write is tried
    // again - what the polling interval used to be.
    private const uint RetryMs = 500;
    // At most this many files of one copied selection are sent - what history
    // keeps; the rest would be hashed, cached and streamed to every device
    // only to be trimmed at once.
    private const int MaxFilesPerCopy = HistoryAccess.MaxHistoryItems;

    private sealed record PendingSet(string Content, string Type, bool FromElsewhere, int Attempts, int? AutomaticGeneration);

    // A write goes through two queues. Prepare - everything slow about it:
    // saving a received picture, copying a received file (up to 1 GB) into
    // place, reading it back - runs on a worker, one write at a time in
    // order; then the write itself is queued for the watcher's thread, which
    // only touches the clipboard. Prepared there, a big file held up every
    // copy made here and every other item waiting to be applied.
    private readonly Channel<PendingSet> _toPrepare = Channel.CreateUnbounded<PendingSet>(new UnboundedChannelOptions { SingleReader = true });
    private sealed record ReadyWrite(PendingSet Pending, Write Write);
    private readonly ConcurrentQueue<ReadyWrite> _ready = new();
    private volatile bool _stopRequested;

    // The watcher thread's window (see Watch); null until it runs.
    private volatile MessageWindow? _window;
    private const uint WM_WORK = MessageWindow.WM_APP + 1; // a write is ready
    private const uint WM_STOP = MessageWindow.WM_APP + 2;
    private const nint RetryTimer = 1;

    // What ClipLink last wrote to the clipboard, or last saw copied here (see
    // LastWrite and design/sync-dedupe-spec.md): a copy of that is not sent
    // (an echo), and a received item with that content isn't written again.
    private readonly LastWrite _lastWrite = new();

    // The watcher thread's own: the sequence number of the last change it
    // dealt with (read, or ClipLink's own write), and how often reading the
    // one after it has failed so far.
    private uint _seenSequence;
    private long _skippedSequence = -1;
    private uint _failedSequence;
    private int _readFailures;

    // Copied file selections are hashed off the watcher thread - up to
    // MaxFilesPerCopy files of up to 1 GB each, which held up every peer item
    // waiting to be applied for minutes - one selection at a time, in order.
    private readonly SemaphoreSlim _filesGate = new(1, 1);

    // The received image's file (ReceivedFiles) this last put on the
    // clipboard with the picture, and the clipboard's sequence number right
    // after - see ImageFileOnClipboard.
    private sealed record ImageFileWrite(string Path, uint Sequence);
    private volatile ImageFileWrite? _imageFileWrite;

    // Text or a picture copied here that ClipLink hasn't written or seen
    // already. (Whether it is just the newest history item again is the
    // engine's to say.) name: a picture's original name, when the copy said
    // one (see ReadImageName); null for text and for a picture without one.
    // Raised on the watcher thread.
    public event Action<(string content, string type, string? sourceFilePath, string? name), int>? ClipboardChanged;

    // Files copied here (Explorer), the same way: each one's FilePayload as
    // JSON, and its path to read the bytes from when streaming to peers. At
    // most MaxFilesPerCopy, the same file once. Raised off the watcher thread.
    public event Action<IReadOnlyList<(string content, string path)>, int>? FilesCopied;

    public ClipboardSync(FileStore fileStore, string label, Func<int?> activeGeneration)
    {
        this.fileStore = fileStore;
        this.label = label;
        this.activeGeneration = activeGeneration;
    }

    // Resume from the next copy, even if a clipboard notification posted
    // while paused is still waiting on the watcher thread.
    public void SkipCurrentClipboard()
    {
        uint current = Win32Clipboard.Sequence;
        Volatile.Write(ref _skippedSequence, current);
        if (current != Volatile.Read(ref _seenSequence)) _lastWrite.Classified(Array.Empty<string>());
    }

    // The clipboard's sequence number: changes with every write to it, by
    // ClipLink or anything else. Any thread.
    public uint Sequence => Win32Clipboard.Sequence;

    // Whether what ClipLink last wrote to the clipboard, or last saw copied
    // here, has this print (see ContentPrint): the clipboard already holds
    // that content, as far as ClipLink knows. Any thread.
    public bool Holds(string? print) => _lastWrite.Holds(print);

    // Runs the watcher on the calling thread until Stop: a message-only
    // window listening for clipboard changes, and that thread's message loop.
    public void Watch()
    {
        try
        {
            _seenSequence = Win32Clipboard.Sequence;
            using var window = new MessageWindow(OnMessage);
            window.Listen();
            _window = window;
            if (_stopRequested) return;
            _ = Task.Run(PrepareWrites);
            window.Run();
        }
        catch (Exception ex)
        {
            // On its own thread: escaping, this would end the app.
            Console.WriteLine($"[clip] the clipboard watcher stopped: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            _window = null;
        }
    }

    // The watcher thread's messages. True: dealt with.
    private bool OnMessage(uint message, nint wParam)
    {
        switch (message)
        {
            case MessageWindow.WM_CLIPBOARDUPDATE:
                CaptureIfChanged();
                return true;
            case WM_WORK:
                ApplyReady();
                return true;
            case MessageWindow.WM_TIMER when wParam == RetryTimer:
                _window?.StopTimer(RetryTimer);
                CaptureIfChanged();
                ApplyReady();
                return true;
            case WM_STOP:
                // Only this thread's message loop.
                MessageWindow.Quit();
                return true;
            default:
                return false;
        }
    }

    // A busy clipboard: everything is tried again in RetryMs.
    private void RetrySoon() => _window?.SetTimer(RetryTimer, RetryMs);

    // Reads what was copied here since the last change this dealt with, if
    // anything was. The sequence number counts as dealt with only once the
    // read worked (or gave up after MaxReadAttempts): it used to be taken
    // before reading, so a copy whose read failed was never tried again.
    private void CaptureIfChanged()
    {
        uint current = Win32Clipboard.Sequence;
        if (current == _seenSequence) return;
        if (activeGeneration() is not int generation || current == Volatile.Read(ref _skippedSequence))
        {
            if (!_lastWrite.IsOwnWrite(current)) _lastWrite.Classified(Array.Empty<string>());
            _seenSequence = current;
            _readFailures = 0;
            return;
        }
        // Still ClipLink's own write: nothing to read.
        if (_lastWrite.IsOwnWrite(current))
        {
            _seenSequence = current;
            return;
        }
        if (current != _failedSequence)
        {
            _failedSequence = current;
            _readFailures = 0;
        }
        bool read;
        try
        {
            read = Capture(generation);
        }
        catch (Exception)
        {
            read = false;
        }
        if (read || ++_readFailures >= MaxReadAttempts)
        {
            if (!read) Console.WriteLine($"clipboard busy, giving up on this copy after {MaxReadAttempts} attempts");
            _seenSequence = current;
            _readFailures = 0;
        }
        else
        {
            Console.WriteLine("clipboard busy, will retry shortly");
            RetrySoon();
        }
    }

    // One read of the clipboard. False if it couldn't be read (try again).
    private bool Capture(int generation)
    {
        // What kind of copy it is, and what it holds, in one opening of the
        // clipboard; a picture is encoded once it's closed again, so the app
        // that copied it isn't kept waiting meanwhile.
        System.Drawing.Image? image = null;
        string? imageName = null;
        string? text = null;
        List<string>? paths = null;
        bool audio = false;
        using (Win32Clipboard.Open(_window!.Handle))
        {
            // check image before text: a copied bitmap is the thing the
            // user actually wants synced, even if Windows also exposes
            // some auto-generated text representation alongside it
            if (Win32Clipboard.Has(Win32Clipboard.CF_BITMAP))
            {
                image = ReadBitmap();
                if (image == null) return false;
                imageName = ReadImageName();
            }
            else if (Win32Clipboard.Has(Win32Clipboard.CF_UNICODETEXT))
            {
                text = Win32Clipboard.GetText();
                if (text == null) return false;
            }
            else if (Win32Clipboard.Has(Win32Clipboard.CF_HDROP))
            {
                paths = Win32Clipboard.GetFiles();
                if (paths == null) return false;
            }
            else
            {
                audio = Win32Clipboard.Has(Win32Clipboard.CF_WAVE);
            }
        }

        if (image != null)
        {
            byte[] imageBytes;
            using (image) imageBytes = PngOf(image).ToArray();
            if (IsNew(new[] { ContentPrint.Image(imageBytes) }))
            {
                ClipboardChanged?.Invoke((Convert.ToBase64String(imageBytes), "image", null, imageName), generation);
            }
        }
        else if (text != null)
        {
            // Read once: what is sent is exactly what was compared. (A second
            // read could get a newer copy, sent now and then again next time.)
            if (IsNew(new[] { ContentPrint.Text(text) }))
            {
                ClipboardChanged?.Invoke((text, "text", null, null), generation);
            }
        }
        else if (paths != null)
        {
            HandleFileDropList(paths, generation);
        }
        else
        {
            // Audio has no meaningful cross-device representation the same
            // way files/images do — skip rather than half-implement it.
            Console.WriteLine($"unsupported clipboard change: audio={audio}");
        }
        return true;
    }

    // The clipboard's bitmap (clipboard open), as a copy here is read - the
    // same GDI+ copy of CF_BITMAP WinForms' Clipboard.GetImage made - or null
    // if there is none.
    private static System.Drawing.Image? ReadBitmap()
    {
        nint bitmap = Win32Clipboard.GetBitmap();
        return bitmap == 0 ? null : System.Drawing.Image.FromHbitmap(bitmap);
    }

    // The copied picture's original name (clipboard open), from the other
    // formats the app that copied it put next to the bitmap - see ImageName:
    // the file it came from (a one-file CF_HDROP, "FileNameW", "FileName"),
    // a virtual file ("FileGroupDescriptorW"), its HTML ("HTML Format") or
    // its address ("UniformResourceLocatorW", "UniformResourceLocator"), in
    // that order, the first that gives a usable name. The address is asked
    // only when the HTML holds no picture, and only counts with a picture's
    // extension (ImageName.FromPictureUrl): next to HTML with a picture it is
    // the page's or a link's address. Null for a screenshot, which has only
    // pixels. Never throws: a name is a nicety, and a format that can't be
    // read must not cost the picture.
    private static string? ReadImageName()
    {
        const int MaxPathChars = 32 * 1024;
        bool htmlDecided = false;
        Func<string?>[] readers =
        {
            () => Win32Clipboard.Has(Win32Clipboard.CF_HDROP) && Win32Clipboard.GetFiles() is { Count: 1 } files ? ImageName.Suggest(files[0]) : null,
            () => ImageName.Suggest(Win32Clipboard.GetUnicodeText(Win32Clipboard.FileNameWFormat, MaxPathChars)),
            () => ImageName.Suggest(Win32Clipboard.GetAnsiText(Win32Clipboard.FileNameFormat, MaxPathChars)),
            () => Win32Clipboard.GetBytes(Win32Clipboard.FileGroupDescriptorWFormat, 64 * 1024) is byte[] descriptor ? ImageName.FromFileGroupDescriptorW(descriptor) : null,
            // One byte more than FromHtmlBytes takes, so HTML that is too big
            // is seen to be, rather than cut short and searched anyway.
            () => Win32Clipboard.GetBytes(Win32Clipboard.HtmlFormat, ImageName.MaxHtmlBytes + 1) is byte[] html ? ImageName.FromHtmlBytes(html, out htmlDecided) : null,
            () => htmlDecided ? null : ImageName.FromPictureUrl(Win32Clipboard.GetUnicodeText(Win32Clipboard.UrlWFormat, MaxPathChars)),
            () => htmlDecided ? null : ImageName.FromPictureUrl(Win32Clipboard.GetAnsiText(Win32Clipboard.UrlFormat, MaxPathChars)),
        };
        foreach (var read in readers)
        {
            try
            {
                if (read() is string name) return name;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[clip] couldn't read a copied picture's name: {ex.GetType().Name}: {ex.Message}");
            }
        }
        return null;
    }

    // Whether a copy is new, as far as the clipboard goes (the spec's 1.3,
    // automatic: no history here - the engine checks the newest item), and
    // remembering it either way: it's what the clipboard holds now.
    private bool IsNew(IReadOnlyCollection<string> prints, bool every = false)
    {
        bool already = LastWrite.IsAlready(manual: false, ownWrite: false, _lastWrite.Prints, prints, _ => false, _ => false, every);
        _lastWrite.Classified(prints);
        return !already;
    }

    // Multiple files can be selected and copied together in Explorer — sync
    // every one of them, not just the first, each as its own history entry.
    // (The per-file checks and payload are LocalFiles.Describe, which "Share
    // to ClipLink" uses too.) Only the list is read here; the hashing is done
    // off the watcher thread (see _filesGate).
    private void HandleFileDropList(List<string> paths, int generation)
    {
        if (paths.Count == 0) return;
        long since = _lastWrite.Generation;
        _ = Task.Run(async () =>
        {
            await _filesGate.WaitAsync();
            try
            {
                if (generation == activeGeneration()) DescribeAndPublish(paths, since, generation);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"couldn't read the copied files: {ex.GetType().Name}: {ex.Message}");
            }
            finally
            {
                _filesGate.Release();
            }
        });
    }

    // since: LastWrite's generation when the files were copied - if ClipLink
    // wrote the clipboard while they were hashed, the record keeps saying that.
    private void DescribeAndPublish(IReadOnlyList<string> paths, long since, int generation)
    {
        var readableFiles = new List<(string path, FilePayload payload)>();
        for (int i = 0; i < paths.Count; i++)
        {
            if (generation != activeGeneration()) return;
            if (readableFiles.Count == MaxFilesPerCopy)
            {
                Console.WriteLine($"copied {paths.Count} items: only the first {MaxFilesPerCopy} files are synced (what history keeps)");
                break;
            }
            string path = paths[i];
            var payload = LocalFiles.Describe(path, out var skip, out string? error);
            if (payload == null)
            {
                Console.WriteLine(skip == FileSkipReason.TooLarge
                    ? $"skipping file drop, too large to sync (limit {LocalFiles.MaxFileBytes} bytes): {path}"
                    : $"skipping file drop, not a readable file ({skip}{(error != null ? ": " + error : "")}): {path}");
                continue;
            }
            readableFiles.Add((path, payload));
        }
        if (readableFiles.Count == 0 || generation != activeGeneration()) return;

        // A file's print is its hash in lowercase (ContentPrint.File): this
        // PC hashes in uppercase and the phones in lowercase, so a file
        // received from Android or HarmonyOS and copied again in Explorer
        // never matched and went out as a new copy. The whole selection is an
        // echo only when every file in it is.
        var prints = readableFiles.Select(file => ContentPrint.File(file.payload.FileHash)).ToList();
        bool already = LastWrite.IsAlready(manual: false, ownWrite: false, _lastWrite.Prints, prints, _ => false, _ => false, every: true);
        _lastWrite.ClassifiedIfUnchanged(prints, since);
        if (already) return;

        // The same file twice in one selection goes out once.
        var seen = new HashSet<string>();
        var files = readableFiles.Where((_, index) => seen.Add(prints[index]))
            .Select(file => (System.Text.Json.JsonSerializer.Serialize(file.payload), file.path))
            .ToList();
        FilesCopied?.Invoke(files, generation);
    }

    // Ends Watch() (from any thread): its loop exits, and nothing queued
    // after that is applied. The engine stopping.
    public void Stop()
    {
        _stopRequested = true;
        _toPrepare.Writer.TryComplete();
        _window?.Post(WM_STOP);
    }

    // Puts content on the clipboard, on the watcher's thread. fromElsewhere:
    // another device's - a file then gets the Mark of the Web (see
    // ReceivedFiles.SaveFile).
    public void addToQueue(string content, string type = "text", bool fromElsewhere = false, int? automaticGeneration = null)
    {
        _toPrepare.Writer.TryWrite(new PendingSet(content, type, fromElsewhere, 0, automaticGeneration));
    }

    // The received image's file the clipboard refers to right now - the one
    // this put there with the picture (see Apply), while nothing else
    // has been copied since - or null. Any thread. "Clear synced history"
    // keeps that one (ReceivedFiles.DeleteImages): a clear never touches the
    // clipboard, and pasting the picture into a folder needs its file.
    public string? ImageFileOnClipboard()
    {
        var written = _imageFileWrite;
        return written != null && Win32Clipboard.Sequence == written.Sequence ? written.Path : null;
    }

    // The prepare worker (see _toPrepare): one write at a time, in order. One
    // that fails (a file still locked) is tried again later, like a write.
    private async Task PrepareWrites()
    {
        await foreach (var pending in _toPrepare.Reader.ReadAllAsync())
        {
            if (_stopRequested) return;
            if (!CanApply(pending)) continue;
            Write? write;
            try
            {
                write = Prepare(pending);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"couldn't get a peer update ready for the clipboard: {ex.GetType().Name}: {ex.Message}");
                RetryLater(pending, () => _ = Task.Delay((int)RetryMs).ContinueWith(_ => _toPrepare.Writer.TryWrite(pending with { Attempts = pending.Attempts + 1 })));
                continue;
            }
            if (write == null) continue;
            _ready.Enqueue(new ReadyWrite(pending, write));
            _window?.Post(WM_WORK);
        }
    }

    // Writes what's ready, in order, on the watcher's thread - until one
    // can't be written (the clipboard stays busy): it goes to the back, and
    // the rest wait for the retry.
    private void ApplyReady()
    {
        while (!_stopRequested && _ready.TryDequeue(out var ready))
        {
            if (!CanApply(ready.Pending)) continue;
            if (!Apply(ready))
            {
                RetryLater(ready.Pending, () => _ready.Enqueue(ready with { Pending = ready.Pending with { Attempts = ready.Pending.Attempts + 1 } }));
                RetrySoon();
                return;
            }
        }
    }

    // Queues a failed write again, unless it has failed MaxApplyAttempts
    // times. A transient failure (e.g. clipboard contention) used to lose
    // the peer update forever instead of just retrying once the contention
    // clears, the way local detection already does.
    private static void RetryLater(PendingSet pending, Action again)
    {
        int nextAttempt = pending.Attempts + 1;
        if (nextAttempt < MaxApplyAttempts)
        {
            Console.WriteLine($"clipboard busy, will retry this peer update (attempt {nextAttempt}/{MaxApplyAttempts})");
            again();
        }
        else
        {
            Console.WriteLine($"clipboard busy, giving up on this peer update after {MaxApplyAttempts} attempts");
        }
    }

    // One write, on the watcher's thread. A copy made here since the last
    // read - or while a big received file was being copied into place - is
    // read and sent first: the write replaces it on this PC, and it used to
    // be lost for good. False if the clipboard couldn't be written.
    private bool CanApply(PendingSet pending) =>
        !pending.AutomaticGeneration.HasValue || pending.AutomaticGeneration == activeGeneration();

    private bool Apply(ReadyWrite ready)
    {
        Write write = ready.Write;
        bool writing = false;
        uint before = 0;
        try
        {
            CaptureIfChanged();
            if (!CanApply(ready.Pending)) return true;
            before = Win32Clipboard.Sequence;
            writing = true;
            bool bitmap = write.Put();
            uint after = Win32Clipboard.Sequence;
            if (write.ImageFile != null) _imageFileWrite = new ImageFileWrite(write.ImageFile, after);
            // Our own write bumps the sequence number too - take it as already
            // seen, or WM_CLIPBOARDUPDATE has it read back as a fresh local
            // copy and sent straight back out. And what it wrote is remembered,
            // with - for a picture - the print of the PNG a read-back of the
            // bitmap makes (GDI+ re-encodes it, so it never matched the bytes
            // received): something else announcing the clipboard again (a
            // clipboard manager, RDP, Win+V) is then no new copy either.
            var prints = write.Prints.ToList();
            if (bitmap && ReadBackPrint() is string readBack) prints.Add(readBack);
            _lastWrite.Wrote(prints, after);
            _seenSequence = after;
            return true;
        }
        catch (Exception)
        {
            uint now = Win32Clipboard.Sequence;
            if (writing && now != before)
            {
                // A write that fails partway can still have changed the
                // clipboard: that's ClipLink's own half-done write, not a copy
                // (a picture read back from it matches no print). The retry
                // writes it again. (One that never got the clipboard changed
                // nothing: a copy still waiting to be read - busy too, say -
                // stays unseen, or it would be lost.)
                _seenSequence = now;
            }
            return false;
        }
    }

    // A write, ready to go: Put writes the clipboard (true if a bitmap went
    // on), Prints are of the content written (ContentPrint.Of, as for its
    // entry), ImageFile the received image's file it puts on with it.
    private sealed record Write(Func<bool> Put, IReadOnlyList<string> Prints, string? ImageFile = null);

    // Everything slow about a write - saving a received picture, copying a
    // received file into place - before the clipboard is touched. Null:
    // nothing to write. On the prepare worker.
    private Write? Prepare(PendingSet pending)
    {
        string content = pending.Content;
        if (pending.Type == "text")
        {
            return new Write(() =>
            {
                using (Win32Clipboard.Open(_window!.Handle))
                {
                    Win32Clipboard.Empty();
                    Win32Clipboard.SetText(content);
                }
                return false;
            }, new[] { ContentPrint.Text(content) });
        }
        if (pending.Type == "image")
        {
            byte[] imageBytes = Convert.FromBase64String(content);
            // Saved as a real file too, and put on the clipboard both ways (see
            // SetImageAndFile) - a bitmap alone pasted into Word or Paint but
            // not into an Explorer folder, which only accepts files. Named by
            // its content, so applying it again reuses the file (see
            // ReceivedFiles.SaveImage). If it can't be saved, the picture
            // still goes on, without the file.
            string? imageFile = ReceivedFiles.SaveImage(imageBytes, label);
            var prints = new List<string> { ContentPrint.Image(imageBytes) };
            // Copied again in Explorer, that file is these same bytes.
            if (imageFile != null) prints.Add(ContentPrint.File(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(imageBytes))));
            var picture = DecodePicture(imageBytes);
            if (picture == null && imageFile == null)
            {
                Console.WriteLine("image format not decodable here, and it couldn't be saved as a file - nothing to put on the clipboard");
                return null;
            }
            return new Write(() => SetImageAndFile(picture, imageFile), prints, imageFile);
        }
        if (pending.Type == "file")
        {
            var payload = System.Text.Json.JsonSerializer.Deserialize<FilePayload>(content);
            if (payload == null) return null;
            if (!fileStore.Exists(payload.FileHash))
            {
                // we don't have the bytes yet (chunks still arriving, or this
                // came from history reconciliation rather than a live transfer)
                Console.WriteLine($"can't apply file '{payload.FileName}' yet — content not available locally");
                return null;
            }

            string destPath = ReceivedFiles.SaveFile(fileStore.GetPath(payload.FileHash), payload.FileName, payload.FileHash, pending.FromElsewhere);
            var filePrints = new[] { ContentPrint.File(payload.FileHash) };

            // The same merge the other way round: a received image FILE also
            // goes on as a picture, so it pastes into documents as well as
            // into folders.
            var info = new FileInfo(destPath);
            if (ImageFiles.BitmapExtensions.Contains(info.Extension) && info.Length <= ImageFiles.MaxDecodeBytes)
            {
                var picture = DecodePicture(File.ReadAllBytes(destPath));
                return new Write(() => SetImageAndFile(picture, destPath), filePrints);
            }
            return new Write(() =>
            {
                using (Win32Clipboard.Open(_window!.Handle))
                {
                    Win32Clipboard.Empty();
                    Win32Clipboard.SetFiles(new[] { destPath });
                }
                return false;
            }, filePrints);
        }
        throw new NotImplementedException($"Clipboard type '{pending.Type}' is not supported yet.");
    }

    // The print of the clipboard's bitmap read back the way a copy here is
    // read (ReadBitmap, PngOf); null if it can't be read.
    private string? ReadBackPrint()
    {
        try
        {
            System.Drawing.Image? image;
            using (Win32Clipboard.Open(_window!.Handle)) image = ReadBitmap();
            if (image == null) return null;
            using (image) return ContentPrint.Image(PngOf(image).ToArray());
        }
        catch (Exception ex)
        {
            Console.WriteLine($"couldn't read back the picture just written: {ex.Message}");
            return null;
        }
    }

    // A received picture made ready for the clipboard (on the prepare
    // worker): decoded, turned upright, and - for a PNG - the bytes for the
    // "PNG" format. Null if GDI+ can't decode it (e.g. WebP or HEIC from a
    // phone): the file alone then pastes.
    private sealed record Picture(System.Drawing.Bitmap Bitmap, byte[]? Png);

    private static Picture? DecodePicture(byte[] imageBytes)
    {
        System.Drawing.Image? image = null;
        try
        {
            image = System.Drawing.Image.FromStream(new MemoryStream(imageBytes));
            bool turned = TurnUpright(image);
            byte[]? png = ImageFiles.Extension(imageBytes) == ".png" ? (turned ? PngOf(image).ToArray() : imageBytes) : null;
            var bitmap = image as System.Drawing.Bitmap ?? new System.Drawing.Bitmap(image);
            if (!ReferenceEquals(bitmap, image)) image.Dispose();
            return new Picture(bitmap, png);
        }
        catch (ArgumentException)
        {
            image?.Dispose();
            return null;
        }
    }

    // One clipboard item carrying the picture AND the file it's saved as:
    // apps that paste images (Word, Paint, chat apps) take the bitmap - or
    // the "PNG" format, which keeps transparency, for the ones that look for
    // it - while Explorer takes the file. No picture (not decodable here):
    // the file alone. No filePath (it couldn't be saved): the picture alone.
    // True if the bitmap went on. On the watcher's thread.
    private bool SetImageAndFile(Picture? picture, string? filePath)
    {
        if (picture == null) Console.WriteLine($"image format not decodable here, putting it on the clipboard as a file only: {filePath}");
        nint bitmap = 0;
        try
        {
            if (picture != null)
            {
                // A screen-compatible bitmap from GDI+'s, as WinForms made
                // for CF_BITMAP (transparent pixels on light grey there; the
                // PNG format keeps them).
                nint gdiBitmap = picture.Bitmap.GetHbitmap();
                try
                {
                    bitmap = Win32Clipboard.ScreenCompatibleCopy(gdiBitmap, picture.Bitmap.Width, picture.Bitmap.Height);
                }
                finally
                {
                    Win32Clipboard.DeleteBitmap(gdiBitmap);
                }
            }
            using (Win32Clipboard.Open(_window!.Handle))
            {
                Win32Clipboard.Empty();
                if (filePath != null) Win32Clipboard.SetFiles(new[] { filePath });
                if (bitmap != 0)
                {
                    nint giving = bitmap;
                    bitmap = 0; // the clipboard's now, on or not
                    Win32Clipboard.SetBitmap(giving);
                }
                if (picture?.Png != null) Win32Clipboard.SetBytes(Win32Clipboard.PngFormat, picture.Png);
            }
            // Written: no retry will need it. (A write that failed keeps it
            // for the next attempt.)
            picture?.Bitmap.Dispose();
            return picture != null;
        }
        finally
        {
            if (bitmap != 0) Win32Clipboard.DeleteBitmap(bitmap);
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

    // The bitmap as PNG: how a copy here is sent, and the "PNG" format of a
    // turned picture (the received bytes would paste it unturned).
    private static MemoryStream PngOf(System.Drawing.Image image)
    {
        var png = new MemoryStream();
        image.Save(png, System.Drawing.Imaging.ImageFormat.Png);
        png.Position = 0;
        return png;
    }
}
