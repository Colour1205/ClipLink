# ClipLink for Android

Jetpack Compose + Material 3 Expressive. Speaks the same wire protocol as
`windows/daemon` and `mobile/harmonyos` — same UDP beacon, same TCP handshake,
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

## Known cross-implementation bug (not fixed here)

The connect tie-breaker — only the smaller-public-key side dials — is
implemented with **ordinal** string comparison here and on HarmonyOS
(Kotlin's and JavaScript's `<` are both ordinal over UTF-16 code units), but
the Windows daemon uses culture-sensitive `String.CompareTo`. ICU sorts `'k'`
before `'Q'`; ordinal does not. For roughly one key pair in six the two sides
disagree about who should dial, so either both dial or neither does.

The fix belongs in `windows/daemon` (`string.CompareOrdinal`). Do **not**
"match" it by going culture-sensitive here — that would only break this
against HarmonyOS as well.
