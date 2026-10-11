using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace ClipLink;

// A Start menu shortcut that carries ClipLink's notification identity: its
// AppUserModelID and ToastActivatorCLSID.
//
// Without it, Windows 11 (seen on 25H2) accepts ClipLink's toasts, files them
// ("delivered" in the PushNotification-Platform log, a row in the Action
// Center's database) and never shows a banner or lists the app under
// Settings > Notifications. What ToastNotificationManagerCompat registers on
// its own - the AppUserModelId key under HKCU\Software\Classes - isn't
// enough: a plain toast sent under the app's own id was dropped the same
// way, and shown the moment this shortcut existed. So the pairing request
// (and the new-item notification) never appeared, whatever ClipLink did.
//
// The identity isn't ours to choose: the toast library derives it - the SHA-1
// of this exe's path, in hex (it never sets one on the process) - and registers
// it, so this works it out the same way, checks the library did register that
// one, reads the CustomActivator it wrote under it, and puts exactly that on the
// shortcut. Written at every start, only if missing or different
// (a moved exe fixes itself, like ShellIntegration's). Best effort: if it
// can't be written, notifications are as they were and the pairing request
// is still answered in the window.
//
// The setup program makes a Start menu shortcut of its own, "ClipLink", in the
// same folder for a per-user install: the installed copy rewrites that one
// (same target, so it only gains the identity), and for an all-users install
// adds a per-user one beside it. Any other copy - a build folder, a test copy -
// would otherwise point that entry at itself, so it gets a shortcut of its
// own, named with a few characters of its path's hash.
internal static class ToastShortcut
{
    private static readonly Guid AppUserModelKeys = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private const uint AppUserModelIdPid = 5;
    private const uint ToastActivatorClsidPid = 26;
    private const ushort VtLpwstr = 31;
    private const ushort VtClsid = 72;

