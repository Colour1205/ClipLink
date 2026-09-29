using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using ClipboardDaemon.Engine;
using Microsoft.Win32;

namespace ClipLink;

// "Share to ClipLink" in File Explorer, two ways, both per user (no admin):
//   - a verb on every file's right-click menu, HKCU\Software\Classes\*\shell\
//     ClipLink.Share ("*": files only, never folders). Explorer starts one
//     ClipLink per selected file - a command-line verb can't get them all at
//     once - and each hands its file to the running copy (InstancePipe),
//     which gathers them into one share. MultiSelectModel=Player keeps it on
//     the menu for up to 100 selected files (the default hides it past 15).
//   - a Send To shortcut, %APPDATA%\Microsoft\Windows\SendTo\ClipLink.lnk,
//     which gets every selected file in one command line (up to Windows'
//     ~32,000 characters - about 280 paths).
// On Windows 11 both are under "Show more options" (or Shift+F10): its new
// top-level menu only takes packaged apps (IExplorerCommand + package
// identity).
// There's no installer, so ClipLink keeps them itself: EnsureRegistered at
// every start while the setting is on (it only writes what's missing or
// stale, so a moved exe fixes itself), Unregister when it's turned off - in
// Settings, or with `ClipLink.exe --unregister`. A test copy (--label) gets
// its own verb and shortcut, never the real ones.
internal sealed class ShellIntegration
{
    private const string DefaultClassesKey = @"Software\Classes";

    private readonly string exePath;
    private readonly string identityArguments;
    private readonly string classesKey;
    private readonly string sendToFolder;
    private readonly bool notifyShell;

    // Tests can point it somewhere harmless: another HKCU key than
    // Software\Classes (Explorer never reads it), another folder than
    // SendTo, and no SHChangeNotify.
    public ShellIntegration(string exePath, string label, string identityArguments,
        string classesKey = DefaultClassesKey, string? sendToFolder = null, bool notifyShell = true)
    {
        this.exePath = exePath;
        this.identityArguments = identityArguments;
        this.classesKey = classesKey;
        this.sendToFolder = sendToFolder ?? Environment.GetFolderPath(Environment.SpecialFolder.SendTo);
        this.notifyShell = notifyShell;
        bool real = label == ClipLinkEngine.DefaultLabel;
        VerbName = real ? "ClipLink.Share" : $"ClipLink.Share.{label}";
        VerbText = real ? "Share to ClipLink" : $"Share to ClipLink ({label})";
        LinkName = real ? "ClipLink.lnk" : $"ClipLink ({label}).lnk";
    }

    // This exe, as it was started (Environment.ProcessPath: a single-file
    // publish has no Assembly.Location), for the ClipLink these options pick.
    public static ShellIntegration For(AppOptions options) =>
        new(Environment.ProcessPath ?? throw new InvalidOperationException("Can't tell where ClipLink.exe is."),
            options.Label, options.IdentityArguments());

    public string VerbName { get; }
    public string VerbText { get; }
    public string LinkName { get; }

    public string VerbKeyPath => $@"{classesKey}\*\shell\{VerbName}";
    public string LinkPath => Path.Combine(sendToFolder, LinkName);

    // The options before --share, so a test copy's share reaches that copy
    // (its label) - and a cold start is that copy.
    private string Prefix => identityArguments.Length > 0 ? identityArguments + " " : "";
    public string VerbCommand => $"\"{exePath}\" {Prefix}--share \"%1\"";
    public string LinkArguments => $"{Prefix}--share";

    // Writes whatever is missing or different from what this exe needs;
    // true if anything was. Throws (UnauthorizedAccessException, IOException,
    // COMException) if something couldn't be written.
    public bool EnsureRegistered()
    {
        bool changed = false;
        using (var verb = Registry.CurrentUser.CreateSubKey(VerbKeyPath, writable: true))
        {
            changed |= SetIfDifferent(verb, "MUIVerb", VerbText);
            changed |= SetIfDifferent(verb, "Icon", $"\"{exePath}\",0");
            // Shown for up to 100 selected files (still one process each).
            changed |= SetIfDifferent(verb, "MultiSelectModel", "Player");
            // Never what a double-click does, even for a file type with no
            // "open" of its own.
            changed |= SetIfDifferent(verb, "NeverDefault", "");
            using var command = verb.CreateSubKey("command", writable: true);
            changed |= SetIfDifferent(command, "", VerbCommand); // "": the key's (Default) value
        }

        if (!LinkIsCurrent())
        {
            Directory.CreateDirectory(sendToFolder);
            WriteLink();
            changed = true;
        }

        if (changed) NotifyShell();
        return changed;
    }

    // Removes both; true if either was there. Throws if one couldn't be
    // removed (e.g. the shortcut is open somewhere).
    public bool Unregister()
    {
        bool removed = false;
        try
        {
            using (var existing = Registry.CurrentUser.OpenSubKey(VerbKeyPath))
            {
                removed = existing != null;
            }
            if (removed) Registry.CurrentUser.DeleteSubKeyTree(VerbKeyPath, throwOnMissingSubKey: false);
            if (File.Exists(LinkPath))
            {
                File.Delete(LinkPath);
                removed = true;
            }
        }
        finally
        {
            if (removed) NotifyShell();
        }
        return removed;
    }

    // What's there now, for tests: the command, and the shortcut's target
    // and arguments (null if missing).
    public string? ReadVerbCommand()
    {
        using var command = Registry.CurrentUser.OpenSubKey(VerbKeyPath + @"\command");
        return command?.GetValue("") as string;
    }

    public (string Target, string Arguments)? ReadLink()
    {
        if (!File.Exists(LinkPath)) return null;
        var link = (IShellLinkW)new CShellLink();
        try
        {
            ((IPersistFile)link).Load(LinkPath, 0 /* STGM_READ */);
            var target = new StringBuilder(1024);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0x4 /* SLGP_RAWPATH */);
            var arguments = new StringBuilder(1024);
            link.GetArguments(arguments, arguments.Capacity);
            return (target.ToString(), arguments.ToString());
        }
        catch (Exception ex) when (ex is COMException or IOException or UnauthorizedAccessException)
        {
            return null; // not a shortcut we can read: rewritten
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    private bool LinkIsCurrent() =>
        ReadLink() is { } link
        && string.Equals(link.Target, exePath, StringComparison.OrdinalIgnoreCase)
        && link.Arguments == LinkArguments;

    private void WriteLink()
    {
        var link = (IShellLinkW)new CShellLink();
        try
        {
            link.SetPath(exePath);
            link.SetArguments(LinkArguments);
            link.SetWorkingDirectory(Path.GetDirectoryName(exePath)!);
            link.SetDescription("Send the selected files to your ClipLink devices");
            link.SetIconLocation(exePath, 0);
            ((IPersistFile)link).Save(LinkPath, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    private static bool SetIfDifferent(RegistryKey key, string name, string value)
    {
        if (key.GetValue(name) is string current && current == value) return false;
        key.SetValue(name, value, RegistryValueKind.String);
        return true;
    }

    // So Explorer picks the change up without a restart.
    private void NotifyShell()
    {
        if (notifyShell) SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, IntPtr.Zero, IntPtr.Zero);
    }

    private const int SHCNE_ASSOCCHANGED = 0x08000000;
    private const uint SHCNF_IDLIST = 0x0000;

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    // The shell's own shortcut object (no WScript.Shell, which policy can
    // turn off; no NuGet package).
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class CShellLink { }

    // Vtable order matters: every method, in IShellLinkW's order.
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }
}
