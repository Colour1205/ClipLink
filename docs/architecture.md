# Architecture

## Model

Pure P2P, no central server. Every device is a **node**. Nodes:

1. **Discover** each other on the local network (UDP broadcast / mDNS).
2. **Gossip** clipboard entries to every peer they can reach directly.
3. **Reconcile history** with each peer on connect, so a device that was offline catches up from whichever peer it talks to next (epidemic/gossip propagation — no single node needs to have been online the whole time).

There is no "server" role. An always-running tray app (Windows) and a foreground app (iOS/Android/HarmonyOS) are both just nodes with different lifecycle constraints — see below.

## Node lifecycle by platform

| Platform | Runs as | Sync trigger |
|---|---|---|
| Windows | One app, `ClipLink.exe`: the engine (`windows/daemon`, a library) in-process, a tray icon and a window | Continuous — watches clipboard, listens for peers at all times |
| iOS | Foreground app + Background App Refresh + Share extension | On launch / foreground: announce presence (unicast beacons + /24 sweep when iOS blocks broadcast), pull history from any reachable peer, push local clipboard once; iOS-scheduled background rounds catch up history; "Share → ClipLink" sends from any app |
| Android | Foreground app (+ optional short-lived background window if OS allows) | Same as iOS |
| HarmonyOS | Foreground app | Same as iOS |

Mobile platforms cannot keep a socket open indefinitely, so they are **eventually-consistent by design**: they catch up when opened rather than staying live. The gossip/history-reconciliation protocol is what makes this safe — a phone that was closed for two days still gets fully caught up the next time it opens near any peer (or via relay, see `docs/protocol.md`).

## The Windows app

One process, `ClipLink.exe` (a self-contained single file made by `windows/publish.ps1`; build and run details in `windows/README.md`):

- **Engine** — `windows/daemon`, a class library: `ClipLinkEngine` is the whole node (discovery, peer connections, clipboard watcher, history, trust, pairing). The app calls typed methods on it and subscribes to its events (`HistoryChanged`, `DevicesChanged`, `PairingRequested`/`PairingResolved`, `StatusChanged`). Events are raised in order on one background thread; the app marshals them to the UI thread with `Dispatcher.BeginInvoke`. If the TCP port is taken the engine reports `Faulted` (shown in the window, with Try again) instead of exiting.
- **Threads** — the WPF UI thread; the clipboard watcher on its own STA thread with its own WinForms message loop (while it runs, every clipboard write, the UI's Copy included, goes through its queue, so ClipLink's own writes aren't echoed to peers as new copies); networking on the thread pool.
- **UI** — WPF with WPF-UI (Fluent: Mica, NavigationView): Synced (history as a list or grid, Copy/Open/Delete, full view), Devices (paired and nearby devices; the pairing view with this PC's QR code and pair by address — pairing mode is on only while that view is on screen), Settings (device name and ID, passcode, start at sign-in, clear history, Quit).
- **Tray** — a WinForms `NotifyIcon` with the ClipLink icon: left click shows the window; there is no right-click menu. Closing the window hides it; only Settings > Quit exits.
- **Single instance** — a mutex `Local\ClipLink_<label>`; a second launch sends `activate` (or `share`, for Explorer's Share, not implemented yet) over a `CurrentUserOnly` named pipe to the running copy and exits. There is no other pipe: the engine has no external control channel.
- **Storage** — the engine's data stays in `%APPDATA%\ClipboardDaemon` (the old daemon's files, suffixed with the label, `default` normally); the app's settings and log live in `%LOCALAPPDATA%\ClipLink`. Starting at sign-in is an `HKCU\...\Run` value with `--background`.

## Core components (per node)

- **Discovery** — finds peers (LAN broadcast now; NAT traversal / relay fallback later for peers off-LAN).
- **Peer link** — authenticated, encrypted transport between two discovered nodes.
- **Clipboard watcher** — OS-specific hook that detects local clipboard changes.
- **History store** — local append-only log of clipboard entries (content, source device, timestamp, content hash) used both to answer "what did I miss" queries and to keep a scrollable history UI.
- **Sync/gossip engine** — decides what to send a newly connected peer (diff since last known state) and what to broadcast when the local clipboard changes.
- **Identity/pairing** — each device has a keypair; devices must be paired once (e.g. QR code / pairing code) before they trust each other's broadcasts.

See `docs/protocol.md` for the wire format and `docs/security.md` for the trust model.
