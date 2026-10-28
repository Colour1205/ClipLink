using System.Security.Cryptography;

namespace ClipLink.Updates;

// An installer on disk that matches what GitHub lists for the release (size
// and SHA-256), and is still held open: until Dispose nobody else can write
// to it, rename it or delete it, so the file that is run is the very file
// that was checked.
internal sealed class VerifiedInstaller : IDisposable
{
    private readonly FileStream hold;

    private VerifiedInstaller(string filePath, FileStream hold)
    {
        FilePath = filePath;
        this.hold = hold;
    }

    public string FilePath { get; }

    public void Dispose() => hold.Dispose();

    // Opens the file and checks it, in that order, on the same handle. Throws
    // an UpdateException (Verification) if it isn't what `asset` describes,
    // or (Disk) if it can't be read.
    public static async Task<VerifiedInstaller> OpenAsync(string filePath, UpdateAsset asset, CancellationToken cancellation)
    {
        var stream = await OpenLockedAsync(filePath, cancellation);
        try
        {
            if (asset.Sha256 == null) throw NotVerified();
            if (stream.Length != asset.Size) throw NotVerified();
            string hash = UpdateVerification.ToHex(await SHA256.HashDataAsync(stream, cancellation));
            if (UpdateVerification.Check(stream.Length, hash, asset) != VerifyResult.Ok) throw NotVerified();
            return new VerifiedInstaller(filePath, stream);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            stream.Dispose();
            throw new UpdateException(UpdateFailure.Disk, "Couldn't read the downloaded update.", ex);
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    public static UpdateException NotVerified() =>
        new(UpdateFailure.Verification, "The download doesn't match what GitHub lists for this version, so it wasn't installed.");

    private static async Task<FileStream> OpenLockedAsync(string filePath, CancellationToken cancellation)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                // Read-only, and no one else may write, rename or delete it
                // while it's open.
                return new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16,
                    FileOptions.Asynchronous | FileOptions.SequentialScan);
            }
            catch (IOException) when (attempt < 5 && File.Exists(filePath))
            {
                // (A virus scanner may have just been at the new file.)
                await Task.Delay(200, cancellation);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new UpdateException(UpdateFailure.Disk, "Couldn't read the downloaded update.", ex);
            }
        }
    }
}
