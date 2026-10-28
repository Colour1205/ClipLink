# windows/

Windows implementation: one app, `ClipLink.exe` — a tray icon and a window —
with the always-on P2P node running inside it.

- `ClipLink/` — the app: WinUI 3 (Windows App SDK) with Mica and the native
  Fluent controls — the tray icon and the window (synced history, devices and
  pairing, settings).
  - `ClipLink/Engine/` — the sync engine (`ClipLinkEngine`): discovery, peer
    connections, clipboard watcher, history store, trust and pairing, running
    in-process. See `ClipLink/Engine/README.md`.
  - `ClipLink/Updates/` — the updater's logic, plain C# with no WinUI in it:
    which release to offer, the download, the size and SHA-256 check. The
    app's side of it is `UpdateService.cs` and the Updates card in Settings
    (see [Updates](#updates)).
- `ClipLink.Tests/` — xUnit tests for the parts that need no UI: the updater
  (`ClipLink/Updates/`) and the engine's beacon codec and who-dials-whom rule.
  The source files are linked in (`ClipLink.csproj` is a WinUI exe), so
  running them builds no app: `dotnet test windows\ClipLink.Tests`.
- `installer/ClipLink.iss` — the installer script (Inno Setup).
- `ClipLink.slnx` — the solution, for Visual Studio / `dotnet build`; it
  includes the tests.
- `publish.ps1` — builds the app folder and the installer into `dist/`
  (git-ignored).
- `ClipLink.ico` — the app icon.

Stack: .NET 10 (C#) — WinUI 3, Win32 clipboard access through WinForms, plain
sockets.

The pairing QR code is a link to the website, `https://cliplink.uaena.io/pair/#<pairing info>`
(`ClipLink/Engine/PairingLink.cs`; the format is in `docs/protocol.md`), so a phone's own
scanner opens ClipLink there if it is installed and the website, with the
downloads, if not. "Copy pairing info" still copies the bare JSON, and the
pair-by-address box takes either. The Devices page and the pairing view also
carry the website's address, for the other devices' downloads.

## Build, publish, run

Needs the .NET 10 SDK (NuGet packages download on the first build). No Visual
Studio needed.

```powershell
dotnet build windows\ClipLink.slnx                                  # development build
dotnet run --project windows\ClipLink\ClipLink.csproj               # build and run it
dotnet test windows\ClipLink.Tests                                  # the unit tests
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
- **Notifications** (Windows toasts, `PairingNotifications.cs`), only while the
  window isn't in front: a pairing request, with **Trust** and **Ignore**
  buttons; and, if Settings > General > **Notify me about new items** is on
  (off by default), items that arrive from another device — "New from <device>"
  for the first, "3 new items synced" after, one toast replaced as more arrive,
  gone as soon as the window is in front. A toast shows a short preview and never
  a key or token, a link's host only, a text's first 60 characters.
  - **Windows 11 shows no toast of an app that has no Start menu shortcut
    carrying its notification identity** (AppUserModelID + ToastActivatorCLSID):
    the toast is "delivered" to the shell and then dropped with no banner, and the
    app doesn't appear in Settings > Notifications. The identity the toast library
    registers on its own (under `HKCU\Software\Classes\AppUserModelId`) isn't
    enough — a plain toast sent under ClipLink's own id was dropped until the
    shortcut existed. So every start `ToastShortcut` makes sure one exists
    (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClipLink.lnk`, same
    target, so the setup program's own entry just gains the identity). A copy
    that isn't the installed one (a build folder, a test copy) doesn't take that
    entry over: it gets `ClipLink <6 hex digits of its path's hash>.lnk` instead,
    and `ClipLink.exe --label <name> --unregister` removes a test copy's.
- Data: `%APPDATA%\ClipboardDaemon` — the same files the older Windows builds
  used, so an existing identity, trusted devices and history carry over:
  `identitydefault.key`, `truststoredefault.json`, `blockeddefault.json` (devices
  blocked from the Devices page: their keys, which are refused before anything
  else is decided), `historydefault.json`,
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

### Updates

**Settings > About > Updates** looks on GitHub for a newer ClipLink and, when
you click **Download and install**, downloads the installer, checks it and
runs it. While an update is waiting, the Settings item in the sidebar has a
dot. Nothing is downloaded or installed without that click.

- **What it contacts:** `https://api.github.com/repos/Colour1205/ClipLink/releases?per_page=15`,
  a plain HTTPS request with the header `User-Agent: ClipLink/<version>`.
  Nothing else is sent: nothing about this PC, your devices or your
  clipboard. The installer comes from the release's download address on
  `github.com`, which redirects to GitHub's file servers
  (`*.githubusercontent.com`). Every address, each redirect included, has to be
  `https` on one of GitHub's hosts, or the update is stopped.
- **When:** about 10 seconds after ClipLink starts, then at most once every
  24 hours while it runs; a restart within 24 hours of the last answer doesn't
  ask again (`LastUpdateCheckUtc` in `settings.json`; a look that couldn't
  reach GitHub at all doesn't count and is repeated after an hour). The
  **Check for updates** button asks at once. **Check for updates
  automatically** (Settings > About, on by default) switches the automatic
  looks off; the button still works. A test copy started with
  `--loopback-only` never looks by itself, as it promises to touch no network.
- **What counts as an update, and so how to publish a release for it:** the
  release with the highest version that is published (not a draft), not
  marked as a pre-release, tagged `vX.Y.Z`, with an asset named exactly
  `ClipLink-Setup-X.Y.Z.exe`, and higher than the running version. That is
  what `publish.ps1` builds (`windows\dist\ClipLink-Setup-X.Y.Z.exe`), so
  `gh release create vX.Y.Z windows\dist\ClipLink-Setup-X.Y.Z.exe --repo Colour1205/ClipLink ...`
  is enough. A release without that file (the Android one, say) is skipped,
  and the look goes on to the older releases.
- **The check:** the download must have exactly the size and SHA-256 that
  GitHub lists for the asset (its `digest` field, which GitHub adds to every
  uploaded file); without one ClipLink doesn't install and only offers **Open
  download page**. It is saved as
  `%TEMP%\ClipLink-update\ClipLink-Setup-X.Y.Z.exe.part` (a name made from the
  version, never from the release's text), renamed once it matches, checked
  again and started from that same file, which stays held open so it can't be
  swapped on the way. The installer isn't code-signed, so this shows the file
  is what GitHub publishes for that release, not who published it.
- **Installing:** `ClipLink-Setup-X.Y.Z.exe /SILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1`.
  Setup asks the running ClipLink to quit, as always, replaces the files and,
  because of `/RELAUNCH=1`, starts ClipLink again; settings, pairings and
  history are kept. Meanwhile Settings says "Installing - ClipLink will
  restart". If Windows asks for permission and it's declined, ClipLink stays
  as it is.
- **For testing** (Debug builds only; compiled out of Release, there is no
  way to switch them on there): `CLIPLINK_UPDATE_API_URL=http://127.0.0.1:<port>/<path>`
  asks that address for the releases instead, and lets the updater use
  `http://127.0.0.1:<port>` addresses for them and for the installers they
  list; `CLIPLINK_UPDATE_CHECK_DELAY_SECONDS=<n>` shortens the 10-second wait
  before the first look.

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
