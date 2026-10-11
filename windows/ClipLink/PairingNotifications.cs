using ClipboardDaemon.Engine;
using Microsoft.Toolkit.Uwp.Notifications;

namespace ClipLink;

// A pairing request as a Windows notification with Trust and Ignore buttons,
// for when the window isn't in front. In front, the window shows a dialog
// over whatever page is open instead (MainWindow) and this stays quiet.
// Also the notification for items that arrive while the window isn't in
// front (opt-in, Settings > General): the one place ClipLink's toasts are
// made, so the one place that registers for them.
//
// Ignore, not Deny: nothing is remembered, so the device can ask again.
// Blocking is a separate, deliberate action on the Devices page.
//
// The app's own tray balloon (Tray.Notify) can't carry buttons, which is why
// this is a real toast. It goes through the Windows Community Toolkit's
// ToastNotificationManagerCompat, not the Windows App SDK's
// AppNotificationManager: that one needs a resource DLL
// (Microsoft.WindowsAppRuntime.Insights.Resource.dll) that only the installed
// Windows App Runtime has, and this app is self-contained, so its Register()
// fails with "The specified module could not be found". The Compat one is made
// for unpackaged desktop apps: it registers the COM activator itself, and a
// click on a closed app starts it with -ToastActivated (see AppOptions).
internal sealed class PairingNotifications
{
    public enum Answer { Trust, Ignore, Open }

    private const string Tag = "pairing";

    // How long a request waits (the engine ignores it at the same moment), so
    // a toast can't sit in the Action Center for a request that has long gone.
    private static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(3);

    private readonly Action<Answer, string?> answered;
    private bool registered;

    // answered is called on a background thread: marshal it to the UI.
    public PairingNotifications(Action<Answer, string?> answered)
    {
        this.answered = answered;
    }

    // False if notifications aren't available (then nothing here does anything).
    public bool Register()
    {
        try
        {
            ToastNotificationManagerCompat.OnActivated += OnActivated;
            registered = true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] notifications aren't available: {ex.GetType().Name}: {ex.Message}");
            return false;
        }

        try
        {
            // Windows 11 shows no toast of an app without this (see ToastShortcut).
            if (ToastShortcut.Ensure(App.Options.Label)) Console.WriteLine("[app] wrote the Start menu shortcut that notifications need");
            return true;
        }
        catch (Exception ex)
        {
            // Registered, so the toasts are still made - they may just never show.
            Console.WriteLine($"[app] couldn't write the Start menu shortcut notifications need: {ex.GetType().Name}: {ex.Message}");
            return true;
        }
    }

    // False if it couldn't be shown (so the caller can do something else).
    public bool Show(PendingPairing pending)
    {
        if (!registered) return false;
        try
        {
            string name = DeviceLabel.Of(pending.DeviceId, pending.Name);
            // The name is whatever that device chose to call itself; the
            // fingerprint comes from its id, so the two are shown together.
            string detail = $"ID {DeviceLabel.Fingerprint(pending.DeviceId)}" + (pending.Address != null ? $" - {pending.Address}" : "");

            new ToastContentBuilder()
                .AddArgument("device", pending.DeviceId)
                .AddText("Pairing request")
                .AddText($"{name} wants to pair with this PC. Only trust it if you're pairing it right now.")
                .AddText(detail)
                .AddButton(new ToastButton()
                    .SetContent("Trust")
                    .AddArgument("action", "trust")
                    .AddArgument("device", pending.DeviceId))
                .AddButton(new ToastButton()
                    .SetContent("Ignore")
                    .AddArgument("action", "ignore")
                    .AddArgument("device", pending.DeviceId))
                .Show(toast =>
                {
                    // One at a time: replaces the toast of an earlier request.
                    toast.Tag = Tag;
                    toast.Group = Tag;
                    toast.ExpirationTime = DateTimeOffset.Now + Lifetime;
                });
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't show the pairing notification: {ex.GetType().Name}: {ex.Message}");
            return false;
        }
    }

    // ---- items that arrived while the window isn't in front ----

    private const string ReceivedTag = "received";
    private const int PreviewChars = 60;

    // One toast, replaced as more arrive: "New from <device>" for the first,
    // "3 new items synced" after (count is how many since the window was last
    // in front). newest is the one it previews. Clicking it brings the window
    // up (the default of OnActivated).
    public void ShowReceived(HistoryItem newest, int count)
    {
        if (!registered) return;
        try
        {
            string title = count == 1
                ? $"New from {DeviceLabel.Of(newest.DeviceId, newest.DeviceName)}"
                : $"{count} new items synced";
            new ToastContentBuilder()
                .AddArgument("action", "open")
                .AddText(title)
                .AddText(ReceivedPreview(newest))
                .Show(toast =>
                {
                    toast.Tag = ReceivedTag;
                    toast.Group = ReceivedTag;
                });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't show the new-item notification: {ex.GetType().Name}: {ex.Message}");
        }
    }

    // Takes it down: the window is in front now.
    public void RemoveReceived()
    {
        if (!registered) return;
        try
        {
            ToastNotificationManagerCompat.History.Remove(ReceivedTag, ReceivedTag);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't remove the new-item notification: {ex.Message}");
        }
    }

    // What the notification says about an item. It can end up on the lock
    // screen, in the Action Center and on a paired phone's mirror, so: no
    // keys or tokens, a link as its host only, and a short first line of text
    // (the same rules as the iOS and HarmonyOS notifications).
    private static string ReceivedPreview(HistoryItem item)
    {
        switch (item.Type)
        {
            case "image":
                return "Image";
            case "file":
                return string.IsNullOrWhiteSpace(item.FileName) ? "File" : item.FileName;
        }

        string text = (item.TextPreview ?? "").Trim();
        if (text.Length >= 40 && !text.Contains(' ') && text.All(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '/' or '=' or '_' or '-'))
        {
            return "Key or token";
        }
        if ((text.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || text.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            && Uri.TryCreate(text.Split(new[] { ' ', '\n', '\r', '\t' }, StringSplitOptions.RemoveEmptyEntries)[0], UriKind.Absolute, out Uri? uri) && uri.Host.Length > 0)
        {
            return uri.Host;
        }
        string firstLine = text.Split('\n').Select(line => line.Trim()).FirstOrDefault(line => line.Length > 0) ?? "";
        if (firstLine.Length == 0) return "Text";
        return firstLine.Length > PreviewChars ? firstLine[..PreviewChars] + "…" : firstLine;
    }

    // Takes it down: the request was answered, in the window or elsewhere.
    public void Remove()
    {
        if (!registered) return;
        try
        {
            ToastNotificationManagerCompat.History.Remove(Tag, Tag);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] couldn't remove the pairing notification: {ex.Message}");
        }
    }

    private void OnActivated(ToastNotificationActivatedEventArgsCompat args)
    {
        var arguments = ToastArguments.Parse(args.Argument);
        arguments.TryGetValue("action", out string? action);
        arguments.TryGetValue("device", out string? device);
        answered(action switch
        {
            "trust" => Answer.Trust,
            "ignore" => Answer.Ignore,
            _ => Answer.Open, // the toast itself, not one of its buttons
        }, device);
    }
}
