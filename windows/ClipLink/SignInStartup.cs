using System.IO;
using Microsoft.Win32;

namespace ClipLink;

// "Start ClipLink when I sign in": a value under HKCU\...\Run starting this
// exe with --background (tray icon only). Per user, no admin needed. A test
// copy (another --label) gets its own value, so it never replaces the real
// one.
internal static class SignInStartup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    // Where Task Manager's "Startup apps" (and Settings > Apps > Startup)
    // record a Run value the user switched off - it stays in Run, but
    // Windows skips it.
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    private static string ValueName(AppOptions options) =>
        options.IsDefaultLabel ? "ClipLink" : $"ClipLink ({options.Label})";

    private static string Command(AppOptions options)
    {
        string extra = options.IdentityArguments();
        return $"\"{Environment.ProcessPath}\" --background" + (extra.Length > 0 ? " " + extra : "");
    }

    // On, and not switched off in Task Manager.
    public static bool IsEnabled(AppOptions options)
    {
        using var run = Registry.CurrentUser.OpenSubKey(RunKey);
        if (run?.GetValue(ValueName(options)) is not string) return false;
        using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
        // 12 bytes; the first is even (02/06) when enabled, odd (03/07) when disabled.
        return approved?.GetValue(ValueName(options)) is not byte[] { Length: > 0 } state || (state[0] & 1) == 0;
    }

    public static void Enable(AppOptions options)
    {
        using (var run = Registry.CurrentUser.CreateSubKey(RunKey))
        {
            run.SetValue(ValueName(options), Command(options), RegistryValueKind.String);
        }
        // Turning it on here overrides an earlier "Disabled" in Task Manager.
        ForgetApproval(options);
    }

    public static void Disable(AppOptions options)
    {
        using (var run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true))
        {
            run?.DeleteValue(ValueName(options), throwOnMissingValue: false);
        }
        ForgetApproval(options);
    }

    // The exe was moved (or replaced by a build somewhere else): an entry
    // left pointing at a file that's gone is pointed at this one instead.
    public static void RepairPath(AppOptions options)
    {
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(ValueName(options)) is not string command) return;
            string? exe = ExeOf(command);
            if (exe != null && !File.Exists(exe))
            {
                Console.WriteLine($"[startup] sign-in entry pointed at {exe}, which is gone - now {Environment.ProcessPath}");
                Enable(options);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[startup] couldn't check the sign-in entry: {ex.Message}");
        }
    }

    private static string? ExeOf(string command)
    {
        command = command.Trim();
        if (command.StartsWith('"'))
        {
            int end = command.IndexOf('"', 1);
            return end > 1 ? command[1..end] : null;
        }
        int space = command.IndexOf(' ');
        return space > 0 ? command[..space] : command;
    }

    private static void ForgetApproval(AppOptions options)
    {
        using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
        approved?.DeleteValue(ValueName(options), throwOnMissingValue: false);
    }
}
