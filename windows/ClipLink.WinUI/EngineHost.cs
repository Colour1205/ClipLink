using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using ClipboardDaemon.Engine;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace ClipLink;

// The engine as the UI sees it: owns the ClipLinkEngine, brings its events
// (raised on the engine's own thread) onto the UI thread, and keeps the
// state the pages bind to. Everything here is UI-thread only.
public sealed class EngineHost : Observable
{
    private readonly DispatcherQueue dispatcher;
    private readonly DispatcherQueueTimer clock;

    public EngineHost(DispatcherQueue dispatcher)
    {
        this.dispatcher = dispatcher;
        Engine.HistoryChanged += () => Post(ReloadHistory);
        Engine.DevicesChanged += devices => Post(() => ApplyDevices(devices));
        Engine.PairingRequested += pending => Post(() => PairingRequested?.Invoke(pending));
        Engine.PairingResolved += (id, decision) => Post(() => PairingResolved?.Invoke(id, decision));
        Engine.StatusChanged += _ => Post(RefreshStatus);

        // "5 min ago" moves on by itself.
        clock = dispatcher.CreateTimer();
        clock.Interval = TimeSpan.FromSeconds(30);
        clock.Tick += (_, _) =>
        {
            foreach (var card in History) card.Tick();
        };
    }

    public ClipLinkEngine Engine { get; } = new();

    // Newest first, as GetHistory() orders it.
    public ObservableCollection<HistoryCard> History { get; } = new();
    // Trusted devices, then untrusted ones on the LAN - each in the engine's
    // stable order.
    public ObservableCollection<DeviceRow> PairedDevices { get; } = new();
    public ObservableCollection<DeviceRow> NearbyDevices { get; } = new();

    public EngineStatus Status { get; private set; } = new(EngineState.NotStarted, null);

    // Faulted: nothing syncs. Running with an Error: partly working.
    public bool IsFaulted => Status.State == EngineState.Faulted;
    public bool HasWarning => Status.State == EngineState.Running && Status.Error != null;

    public bool HasPasscode { get; private set; }

    public int ConnectedCount => PairedDevices.Count(device => device.Connected);

    // Synced page's line under its title.
    public string ConnectionSummary => IsFaulted ? "Not syncing"
        : ConnectedCount > 0 ? $"Syncing with {Format.Count(ConnectedCount, "device", "devices")}"
        : PairedDevices.Count > 0 ? "None of your devices are connected right now"
        : "No devices paired yet";

    public bool HistoryIsEmpty => History.Count == 0;
    public bool HasPairedDevices => PairedDevices.Count > 0;
    public bool HasNearbyDevices => NearbyDevices.Count > 0;
    public bool HasNoDevices => PairedDevices.Count == 0 && NearbyDevices.Count == 0;

    // The Devices page's pairing view is showing (so pairing mode is on).
    public bool PairingUiActive { get; private set; }

    public event Action<PendingPairing>? PairingRequested;
    public event Action<string, PairingDecision>? PairingResolved;

    public bool Start(AppOptions options)
    {
        bool running = Engine.Start(options.Label, options.Port, options.EngineOptions);
        RefreshStatus();
        RefreshPasscode();
        ReloadHistory();
        ApplyDevices(Engine.GetDevices());
        clock.Start();
        return running;
    }

    public void Retry()
    {
        Engine.Retry();
        RefreshStatus();
    }

    public void Stop()
    {
        clock.Stop();
        Engine.Stop();
    }

    public void RefreshPasscode()
    {
        HasPasscode = Engine.HasPasscode;
        Raise(nameof(HasPasscode));
    }

    // Text ClipLink shows (a device ID, the pairing info) onto the
    // clipboard. Through the engine while it runs, so it isn't synced to
    // the other devices as a copy; straight from here when it isn't (its
    // clipboard watcher isn't running then). False if the clipboard was
    // busy.
    public bool CopyText(string text)
    {
        if (Status.State == EngineState.Running || App.Options.NoClipboard)
        {
            Engine.CopyTextToClipboard(text);
            return true;
        }
        try
        {
            var package = new DataPackage();
            package.SetText(text);
            Clipboard.SetContent(package);
            return true;
        }
        catch (COMException ex)
        {
            Console.WriteLine($"[app] couldn't write the clipboard: {ex.Message}");
            return false;
        }
    }

    public void SetPairingUiActive(bool active)
    {
        if (active == PairingUiActive) return;
        PairingUiActive = active;
        Engine.SetPairingMode(active);
        Console.WriteLine($"[app] pairing mode {(active ? "on" : "off")}");
    }

    private void Post(Action action) => dispatcher.TryEnqueue(() => action());

