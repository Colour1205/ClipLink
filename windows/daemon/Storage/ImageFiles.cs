namespace ClipboardDaemon.Storage;

public static class ImageFiles
{
    // From the file's magic bytes - phones send PNG or JPEG, sometimes others.
    public static string Extension(byte[] bytes)
    {
        bool StartsWith(params byte[] magic) => bytes.Length >= magic.Length && bytes.AsSpan(0, magic.Length).SequenceEqual(magic);
        if (StartsWith(0x89, 0x50, 0x4E, 0x47)) return ".png";
        if (StartsWith(0xFF, 0xD8, 0xFF)) return ".jpg";
        if (StartsWith(0x47, 0x49, 0x46, 0x38)) return ".gif";
        if (StartsWith(0x42, 0x4D)) return ".bmp";
        if (bytes.Length >= 12 && StartsWith(0x52, 0x49, 0x46, 0x46) && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) return ".webp";
        return ".png";
    }
}