    // "ClipLink.lnk" for the real one, "ClipLink (<label>).lnk" for a test
    // copy - unless that name is another copy's (a shortcut to a different
    // exe that is still there), then it has the path's hash after it.
    private static string LinkPath(string label, string exe)
    {
        string name = label == ClipboardDaemon.Engine.ClipLinkEngine.DefaultLabel ? "ClipLink" : $"ClipLink ({label})";
        string folder = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        string path = Path.Combine(folder, name + ".lnk");
        if (!File.Exists(path) || TargetOf(path) is not { } other || string.Equals(other, exe, StringComparison.OrdinalIgnoreCase) || !File.Exists(other))
        {
            return path;
        }
        string hash = Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(exe)))[..6];
        return Path.Combine(folder, $"{name} {hash}.lnk");
    }

    // True if it wrote the shortcut, false if it was already right. Throws
    // (IOException, UnauthorizedAccessException, COMException) if it couldn't.
    public static bool Ensure(string label)
    {
        string exe = Environment.ProcessPath ?? throw new InvalidOperationException("Can't tell where ClipLink.exe is.");
        string aumid = Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(exe)));
        Guid activator = ActivatorOf(aumid)
            ?? throw new InvalidOperationException($"The toast library has no registration for {aumid} (derived from {exe}).");

        string path = LinkPath(label, exe);
        if (IsCurrent(path, exe, aumid, activator)) return false;

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var link = (IShellLinkW)new CShellLink();
        try
        {
            link.SetPath(exe);
            link.SetWorkingDirectory(Path.GetDirectoryName(exe)!);
            link.SetDescription("Clipboard sync between your devices");
            link.SetIconLocation(exe, 0);
            var store = (IPropertyStore)link;
            SetString(store, AppUserModelIdPid, aumid);
            SetClsid(store, ToastActivatorClsidPid, activator);
            Check(store.Commit());
            ((IPersistFile)link).Save(path, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
        return true;
    }

    // A test copy's own shortcut, taken out with its other traces
    // (--unregister). The real one is the setup program's to remove.
    public static void Remove(string label)
    {
        if (label == ClipboardDaemon.Engine.ClipLinkEngine.DefaultLabel) return;
        string exe = Environment.ProcessPath ?? "";
        string path = LinkPath(label, exe);
        if (File.Exists(path) && string.Equals(TargetOf(path), exe, StringComparison.OrdinalIgnoreCase)) File.Delete(path);
    }

    // Where a shortcut points; null if it can't be read.
    private static string? TargetOf(string path)
    {
        var link = (IShellLinkW)new CShellLink();
        try
        {
            ((IPersistFile)link).Load(path, 0 /* STGM_READ */);
            var target = new StringBuilder(1024);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0x4 /* SLGP_RAWPATH */);
            return target.ToString();
        }
        catch (Exception ex) when (ex is COMException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    private static bool IsCurrent(string path, string exe, string aumid, Guid activator)
    {
        if (!File.Exists(path)) return false;
        var link = (IShellLinkW)new CShellLink();
        try
        {
            ((IPersistFile)link).Load(path, 0 /* STGM_READ */);
            var target = new StringBuilder(1024);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0x4 /* SLGP_RAWPATH */);
            if (!string.Equals(target.ToString(), exe, StringComparison.OrdinalIgnoreCase)) return false;
            var store = (IPropertyStore)link;
            return GetString(store, AppUserModelIdPid) == aumid && GetClsid(store, ToastActivatorClsidPid) == activator;
        }
        catch (Exception ex) when (ex is COMException or IOException or UnauthorizedAccessException)
        {
            return false; // not a shortcut we can read: written again
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    private static Guid? ActivatorOf(string aumid)
    {
        using var key = Registry.CurrentUser.OpenSubKey($@"Software\Classes\AppUserModelId\{aumid}");
        return key?.GetValue("CustomActivator") is string text && Guid.TryParse(text, out Guid guid) ? guid : null;
    }

    // ---- property store ---------------------------------------------------------

    private static void SetString(IPropertyStore store, uint pid, string value)
    {
        var key = new PROPERTYKEY { fmtid = AppUserModelKeys, pid = pid };
        var variant = new PROPVARIANT { vt = VtLpwstr, p = Marshal.StringToCoTaskMemUni(value) };
        try
        {
            Check(store.SetValue(ref key, ref variant));
        }
        finally
        {
            PropVariantClear(ref variant);
        }
    }

    private static void SetClsid(IPropertyStore store, uint pid, Guid value)
    {
        var key = new PROPERTYKEY { fmtid = AppUserModelKeys, pid = pid };
        IntPtr memory = Marshal.AllocCoTaskMem(16);
        Marshal.Copy(value.ToByteArray(), 0, memory, 16);
        var variant = new PROPVARIANT { vt = VtClsid, p = memory };
        try
        {
            Check(store.SetValue(ref key, ref variant));
        }
        finally
        {
            PropVariantClear(ref variant);
        }
    }

    private static string? GetString(IPropertyStore store, uint pid)
    {
        var key = new PROPERTYKEY { fmtid = AppUserModelKeys, pid = pid };
        Check(store.GetValue(ref key, out PROPVARIANT variant));
        try
        {
            return variant.vt == VtLpwstr ? Marshal.PtrToStringUni(variant.p) : null;
        }
        finally
        {
            PropVariantClear(ref variant);
        }
    }

    private static Guid? GetClsid(IPropertyStore store, uint pid)
    {
        var key = new PROPERTYKEY { fmtid = AppUserModelKeys, pid = pid };
        Check(store.GetValue(ref key, out PROPVARIANT variant));
        try
        {
            return variant.vt == VtClsid ? Marshal.PtrToStructure<Guid>(variant.p) : null;
        }
        finally
        {
            PropVariantClear(ref variant);
        }
    }

    private static void Check(uint hresult)
    {
        if ((int)hresult < 0) Marshal.ThrowExceptionForHR((int)hresult);
    }

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT variant);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;
    }

    // Only the two kinds read and written here (a string, a CLSID): the
    // value is a pointer at offset 8 in both.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        uint GetCount(out uint count);
        uint GetAt(uint index, out PROPERTYKEY key);
        uint GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        uint SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        uint Commit();
    }

    // The shell's own shortcut object (see ShellIntegration, which has the
    // same two declarations - they are private to each class).
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