    private void RefreshStatus()
    {
        // The latest, not the event's: a queued older status mustn't win.
        Status = Engine.Status;
        Raise(nameof(Status), nameof(IsFaulted), nameof(HasWarning), nameof(ConnectionSummary));
    }

    private void ReloadHistory()
    {
        var items = Engine.GetHistory();
        SyncByKey(History, items, card => card.Key, item => item.Key, item => new HistoryCard(item), (card, item) => card.Update(item));
        foreach (var card in History)
        {
            if (card.IsImage && !card.ThumbnailRequested) _ = LoadThumbnailAsync(card);
        }
        Raise(nameof(HistoryIsEmpty));
    }

    private void ApplyDevices(IReadOnlyList<DeviceListing> devices)
    {
        SyncByKey(PairedDevices, devices.Where(d => d.Trusted).ToList(), row => row.PublicKey, d => d.PublicKey, d => new DeviceRow(d), (row, d) => row.Update(d));
        SyncByKey(NearbyDevices, devices.Where(d => !d.Trusted).ToList(), row => row.PublicKey, d => d.PublicKey, d => new DeviceRow(d), (row, d) => row.Update(d));
        Raise(nameof(ConnectedCount), nameof(ConnectionSummary), nameof(HasPairedDevices), nameof(HasNearbyDevices), nameof(HasNoDevices));
        // The cards show device names too, which may have just changed.
        ReloadHistory();
    }

    // Makes target match source, in source's order, reusing the items it
    // already has by key - so a card keeps its thumbnail, a row its focus,
    // and the list its scroll position.
    private static void SyncByKey<TItem, TSource>(ObservableCollection<TItem> target, IReadOnlyList<TSource> source,
        Func<TItem, string> keyOfItem, Func<TSource, string> keyOfSource, Func<TSource, TItem> create, Action<TItem, TSource> update)
    {
        var existing = new Dictionary<string, TItem>();
        foreach (var item in target) existing.TryAdd(keyOfItem(item), item);
        for (int i = 0; i < source.Count; i++)
        {
            if (existing.TryGetValue(keyOfSource(source[i]), out var item))
            {
                update(item, source[i]);
                int at = target.IndexOf(item);
                if (at != i) target.Move(at, i);
            }
            else
            {
                target.Insert(i, create(source[i]));
            }
        }
        while (target.Count > source.Count) target.RemoveAt(target.Count - 1);
    }

    // Thumbnails are decoded at most this big - enough for the list's 320 x
    // 180 box and a grid card's full width (up to 320 high) on a high-DPI
    // screen, never the full size a phone screenshot has.
    private const int ThumbnailMaxWidth = 720;
    private const int ThumbnailMaxHeight = 960;

    private async Task LoadThumbnailAsync(HistoryCard card)
    {
        card.ThumbnailRequested = true;
        var (image, width, height) = await DecodeImageAsync(card.Key, ThumbnailMaxWidth, ThumbnailMaxHeight);
        card.PixelWidth = image == null ? 0 : width;
        card.PixelHeight = image == null ? 0 : height;
        if (image == null) card.ThumbnailFailed = true;
        else card.Thumbnail = image;
    }

    // An image entry decoded for the Synced page's full view (at most this
    // big - enough for a large window on a high-DPI screen). Null if it's
    // gone or can't be decoded. Not cached: it's one image at a time.
    public async Task<BitmapImage?> LoadImageAsync(string key) =>
        (await DecodeImageAsync(key, 2400, 2400)).Image;

    // The bytes are read off the UI thread; the decode itself is WinUI's
    // (a BitmapImage belongs to the UI thread), no bigger than maxWidth x
    // maxHeight (never enlarged); also the image's own pixel size.
    private async Task<(BitmapImage? Image, int Width, int Height)> DecodeImageAsync(string key, int maxWidth, int maxHeight)
    {
        try
        {
            if (await Task.Run(() => Engine.GetImageBytes(key)) is not byte[] bytes) return (null, 0, 0);
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            // Only the header, to pick the decode size.
            var decoder = await BitmapDecoder.CreateAsync(stream);
            int width = (int)decoder.PixelWidth;
            int height = (int)decoder.PixelHeight;
            var bitmap = new BitmapImage();
            if ((long)width * maxHeight > (long)height * maxWidth)
                bitmap.DecodePixelWidth = Math.Min(width, maxWidth);
            else
                bitmap.DecodePixelHeight = Math.Min(height, maxHeight);
            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
            return (bitmap, width, height);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't decode an image: {ex.GetType().Name}: {ex.Message}");
            return (null, 0, 0);
        }
    }
}
