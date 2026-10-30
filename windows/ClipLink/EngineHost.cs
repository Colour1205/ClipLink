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
            foreach (var card in cards.Values) card.Tick();
        };
    }

    public ClipLinkEngine Engine { get; } = new();

    // The cards on the Synced page, in the order GetHistory() lists them (what
    // just arrived on top, then newest first). Items that arrived together in
    // one history sync are ONE card here (a stack, see BatchGrouping) until it
    // is opened.
    public ObservableCollection<HistoryCard> History { get; } = new();
    // Trusted devices, then untrusted ones on the LAN - each in the engine's
    // stable order.
    public ObservableCollection<DeviceRow> PairedDevices { get; } = new();
    public ObservableCollection<DeviceRow> NearbyDevices { get; } = new();
    // Blocked ones, listed last so they can be unblocked.
    public ObservableCollection<DeviceRow> BlockedDevices { get; } = new();

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
    public bool HasBlockedDevices => BlockedDevices.Count > 0;
    public bool HasNoDevices => PairedDevices.Count == 0 && NearbyDevices.Count == 0 && BlockedDevices.Count == 0;

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

    private void Post(Action action) => dispatcher.TryEnqueue(() => action());

    private void RefreshStatus()
    {
        // The latest, not the event's: a queued older status mustn't win.
        Status = Engine.Status;
        Raise(nameof(Status), nameof(IsFaulted), nameof(HasWarning), nameof(ConnectionSummary));
    }

    // Items that came from other devices and weren't in History before: what
    // arrived since the last reload (newest first). Never raised for the
    // first load, nor for this PC's own copies, nor for the items of a sync
    // after its first (HistoryItem.Quiet).
    public event Action<IReadOnlyList<HistoryItem>>? ItemsArrived;

    private bool historyLoaded;

    // Every entry's card, shown or folded into a stack, so a card keeps its
    // thumbnail when it comes out of one.
    private readonly Dictionary<string, HistoryCard> cards = new();
    // Stacks the user has opened: their cards stay ordinary ones.
    private readonly HashSet<string> expandedBatches = new();
    // Stacks already shown once (one that appears animates in once).
    private readonly HashSet<string> shownStacks = new();
    // What the engine listed last.
    private IReadOnlyList<HistoryItem> latestItems = Array.Empty<HistoryItem>();

    // The page's cards are about to be added to, so the ones that stay can
    // glide to their new places instead of jumping (SyncedPage).
    public event Action? CardsWillShift;

    // Only this many cards of an opened stack fly out one after another; a
    // huge stack would otherwise go on for seconds. The rest just appear.
    private const int MaxFlyingCards = 12;

    private void ReloadHistory() => ApplyHistory(Engine.GetHistory(), Array.Empty<string>());

    // Opens a stack: its cards come out as ordinary ones, right below the front
    // card (the engine lists them there, above everything older). It doesn't
    // fold again (nothing about stacks is saved: after a restart the history is
    // ordinary cards by time anyway).
    public void ExpandBatch(string batchId)
    {
        if (expandedBatches.Contains(batchId)) return;
        var folded = BatchGrouping.Build(ToEntries(latestItems), expandedBatches)
            .FirstOrDefault(row => row.BatchId == batchId)?.HiddenKeys ?? Array.Empty<string>();
        expandedBatches.Add(batchId);
        ApplyHistory(Engine.GetHistory(), folded);
    }

    private static List<BatchGrouping.Entry> ToEntries(IReadOnlyList<HistoryItem> items) =>
        items.Select(item => new BatchGrouping.Entry(item.Key, item.BatchId, item.BatchExpected)).ToList();

    // Shows the engine's history: one update, however many items it adds.
    // reveal: cards coming out of a stack that was just opened, newest first.
    private void ApplyHistory(IReadOnlyList<HistoryItem> items, IReadOnlyList<string> reveal)
    {
        latestItems = items;
        var arrived = historyLoaded ? items.Where(item => !item.FromThisDevice && !item.Quiet && !cards.ContainsKey(item.Key)).ToList() : new List<HistoryItem>();
        bool animate = historyLoaded;
        historyLoaded = true;

        // A card for every entry: made, updated, or dropped when it's gone.
        var present = new HashSet<string>(items.Select(item => item.Key));
        foreach (string gone in cards.Keys.Where(key => !present.Contains(key)).ToList()) cards.Remove(gone);
        foreach (var item in items)
        {
            if (cards.TryGetValue(item.Key, out var card)) card.Update(item);
            else cards[item.Key] = new HistoryCard(item);
        }

        // Which of them are cards on the page, and which are folded in a stack.
        var entries = ToEntries(items);
        BatchGrouping.ForgetExpandedGone(expandedBatches, entries);
        shownStacks.IntersectWith(items.Where(item => item.BatchId != null).Select(item => item.BatchId!));
        var rows = BatchGrouping.Build(entries, expandedBatches);
        var shown = new List<HistoryItem>(rows.Count);
        bool newStack = false;
        var byKey = new Dictionary<string, HistoryItem>();
        foreach (var item in items) byKey.TryAdd(item.Key, item);
        var stacks = new Dictionary<string, BatchGrouping.Row>();
        foreach (var row in rows)
        {
            shown.Add(byKey[row.FrontKey]);
            if (!row.IsStack) continue;
            stacks[row.FrontKey] = row;
            if (shownStacks.Add(row.BatchId!) && animate)
            {
                cards[row.FrontKey].PlanMotion(HistoryCard.Motion.Appear);
                newStack = true;
            }
        }
        // (Each card is set once, so a stack's card isn't unstacked and
        // stacked again in the same update.)
        foreach (var (key, card) in cards)
        {
            if (stacks.TryGetValue(key, out var row)) card.SetStack(row.BatchId, row.Hidden);
            else card.SetStack(null, 0);
        }
        for (int i = 0; i < reveal.Count; i++)
        {
            if (cards.TryGetValue(reveal[i], out var revealed) && i < MaxFlyingCards) revealed.PlanMotion(HistoryCard.Motion.Reveal, i);
        }

        if (newStack || reveal.Count > 0) CardsWillShift?.Invoke();
        CollectionSync.ByKey(History, shown, card => card.Key, item => item.Key, item => cards[item.Key], (card, item) => card.Update(item));
        foreach (var card in History)
        {
            // (A picture file's bytes may still be on their way: asked for
            // once they're here - this runs again when they are.)
            if (card.IsPicture && card.Item.IsAvailable && !card.ThumbnailRequested) _ = LoadThumbnailAsync(card);
        }
        Raise(nameof(HistoryIsEmpty));
        if (arrived.Count > 0) ItemsArrived?.Invoke(arrived);
    }

    private void ApplyDevices(IReadOnlyList<DeviceListing> devices)
    {
        CollectionSync.ByKey(PairedDevices, devices.Where(d => d.Trusted && !d.Blocked).ToList(), row => row.PublicKey, d => d.PublicKey, d => new DeviceRow(d), (row, d) => row.Update(d));
        CollectionSync.ByKey(NearbyDevices, devices.Where(d => !d.Trusted && !d.Blocked).ToList(), row => row.PublicKey, d => d.PublicKey, d => new DeviceRow(d), (row, d) => row.Update(d));
        CollectionSync.ByKey(BlockedDevices, devices.Where(d => d.Blocked).ToList(), row => row.PublicKey, d => d.PublicKey, d => new DeviceRow(d), (row, d) => row.Update(d));
        Raise(nameof(ConnectedCount), nameof(ConnectionSummary), nameof(HasPairedDevices), nameof(HasNearbyDevices), nameof(HasBlockedDevices), nameof(HasNoDevices));
        // The cards show device names too, which may have just changed.
        ReloadHistory();
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
            // As shown, not as stored: a phone's photo is saved sideways with
            // a tag saying how to turn it, which the BitmapImage honours.
            int width = (int)decoder.OrientedPixelWidth;
            int height = (int)decoder.OrientedPixelHeight;
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
