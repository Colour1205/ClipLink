# windows/

Windows implementation: one app, `ClipLink.exe` — a tray icon and a window —
with the always-on P2P node running inside it.

- `daemon/` — the engine library (`ClipLinkEngine`): discovery, peer
  connections, clipboard watcher, history store, trust and pairing. See
  `daemon/README.md`.
- `ClipLink/` — the app (WPF + [WPF-UI](https://github.com/lepoco/wpfui)):
  the tray icon and the Fluent window (synced history, devices and pairing,
  settings), running the engine in-process.
- `ClipLink.slnx` — both projects, for Visual Studio / `dotnet build`.
- `publish.ps1` — builds the release exe into `dist/` (git-ignored).
- `ClipLink.ico` — the app icon, shared by the projects.

Stack: .NET 10 (C#) — Win32 clipboard access through WinForms, plain sockets.

## Build, publish, run

Needs the .NET 10 SDK (NuGet packages download on the first build).

```powershell
dotnet build windows\ClipLink.slnx                                  # development build
powershell -ExecutionPolicy Bypass -File windows\publish.ps1        # -> windows\dist\ClipLink.exe
```

`dist\ClipLink.exe` is the whole app: one self-contained file (~155 MB, the
.NET runtime included, uncompressed on purpose — see `ClipLink.csproj`; zip
it to ship it). Run it from anywhere; nothing is installed.

- Double-click: the window opens. Closing the window keeps ClipLink running
  in the notification area — left-click its icon to bring the window back
  (the icon has no right-click menu). **Settings > Quit ClipLink** is the only
  way to stop it.
- Starting it again while it runs just brings up the running one's window.
- **Synced** shows the history as a list or a grid (the switch next to the
  title; remembered in `settings.json`). Select a card — click it, or Enter —
  to see it in full (all of the text, the whole image); Escape goes back.
  Right-click or Shift+F10 on a card for Copy / Open / Show in folder / Delete.
- First run turns on **Start ClipLink when I sign in** (Settings): an
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value "ClipLink"
  starting it with `--background` (tray icon only).
- Data: `%APPDATA%\ClipboardDaemon` — the same files the old daemon used, so
  an existing identity, trusted devices and history carry over:
  `identitydefault.key`, `truststoredefault.json`, `historydefault.json`,
  `deleteddefault.json` (deleted items), `passphrasekeydefault.key`,
  `devicenamedefault.txt`, `filestoredefault\` (synced files by hash) and
  `ReceivedFiles\` (files and images put on the clipboard). The app's own
  preferences: `%LOCALAPPDATA%\ClipLink\settings.json`. Files opened from
  Synced are copied to `%TEMP%\ClipLink\default` first.
- Log: `%LOCALAPPDATA%\ClipLink\logs\cliplink.log`, rolled over to
  `cliplink.1.log` at 5 MB (Settings > About > Open log folder).
- The first run from a new location may bring up a Windows Firewall prompt
  (ClipLink listens on TCP and UDP port 49000): allow private networks.
- Coming from the old `ClipboardDaemon.exe` + `ClipboardTray.exe`: quit both
  first. While the old daemon holds port 49000 ClipLink shows "Can't listen
  for other devices…" with a **Try again** button, and syncs nothing.

### Command line

| Option | |
|---|---|
| `--background` | Start hidden in the tray (how the sign-in entry starts it). |
| `--share <path>...` | For Explorer's "Share" (next batch) — handed to the running copy, logged and ignored for now. |

For testing, a second, separate ClipLink can run next to the real one —
it touches none of the real one's data, and with `--loopback-only` and
`--no-clipboard` nothing of it reaches the network or the clipboard (so no
firewall prompt):

| Option | |
|---|---|
| `--label <name>` | Its own data files (`...<name>...` instead of `...default...`), log (`cliplink-<name>.log`), settings, sign-in entry and single-instance lock. |
| `--port <n>` / `--discovery-port <n>` | TCP port to listen on / UDP port for LAN discovery (default 49000). |
| `--loopback-only` | Listen on 127.0.0.1 only; no LAN discovery. |
| `--no-clipboard` | Never read or write the system clipboard. |
| `--theme light\|dark` | A fixed theme instead of following Windows. |

For example `ClipLink.exe --label test --port 49321 --loopback-only --no-clipboard`.
A test copy never turns on the sign-in entry by itself. Afterwards, delete
its `%APPDATA%\ClipboardDaemon\*test*` files (and `filestoretest` folder),
`%LOCALAPPDATA%\ClipLink\settings-test.json`,
`%LOCALAPPDATA%\ClipLink\logs\cliplink-test*.log` and (files it opened)
`%TEMP%\ClipLink\test`.
