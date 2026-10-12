# mobile/harmonyos/ — implementation plan (2026-09-18)

Target: HarmonyOS 7, API 26, ArkTS/ArkUI, built with DevEco Studio 26. This is
new ground for this project (and, honestly, for me too — API 26 is very
recent) so this plan leans conservative: prove the riskiest thing (protocol
compatibility with the Windows daemon) before building anything else.

## Hard constraint: wire compatibility with the Windows daemon

This app must speak the *exact same* protocol the Windows daemon already
implements — nothing here is a new design, it's a port. That means matching,
byte-for-byte where it matters:

- UDP discovery beacon: `"{tcpPort}:{deviceID}:{proof}:{address}"`, `-` for absent fields.
- TCP handshake: `HandshakeMessage { EphemeralPublicKey, IdentityPublicKey, Signature }` as one JSON line, ECDH on curve P-256 (nistP256/secp256r1), session key via `DeriveKeyFromHash` (SHA-256 over the shared secret).
- Session transport: every line after the handshake is `Convert.ToBase64String(nonce[12] + tag[16] + ciphertext)`, AES-256-GCM.
- Application messages: `Envelope { Type, Payload }` JSON, `Type` ∈ `entry | history_batch | file_chunk | file_request`.
- `ClipboardEntry { Content, Type, DeviceId, Timestamp, Signature }`, signed over `"{Content}:{Type}:{DeviceId}:{Timestamp:o}"` with ECDSA P-256 / SHA-256.
- Passphrase auto-trust: PBKDF2-SHA256, 210,000 iterations, **fixed salt** `"ClipboardDaemonPassphraseSaltV1"` (UTF-8 bytes) — this exact salt must match or two devices can never derive the same key from the same passphrase.
- File chunking: `FileChunkMessage { FileHash, ChunkIndex, IsLast, DataBase64 }`, `FilePayload { FileName, FileHash, FileSize }`, SHA-256 content-addressing.

Any mismatch in any of these (a different JSON casing, a different curve, a
different KDF parameter) means this app simply can't talk to anything else in
the mesh — it won't error cleanly, it'll just silently fail signature/AEAD
verification. That's why step 2 below is a dedicated compatibility spike
before any real app-building starts.

## Platform mapping (Windows piece → HarmonyOS API)

| Concern | Windows | HarmonyOS |
|---|---|---|
| Clipboard read/watch | `System.Windows.Forms.Clipboard` + polling | `@ohos.pasteboard`: `getSystemPasteboard()`, `on('update', cb)` for change notification (free, no permission). **Reading content is restricted** — `ohos.permission.READ_PASTEBOARD` is above normal APL; declaring it in `module.json5` made the app fail to *install* on-device (`hdc shell bm install`: "grant request permissions failed"), not just fail at runtime. Actual content reads must go through a tap-triggered `PasteButton` security component, which needs no permission declaration at all but only grants a **temporary** read window for that gesture. Net effect: no silent auto-pull is possible for a normal app — see step 3 below. **Update 2026-10-12: Huawei approved `READ_PASTEBOARD` for ClipLink through the ACL process; see "Clipboard access" below.** **No `changeCount`-equivalent exists** either (confirmed via the pasteboard service source) — echo-suppression is content-hash-based, same limitation already documented in `docs/architecture.md` for this exact platform. |
| Identity key (long-term ECDSA) | DPAPI-encrypted file | **HUKS** (Hardware Universal Keystore) — official guidance is explicit that long-term keys should live in HUKS, not be generated/exported via the crypto framework and serialized to a file. This is actually *better* than the Windows approach: the private key material can stay inside hardware-backed storage and never exist as exportable bytes at all. Needs a compatibility check: can HUKS export/sign in a way that produces standard P-256 signatures interoperable with .NET's `ECDsa`? — first thing to verify in the spike. |
| Passphrase/session crypto | `System.Security.Cryptography` | `@ohos.security.cryptoFramework` — confirmed support for AES-GCM (`createSymCipher('AES|GCM|PKCS7')`), HMAC, ECDH/ECDSA (ECC_256), PBKDF2. |
| Local persistence (history, trust store) | JSON files | `@ohos.data.preferences` for small config (trust store, passphrase-derived key reference), `@ohos.file.fs` for larger blobs (FileStore-equivalent). |
| Networking (UDP discovery, TCP peer link) | `System.Net.Sockets` | `@ohos.net.socket` — `constructUDPSocketInstance()` / `constructTCPSocketInstance()`. Requires `ohos.permission.INTERNET` declared in `module.json5`. |
| Background sync | N/A (always-on daemon) | **Foreground-only**, per the original architecture decision — HarmonyOS's background task model (Transient/Continuous/Deferred, none suited to "run indefinitely like a daemon") confirms that decision still holds for API 26. Sync happens on app open/foreground only. |

