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
  `Storage/HistoryBatch.cs` is a peer's `history_batch` as one unit: all its
  new entries go into history in one step (one write, one `HistoryChanged`),
  and a batch that adds two or more gives them a shared `HistoryItem.BatchId`
  (in memory only), which the app shows as one stack on the Synced page.
  `Storage/HistoryHead.cs` and `Storage/BatchGroups.cs` are the `history_head`
  that goes first when a batch has two or more entries: the newest entry and
  the keys of the whole batch in one small message, so the receiver adds that
  entry and shows the stack (with its real size) while the big batch is still
  arriving; the batch then joins the same group.
  That is protocol 1. Protocol 2 (`Protocol: 2` in the handshake, both sides)
  sends no history on connect: each side sends a `history_head` of the keys and
  times of its history and its latest 500 deleted keys (`HistoryHead.SyncHead`),
  deletes what the other deleted, and asks (`history_request`, kept in
  `Storage/SyncRequests.cs`) for the entries it lacks - the newest alone first,
  the only one that goes on the clipboard (the "convenience item"), then the
  rest - each answered with one `history_batch`, in order. A delete on one device
  is sent to the others as a `delete` message (`ClipLinkEngine.BroadcastDelete`).
  An older peer keeps getting the head and the whole batch, and never a request
  or a delete. What just arrived is listed on top, whatever its time, with the
  convenience item first and kept by the trim (`BatchGroups.Order`).
  `Storage/LocalFiles.cs` is the per-file check and payload (name, size,
  streamed SHA-256, 1 GB cap) shared by copied files and shared ones, and
  their copy into the FileStore, which refuses a file changed since it was
  hashed.

Build: `dotnet build windows\ClipLink.slnx` — the engine is part of the app
project. Tests: `ClipLink.Tests` (the plain parts, linked in) and
`ClipLink.EngineTests` (the real engine on loopback, against a scripted peer and
against another engine; its files are named `zz-e2e-...` and deleted afterwards).
The iOS interop tests compile these same sources for macOS
(`mobile/ios/ClipLink/CoreTests/DaemonHarness`), patching a few lines by exact
text — `prepare.py` stops with "shim anchor not found" if one of those lines
changes.
