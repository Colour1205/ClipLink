namespace ClipLink.Updates;

// %TEMP%\ClipLink-update: where an update is downloaded to.
internal static class UpdateFolder
{
    public static string DefaultPath => Path.Combine(Path.GetTempPath(), "ClipLink-update");

    // Frees what earlier updates left behind: installers that have run, and
    // downloads that never finished. Only files the updater makes (by their
    // names), and never `keep`. Best effort: a file still in use - an
    // installer that is still finishing - stays until next time.
    public static void Clear(string folder, string? keep = null)
    {
        try
        {
            foreach (string file in Directory.EnumerateFiles(folder, "ClipLink-Setup-*"))
            {
                string name = Path.GetFileName(file);
                if (!name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && !name.EndsWith(".exe.part", StringComparison.OrdinalIgnoreCase)) continue;
                if (keep != null && string.Equals(Path.GetFullPath(file), Path.GetFullPath(keep), StringComparison.OrdinalIgnoreCase)) continue;
                TryDelete(file);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // (No folder yet, or not readable.)
        }
    }

    public static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"[update] couldn't delete {path}: {ex.Message}");
        }
    }
}