## Genuine unknowns — resolved via the spike (2026-09-18/19)

- ~~**HUKS-signed output format compatibility**~~ — RESOLVED: **DER/ASN.1-encoded** (measured 70/71/72 bytes across runs, always starting `0x30` — the small length variance is normal DER, depending on whether `r`/`s` need a leading zero byte). **Not** raw r‖s like .NET's `ECDsa.SignData`/`VerifyData` default. Implemented and verified in step 4 (`crypto/EcdsaDer.ets`, `derToRaw`/`rawToDer`): round-trips byte-exact against a real HUKS signature. **Refined finding from step 4's diagnostics**: `cryptoFramework`'s own `Verify.verify()` only ever accepts DER too — it flatly rejects the mathematically-identical raw form, unlike .NET which defaults to raw. So the conversion isn't optional plumbing, it's required on *every* cross-platform boundary: `derToRaw()` before sending a HarmonyOS-signed entry to Windows (or any peer), `rawToDer()` before verifying *any* incoming signature here — the wire format is always raw (matching Windows' native shape), regardless of which platform actually sent it.
- ~~**PBKDF2 output compatibility**~~ — RESOLVED, but not the way expected: `cryptoFramework.createKdf('PBKDF2|SHA256').generateSecret()` **fails on-device** with `code 401, message: "build context fail"`, reproducibly, regardless of iteration count (tried 210,000 and 1), `algName` literal (`'PBKDF2Spec'` and `'Pbkdf2ParamsSpec'`), or `password` type (`Uint8Array` and `string`). Device confirmed at `OpenHarmony-7.0.0.105`, `sdkApiVersion 26` — exactly matches the SDK, so it's not a version mismatch. `cryptoFramework`'s HMAC-SHA256 path was verified working and byte-exact against .NET's `HMACSHA256` in isolation, which narrows this to a genuine gap in this Beta OS build's native PBKDF2 implementation specifically, not a parameter-shape bug or a broader crypto framework problem.
  **Workaround (implemented and verified correct)**: PBKDF2-HMAC-SHA256 built manually on top of the working HMAC primitive (standard construction: `T_i = U_1 xor U_2 xor ... xor U_c`, `U_1 = HMAC(P, S‖INT32BE(i))`, `U_j = HMAC(P, U_{j-1})`). Verified byte-exact against a .NET reference at both 1,000 and 210,000 iterations. This is what the real app should use for the identity/passphrase KDF — not the built-in `Kdf.generateSecret`. Worth re-testing the built-in path against a future OS update in case it gets fixed, but don't block on it.
- **LAN broadcast/multicast permission specifics** — still unverified, deferred to step 5 (networking) since it needs actual socket code to test, not just crypto.

## Environment setup

1. **DevEco Studio 26** (Beta as of this writing) — download from the official Huawei developer site. Windows requirements: Windows 10/11 64-bit, **16GB+ RAM, 100GB+ free disk**, 1280×800+ display. The installer bundles the HarmonyOS SDK, Node.js, hvigor (build tool), ohpm (package manager), and an ARM-based emulator — no separate downloads needed for those.
2. **A Huawei Developer account** — needed to download the SDK/tooling and to deploy to a real device.
3. **Testing target**: the bundled emulator is fine for UI/clipboard basics, but given how much of this app is real networking behavior (UDP broadcast, TCP handshake, LAN discovery), **a real HarmonyOS device is strongly recommended** once past the initial spike — emulator networking often doesn't behave identically to a real device on a real LAN.

## Build order

1. ~~**Environment + hello-world**~~ — done (2026-09-17). DevEco Studio 26 installed, Empty Ability project created under `entry/`, blank ArkTS app confirmed running on a real device.
2. ~~**Protocol compatibility spike**~~ — done (2026-09-19). `entry/src/main/ets/pages/Index.ets` holds the spike harness (still not a real app screen — replaces the default hello-world page temporarily; will be replaced for real in step 3). Four on-device tests, all resolved — see "Genuine unknowns" above for the detailed findings:
   1. **PBKDF2-SHA256 via built-in `Kdf`** — fails on-device (platform bug, not our bug).
   2. **HUKS ECDSA P-256 signing** — works, but DER-encoded, not raw r‖s.
   3. **HMAC-SHA256 baseline** — works, byte-exact vs .NET.
   4. **Manual PBKDF2-via-HMAC workaround** — works, byte-exact vs .NET at both 1,000 and 210,000 iterations.

   Carry forward into later steps: `pbkdf2Sha256Manual()` (test 4) for the real passphrase-derived key in step 4, and a DER↔raw signature converter (needed before step 7) for HUKS-signed data to interop with `ECDsa`.
