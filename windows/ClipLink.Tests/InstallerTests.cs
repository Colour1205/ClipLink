using System.ComponentModel;
using ClipLink.Updates;
using Xunit;

namespace ClipLink.Tests;

public class VerifiedInstallerTests
{
    private static readonly byte[] Installer = TestReleases.Installer(50_000);

    private static UpdateAsset AssetOf(byte[] bytes) => TestReleases.Offer("2.0.2", bytes).Asset;

    [Fact]
    public async Task OpensAFileThatMatchesAndHoldsIt()
    {
        using var folder = new TempFolder();
        string path = folder.File("ClipLink-Setup-2.0.2.exe");
        await File.WriteAllBytesAsync(path, Installer);

        using (var installer = await VerifiedInstaller.OpenAsync(path, AssetOf(Installer), CancellationToken.None))
        {
            Assert.Equal(path, installer.FilePath);
            // Nobody can change, rename or delete it meanwhile ...
            Assert.Throws<IOException>(() => File.Delete(path));
            Assert.Throws<IOException>(() => File.Move(path, folder.File("moved.exe")));
            Assert.Throws<IOException>(() => File.WriteAllBytes(path, new byte[1]));
            // ... but it can be read, which is what starting a program does.
            using var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            Assert.Equal(Installer.Length, reader.Length);
        }

        File.Delete(path);
        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task RefusesAFileWithTheWrongContent()
    {
        using var folder = new TempFolder();
        string path = folder.File("ClipLink-Setup-2.0.2.exe");
        var tampered = (byte[])Installer.Clone();
        tampered[0] ^= 1;
        await File.WriteAllBytesAsync(path, tampered);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => VerifiedInstaller.OpenAsync(path, AssetOf(Installer), CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        File.Delete(path); // (and it isn't left held)
    }

    [Fact]
    public async Task RefusesAFileOfTheWrongSize()
    {
        using var folder = new TempFolder();
        string path = folder.File("ClipLink-Setup-2.0.2.exe");
        await File.WriteAllBytesAsync(path, Installer[..^1]);

        var ex = await Assert.ThrowsAsync<UpdateException>(() => VerifiedInstaller.OpenAsync(path, AssetOf(Installer), CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        File.Delete(path);
    }

    [Fact]
    public async Task RefusesWhenThereIsNothingToCompareWith()
    {
        using var folder = new TempFolder();
        string path = folder.File("ClipLink-Setup-2.0.2.exe");
        await File.WriteAllBytesAsync(path, Installer);

        var ex = await Assert.ThrowsAsync<UpdateException>(() =>
            VerifiedInstaller.OpenAsync(path, AssetOf(Installer) with { Sha256 = null }, CancellationToken.None));

        Assert.Equal(UpdateFailure.Verification, ex.Kind);
        File.Delete(path);
    }

    [Fact]
    public async Task AMissingFileIsADiskProblem()
    {
        using var folder = new TempFolder();
        var ex = await Assert.ThrowsAsync<UpdateException>(() =>
            VerifiedInstaller.OpenAsync(folder.File("nope.exe"), AssetOf(Installer), CancellationToken.None));
        Assert.Equal(UpdateFailure.Disk, ex.Kind);
    }
}

public class InstallerLauncherTests
{
    [Fact]
    public void RunsSilentlyAndAsksForARelaunch()
    {
        Assert.Equal(new[] { "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/RELAUNCH=1" }, InstallerLauncher.Arguments);
    }

    [Fact]
    public void TheStartInfoHasTheArgumentsAndGoesThroughTheShell()
    {
        string path = @"C:\Users\someone\AppData\Local\Temp\ClipLink-update\ClipLink-Setup-2.0.2.exe";
        var info = InstallerLauncher.CreateStartInfo(path);

        Assert.Equal(path, info.FileName);
        Assert.True(info.UseShellExecute);
        Assert.Equal(InstallerLauncher.Arguments, info.ArgumentList);
        Assert.Equal(@"C:\Users\someone\AppData\Local\Temp\ClipLink-update", info.WorkingDirectory);
    }

    [Fact]
    public void DecliningThePermissionPromptIsDeclinedNotBroken()
    {
        // ERROR_CANCELLED, what ShellExecute reports when the UAC prompt is dismissed.
        var ex = InstallerLauncher.Translate(new Win32Exception(1223));
        Assert.Equal(UpdateFailure.Declined, ex.Kind);
        Assert.Contains("Nothing was changed", ex.Message);
    }

    [Fact]
    public void AnyOtherWindowsErrorIsALaunchProblem()
    {
        var ex = InstallerLauncher.Translate(new Win32Exception(5));
        Assert.Equal(UpdateFailure.Launch, ex.Kind);
    }

    [Fact]
    public void StartingSomethingThatIsNotThereIsALaunchProblem()
    {
        // (Nothing runs: the file doesn't exist.)
        string missing = Path.Combine(Path.GetTempPath(), "ClipLink-tests-nothing-here", "ClipLink-Setup-0.0.0.exe");
        var ex = Assert.Throws<UpdateException>(() => InstallerLauncher.Start(missing));
        Assert.Equal(UpdateFailure.Launch, ex.Kind);
    }
}

public class UpdateFolderTests
{
    [Fact]
    public void ClearOnlyRemovesWhatTheUpdaterMakes()
    {
        using var folder = new TempFolder();
        foreach (string name in new[]
        {
            "ClipLink-Setup-1.0.0.exe", "ClipLink-Setup-2.0.0.exe.part", "ClipLink-Setup-2.0.2.exe",
            "notes.txt", "setup.exe", "ClipLink-Setup-3.0.0.zip", "other.exe.part",
        })
        {
            File.WriteAllText(folder.File(name), "x");
        }

        UpdateFolder.Clear(folder.Path, keep: folder.File("ClipLink-Setup-2.0.2.exe"));

        Assert.Equal(new[] { "ClipLink-Setup-2.0.2.exe", "ClipLink-Setup-3.0.0.zip", "notes.txt", "other.exe.part", "setup.exe" }, folder.Names());
    }

    [Fact]
    public void ClearWithoutKeepRemovesThemAll()
    {
        using var folder = new TempFolder();
        File.WriteAllText(folder.File("ClipLink-Setup-2.0.2.exe"), "x");
        UpdateFolder.Clear(folder.Path);
        Assert.Empty(folder.Names());
    }

    [Fact]
    public void ClearIgnoresAFolderThatIsNotThere()
    {
        UpdateFolder.Clear(Path.Combine(Path.GetTempPath(), "ClipLink-tests-no-such-folder"));
    }

    [Fact]
    public void ClearLeavesAFileThatIsInUse()
    {
        using var folder = new TempFolder();
        string busy = folder.File("ClipLink-Setup-1.0.0.exe");
        File.WriteAllText(busy, "x");
        using (new FileStream(busy, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            UpdateFolder.Clear(folder.Path);
            Assert.True(File.Exists(busy));
        }
        UpdateFolder.Clear(folder.Path);
        Assert.False(File.Exists(busy));
    }

    [Fact]
    public void TheFolderIsUnderTemp()
    {
        Assert.Equal(Path.Combine(Path.GetTempPath(), "ClipLink-update"), UpdateFolder.DefaultPath);
    }

    [Fact]
    public void TheFileNameCannotLeaveTheFolder()
    {
        // Whatever the version text, a name made from it stays in the folder.
        foreach (string text in new[] { "2.0.2", "2.0", "1.2.3.4", "0", "999999999.999999999" })
        {
            Assert.True(ReleaseVersion.TryParse(text, out var version));
            string name = new ReleaseOffer(version, new Uri("https://github.com/x"), new UpdateAsset(null, 0, null)).InstallerFileName;
            string folder = UpdateFolder.DefaultPath;
            Assert.Equal(name, Path.GetFileName(name));
            Assert.Equal(folder, Path.GetDirectoryName(Path.Combine(folder, name)));
            Assert.Matches(@"^ClipLink-Setup-[0-9.]+\.exe$", name);
        }
    }
}
