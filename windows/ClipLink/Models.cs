using System.ComponentModel;
using System.Windows.Media;
using ClipboardDaemon.Engine;
using Wpf.Ui.Controls;

namespace ClipLink;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Raise(params string[] names)
    {
        foreach (string name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

// One card on the Synced page. Kept (and updated) for as long as its entry
// is in history, so its thumbnail is decoded once.
public sealed class HistoryCard : Observable
{
    public HistoryCard(HistoryItem item)
    {
        Item = item;
    }

    public HistoryItem Item { get; private set; }

    public string Key => Item.Key;
    public bool IsText => Item.Type == "text";
    public bool IsImage => Item.Type == "image";
    public bool IsFile => Item.Type == "file";
    public bool IsLink => IsText && LooksLikeLink(Item.TextPreview);

    public string KindText => IsLink ? "Link" : IsText ? "Text" : IsImage ? "Image" : IsFile ? "File" : "Item";

    public SymbolRegular KindIcon => IsLink ? SymbolRegular.Link24
        : IsText ? SymbolRegular.TextDescription24
        : IsImage ? SymbolRegular.Image24
        : IsFile ? SymbolRegular.Document24
        : SymbolRegular.DocumentQuestionMark24;

    // Names come from other devices: only ever through DeviceLabel.Of.
    public string Source => Item.FromThisDevice ? "This PC" : DeviceLabel.Of(Item.DeviceId, Item.DeviceName);

    public string When => Format.When(Item.TimestampUtc, DateTime.UtcNow);
    public string WhenExactly => Format.Exactly(Item.TimestampUtc);

    // The text as sent (untrusted, shown as plain text only), without the
    // blank lines around it.
    public string? Text => IsText ? Item.TextPreview?.Trim() : IsFile || IsImage ? null
        : "This kind of item can't be shown on Windows yet.";

    // What a card shows: at most its first lines (four in the list, ten in
    // the grid), with "…" when there's more. (The card cuts wrapped lines
    // off with an ellipsis by itself, but not the line after a line break -
    // a shopping list would just stop.) Selecting the card shows all of it.
    public string? PreviewText => FirstLines(4);
    public string? GridPreviewText => FirstLines(10);

    private string? FirstLines(int count)
    {
        if (Text is not { } text) return null;
        string[] lines = text.ReplaceLineEndings("\n").Split('\n');
        return lines.Length <= count ? text : string.Join('\n', lines[..count]).TrimEnd() + " …";
    }

    public string FileName => string.IsNullOrWhiteSpace(Item.FileName) ? "File" : Item.FileName!;

    public string FileDetail => !Item.IsAvailable ? "Not received yet"
        : Item.SizeBytes is long size ? Format.Size(size) : "";

    private ImageSource? thumbnail;
    // Decoded off the UI thread once the card exists; null until then.
    public ImageSource? Thumbnail
    {
        get => thumbnail;
        set { thumbnail = value; Raise(nameof(Thumbnail), nameof(ImageDetail), nameof(ThumbnailWidth), nameof(ThumbnailHeight), nameof(AspectRatio)); }
    }

    private bool thumbnailFailed;
    public bool ThumbnailFailed
    {
        get => thumbnailFailed;
        set { thumbnailFailed = value; Raise(nameof(ThumbnailFailed), nameof(ImageDetail)); }
    }

    public bool ThumbnailRequested { get; set; }

    public int PixelWidth { get; set; }
    public int PixelHeight { get; set; }

    // The thumbnail's size on the card: fitted into 320 x 180, never
    // enlarged past its own pixel size.
    private const double ThumbnailBoxWidth = 320, ThumbnailBoxHeight = 180;
    private double Scale => PixelWidth <= 0 || PixelHeight <= 0 ? 0
        : Math.Min(1, Math.Min(ThumbnailBoxWidth / PixelWidth, ThumbnailBoxHeight / PixelHeight));
    public double ThumbnailWidth => Math.Max(24, Math.Round(PixelWidth * Scale));
    public double ThumbnailHeight => Math.Max(24, Math.Round(PixelHeight * Scale));

    // Height over width, for the grid's full-width thumbnail (0 until known).
    public double AspectRatio => PixelWidth <= 0 || PixelHeight <= 0 ? 0 : (double)PixelHeight / PixelWidth;

    public string ImageDetail
    {
        get
        {
            if (ThumbnailFailed) return "This image couldn't be shown";
            string size = Item.SizeBytes is long bytes ? Format.Size(bytes) : "";
            return PixelWidth > 0 ? $"{PixelWidth} × {PixelHeight} · {size}" : size;
        }
    }

    public bool CanCopy => IsText || IsImage || (IsFile && Item.IsAvailable);
    public bool CanOpen => IsImage || (IsFile && Item.IsAvailable);

    // What a screen reader says for the card: what, from where, when - and
    // enough of the item to tell it apart from the others.
    public string AutomationName
    {
        get
        {
            string? what = IsFile ? FileName : IsText ? Text : null;
            if (what != null)
            {
                what = string.Join(' ', what.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                if (what.Length > 120) what = what[..(char.IsHighSurrogate(what[119]) ? 119 : 120)] + "…";
            }
            return $"{KindText} from {Source}, {When}{(string.IsNullOrEmpty(what) ? "" : $": {what}")}";
        }
    }

    // Under the full view's title: where it's from and exactly when.
    public string Origin => $"{(Item.FromThisDevice ? "Copied on this PC" : $"From {Source}")} · {WhenExactly}";

    public void Update(HistoryItem item)
    {
        if (item == Item) return;
        Item = item;
        Raise(nameof(Item), nameof(Source), nameof(Text), nameof(PreviewText), nameof(GridPreviewText), nameof(FileName), nameof(FileDetail), nameof(ImageDetail),
            nameof(CanCopy), nameof(CanOpen), nameof(AutomationName), nameof(Origin));
    }

    // The relative time moved on.
    public void Tick() => Raise(nameof(When), nameof(AutomationName));

    // What UI Automation calls the list item.
    public override string ToString() => AutomationName;

    private static bool LooksLikeLink(string? text)
    {
        string trimmed = text?.Trim() ?? "";
        return trimmed.Length > 0 && !trimmed.Any(char.IsWhiteSpace)
            && Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
    }
}

// One row on the Devices page.
public sealed class DeviceRow : Observable
{
    public DeviceRow(DeviceListing listing)
    {
        Listing = listing;
    }

    public DeviceListing Listing { get; private set; }

    public string PublicKey => Listing.PublicKey;
    public bool Trusted => Listing.Trusted;
    public bool Connected => Listing.Connected;

    public string Title => DeviceLabel.Of(Listing.PublicKey, Listing.Name);

    public string Status => Listing.Trusted
        ? (Listing.Connected ? "Connected" : "Not connected")
        : (Listing.PairingOpen ? "Pairing open" : "Not paired");

    // Second line: status, then every address it's known at.
    public string Details => Listing.Addresses.Count == 0
        ? Status
        : $"{Status} · {string.Join(" · ", Listing.Addresses)}";

    public string IdToolTip => $"Device ID: {Listing.PublicKey}";

    public string AutomationName => $"{Title}, {Details}";

    public override string ToString() => AutomationName;

    public void Update(DeviceListing listing)
    {
        if (listing.PublicKey == Listing.PublicKey && listing.Name == Listing.Name && listing.Trusted == Listing.Trusted
            && listing.Connected == Listing.Connected && listing.PairingOpen == Listing.PairingOpen
            && listing.Addresses.SequenceEqual(Listing.Addresses))
        {
            return;
        }
        Listing = listing;
        Raise(nameof(Listing), nameof(Trusted), nameof(Connected), nameof(Title), nameof(Status), nameof(Details), nameof(AutomationName));
    }
}