3. ~~**Clipboard read + watch**~~ — working (2026-09-19) via the tap-to-sync model: `entry/src/main/ets/clipboard/ClipboardWatcher.ets` + `pages/Index.ets`. Confirmed on-device that declaring `ohos.permission.READ_PASTEBOARD` blocks the app from installing at all (see platform mapping table above); pivoted to the `PasteButton` security component, which needs no permission declaration and grants a temporary read window on tap. `pasteboard.on('update')` (free) flips a "pending change" indicator; the user taps `PasteButton` to actually read + hash + record content.

   **Pursuing true auto-read via ACL, in parallel, not blocking further work**: `READ_PASTEBOARD` can be unlocked via Huawei's ACL process — email `agconnect@huawei.com` with the app's AGC APP ID + permission name + use-case description (~1 business day turnaround), then generate a debug Profile with that permission checked and this device's UDID registered, then switch DevEco Studio's signing from automatic to manual/custom (Project Structure → Signing Configs) using the resulting cert files. This is an account/email process only the project owner can do — not something automatable here. Once the Profile is in hand: re-add `READ_PASTEBOARD` to `module.json5`, and change `ClipboardWatcher`'s `on('update')` handler to call `readCurrentClipboard()` directly instead of requiring a `PasteButton` tap.

   Until then, the tap-to-sync model is the real, permanent fallback (not just a placeholder) — worth keeping even after ACL is granted, in case the ACL request is ever denied or a future OS update changes the rules. Reflect this in the step 9 UI design (a persistent "sync now" affordance in addition to any auto-read) and in `docs/architecture.md`'s per-platform notes.
