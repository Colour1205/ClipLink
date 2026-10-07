# ClipLink for Android

Jetpack Compose + Material 3 Expressive. Speaks the same wire protocol as
`windows/ClipLink/Engine` and `mobile/harmonyos` — same UDP beacon, same TCP handshake,
same encrypted envelopes — so all three interoperate directly.

## Build

```bash
./gradlew :app:assembleDebug
```

Requires JDK 21 (Android Studio's bundled JBR works) and `ANDROID_HOME` set.
Because this repo lives in a OneDrive-synced folder, the root build script
redirects build output to `%TEMP%/cliplink-build`; OneDrive was otherwise
opening intermediates mid-build and failing it with `Unable to delete
directory`. Override with `-Pcliplink.buildRoot=<path>`, and note the APK
lands under that root, not `app/build/`.

## Things that will surprise you

**Material 3 Expressive is not in the stable Compose BOM.** `material3 1.4.x`
ships zero expressive APIs. `MaterialExpressiveTheme`, `MotionScheme`,
`expressiveLightColorScheme`, `ShortNavigationBar`, `HorizontalFloatingToolbar`
and `ToggleButton` all require `material3 1.5.0-alpha`, pinned here via
`androidx.compose:compose-bom-alpha`. Dropping to the stable BOM removes every
expressive API this UI is built on.

**compileSdk is 37.1, not 37.0.** The alpha Compose artifacts refuse to be
consumed by anything compiled against an older minor API level. `targetSdk`
stays at 37.

**`ACCESS_LOCAL_NETWORK` is mandatory at targetSdk 37.** Local Network
Protections are enforced for apps targeting Android 17. Without the runtime
grant, UDP `sendto` returns `EPERM` and TCP dials to LAN addresses *hang*
rather than fail — so a denial is indistinguishable from "no peers exist"
unless you go looking. Apps targeting SDK 36 or lower must *not* declare it.

**The clipboard can only be read in the foreground.** Since Android 10 an app
may read the clipboard only while it holds focus or is the default IME, and
`addPrimaryClipChangedListener` does not fire for other apps' copies. There is
no Android equivalent of the Windows daemon's silent background capture. The
app therefore offers three honest paths instead:

- automatic capture when ClipLink comes to the foreground (Me → *Send my
  clipboard when I open ClipLink*),
- the paste button on the Synced screen,
- a share-sheet target ("ClipLink" in any app's Share menu), so anything can
  be pushed from any app without switching to ClipLink first. Text arrives as
  text; files - one or many, photos included - arrive as files, up to 1 GB
  each and 25 per share (the history's size). `ShareReceiverActivity` copies
  them into app storage while it still holds the read grant, toasts the
  result and finishes; ClipLink itself never opens.

The first two take a copied file the same way - another app's `content://`
URI only, streamed into app storage, up to 1 GB. A copied image up to 4096 px
a side goes as an inline PNG, like the other platforms send; a bigger one goes
as the file it is.

Writing to the clipboard is unrestricted, so *receiving* works normally.

**The foreground service is `connectedDevice`, not `dataSync`.** Since Android
15, `dataSync` services share a 6-hour budget per 24 hours and then hard-crash
the app with `RemoteServiceException`. `connectedDevice` is documented for
network connections to external devices and has no time limit — but it
requires the app to hold `CHANGE_WIFI_MULTICAST_STATE` (or one of its
siblings) at runtime, or `startForeground` throws.

## Protocol notes specific to this port

The JCA disagrees with .NET in two places, and both fail *silently* rather
than loudly:

- **Signatures.** `SHA256withECDSA` produces DER; the wire format is raw
  fixed-width `r||s` (IEEE P1363). Without `EcdsaDer`'s conversion, `verify()`
  simply returns false, which reads as "wrong key" rather than "wrong
  encoding".
- **AES-GCM layout.** The JCA appends the tag to the ciphertext; the wire
  format is `nonce(12) || tag(16) || ciphertext`. Getting the order wrong
  throws `AEADBadTagException` on every message, including from a peer
  behaving perfectly.

Both, plus PBKDF2 and the .NET round-trip timestamp format, are covered by
`app/src/test/.../InteropTest.kt`, which runs on the JVM with no device:

```bash
./gradlew :app:testDebugUnitTest
```

## Who dials

When two devices hear each other's beacons, only one of them connects: the one
with the **larger** public key (`peer >= own` means "wait to be dialled" in
`ClipLinkEngine.losesTieBreaker`). The comparison is **ordinal** - Kotlin's
`String.compareTo` is over UTF-16 code units, the same as HarmonyOS's JS `<` and
the Windows engine's `string.CompareOrdinal` (which dials when the other key is
smaller, that is, when its own is larger). The Windows daemon used to use the
culture-sensitive `String.CompareTo`, which ICU orders differently for some key
pairs (`'k'` sorts before `'Q'`), so for roughly one pair in six either both
sides dialled or neither did; that is fixed there, and all three now agree. Do
not "match" it by going culture-sensitive here.

## Staying up when a peer misbehaves

Port 49000 is open to everyone on the network, and the phone has a heap of a
few hundred MB, so what a peer can make the app hold is capped (`net/Limits.kt`):

- **Lines.** No line is read without a cap (`core/LineReader.kt`; `BufferedReader.readLine`
  has none). The handshake - the one thing read before anything is trusted - is
  capped at 8 KB (the real one is under 1.5 KB) and must finish within 10 s in
  total, not per read. A session line is capped at 64 MB; a longer one is read
  and dropped, with a log line, and the link goes on. Anything parsed from a peer
  is parsed with `untrusted { }`, which also catches Errors (a deeply nested JSON
  document overflows org.json's stack, a huge one runs out of memory; neither is
  an `Exception`).
- **Sockets that haven't proved who they are.** At most 8 handshakes run at once
  and a single address gets at most 20 connections per 10 s (`net/ConnectionGate.kt`);
  the rest are closed unread.
- **Coroutines.** Every scope has a `CoroutineExceptionHandler` that logs to the
  Activity log and keeps the process alive; the loops that must keep going
  (reconnecting, accepting connections, housekeeping) catch their own failures
  once per pass. The TCP listener is bound again, with a growing pause, if the
  port is taken or the socket dies, and `ClipLinkEngine.serverFault` says so
  while it is down.
- **Messages.** Each connection hands its messages to one handler through a
  2-slot inbox, and the read loop waits when it is full, so a handler that is slower
  than the network slows the sender through TCP instead of queueing a whole
  file in memory. Any bytes arriving count as the peer being alive (see
  `Liveness`), so a busy handler can't make the heartbeat misfire, and a dead-peer
  watchdog runs apart from the pings, so a blocked write can't hide a dead link.
  The heartbeat intervals and timeouts themselves are unchanged.
- **Inline images and history.** An entry over 36 M characters of content is
  dropped on arrival; one over 12 M characters is not repeated in a history_batch
  (which carries at most 16 M in all, newest first). History is not rebuilt per
  read: see below.
- **Files.** A received file may not pass 1 GB, nor the size its signed entry
  says; at most 8 are received at once (4 per peer); a stream that stops getting
  chunks is dropped after 5 minutes, and stray `.tmp` files are deleted at
  start. Blobs are written to a temporary file and renamed, never in place.

## Where things are stored

- **History** is `files/cliplink_history.jsonl`, one entry per line in the
  wire JSON, parsed once into memory and rewritten atomically (temporary file,
  fsync, rename) on each change. It used to be a single SharedPreferences
  string; that is moved to the file the first time it is read, and only then
  removed from SharedPreferences (the identity key, trust store, passcode key and
  deleted-entries store are never touched). A line that can't be parsed costs
  that entry only. The history keeps 25 items and at most 64 M characters of
  content (oldest evicted first, never the last one).
- **The passcode key** is wrapped with an AES-GCM key in the Android Keystore; a
  plain key from an older build is wrapped when it is first read. If the Keystore
  refuses, the key is stored as before and the log says so.
- **The Tailscale address** must be an IPv4 address: it goes into the
  colon-separated beacon, where a stray `:` would shift every field after it.
  IPv6 would need an encoding the other platforms don't have.
