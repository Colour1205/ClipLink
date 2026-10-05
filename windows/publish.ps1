# Builds the release of ClipLink for Windows into windows\dist:
#   dist\ClipLink\                  the app: ClipLink.exe plus the .NET and Windows
#                                   App SDK runtime it needs (self-contained, nothing
#                                   to install first) - runs from anywhere
#   dist\ClipLink-Setup-<ver>.exe   the installer (per-user, no admin needed)
#
#   powershell -ExecutionPolicy Bypass -File windows\publish.ps1
#   powershell -ExecutionPolicy Bypass -File windows\publish.ps1 -SkipInstaller
#
# Needs the .NET 10 SDK; NuGet packages are downloaded the first time. The
# installer is built with Inno Setup's compiler, fetched once from NuGet
# (Tools.InnoSetup) into windows\.tools - nothing is installed on this PC.
# Quit ClipLink first if it's running from windows\dist (its files are locked).
param(
    [string]$Configuration = 'Release',
    [switch]$SkipInstaller
)
$ErrorActionPreference = 'Stop'

$project = Join-Path $PSScriptRoot 'ClipLink\ClipLink.csproj'
$dist = Join-Path $PSScriptRoot 'dist'
$appDir = Join-Path $dist 'ClipLink'
$appExe = Join-Path $appDir 'ClipLink.exe'

# Say so plainly rather than fail half way through: most likely it's your
# own ClipLink, which the sign-in entry starts from here. dist is emptied, so
# any copy running from it counts - an older build's ClipLink.exe included.
$running = @(Get-Process -Name ClipLink -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dist\*" })
if ($running) {
    $where = ($running | ForEach-Object Path | Select-Object -Unique) -join ', '
    throw ("ClipLink is running from $where (process {0}). Quit it first (Settings > Quit in its window, or its tray icon's menu), then publish again." -f
        (($running | ForEach-Object Id) -join ', '))
}

$version = ([xml](Get-Content $project)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { $version = '1.0.0' }

if (Test-Path $dist) {
    Remove-Item $dist -Recurse -Force
}

& dotnet publish $project -c $Configuration -r win-x64 -o $appDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed (exit code $LASTEXITCODE)"
}
$files = Get-ChildItem $appDir -Recurse -File
Write-Host ("Published {0} ({1} files, {2:N0} MB)" -f $appExe, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))

if ($SkipInstaller) { return }

# ---- the installer ------------------------------------------------------

$iscc = Get-ChildItem (Join-Path $PSScriptRoot '.tools\innosetup') -Recurse -Filter ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $iscc) {
    # Inno Setup is also fine if it's installed (winget install JRSoftware.InnoSetup).
    $installed = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($installed) {
        $iscc = Get-Item $installed
    } else {
        Write-Host 'Fetching the Inno Setup compiler from NuGet (once)...'
        $tools = Join-Path $PSScriptRoot '.tools'
        New-Item -ItemType Directory -Force $tools | Out-Null
        $zip = Join-Path $tools 'innosetup.zip'
        Invoke-WebRequest 'https://api.nuget.org/v3-flatcontainer/tools.innosetup/6.7.3/tools.innosetup.6.7.3.nupkg' -OutFile $zip
        Expand-Archive $zip (Join-Path $tools 'innosetup') -Force
        Remove-Item $zip
        $iscc = Get-ChildItem (Join-Path $tools 'innosetup') -Recurse -Filter ISCC.exe | Select-Object -First 1
    }
}
if (-not $iscc) { throw 'Could not find or fetch the Inno Setup compiler (ISCC.exe).' }

& $iscc.FullName "/DAppVersion=$version" "/DSourceDir=$appDir" "/DOutputDir=$dist" (Join-Path $PSScriptRoot 'installer\ClipLink.iss')
if ($LASTEXITCODE -ne 0) {
    throw "The installer build failed (exit code $LASTEXITCODE)"
}
$setup = Get-Item (Join-Path $dist "ClipLink-Setup-$version.exe")
Write-Host ("Built {0} ({1:N0} MB)" -f $setup.FullName, ($setup.Length / 1MB))
