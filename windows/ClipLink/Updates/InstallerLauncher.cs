using System.ComponentModel;
using System.Diagnostics;

namespace ClipLink.Updates;

// Runs the installer. The installer (windows\installer\ClipLink.iss) asks the
// running ClipLink to quit, replaces the files, and - with /RELAUNCH=1 - starts
// ClipLink again.
internal static class InstallerLauncher
{
    // Silent: progress is a small window, no questions, no restart of Windows.
    public static readonly IReadOnlyList<string> Arguments = new[] { "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/RELAUNCH=1" };

    private const int ErrorCancelled = 1223;

    public static ProcessStartInfo CreateStartInfo(string installerPath)
    {
        // The shell starts it, so Windows can ask for permission if the
        // installer turns out to need it (an install for all users).
        var info = new ProcessStartInfo(installerPath)
        {
            UseShellExecute = true,
            WorkingDirectory = Path.GetDirectoryName(installerPath) ?? "",
        };
        foreach (string argument in Arguments) info.ArgumentList.Add(argument);
        return info;
    }

    // Throws an UpdateException: Declined if Windows asked for permission and
    // the answer was no, Launch for anything else.
    public static Process Start(string installerPath)
    {
        try
        {
            return Process.Start(CreateStartInfo(installerPath))
                ?? throw new UpdateException(UpdateFailure.Launch, "Windows didn't start the installer.");
        }
        catch (Win32Exception ex)
        {
            throw Translate(ex);
        }
    }

    public static UpdateException Translate(Win32Exception ex) =>
        ex.NativeErrorCode == ErrorCancelled
            ? new UpdateException(UpdateFailure.Declined, "Windows asked for permission to run the installer and it wasn't given. Nothing was changed.", ex)
            : new UpdateException(UpdateFailure.Launch, $"Windows couldn't start the installer: {ex.Message}", ex);
}
