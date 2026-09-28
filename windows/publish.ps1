# Publishes ClipLink.exe to windows\dist: one self-contained file with the
# .NET runtime and every dependency inside (settings in
# ClipLink\ClipLink.csproj). Needs the .NET 10 SDK; NuGet packages and the
# win-x64 runtime pack are downloaded the first time.
#
#   powershell -ExecutionPolicy Bypass -File windows\publish.ps1
#
# Quit ClipLink first if it's running from windows\dist (the old exe would
# be locked).
param(
    [string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'

$project = Join-Path $PSScriptRoot 'ClipLink\ClipLink.csproj'
$dist = Join-Path $PSScriptRoot 'dist'

# Say so plainly rather than fail half way through: most likely it's your
# own ClipLink, which the sign-in entry starts from here.
$distExe = Join-Path $dist 'ClipLink.exe'
$running = @(Get-Process -Name ClipLink -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $distExe })
if ($running) {
    throw ("ClipLink is running from $distExe (process {0}). Quit it first (Settings > Quit ClipLink), then publish again." -f
        (($running | ForEach-Object Id) -join ', '))
}

if (Test-Path $dist) {
    Remove-Item $dist -Recurse -Force
}

# DebugType=embedded for every project, so the engine's symbols go inside
# the exe too rather than next to it as a loose .pdb.
& dotnet publish $project -c $Configuration -o $dist -p:DebugType=embedded
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed (exit code $LASTEXITCODE)"
}

$exe = Get-Item (Join-Path $dist 'ClipLink.exe')
$others = Get-ChildItem $dist | Where-Object { $_.Name -ne 'ClipLink.exe' }
Write-Host ("Published {0} ({1:N1} MB)" -f $exe.FullName, ($exe.Length / 1MB))
if ($others) {
    Write-Warning ("Also in dist (not needed to run): " + (($others | ForEach-Object Name) -join ', '))
}
