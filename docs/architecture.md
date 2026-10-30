# Architecture

How ClipLink is put together, in plain words. This page is about version 2.0.

**Contents**

- [The idea](#the-idea)
- [The parts inside each app](#the-parts-inside-each-app)
- [Each platform](#each-platform)
- [The Windows app](#the-windows-app)
- [Where the code is](#where-the-code-is)

Other pages: [protocol](protocol.md) (how devices talk) and [security](security.md) (who is trusted and why).

## The idea

There is no ClipLink server. Every device runs the same program, and every device is equal. Each one does three things:

1. **Find** other devices on the local network.
2. **Connect** to the ones it has been paired with.
3. **Share** what you copy, and catch up on recent history.

Each device keeps its own short history. When two devices connect, each tells the other which items it has, and only the missing ones are sent, so a device that was switched off catches up from whichever device it meets next. No single device has to be on all the time. Deleting an item on one device deletes it on every paired device that has the new version.

## The parts inside each app

Every app has the same parts:

| Part | What it does |
| --- | --- |
| Discovery | Announces this device on the local network and listens for others. It also reconnects to saved addresses, such as a Tailscale address |
| Connection | Talks to one other device over a link that is signed and encrypted |
| Clipboard watcher | Notices when you copy something on this device, and puts items received from other devices on the clipboard |
| History | The last 25 items, and the files they point to, kept on the device |
| Sharing | Decides what to send: a new copy goes out straight away, and the history goes out when a device connects |
| Identity and trust | The device's key, the list of devices it trusts, the devices it has blocked, and the optional passcode |

## Each platform

| Platform | How it runs | When it syncs |
| --- | --- | --- |
| Windows | One app, `ClipLink.exe`, with a tray icon and a window. Syncing runs inside the app | All the time, as long as the app is running. It watches the clipboard and listens for other devices |
| Android | An app. If you turn on "Keep syncing in the background", a notification keeps it running | While the app is open, or all the time with that setting on. Android only lets an app read the clipboard while it is open, so there is a setting to send your clipboard when you open ClipLink |
| iOS | An app, with background refresh and a Share extension | When the app is open. iOS closes connections when the app is not in front. On opening, the app announces itself, asks the devices it can reach for their history, and sends the current clipboard. "Share to ClipLink" sends from any app. iOS also runs short background catch-ups when it chooses to |
| HarmonyOS | An app | While the app is open. HarmonyOS pauses the app soon after you leave it, so a new item that arrives in that short time shows a notification |

A phone cannot stay connected for ever. So phones are built to catch up when they are opened, and catching up from the other devices is what makes that safe: a phone that was closed for two days is fully up to date the next time it opens near any of your devices.

## The Windows app

One program, `ClipLink.exe`. Inside it:

- **The sync engine** (`windows/ClipLink/Engine`) does the whole job: discovery, connections, the clipboard watcher, history, trust and pairing. The window and the tray icon only ask it for things and listen for what changes.
- **The window** has three pages: *Synced* (the history, as a list or a grid, with Copy, Open and Delete), *Devices* (paired and nearby devices, and pairing with this PC's QR code or an address) and *Settings* (device name, passcode, start when you sign in, the File Explorer share menu, clear history and Quit).
- **The tray icon** opens the window on a left click, and has Open and Quit on a right click. Closing the window hides it. Quit (from the tray or Settings) is what closes the app.
- **One copy at a time.** If you start ClipLink a second time, the new copy hands its job to the one already running (open the window, share a file, quit) and exits.
- **If the port is taken**, the engine says so in the window, with a Try again button, instead of closing.
- **Data.** History, the trust list and similar files are in `%APPDATA%\ClipboardDaemon`. Settings and the log are in `%LOCALAPPDATA%\ClipLink`.

How to build and run it is in [`windows/README.md`](../windows/README.md).

## Where the code is

| Folder | What is in it |
| --- | --- |
| [`windows/`](../windows/) | The Windows app and its installer |
| [`mobile/android/`](../mobile/android/) | The Android app |
| [`mobile/harmonyos/`](../mobile/harmonyos/) | The HarmonyOS app |
| [`mobile/ios/`](../mobile/ios/) | The iOS app |
| [`docs/`](../docs/) | This page, the protocol and the security page |
| [`site/`](../site/) | The website, [cliplink.uaena.io](https://cliplink.uaena.io) |
| [`images/`](../images/) | Screenshots and store pictures, one folder per platform |

The four apps are written separately, in each platform's own language, and follow the [protocol](protocol.md) so that they work together. Each app's folder has its own README with build steps.
