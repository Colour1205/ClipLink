# windows/

Windows implementation: one app, `ClipLink.exe` — a tray icon and a window —
with the always-on P2P node running inside it.

- `ClipLink/` — the app: WinUI 3 (Windows App SDK) with Mica and the native
  Fluent controls — the tray icon and the window (synced history, devices and
  pairing, settings).
  - `ClipLink/Engine/` — the sync engine (`ClipLinkEngine`): discovery, peer
    connections, clipboard watcher, history store, trust and pairing, running
    in-process. See `ClipLink/Engine/README.md`.
- `installer/ClipLink.iss` — the installer script (Inno Setup).
- `ClipLink.slnx` — the solution, for Visual Studio / `dotnet build`.
- `publish.ps1` — builds the app folder and the installer into `dist/`
  (git-ignored).
- `ClipLink.ico` — the app icon.

Stack: .NET 10 (C#) — WinUI 3, Win32 clipboard access through WinForms, plain
sockets.

## Build, publish, run

Needs the .NET 10 SDK (NuGet packages download on the first build). No Visual
Studio needed.

```powershell
dotnet build windows\ClipLink.slnx                                  # development build
dotnet run --project windows\ClipLink\ClipLink.csproj               # build and run it
powershell -ExecutionPolicy Bypass -File windows\publish.ps1        # -> windows\dist\
```

`publish.ps1` makes two things in `windows\dist\`:

- `ClipLink\` — the app: `ClipLink.exe` plus the .NET and Windows App SDK
  runtime it needs (self-contained: nothing to install first). It runs from
  anywhere, so it can be copied to another PC as it is.
- `ClipLink-Setup-<version>.exe` — the installer. It installs for the current
  user only (`%LOCALAPPDATA%\Programs\ClipLink`, no administrator prompt; the
  setup offers "all users" too), adds a Start menu entry (and, if ticked, a
  desktop shortcut) and an uninstall entry, and asks a running ClipLink to
  quit before replacing or removing its files, so installing over an older
  version just updates it. Your settings, pairings and history are kept when
  updating and uninstalling. Uninstalling also removes "Share to ClipLink"
  from File Explorer (and turns that setting off, so it's on again only once
  you switch it back on in Settings), and the "start when I sign in" entry —
  but only if that entry starts the installed copy.

`publish.ps1 -SkipInstaller` only does the app folder. The installer is built
with Inno Setup's compiler, fetched once from NuGet into `windows\.tools`
(or the installed Inno Setup is used); nothing is installed on the build PC.
Quit ClipLink first if it's running from `windows\dist`: its files are locked.

- Double-click: the window opens. Closing the window keeps ClipLink running
  in the notification area — left-click its icon to bring the window back;
  right-click it for **Open** and **Quit**. **Settings > Quit** also stops it.
- Starting it again while it runs just brings up the running one's window.
- The sidebar can be collapsed to icons only (the button at its top); it's
  remembered.
- **Synced** shows the history as a list or a grid (the switch next to the
  title; remembered in `settings.json`). Select a card — click it, or Enter —
  to see it in full (all of the text, the whole image); Escape goes back.
  Right-click or Shift+F10 on a card for Copy / Open / Show in folder / Delete.
- Scrolling: a touchpad scrolls by exactly the distance you move your fingers
  (WinUI's own touchpad handling); a mouse wheel scrolls Windows' "lines per
  notch" with a short, quick animation.
- First run turns on **Start ClipLink when I sign in** (Settings): an
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value "ClipLink"
  starting it with `--background` (tray icon only). If the value points at
  another `ClipLink.exe` (moved, or another build), each start points it at
  the running one, keeping its arguments.
- **Share to ClipLink** from File Explorer: right-click one or more files and
  choose **Share to ClipLink**, or **Send to > ClipLink**. **On Windows 11
  both are under "Show more options"** (or Shift+right-click / Shift+F10) —
  the new top-level menu only takes packaged apps. Each file goes to your
  devices exactly like a copied file (a file entry in Synced, streamed to
  them; images stay files), without touching this PC's clipboard; folders
  and files over 1 GB are skipped. A file another app has open (a Word
  document you're editing) shares as it was last saved; one that changes
  while it's being shared (still downloading, say) is skipped — share it
  again once it's done. ClipLink says what it shared in its
  window, or as a notification from the tray icon. If ClipLink isn't
  running, sharing starts it (in the tray). As with copies, Synced keeps
  the latest 25 items on every device, so a device that connects after a
  bigger share only gets the latest 25 of it.
  - How: a per-user verb `HKCU\Software\Classes\*\shell\ClipLink.Share`
    (`MultiSelectModel=Player`: shown for up to 100 selected files; Explorer
    starts one `ClipLink.exe --share "<file>"` per file, which hand their
    file to the running copy — files arriving within ~400 ms are shared as
    one batch) and a shortcut `%APPDATA%\Microsoft\Windows\SendTo\ClipLink.lnk`
    (`ClipLink.exe --share` with every selected file, up to Windows'
    ~32,000-character command line — about 280 files). No admin rights.
  - Settings > **Show 'Share to ClipLink' in File Explorer** (on by default)
    turns both on or off. While it's on, every start re-creates them if
    they're missing or point at another `ClipLink.exe`, so moving the app
    fixes itself — but **before deleting a copy that wasn't installed, run
    `ClipLink.exe --unregister`** (or turn the setting off), or the menu
    entries stay behind pointing at nothing. (The uninstaller does this.)
- Data: `%APPDATA%\ClipboardDaemon` — the same files the older Windows builds
  used, so an existing identity, trusted devices and history carry over:
  `identitydefault.key`, `truststoredefault.json`, `historydefault.json`,
  `deleteddefault.json` (deleted items), `passphrasekeydefault.key`,
  `devicenamedefault.txt`, `filestoredefault\` (synced files by hash) and
  `ReceivedFiles\` (files and images put on the clipboard; received images
  are named by their content, `ClipLink image <hash>.png`, only the newest 50
  are kept, and **Clear synced history** deletes them — all but the one on
  the clipboard right then, so it still pastes into a folder; a copy started with
  another `--label` keeps its received images in `receivedimages<label>\`
  instead, so it never touches these). The app's own
  preferences: `%LOCALAPPDATA%\ClipLink\settings.json`. Files opened from
  Synced are copied to `%TEMP%\ClipLink\default` first, one folder per item.
  A copy you've edited is never overwritten (opening the item again makes a
  fresh copy next to it) and never deleted. The other copies are deleted with
  their item, on **Clear synced history** and whenever ClipLink starts.
- Log: `%LOCALAPPDATA%\ClipLink\logs\cliplink.log`, rolled over to
  `cliplink.1.log` at 5 MB (Settings > About > Open log folder).
- The first run from a new location may bring up a Windows Firewall prompt
  (ClipLink listens on TCP and UDP port 49000): allow private networks.
- Coming from an older ClipLink (the WPF build, or the separate
  `ClipboardDaemon.exe` + `ClipboardTray.exe`): quit it first. While it holds
  port 49000 the new one shows "Can't listen for other devices…" with a
  **Try again** button, and syncs nothing.

### Command line

| Option | |
|---|---|
| `--background` | Start hidden in the tray (how the sign-in entry starts it). |
| `--share <path>...` | Share these files (what File Explorer's "Share to ClipLink" and Send To run; everything after it is a path). Handed to the running copy, or — if none is running — this one starts in the tray and shares them. |
| `--unregister` | Remove "Share to ClipLink" and Send To > ClipLink from File Explorer, turn that setting off (a running copy is told), and exit. No window. |
| `--quit` | Ask the running copy to quit (what the installer does before replacing files), and exit. |

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
A test copy never turns on the sign-in entry or "Share to ClipLink" by
itself; turned on in its Settings, it gets its own ("Share to ClipLink
(test)", `SendTo\ClipLink (test).lnk`, starting it with the same options), never
the real ones — remove them with `ClipLink.exe --label test --unregister`. Afterwards, delete
its `%APPDATA%\ClipboardDaemon\*test*` files (and `filestoretest` folder),
`%LOCALAPPDATA%\ClipLink\settings-test.json`,
`%LOCALAPPDATA%\ClipLink\logs\cliplink-test*.log` and (files it opened)
`%TEMP%\ClipLink\test`.
