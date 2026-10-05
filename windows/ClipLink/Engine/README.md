# windows/ClipLink/Engine/ — the ClipLink engine

The whole P2P node, compiled into the ClipLink app (`windows/ClipLink`):
LAN discovery, peer connections, the clipboard watcher, history, trust and
pairing. It's plain C# with no UI in it. The app runs it in-process; the
namespaces keep the `ClipboardDaemon.*` names from when this was a separate
daemon process, so the iOS interop harness and old notes still line up.

- `ClipLinkEngine*.cs` — the node. `Start(label, port)` loads the stores
  from `%APPDATA%\ClipboardDaemon` (files suffixed with the label; the app uses
  `"default"`) and starts everything; `Stop()` ends it. Typed methods for the
  UI (`ClipLinkEngine.Api.cs` — including `ShareFilesAsync`, File Explorer's
  "Share to ClipLink": files sent like copied ones, without the clipboard)
  and events (`HistoryChanged`, `DevicesChanged`, `PairingRequested`,
  `PairingResolved`, `StatusChanged`), raised in order on a background
  thread — a UI marshals them to its own thread.
- `EngineModels.cs` — what the API hands out (`DeviceListing`,
  `HistoryItem`, `PendingPairing`, `PairOutcome`, `EngineStatus`, ...).
- `DeviceLabel.cs` — how to show a device's name safely, and its
  fingerprint (`Device XXXX·XXXX`, the same on every platform).
- `ConsoleLog.cs` — sends the engine's Console logging to a rolling
  log file (`%LOCALAPPDATA%\ClipLink\logs\cliplink.log`).
- `Clipboard/`, `Identity/`, `Networking/`, `Storage/`, `Crypto/` — the pieces
  the engine wires together (see `docs/protocol.md` for the wire format).
  `Storage/LocalFiles.cs` is the per-file check and payload (name, size,
  streamed SHA-256, 1 GB cap) shared by copied files and shared ones, and
  their copy into the FileStore, which refuses a file changed since it was
  hashed.

Build: `dotnet build windows\ClipLink.slnx` — the engine is part of the app
project. The iOS interop tests compile these same sources for macOS
(`mobile/ios/ClipLink/CoreTests/DaemonHarness`), patching a few lines by exact
text — `prepare.py` stops with "shim anchor not found" if one of those lines
changes.
