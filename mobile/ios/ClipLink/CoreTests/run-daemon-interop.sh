#!/bin/sh
# Runs the iOS sync engine against the REAL Windows daemon code on macOS.
#   DOTNET=/path/to/dotnet ./run-daemon-interop.sh        (needs .NET 8+ SDK)
# Also set DEVELOPER_DIR if Xcode isn't the selected toolchain.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
DOTNET=${DOTNET:-dotnet}
build=$(mktemp -d)/daemon-harness
python3 "$here/DaemonHarness/prepare.py" "$repo" "$build"
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build "$build/ClipboardDaemonHarness.csproj" -c Release -o "$build/out" >/dev/null
cd "$here"
CLIPLINK_DOTNET=$(command -v "$DOTNET" || echo "$DOTNET") CLIPLINK_DAEMON_DLL="$build/out/ClipboardDaemonHarness.dll" \
  swift test --filter WindowsDaemonInteropTests
