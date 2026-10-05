# ClipLink for iOS

SwiftUI app, **iOS 15+**, built with Xcode 26. Speaks exactly the same wire
protocol as `windows/daemon`, `mobile/android` and `mobile/harmonyos` - same UDP
beacon, same TCP handshake, same encrypted envelopes - so all four
interoperate directly. No servers, no daemon: iOS is a foreground node that
also catches up in the background when iOS lets it.

## Layout

```
mobile/ios/ClipLink/
  ClipLink.xcodeproj
  ClipLink/            app target (SwiftUI UI, AppModel, settings, clipboard, background tasks)
  ClipLinkShare/       Share extension target ("Share → ClipLink" from any app)
  Shared/              compiled into BOTH targets
    Core/              wire protocol, crypto, networking, stores, SyncEngine (no UIKit)
    Platform/          Keychain identity & secrets, App Group storage, item loading
  CoreTests/           `swift test` harness for Shared/Core on macOS (not part of the app)
    DaemonHarness/     builds the REAL Windows engine for macOS for interop tests
  ClipLink-Info.plist, ClipLinkShare-Info.plist, *.entitlements
```

## Build & run

Open `ClipLink.xcodeproj`, pick your team under *Signing & Capabilities* for
**both** targets (`ClipLink` and `ClipLinkShare`) - a free Apple ID works - and
run the `ClipLink` scheme. Both targets use the App Group
`group.io.uaena.ClipLink`; Xcode registers it on first signing.

Command line (simulator, no signing team needed):

```bash
xcodebuild -project ClipLink.xcodeproj -scheme ClipLink -destination 'generic/platform=iOS Simulator' build
```

## Tests

```bash
cd CoreTests && swift test
```

Runs on the Mac, no simulator: protocol/crypto interop vectors produced by an
independent implementation (OpenSSL), JSON/timestamp edge cases, and two full
sync engines talking over real sockets (passcode pairing, QR-style pairing,
text/image/file sync, history catch-up, background refresh rounds).

Against the **actual Windows engine code** (needs the .NET 10 SDK):

```bash
cd CoreTests && DOTNET=/path/to/dotnet ./run-daemon-interop.sh
```

This compiles `windows/daemon` (the engine library the Windows app runs
in-process) for macOS with only platform shims (DPAPI, WinForms clipboard,
ports) and runs the iOS engine against it: passcode pairing in both
tie-breaker directions with and without broadcast, QR-style pairing with
Accept on both sides through the engine's pairing methods (the harness host
still takes the old tray pipe commands), text/image/file both ways, echo
suppression, untrust.

## Things that will surprise you

**UDP broadcast needs an Apple entitlement.** iOS blocks sending *and*
receiving broadcast without `com.apple.developer.networking.multicast`, which
needs a paid team and Apple's approval (enforcement "came unstuck" on iOS 15,
so an iOS 15 phone may broadcast anyway). The engine detects this at runtime
and falls back to what every peer already accepts:

- it unicasts its beacon to known addresses and, paced, to every host on the
  Wi-Fi /24 - peers treat a unicast beacon exactly like a broadcast, so the
  ones that should dial us (larger id) do;
- for peers *we* should dial whose address we don't know, it runs a TCP
  identity sweep of port 49000: every acceptor writes its handshake line
  first, so reading it reveals the peer's key (and passcode proof) before we
  write anything - peers we don't want never see us and never register a link.

If you do get the entitlement, add it to `ClipLink.entitlements`; nothing else
changes.

**Outbound dials read before they write.** Every acceptor on every platform
writes its handshake immediately, so an iOS dialer reads the peer's line
first, decides, then answers. On the wire this is indistinguishable from the
usual order, but it means a peer iOS would refuse never gets far enough to
register a one-sided link.

**Windows trims timestamps.** `System.Text.Json` drops trailing fractional
zeros (`.1234500Z` → `.12345Z`) while the signature covers the 7-digit
`ToString("o")` text. iOS verifies the received text first, then the padded
canonical form, and stores whichever verified - so it accepts every Windows
entry and re-relays them in a form Android and HarmonyOS can verify. iOS's own
timestamps force the 7th digit non-zero so Windows can't trim them.

**Clipboard reads.** iOS 15 reads freely (with a "pasted from" banner); iOS
16+ asks "Allow Paste?" per read unless you set *Settings › ClipLink › Paste
from Other Apps › Allow*. The Paste button on the Synced tab is the system
`UIPasteControl` on iOS 16+, which never asks. "Send clipboard when ClipLink
opens" only reads when `changeCount` changed, and never re-sends what ClipLink
itself wrote.

