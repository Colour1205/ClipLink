using ClipboardDaemon.Engine;
using Microsoft.Toolkit.Uwp.Notifications;

namespace ClipLink;

// A pairing request as a Windows notification with Trust and Ignore buttons,
// for when the window isn't in front. In front, the window shows a dialog
// over whatever page is open instead (MainWindow) and this stays quiet.
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
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[app] notifications aren't available: {ex.GetType().Name}: {ex.Message}");
            return false;
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
