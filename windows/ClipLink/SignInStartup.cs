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

    // The exe was moved, or a build somewhere else is the one running now:
    // an entry pointing at any other exe - gone, or another copy - is
    // pointed at this one, keeping its arguments (--background, a test
    // copy's --label...). Only the Run value changes, so an entry switched
    // off in Task Manager stays off.
    public static void RepairPath(AppOptions options)
    {
        try
        {
            string? running = Environment.ProcessPath;
            if (running == null) return;
            using var run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (run?.GetValue(ValueName(options)) is not string command) return;
            var (exe, arguments) = Split(command);
            if (exe != null && string.Equals(Path.GetFullPath(exe), Path.GetFullPath(running), StringComparison.OrdinalIgnoreCase)) return;
            Console.WriteLine($"[startup] sign-in entry pointed at {exe ?? command} - now {running}");
            run.SetValue(ValueName(options), exe != null ? $"\"{running}\"{arguments}" : Command(options), RegistryValueKind.String);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[startup] couldn't check the sign-in entry: {ex.Message}");
        }
    }

    // A Run command's exe (null if it can't be read) and the rest of the
    // command line after it, leading space included.
    private static (string? Exe, string Arguments) Split(string command)
    {
        command = command.Trim();
        if (command.StartsWith('"'))
        {
            int end = command.IndexOf('"', 1);
            return end > 1 ? (command[1..end], command[(end + 1)..]) : (null, "");
        }
        // Unquoted, a path with spaces still ends at ".exe".
        int exeEnd = command.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        int split = exeEnd > 0 ? exeEnd + ".exe".Length : command.IndexOf(' ');
        return split > 0 && split < command.Length ? (command[..split], command[split..]) : (command, "");
    }

    private static void ForgetApproval(AppOptions options)
    {
        using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
        approved?.DeleteValue(ValueName(options), throwOnMissingValue: false);
    }
}
