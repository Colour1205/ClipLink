using System.Diagnostics;
using System.IO;

namespace ClipLink;

// Opening files that came from another device. Their names (and so their
// extensions) are the sender's choice.
internal static class FileOpener
{
    // Kinds that run something when opened, rather than showing it: they're
    // never opened without asking first.
    private static readonly HashSet<string> ProgramExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".com", ".scr", ".pif", ".cpl", ".msc", ".dll", ".sys", ".drv", ".ocx",
        ".bat", ".cmd", ".ps1", ".psm1", ".psd1", ".ps1xml", ".psc1", ".vbs", ".vbe", ".vb", ".js", ".jse",
        ".wsf", ".wsh", ".wsc", ".sct", ".hta", ".jar", ".py", ".pyw",
        ".msi", ".msp", ".mst", ".msix", ".msixbundle", ".appx", ".appxbundle", ".appinstaller",
        ".application", ".appref-ms", ".gadget", ".xll", ".xbap", ".jnlp",
        ".lnk", ".url", ".website", ".scf", ".inf", ".reg", ".chm", ".settingcontent-ms", ".library-ms", ".search-ms", ".searchconnector-ms",
        ".rdp", ".diagcab", ".theme", ".themepack",
        ".iso", ".img", ".vhd", ".vhdx",
    };

    public static bool IsProgram(string path) => ProgramExtensions.Contains(Path.GetExtension(path));

    // Marks the copy as downloaded from the internet (the Mark of the Web,
    // as a browser would), so Windows treats it with the same care: Office
    // opens it in Protected View, SmartScreen checks a program. Best
    // effort - some drives can't hold the mark.
    public static void MarkAsFromElsewhere(string path)
    {
        try
        {
            // Writing the mark counts as writing the file: its last-write
            // time goes back as it was, or the engine would take the copy
            // for one the user edited and never clean it up (see
            // ClipLinkEngine.GetFileToOpen).
            DateTime lastWrite = File.GetLastWriteTimeUtc(path);
            File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
            File.SetLastWriteTimeUtc(path, lastWrite);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            Console.WriteLine($"[app] couldn't mark {Path.GetFileName(path)} as downloaded: {ex.Message}");
        }
    }

    public static void ShowInFolder(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
}
