using System.IO;
using ClipboardDaemon.Engine;
using ClipboardDaemon.Storage;

namespace ClipLink;

// What a share tells the user afterwards ("Shared 3 files", and what was
// skipped and why) - in the window if it's showing, else from the tray.
internal sealed record ShareSummary(string Title, string Message, bool IsError)
{
    // The likely ones first.
    private static readonly FileSkipReason[] ReasonOrder =
        { FileSkipReason.Folder, FileSkipReason.TooLarge, FileSkipReason.NotFound, FileSkipReason.Unreadable };

    public static ShareSummary Of(ShareResult result, int connectedDevices)
    {
        var lines = new List<string>();
        int shared = result.Shared.Count;
        // Every device keeps this many synced items: past it, the oldest go
        // (so a device that connects later only gets the latest ones).
        const int kept = HistoryAccess.MaxHistoryItems;
        if (shared > 0)
        {
            lines.Add(connectedDevices > 0
                ? (shared == 1 ? "On its way to your devices."
                    : "On their way to your devices." + (shared > kept ? $" Synced keeps only the latest {kept}." : ""))
                : shared == 1 ? "Your devices get it when they connect."
                : shared > kept ? $"Your devices get the latest {kept} when they connect (Synced keeps {kept} items)."
                : "Your devices get them when they connect.");
        }

        foreach (var group in result.Skipped.GroupBy(skip => skip.Reason).OrderBy(group => Array.IndexOf(ReasonOrder, group.Key)))
        {
            int count = group.Count();
            string name = NameOf(group.First().Path);
            lines.Add(group.Key switch
            {
                FileSkipReason.Folder => count == 1
                    ? $"Skipped the folder {name} - only files can be shared."
                    : $"Skipped {count} folders - only files can be shared.",
                FileSkipReason.TooLarge => count == 1
                    ? $"{name} is over {Format.Size(LocalFiles.MaxFileBytes)}, too big to share."
                    : $"{count} files are over {Format.Size(LocalFiles.MaxFileBytes)}, too big to share.",
                FileSkipReason.NotFound => count == 1 ? $"Couldn't find {name}." : $"Couldn't find {count} files.",
                _ => count == 1 ? $"Couldn't read {name}." : $"Couldn't read {count} files.",
            });
        }

        string title = shared == 0 ? "Nothing shared"
            : shared == 1 ? $"Shared {NameOf(result.Shared[0])}"
            : $"Shared {shared} files";
        return new ShareSummary(title, string.Join(" ", lines), IsError: shared == 0);
    }

    private static string NameOf(string path)
    {
        string name = Path.GetFileName(path.TrimEnd('\\', '/'));
        return name.Length > 0 ? name : path;
    }
}