**Background.** No socket survives suspension (TN2277). ClipLink closes
everything cleanly when backgrounded (after finishing in-flight transfers) and
reconnects on open. On top of that - something Android and HarmonyOS can't
do - **Background App Refresh** wakes it a few times a day (iOS decides when)
for a bounded catch-up round, plus a processing task to finish downloads.
Items that arrive in the background land on the clipboard when you next open
the app, unless you copied something else meanwhile.

**Share extension.** Runs the same engine over the same App Group storage and
Keychain identity, so it *is* this iPhone on the network. It sends
immediately; devices it can't reach get the items from history on the next
connection. It takes text, a link, or files of any kind, several at once (it is
offered for up to 50 and sends the first 25 - all the history holds - saying
how many it left out). As on the other platforms, whatever the system hands
over as a file - from Files, Photos, Mail - is synced as that file, with its
own bytes and name (a photo arrives as `IMG_0001.HEIC`, say); only an image
with no file behind it (a screenshot being marked up) goes inline as a
picture (past 16 MB of those in one share, the rest go as `Image.png` files),
and text or a link only when nothing else came with it - all of it as one
text, so a caption and the link an app passes beside it both arrive. Files over
1 GB and folders are left out, and nothing goes on this device's clipboard.
"Open in ClipLink" from Files sends the file as a file too. The extension's
node is a sender only: it never takes, or asks for, file bytes.

**Deleting.** Delete (a card's menu or the item screen; both ask first)
and *Me › Clear Synced History* are local: nothing goes on the wire, the clipboard is left
alone, and peers keep their copies. Each removed item is remembered by its
signature (the latest 2000, in the App Group, so the Share extension's node
honours them too), and incoming entries and history batches skip those - so
nothing deleted comes back when a peer reconnects and resends its history.

**Device names.** Without Apple's user-assigned-device-name entitlement, iOS
16+ reports every device as plain "iPhone" or "iPad", so that is what peers
see until you set *Me › Device Name*. The app reads the OS name on the main
actor and stores it, with that setting, in the App Group - the Share extension
and background rounds send the same name without touching UIKit.
Beacons are unauthenticated, so a name heard in one is only kept in memory and
shown for nearby devices (and for a paired one with no stored name yet). The
handshake's signature doesn't cover its name either, so a name from a handshake
is stored - for a paired, passcode-paired or just-accepted device alike - only
once that connection decrypts its first line (normally the peer's history
batch, a round trip later), which a replayed handshake never can: one key
covers both directions, so one of our own lines sent back ends the connection
instead of counting. A paired
device's rename shows once it reconnects. Every name a peer sends loses control,
bidi and zero-width characters (`DeviceName.sanitize`). Every id starts with
the same key header, so devices are told apart by a fingerprint, the first 4
bytes of the SHA-256 of the id ("Device AB12·CD34", the same on every
platform): a pairing request shows it beside the requester's name, to compare
with *Me › Fingerprint* on that device.

**Files.** Hashes go out UPPERCASE: Windows' echo suppression compares
uppercase hex, and a lowercase hash makes it re-broadcast your file. Blobs are
stored lowercase-keyed; peers' own spellings are always echoed back
byte-for-byte. Incoming streams are locked to one sender and checked for chunk
order (the other ports interleave two senders into a corrupt file), and
missing blobs are re-requested on every connect. At most 8 streams come in at
once: a file whose stream went by for want of a slot (a share of many files)
is asked for again once that stream ends, and an unanswered request up to 3
more times, 15 s apart. Files go out to each peer 3 at a time, the rest in
turn. A file's name - a peer's, or one shared in - follows Windows'
`FileNames.Safe`, as on Android and HarmonyOS, so it reads the same on every
device (`FileStore.sanitize`): only its last path segment, without control,
bidi or zero-width characters, `\/:*?"<>|` as `_`, no trailing dots or
spaces (leading ones stay), and at most 120 UTF-16 units and 240 UTF-8 bytes,
cut by code point with its extension kept.

## Fixed here that other ports still have (reported separately)

- Android/HarmonyOS reject ~10% of Windows entries (timestamp trimming, above).
- Android reads Windows' `"Address":null` pairing payload as the string `"null"`.
- Every port applies *every* new entry of a history batch to the clipboard, so
  it ends on whichever came last; iOS applies only the newest.
- Untrust doesn't close the live link on Android/HarmonyOS (it does here, like Windows).