4. ~~**Local persistence**~~ — done (2026-09-19), all four modules verified on-device via a diagnostics harness in `Index.ets` (identity sign+verify round-trip, trust store trust/untrust, passphrase key derive/proof, file store path/exists):
   - `identity/DeviceIdentity.ets`: HUKS-backed ECC P-256 identity key. Private key never leaves HUKS (stronger than Windows' DPAPI-file approach). Public key export confirmed byte-compatible with `DeviceIdentity.cs`'s `GetPublicKey()` (both X.509 SPKI DER, base64) — device IDs are directly interoperable. `sign()` returns raw r‖s via `crypto/EcdsaDer.ets`'s conversion (see "Genuine unknowns" above for why that's needed).
   - `identity/TrustStore.ets`: Preferences-backed, mirrors `TrustStore.cs` — one JSON-serialized list under one key (Preferences has no nested-object support), same not-encrypted-at-rest gap as Windows (`docs/security.md` finding #8), not silently "fixed" on one platform only.
   - `identity/PassphraseKeyStore.ets`: uses `crypto/Pbkdf2.ets` (the manual workaround from step 2) for `SetPassphrase`, stores the derived key in Preferences rather than HUKS — deliberately kept at parity with Windows' security level (DPAPI-file, not hardware-backed) rather than gambling on HUKS's unconfirmed symmetric-key-import wire format. `computeProof`/`verifyProof` match `PassphraseAuth.cs` exactly (HMAC-SHA256, base64, constant-time compare).
   - `storage/FileStore.ets`: content-addressed blobs under `filesDir`, mirrors `FileStore.cs`'s API shape (`getPath`/`getTempPath`/`exists`/`delete`). Chunked read/write comes in step 10.
5. ~~**Networking**~~ — done (2026-09-19), verified against a real second device (this Windows PC) on the real LAN, not just loopback:
   - `networking/Discovery.ets`: UDP beacon send+receive, exact same format/port/2s interval as `Discovery.cs`. **Resolves the last open "genuine unknown"**: LAN broadcast works fine with just `ohos.permission.INTERNET` — no extra broadcast/multicast permission needed, confirmed by the phone receiving real beacons from the Windows daemon on `192.168.1.156:49000`.
   - `networking/TcpTransport.ets`: raw TCP listen (`TcpServer`) + connect (`connectTcp`) — deliberately no encryption/framing yet, connectivity proof only. Verified both directions on-device: phone's server accepted an inbound connection and received a message, and the phone connected out to the Windows daemon's TCP port and exchanged a raw message successfully.
   - `pages/Index.ets` diagnostics: beacon list is tap-to-connect per row (own-device beacon greyed out and labeled, since UDP broadcast loopback means the phone always hears itself too) — this is what caught that the naive "connect to most recent beacon" was non-deterministic (could grab the loopback entry instead of the real peer) before it became a real bug.
6. ~~**Handshake + session encryption**~~ — done (2026-09-19), the real interop test passed fully against a live Windows daemon:
   - `crypto/AesGcm.ets`: AES-256-GCM matching `PeerConnection.cs`'s exact packed format (nonce[12]‖tag[16]‖ciphertext, base64). This SDK's `Cipher` has no `getAuthTag()` (unlike blog examples referencing a different SDK version) — confirmed by inspection that `GcmParamsSpec.authTag` is a required field even for encrypt mode. Working hypothesis (`doFinal()` for `ENCRYPT_MODE` returns ciphertext with the tag appended) verified correct via a self round-trip test before ever touching the network.
   - `networking/PeerConnection.ets`: the authenticated ECDH handshake (ephemeral P-256 keypair, signed with the long-term identity key, exchanged as one JSON line) plus a line-buffered encrypted channel (`TcpLineChannel`, replicating `StreamReader`/`StreamWriter` line semantics over HarmonyOS's chunk-based `TCPSocket`). Session key = `SHA256(rawECDHSharedSecret)`, matching .NET's `DeriveKeyFromHash` with no prepend/append.
   - **Real cross-platform proof**: connected to the live Windows daemon (after trusting this device's id there), completed the full handshake, and successfully **decrypted its `history_batch` message** — the daemon's actual clipboard history, including a real file entry, sent automatically right after accepting the connection. ECDH agreement, signature verification (the DER↔raw conversion from step 4), and AES-256-GCM all interoperate correctly with the .NET implementation.
   - Debugging note: hit a transient `2301115` (`EINPROGRESS`) on `TCPSocket.connect()` a few times during testing, most likely caused by the Windows daemon's own accept loop getting stuck on an earlier incomplete handshake (`docs/security.md` finding #2 — no handshake timeout) rather than a HarmonyOS-side bug; resolved by restarting the daemon. Worth fixing that Windows-side gap eventually, but not blocking further HarmonyOS work.
7. ~~**Signing/verification + trust store integration**~~ — done (2026-09-19), verified on-device against the live Windows daemon:
   - `crypto/Signing.ets`: mirrors `SigningService.cs`/`ClipboardEntry.cs` exactly (`"{Content}:{Type}:{DeviceId}:{Timestamp}"`, ECDSA P-256/SHA-256). **Timestamp handling is the one real subtlety**: `ClipboardEntry.cs`'s `Timestamp` is a `DateTime`, signed via `.ToString("o")` (7 fractional digits) — since JS `Date` only has millisecond precision, parsing an incoming (possibly Windows-originated, genuinely sub-millisecond-precise) timestamp into a `Date` and reformatting it would silently alter the string and break verification for most real Windows-sent entries. Fix: treat `Timestamp` as an opaque string end to end — never parse it, just pass the raw JSON string straight through (safe because .NET's `"o"` format is specifically designed to round-trip losslessly). When originating a new entry here, generate a valid `"o"`-shaped string directly (milliseconds + `"0000"` padding to reach 7 digits).
   - `networking/PeerConnection.ets`: now enforces mutual trust (`TrustStore.isTrusted`) at the same point in the flow `PeerConnection.cs` checks it — right after parsing the peer's handshake message, before spending effort on signature verification or key derivation for a peer that would be refused anyway. Both sides must trust each other for the handshake to succeed, matching Windows' behavior exactly (accepting *and* initiating connections both check trust there).
   - **Real cross-platform proof**: after mutually trusting each other (this device's id trusted on the Windows daemon via `--trust`, the daemon's id trusted here via the app's Trust action), completed the handshake and sent a real signed `ClipboardEntry` (not a placeholder string) wrapped in an `entry` envelope — the Windows daemon accepted it cleanly (no "invalid signature" rejection), confirming the signing string construction, DER↔raw conversion, and timestamp handling all interoperate correctly end to end.
8. ~~**Full sync**~~ — done (2026-09-19), verified on-device against the live Windows daemon (bidirectional: broadcast from the phone, receive + apply from Windows, history reconciliation on connect):
   - `storage/HistoryAccess.ets`: mirrors `HistoryAccess.cs` (25-item cap, oldest-first eviction with file-blob cleanup), Preferences-backed like `TrustStore.ets`.
   - `clipboard/ClipboardApply.ets`: applies a verified entry's content to the local clipboard (`pasteboard.setData`/`createData`, text and image — `image.createImageSource(buf).createPixelMap()` for the image case). **Writing needs no permission at all** (`setData`/`setDataSync` carry no `@permission` tag in the SDK) — unlike reading (step 3), incoming sync applies silently, no `PasteButton` tap needed. "file" type entries deferred to step 10 (need `FileStore`-backed chunked transfer), logged clearly rather than silently dropped.
   - `networking/SyncManager.ets`: mirrors `Program.cs`'s `HandleMessage`/`SendHistoryBatch`/`ClipboardChanged` broadcast logic for `entry` and `history_batch` (`file_chunk`/`file_request` are step 10, explicitly logged as not-yet-implemented rather than silently ignored).
   - `pages/Index.ets`: incoming connections (via `TcpServer`) now complete a real handshake as the responder (`PeerConnection.create()` works identically for either role) instead of the old step-5 raw pass-through; outbound handshakes (step 6/7's beacon tap) hand the live connection to `SyncManager`. The `PasteButton` flow (step 3) signs and broadcasts real captured clipboard content to every connected peer.
   - **ArkTS gotcha hit and fixed**: `arkts-no-structural-typing` — a `socket.TCPSocket` (outbound) and `socket.TCPSocketConnection` (inbound) can't be passed where a shape-matching interface is expected, unlike normal TypeScript; needed explicit adapter classes (`TcpSocketAdapter`/`TcpSocketConnectionAdapter` in `PeerConnection.ets`) that formally `implements` the shared interface, even though both underlying types already had the exact right methods.
9. **Foreground-only lifecycle wiring** — sync triggers on app open/foreground, per the architecture doc; minimal UI (pairing screen, connected/trusted devices, maybe a history view).
10. **File transfer** (chunking, `FileStore`-equivalent) — deliberately last, since it's the most complex piece and everything before it needs to be solid first.

## Clipboard access (READ_PASTEBOARD)

Huawei approved the restricted permission `ohos.permission.READ_PASTEBOARD` for ClipLink through the ACL process (2026-10-12; the other permissions applied for - the floating ball and the background-run ones - were rejected). With it, `getData()` works without a PasteButton tap, so ClipLink sends what you copied in another app by itself when it comes forward, like Android's "send my clipboard when I open ClipLink". It is **foreground only**: nothing is read in the background, and a phone is still frozen soon after the app leaves the screen.

- **Declared** in `module.json5` for `EntryAbility` with `usedScene.when: "inuse"` and a reason string (`READ_PASTEBOARD_reason`, English and Chinese) that the system shows in its prompt. **The signing profile must carry the ACL**, or the app cannot be installed: in DevEco Studio use the "ACL Permission Configuration" dialog (Module `entry`, When `inuse`, Abilities `EntryAbility` - not `EntryBackupAbility`), which also writes the module entry and re-signs. DevEco rewrites `module.json5` and `base/string.json` when it does (it drops comments and re-escapes characters); keep the comments.
- **The prompt** is the system's own: "Allow ClipLink to copy from the clipboard?" with *Allow this time*, *Always allow* and *Don't allow* (checked on-device). `clipboard/PasteboardPermission.ets` checks (`checkAccessTokenSync`) and requests (`requestPermissionsFromUser`) it, and logs both under the `ClipLinkNet` hilog tag.
- **The flow** (`Index.ets`): on `onPageShow` (after 300 ms, for the window to take focus) and once the key and the sync engine exist at startup, `captureOnOpen` reads the clipboard through `syncClipboard`, the same path the Paste button uses. It does nothing unless the user wants it, the permission is held, and `getChangeCount` shows the clipboard changed since the last look (the last look is saved, so a restart does not send the same copy again).
- **The setting:** Me > "Send my clipboard when I open ClipLink" (on by default, like Android). The switch shows "on" only while the permission is held (`autoCapture` = wanted AND granted; taking the permission away in Settings turns it off, giving it back turns it on). The first run asks once; turning the switch on asks again; refusing puts the switch back with a toast.
- **The fallback** is unchanged: the Paste button, and the "point out new copies" highlight for a user who refuses the permission.

## The pairing QR code is a link

The QR code on the Pairing screen is a link to the website, `https://cliplink.uaena.io/pair/#<pairing info>` (`networking/PairingLink.ets`; the format is in `docs/protocol.md`), so the system scanner or any scanner app that reads it opens ClipLink if it is installed and the website, with the downloads, if not. The in-app scanner and the pair-by-address box take the link or the bare JSON.

- `module.json5` has a skill for `https://cliplink.uaena.io/pair` with `domainVerify: true` (App Linking). `EntryAbility` takes the link from the Want in `onCreate` (a cold start) and `onNewWant` (the app is running), queues it (`queuePairingLink`) and emits `PAIRING_LINK_EVENT`; `Index.ets` (`drainPairingLink`) opens the Pairing screen and starts pairing, as if the code had been scanned in the app, once the device key exists. Both devices still have to trust each other.
- The system only hands the link to the app after it has verified the site's `/.well-known/applinking.json`, which names the app by its `appIdentifier` (`site/.well-known/applinking.json`; `bm dump -n io.uaena.cliplink` shows the installed build's). **Check that it matches the build you publish** (AppGallery Connect > the app > App information) - until it does, or before the site file is live, the link opens the browser. Testing the app's side without the verification: `aa start -b io.uaena.cliplink -m entry -a EntryAbility -A ohos.want.action.viewData -U "https://cliplink.uaena.io/pair/#<info>"`.
- "Get ClipLink on your other devices" (the website's address, one tap to open it) is at the end of the Pairing screen and of the Devices tab.

## Toasts

A toast is for what the screen doesn't already show: a failure, a result with no visible trace ("History cleared.", "Tailscale IP saved."). A success the UI shows by itself gets none: the paste button says nothing on success, nothing new on the clipboard, nobody connected (the new card is the answer), a read the system did not grant, content ClipLink does not sync, or a paste that failed (the Activity log has why); accepting a pairing ("Paired."), setting or clearing the passcode, saving the device name (the screen closes back to Me, as for the Tailscale IP), removing, blocking or unblocking a device, deleting an item and copying (an item, the device ID, the pairing info - only a failed copy is toasted) say nothing, and neither does a save to the gallery or to a file - the system's own dialog or picker has just been in front of the user. A share into ClipLink only toasts when something was skipped, nobody is connected, or nothing was shared. Add a toast only if the user couldn't otherwise tell what happened. (Android follows the same rule.)

## Notifications

Two local notifications (`notificationManager`, `Index.ets`), both posted only while the app is out of view (`appVisible`, set by `onPageShow` / `onPageHide`):

- A pairing request that arrives while the app is out of view, with Trust and Ignore buttons (see `networking/PairingActions.ets`).
- Items from other devices (`notifyReceivedItem`), if Me > **Notify about new items** is on (on by default): "New from <device>" for the first, "3 new items synced" after. There is one notification, replaced as more arrive and cleared by `onPageShow`, so opening the app starts the count over. Only an item new to the list counts (`alreadyListed`), and only one from a peer. The text is the same as the iOS notification's, since it can sit on the lock screen: a key or token is "Key or token", a link is its host, text is its first line cut at 60 characters, an image is "Image", a file is its name.
- **Both use `SlotType.SERVICE_INFORMATION`.** Without `notificationSlotType` a notification goes to the default slot, `OTHER_TYPES`, which the system folds into the shade's "more notifications" at the bottom and never shows as a banner: it did arrive, nobody saw it. `SERVICE_INFORMATION` (level 4, banner, lock screen, vibration) lands at the top of the shade. A phone in Sleep mode still mutes the banner and sound.
- **Only while the process runs.** HarmonyOS freezes an app within seconds of leaving the screen (this app has no continuous task; see the ACL notes), so an item sent later is listed when the app is next opened, not announced. Checked on a device: an item sent a second after leaving the app was announced; one sent 15 seconds later never reached it (the connection was reset). `netLog` writes `new-item notification: ...` lines under the `ClipLinkNet` hilog tag, and the Activity log gets a line if the notification couldn't be shown.

## Share to ClipLink

ClipLink appears in the system share panel (Gallery, Files, a browser's Share...). `entry/src/main/module.json5` gives `EntryAbility` a second skill (`ohos.want.action.sendData`, `general.object` + `general.file`, up to 50 files). No permission is needed.

- `share/ShareIntake.ets`: `EntryAbility` passes the Want from `onCreate` (cold start) or `onNewWant` (already running; singleton) to `intakeShare`. It reads the Want with `systemShare.getSharedData`, falling back to `want.uri` / `ability.params.stream` when that fails with 1003703001. Each file is copied into `cacheDir/share_in/` with `fs.copy` straight away, while the sender's URI grant still holds. Copies are capped at 1 GB, the same limit as Windows. The size (and whether it's a folder) is checked on the granted URI before copying where `fs.open` can open it, and otherwise the copy is cancelled from its progress listener once the file is known to be over the cap. A share with nothing usable in it still gets a toast. The results are queued in AppStorage under `pendingShares`, and the `sharedIn` event goes out on the eventHub.
- `pages/Index.ets` (`drainPendingShares`) syncs the queue once `SyncManager`, `FileStore` and the device id are ready. That happens on the event, and once at startup for a cold start. Each shared item is synced like a copy on this device:
  - A file is moved into `FileStore` with `FileStore.importFile` (a chunked SHA-256, then a move), and becomes a `file` entry.
  - Text or a link becomes a `text` entry.
  - Nothing is written to this device's clipboard.
  - A toast reports the result, and the Synced tab is shown.
- URIs that `fs.copy` would resolve inside ClipLink's own sandbox are refused: ClipLink's own bundle name, no authority at all (`file:///data/...`), a `file://docs/` path outside `/storage`, or a `..` path segment (checked after undoing `%` escapes). Otherwise a sender, or any app that starts the exported `EntryAbility` with a crafted Want, could get ClipLink's private files sent to its peers. Folders are skipped, as on Windows.
- A file pasted with the Paste button is taken by the same rules (`copyFileIn`): the same refusals and 1 GB cap, then a chunked SHA-256 and a move into `FileStore` (`FileStore.adopt`), never read into memory whole. Pasting a received file that ClipLink put on the clipboard itself says it's already in ClipLink, instead of sending it back out as a new item.
- Not an extension ability: ExtensionAbilities run in their own process, and the peer connections live in the main one, which only runs in the foreground on a phone anyway.

**Peer-supplied hashes and names**: a `FileHash` from a peer (file entry, `file_request`, `file_chunk`) becomes a path only if it is 64 hex digits (`FileStore.isValidFileHash`, enforced in `FileStore` itself as well as in `SyncManager` and `HistoryAccess`). Otherwise a peer could read, overwrite or delete sandbox files through `../`. File names from peers or senders go through `storage/FileNames.ets` (`safeFileName`, which mirrors Windows' `FileNames.Safe`) before they are shown, offered to the save picker or sent. As on the other platforms, control characters and the invisible bidi and zero-width ones are removed and the characters Windows refuses become `_`, so a name comes out the same on every device.

**Missing file bytes**: every peer that connects is sent a `file_request` for each history file whose bytes aren't in `FileStore` (`SyncManager.requestMissingFiles`), not only the items received this run, so a file whose stream was cut off, failed its hash check or never came (the app killed mid-transfer) is fetched later. A file whose stream fails or is cut off is asked for again from the peers still connected, at most 3 times (`requestAgain`, the same cap as Android's `MAX_RETRIES`, so a sender with a bad copy isn't asked forever); after that, only a peer connecting asks again.

**Tests**: `entry/src/test` holds local unit tests (hypium) for the pieces that touch no socket or file: `LineFramer`, `ChunkOrder` (`file_chunk` ordering), `safeFileName`, the own-identity key comparison and the echo guard's nonce key (`nonceKey`). They run on the PC, with no device: `hvigorw --mode module -p module=entry@default -p product=default test`. Read the results in `entry/.test/default/intermediates/test/coverage_data/test_result.txt`, since the task reports BUILD SUCCESSFUL even when a test fails. The host runtime stubs the system APIs (its `util.Base64Helper` encodes everything to `''` and decodes everything to no bytes), so a test that needs the real one only checks something on a device.

## Tablets and wide windows

The pages follow the window's size, not the device: `windowWidthVp`/`windowHeightVp` are kept by the
window's `windowSizeChange` listener (`Index.ets`), so rotating, split screen and a resized free window
all re-lay the page out. What follows is the OS API for each job (Huawei's multi-device "responsive
layout" and "page layout scenarios" guides), not hand-rolled layout.

- **A list beside its detail.** `isSplitLayout()` is the guide's single/double-column rule: the window
  at least 600vp wide and no taller than 1.2 times its width (what
  `NavigationMode.AUTO_WITH_ASPECT_RATIO` applies). Then Synced and Devices are an `HdsNavigation` in
  `NavigationMode.Split` - the cards (or devices) are its navigation bar on the left, the preview (or
  the device's detail) is its one route on the right, with a draggable divider (`navBarWidthRange`).
  A tap only selects: nothing is pushed. The selected card gets a constant-width 2vp border (only its
  colour changes - a border that came and went resized the card and reshuffled the grid). Devices
  shows its first device until one is selected; Synced shows the newest item. Narrower windows
  (a phone, a tablet held upright) keep the original one-column list -> pushed detail stack, which is a
  separate composition (`syncedOneColumnTab`, `devicesOneColumnTab`), so the phone layout is
  unchanged. The shared `geometryTransition` id is cleared in the split (`gtId`), where card and
  preview are on screen together.
- **Columns by width.** The Synced list is `List.lanes({ minLength, maxLength })`: as many lanes as fit,
  each 400-640vp, so its cards are wide enough to show more text. The grid is a `WaterFlow`; its column
  count is the number of 200vp columns that fit the pane's *measured* width (`onAreaChange`), shared
  out evenly, and two on a phone. (`columnsTemplate(ItemFillPolicy)` and `repeat(auto-fill, n)` also
  count columns by width, but the first gives 5 columns even in a narrow pane and the second leaves
  the remainder empty at the edge.)
- **Me.** One column on a phone; on a wide window a `WaterFlow` of the sections (2 columns under 1100vp,
  3 above) so tall and short sections pack without gaps. The sub-screens (pairing, passcode, ...) are
  capped at 680vp and centred.
- **Files.** Tapping a file opens its preview first (never another app): a PDF is rendered in the app
  with PDF Kit's `PdfView`, a plain-text file is read, anything else shows a card with its name and
  size. Open (title bar) hands it to another app. The store keeps files by the hash of their bytes
  (no name, no extension), so Share and Open work on a copy under the file's real name,
  `<cache>/named/<hash>/<name>` (`namedFileUri`, cleared at start) and give the share sheet the type
  its extension implies.

## Long-press menus: cards go solid while pressed

Cards are filled with the "Card transparency" slider's value (default 35%, the same on every platform
that has the slider). A long-press menu on a card (`bindContextMenu` with
`preview: MenuPreviewMode.IMAGE`) lifts a *snapshot* of the card and draws it over the original, which
stays where it is. A snapshot of a see-through card lets the original show through it: the text twice,
a few pixels apart, a doubled button, a doubled type chip. So a card must be **solid from the moment it
is touched until its menu closes**, and back to the slider's value afterwards:

- `cardFillFor(key)` is the fill to use for a card's own background (not `cardFill()`): the solid
  `cardSurface()` when `pressedCardKey` or `menuCardKey` is that card's key, else `cardFill()`.
- `cardTouch(key, event)` on the card's `onTouch` sets `pressedCardKey` on the finger going down and
  clears it on up/cancel (a scroll or drag taking over the touch cancels) or when the finger moves more
  than `CARD_PRESS_MOVE_SLOP_VP`. It is set on touch-down, not after a delay, so the snapshot - taken
  when the long press fires - is already solid. The cost is that a card flashes solid when a scroll
  starts on it, until the finger moves.
- The menu's `aboutToAppear`/`onDisappear` set and clear `menuCardKey`, so the original under the lifted
  card is solid while the menu is open too.
- The key is the item's id for a Synced card, `deviceCardKey(deviceId)` for a device card.

**Any new card with a long-press menu must do all three** (fill, `onTouch`, the two menu callbacks), or
it leaks again. The three-dots menu (`bindMenu`) has no lifted card and needs none of this.

## Languages

The UI comes in English and Simplified Chinese; the system picks one from the device language, and anything not translated falls back to English.

- Every user-visible string lives in `entry/src/main/resources/<qualifier>/element/string.json` (and `plural.json` for counts): `base` is the English fallback and holds every key, `en_US` is identical to it, `zh_CN` is the Chinese. `AppScope/resources` has the same three for `app_name`. A new string goes into all three.
- In UI code use `Text($r('app.string.name'))`, with arguments `$r('app.string.name', a, b)`. Text that code builds itself (toasts, dialog bodies, status lines) goes through `Index.str()` / `countStr()` or `i18n/Strings.ets`, which read the resource when called - never keep the result in a field or `@State` that outlives that moment, or it will stay in the old language after a language change. Store a `Resource` or a key instead.
- Placeholders are positional (`%1$s`, `%2$d`) so a translation can reorder them. Counts are plural resources, not `n === 1 ? '' : 's'`.
- Deliberately not translated: log lines (`netLog`, the Activity log), everything sent over the wire or stored, and the `Device XXXX·XXXX` fingerprint label (`shortDeviceId`), which is the same on every platform.
