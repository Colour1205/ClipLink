# Sync de-duplication and echo spec

Every platform implements this the same way: Windows (C#), Android (Kotlin), HarmonyOS (ArkTS) and iOS (Swift). It fixes the "the same thing shows up twice" bugs, and the "an old item comes back to the top and onto the clipboard" bugs, from the verified findings.

Status: design, for the `fix/bugs-and-optimizations` branch. No version bump.

## Ground rules

- **Nothing on the wire changes.** No new message, field, framing or hashing. Entries, keys (the signature), heads, requests, batches and deletes all stay as they are. Every rule here is a local decision about what to send, what to put on the clipboard and how to list things. The one optional exception is 4.4, which changes only the letter case of a hash value that every receiver already accepts in either case.
- **History storage stays the same.** What goes into the 25-item history, how entries are identified (signature, or the full record on HarmonyOS and Android), the time-based trim, tombstones and the head built from them all stay as they are. The content rules (fold, echo) only read the history. They never add, drop or keep back an entry because of its content. This is why none of this can start a sync loop with any peer, old or new (see 2.6).
- **Old versions keep working.** Windows 2.0.x to 2.1.3, Android 2.0.0 to 2.1.2, HarmonyOS 2.0.0 to 2.1.2 and iOS 2.0 to 2.1.2 see the same messages as before. Each rule has its own old-peer story.
- **Stored formats migrate.** The only new stored thing is the LastWrite record (1.7). It is read from the old single-hash key when the new key is missing.

## Definitions

| Term | Meaning |
| --- | --- |
| **norm(text)** | The text with every `\r\n` changed to `\n`, then every remaining `\r` changed to `\n`, then **one** trailing `\n` removed if there is one. Used only to compare. Nothing that is sent, stored or put on the clipboard is ever normalised. See rule 5. |
| **print** | A string that identifies content, made of a kind prefix and lowercase SHA-256 hex. `t:` + sha256(UTF-8 of norm(text)) for text. `i:` + sha256(the picture's bytes, that is, the base64 of an image entry decoded) for a picture. `f:` + lowercase(FileHash) for a file. `x:` + a lowercase legacy hash, only during migration (1.7). |
| **contentKey(entry)** | The print of an entry's content. Text: `t:`…, image: `i:`… (null if the base64 does not decode), file: `f:` + lowercase(FileHash) from its FilePayload (null if the payload does not parse or the hash is not 64 hex digits). Any other type: null. A null key never matches anything. Platforms cache it in memory by entry key, because an image key means decoding megabytes. |
| **LastWrite** | One record per device, kept until it is replaced: the prints of what this device believes is on its clipboard because of ClipLink. That is the last thing ClipLink wrote there, or the last capture it classified (sent, or found already synced). See 1.2 and 1.7. |
| **own-write check** | The platform's cheap test, done without reading the content, that the clipboard still holds ClipLink's own last write. Windows: `GetClipboardSequenceNumber()` equals the number recorded right after ClipLink's write. Android: the primary clip's label is `CLIP_LABEL`. HarmonyOS: `getChangeCount()` equals the count recorded right after ClipLink's write (new, 1.7). iOS: `ClipboardService.holdsOwnWrite`. |
| **newest(n)** | The n entries of this device's history with the latest timestamps, compared the way the trim compares them. Entries tied at the boundary are all included. Most rules use n = 1. |
| **localNewest** | The latest timestamp in this device's history just before a merge adds anything. Minus infinity when the history is empty. |
| **fresh** | An entry is fresh when its timestamp is strictly later than localNewest. |
| **quiet merge** | Adding entries the way an expired (late) v2 answer is added today. They go in by timestamp, in no session block or stack, with no clipboard write and no notification, and nothing is spared by the trim. An entry older than everything the full history keeps is trimmed straight away, so it is never listed. |
| **auto / manual** | How a capture started. **auto**: the Windows clipboard watcher, or the on-open capture on Android, HarmonyOS and iOS. **manual**: a Paste button or control the user tapped. |

## Rule 1: echo suppression

### 1.1 What a device remembers

The **LastWrite** record holds:

- `prints`: a set of prints. A picture can have more than one: the bytes as received, plus the print of the PNG that this platform's own capture path would make if it read the clipboard back (see 1.2).
- `count`: the platform's own-write counter just after ClipLink's last write. That is the sequence number on Windows and the change count on HarmonyOS and iOS. Android uses the label instead, so it stores no count.

**How long it lasts:** until it is replaced. There is no timer. It means "what the clipboard holds as far as ClipLink knows", so it stays right for as long as nothing else replaces it. A copy that ClipLink does not see (on mobile, while the app is closed) leaves the record stale. That is harmless: a stale record can only suppress content equal to what it names (see 1.3).

There is no list of recent hashes with a time limit. Copies of content that is already in the history are handled by the newest-entry test (1.3, step 4) and by the fold (rule 2). A time window was rejected because it would swallow a deliberate A, B, A re-copy, where the user wants A back on the other device.

### 1.2 When LastWrite is written

The record is written **only after the clipboard write succeeded**. This fixes the Android finding where it was set before `setPrimaryClip` and a failed write lost track. On failure the record stays as it was.

| Event | `prints` becomes | `count` |
| --- | --- | --- |
| Applying a received entry (live, convenience item, finished file) | contentKey(entry). For a picture, or a picture file that the platform puts on as a bitmap, also the read-back print if the platform computes one (see below) | the counter after the write |
| Card **Copy**, Copy device ID, Copy pairing info, and any other write by ClipLink | the print of what was written | the counter after the write |
| A capture that was classified NEW and sent | the capture's prints | unchanged |
| A capture that was classified ALREADY | the capture's prints | unchanged |
| A share-in, drag-in or picked file | not touched: the clipboard was not involved | not touched |
| Deleting or clearing items | not touched. iOS stops calling `forgetLastHash()` on delete and clear: manual capture handles re-sending deleted content (1.3) | not touched |

**Read-back print.** This is the print the platform's own capture code would give for what ClipLink just wrote.

- **Windows must compute it** for a picture, or for a picture file put on as a bitmap. Right after `SetDataObject` succeeds, in the same tick, it reads `Clipboard.GetImage()`, saves it as PNG exactly as the watcher does, and adds `i:` + sha256 of that PNG. If that fails, it simply has no alternative print. This closes the "re-announced clipboard re-sends a received picture" findings (RDP, clipboard managers, Win+V).
- **HarmonyOS may compute it**: pack the PixelMap it wrote with the same `ImagePacker` options the watcher uses. The own-write count already covers the main cases, so this only matters after the pasteboard service restarts.
- **Android and iOS rely on the own-write check** (`CLIP_LABEL`, or `holdsOwnWrite`) and do not compute it.

### 1.3 Classifying a capture

Captures from the clipboard watcher, the on-open capture and the Paste button or control run this. `mode` is `auto` or `manual`. P is the set of prints of what was read. A Windows file selection has one print per file and is handled per file (1.4).

```
classify(mode):
  1. if ownWriteCheck():                          // before reading: no read, no iOS paste prompt
        inHistory = any entry e in history with contentKey(e) in LastWrite.prints
        if mode == auto or inHistory: return ALREADY
        // manual and no longer in history: the user deleted it and is pasting it again, so read and continue
  2. read the clipboard -> P                      // skip on any read failure (see 1.6)
  3. if P intersects LastWrite.prints (an x: print matches the raw hash of the capture, see 1.7):
        if mode == auto or (some entry in history has contentKey in P): return ALREADY
  4. if some entry in newest(1) has contentKey in P: return ALREADY
  5. return NEW
```

- **ALREADY**: no entry is signed or sent, and LastWrite.prints becomes P. The response is the platform's existing one for "nothing new": iOS shows its existing "Already synced." toast on manual, Android and HarmonyOS stay silent, and an auto capture is always silent. Nothing moves in the list.
- **NEW**: sign and send as today, then set LastWrite.prints to P. If the content matches an older entry (one that is not newest), this is a deliberate re-copy. The new entry is listed on top and rule 2 hides the older twin. Peers get it on their clipboard. This is the "re-copy from Win+V or a document" case, and it stays working.
- Why step 4 only looks at newest(1): it catches every "this is already what everyone has" case (auto-apply was off, a share followed by a capture, OS clipboard sharing once the entry has arrived, the iOS share extension). It never blocks re-copying an older item, which is how the user gets that item back onto the other devices.
- Why steps 1 and 3 ignore history in `auto` mode: a deleted item still on the clipboard must not come back by itself (Android's reason for persisting the hash). Why they look at history in `manual` mode: a Paste tap after a delete is a deliberate re-send (iOS's reason for `forgetLastHash`). Both behaviours stay, one per mode.

### 1.4 Where it is used

| Call site | Own-write check (step 1) | LastWrite (step 3) | Newest (step 4) |
| --- | --- | --- | --- |
| Windows clipboard watcher (`ClipboardSync.Watch`, auto) | yes (sequence number) | yes | yes |
| Android on-open capture (`ClipLinkEngine.onForeground` -> `captureAndBroadcast(quiet = true)`, auto) and Paste button (`captureAndBroadcast(false)`, manual) | yes (`CLIP_LABEL`) | yes | yes |
| HarmonyOS on-open capture (`Index.captureOnOpen`, auto) and PasteButton (`onPasteButtonClick`, manual), both through `syncClipboard(mode)` | yes (change count, **new**: this is the missing check behind the "Paste re-sends what ClipLink just applied" finding) | yes | yes |
| iOS on-open capture (`AppModel.becameActive` -> `captureAndSend(quiet: true)`, auto), Paste button (`captureAndSend(quiet: false)`, manual) and system Paste control (`sendProviders` from `SyncedPasteControl`, manual) | yes, `holdsOwnWrite`, **now on the Paste control path too** | yes | yes |
| Share-in, drag-in, file picker, "Open in ClipLink" and window drops (Windows `ShareFilesAsync`, `ShareText`, `ShareImage`; Android `ClipLinkEngine.share`; HarmonyOS `syncShared` and `pickAndSyncFiles`; iOS `sendProviders` from a drop, `openFile`, `sendFile`, `sendImageData`, and `ShareViewController.ShareModel.sendNext`) | **no**: the content is not from the clipboard (iOS: `sendProviders` gets a `fromPasteboard` flag, and only the Paste control passes true) | no | yes, with n = the number of items in that share, taken from the history **before** the share starts |

More rules for shares, drops and file selections:

- If an item matches newest(n), it is **not signed again**, and it is reported as shared. The user's goal, having the content on their devices, is already met, so no new message string is needed. The other items go out as usual.
- Two items in one share or selection with the same print go out once.
- **Windows file drop list** (`HandleFileDropList`) works per file. If every file's print is in LastWrite.prints, that is ALREADY, which replaces today's combined-hash check. Otherwise each file goes through step 4 with n = the number of files in the selection, and only the files that do not match are published. LastWrite.prints then becomes the set of all the selection's file prints.
- **Copies made inside ClipLink's own UI** count as ClipLink writes where the platform can catch them: they set LastWrite and the own-write state. iOS: override `copy(_:)` in `SyncedAutoSizingTextView` and `SyncedScrollingText`, and route it through `ClipboardService.copyText`. Android: give the `SelectionContainer`s in `DetailScreen` and `DeviceDetailScreen` a clipboard that writes with `CLIP_LABEL` and records LastWrite. HarmonyOS cannot catch `.copyOption` copies, so rule 2 covers them.

### 1.5 Received entries and LastWrite

When a **live** entry, or an entry that may be applied (a fresh convenience item, the newest of a fresh v1 batch, a finished pending file), arrives and its contentKey is in LastWrite.prints:

- it is stored and listed as usual (rule 2 folds it with its twin);
- it is **not written to the clipboard**, and **there is no notification**. The clipboard already holds that content, or held it last as far as ClipLink knows.

This silences echoes from old peers. An installed old HarmonyOS, for example, still re-sends what it was given after a Paste tap.

### 1.6 Ordering and races

- **Reading and writing the clipboard happen one at a time.** Classifying a capture (from the read through to LastWrite being set) and applying an entry (from the write through to LastWrite being set) never overlap.
  - Windows: both already run on the watcher thread.
  - Android: one `Mutex` for both. `captureLock` becomes the clipboard lock and is also taken around `clipboard.apply` in `onEntryReceived` and `onBatchReceived` (launch on the engine scope).
  - HarmonyOS: one promise chain for `syncClipboard` and every `applyEntryToClipboard` call (in SyncManager and HistorySync, through the host).
  - iOS: everything is on the main actor. After any read that suspended (`await imagePNG()`, `ItemLoader`), check `holdsOwnWrite` again. If ClipLink wrote the clipboard in the meantime, throw the read away (ALREADY, silent).
- **Windows watcher:**
  - Read the text **once**: the published text is the text that was hashed. This fixes the double `GetText()`.
  - Set `last_sequence_num` only after the read **succeeded**. A busy clipboard is retried on the next tick, up to 3 ticks.
  - Before writing a queued peer item, check the sequence number again. If it moved, handle that local copy first, in this tick (see 6.5).
- **HarmonyOS:**
  - If the saved count is above the current one, it is stale (reboot, or the pasteboard service restarted). Treat it as -1, as iOS `discardStaleCounts()` does. This applies to both `lastSeenCount` and LastWrite.count.
  - `syncClipboard` calls `markClipboardSeen` only after a read that succeeded. A failed read calls `watcher.forget()`.

### 1.7 Storage and migration

| Platform | Where LastWrite lives | Migration |
| --- | --- | --- |
| Windows | In memory, in `ClipboardSync`. The watcher starts from the current sequence number, so nothing already on the clipboard is captured at start. | None. `_lastKnownHash` goes away. |
| Android | `cliplink_clipboard` SharedPreferences, new key `last_write` (JSON `{"prints":[…]}`). | If `last_write` is missing and the old `LAST_HASH_KEY` has a value h, prints = {`x:` + lowercase(h)}. The old key is removed the first time the record is written. The URI-clip memo (`URI_CLIP_KEY` / `URI_CLIP_HASH_KEY`) now compares against LastWrite.prints. |
| HarmonyOS | `DeviceSettings` preferences, new key `lastWrite` (JSON `{"prints":[…],"count":n}`). | None: older builds kept the hash in memory only. `lastSeenClipCount` stays as it is. |
| iOS | `UserDefaults.standard`, new key `clip.lastWrite` (JSON). `ownChangeCount` and `seenChangeCount` stay as they are. | If it is missing and `clip.lastHash` has a value h, prints = {`x:` + lowercase(h)}. Remove `clip.lastHash` on the first write. |

An `x:h` print matches a capture when h equals the capture's **raw** hash: sha256 of the exact UTF-8 text, of the picture bytes, or the lowercase file hash. That is what the old single slot held.

### Old-peer story (rule 1)

Rule 1 only changes what this device decides to send and to apply. Old peers get fewer echo entries and otherwise the same messages as before. An old peer that echoes our item back is handled by 1.5 (no clipboard write, no notification) and rule 2 (one card).

### Platform map (rule 1)

| Concern | Windows | Android | HarmonyOS | iOS |
| --- | --- | --- | --- | --- |
| Prints and norm | new `Engine/Storage/ContentPrint.cs` (static `Text`, `Image`, `File`, `Key(entry)`, `Norm`). Use `Convert.ToHexStringLower` | new `core/ContentPrint.kt` | new `storage/ContentPrint.ets`, using a sync `cryptoFramework` digest (`updateSync`/`digestSync`) so `syncedItemFor` stays sync | new `Shared/Core/Store/ContentPrint.swift` |
| LastWrite and classify | `ClipboardSync`: replace `_lastKnownHash`. Tick: classify; `setContent`: write, then the record (and the read-back print) | `ClipboardBridge.lastKnownHash` becomes `lastWrite`; `capture()` / `apply()` / `noteLocalHash()`; `ClipLinkEngine.broadcastText/Image/File` call classify (newest check through `HistoryStore`) | `ClipboardWatcher` gets the prints and count, compared in `readCurrentClipboard` after the read; `Index.syncClipboard(mode)`, `noteOwnClipboardWrite(prints)` from `copyItemContent`, `copyDeviceId`, `copyPairingPayload` and `onEntryApplied`/`onBatchApplied`/`onHeadApplied`/`onSyncApplied` | `ClipboardService` (`apply`, `copyText`, `noteSent` set the record); `AppModel.captureAndSend`, `sendProviders(fromPasteboard:)`, `send(_:quiet:skipRepeat:)`; drop `forgetLastHash()` from `delete` and `clearHistory` |
| Share and drop newest(n) | `ClipLinkEngine.Api.cs` `ShareFilesAsync`, `ShareText`, `ShareImage` (through `PublishLocal`) | `ClipLinkEngine.share` | `Index.syncShared` (also the files from `pickAndSyncFiles`) | `AppModel.openFile`, `sendFile`, `sendCopiedFile`, `sendImageData`, `sendProviders(fromPasteboard: false)`; `ShareViewController` `ShareModel.sendNext` (reads the App Group history) |
| 1.5, received matches LastWrite | `ClipLinkEngine.Peers.cs` `ApplyReceivedEntry`, the live-entry branch, `TryFulfillPendingEntry` | `ClipLinkEngine.onEntryReceived` / `onBatchReceived` | `SyncManager.applyAndReport` / `applyFileEntry`; `HistorySync.announceAnswer` / `announceBatch` / `announceHead` (host `applyToClipboard`) | `AppModel.received(_:fileURL:)` (keep the `lastSentImage` fingerprint check as well) |

## Rule 2: one card per content (the fold)

### 2.1 What the user sees

The Synced list never shows two cards with the same contentKey. When a new local copy or a received entry has the same content as a card that is already listed, the new one is listed in its usual place (a live item on top) and **the older card disappears into it**. In effect the existing card moves to the top, and the newest wins.

### 2.2 Algorithm (display only)

Run it at the point where each platform has the final display order: the session blocks and stacks first, then everything else by time.

```
fold(ordered):                        // ordered = the cards top to bottom, with stack members in their place
  seen = {}
  visible = []
  for entry in ordered:
     k = contentKey(entry)
     if k != null and k in seen: hide entry (it is a twin of the card already shown); continue
     if k != null: seen.add(k)
     visible.append(entry)
  return visible
```

- The **topmost** occurrence wins. A live item is on top, so it beats an older card. After a restart the list is in time order, so the newest timestamp wins.
- Stacks are counted from **visible** members only. A stack left with fewer than 2 visible members becomes a single card. If a stack's front member is hidden, the next visible member is the front: this is the same "front gone" rule the platforms already use for deleted or trimmed members.
- A provisional stack's `expected` count is not adjusted. A twin is simply not drawn when it lands, and the final count is the visible count.
- The card shows its visible entry's device label, time and content. Copy, Share, Save, Open and Drag all act on the visible entry.

### 2.3 Deleting a folded card

Deleting a card deletes **every** history entry with that card's contentKey. All their keys are tombstoned, and one `delete` with all the keys goes to v2 peers (chunked by 100, as today). Without this, the hidden twin would show up again as "the deleted item came back".

When a peer deletes only one key (for example an old build that shows two cards), only that entry goes. The card then shows the remaining twin, which is correct: that content is still in the history.

### 2.4 Hidden twins

Hidden twins stay in the history and in the head. They take a history slot until the normal time-based trim drops them, so the list can show fewer than 25 cards. That is accepted. A smarter trim that prefers to drop hidden twins was **rejected**. A twin dropped early would be newer than entries the device keeps, so on the next v2 connection `wanted` would fetch it again, the trim would drop it again, and so on: a re-fetch bounce.

When the visible twin leaves (trimmed, or deleted by a peer), the next twin becomes visible. HarmonyOS keeps its list incrementally, so it either keeps hidden twins in a side map (contentKey -> items) or brings them back at the next `loadHistoryIntoList`. Both are acceptable.

### 2.5 Clipboard and notifications

The fold changes neither. A live entry with a twin is applied and announced as usual, unless 1.5 applies (its content is in LastWrite).

### 2.6 Why this cannot loop, with old or new peers

- **Heads:** they are built from the history, which still holds every twin, so a device's keys are exactly what they would have been without the fold. No key is reported missing that was not missing before.
- **Wanted and re-fetch:** a twin is never dropped or skipped because of its content, so it is never asked for again.
- **Trim:** time-based as before. Content plays no part in it.
- **Tombstones:** deleting a card tombstones real keys, and every build already handles a `delete` with several keys. A v1 peer that keeps re-sending a deleted twin is ignored, as for any deleted entry.
- **v1 peers:** they send their whole history. Every entry is already known by identity, so nothing is added.
- **Old peers:** they list twins as two cards, as before. Nothing they receive is different.

### Platform map (rule 2)

| | Windows | Android | HarmonyOS | iOS |
| --- | --- | --- | --- | --- |
| Fold | `HistoryAccess.GetHistoryWithBatches`: after `groups.Order(inMemoryHistory)`, call `ContentPrint.Fold`. Remove hidden keys from `BatchOf` and `Quiet`, and drop a batch id that is left with fewer than 2 visible members. The pure fold lives in `ContentPrint.cs` so `ClipLink.Tests` can test it | `ClipLinkEngine.refreshItems`: fold `arrange(history, placement.blocks)`, and drop the `GroupTag` of a group with fewer than 2 visible members. A pure `foldTwins` lives next to `arrange` in `engine/BatchGroups.kt` | `SyncedItem` gets `contentKey` (set in `syncedItemFor`). A pure `foldTwins<T>` goes in `stack/SyncedRows.ets` and runs on every new list: `onEntryApplied`, `onBatchApplied`, `onHeadApplied`, `onSyncApplied`, `placeQuiet`, `recordLocalEntry`, `loadHistoryIntoList` | `StackPlanner.rows` (`Shared/Core/Engine/BatchGroups.swift`) folds the items before building rows. Blocks are counted from visible members |
| Delete all twins | `ClipLinkEngine.Api.cs` `DeleteHistoryEntry(key)`: expand to the twin keys, then `RemoveMany` and `BroadcastDelete(keys)` | `ClipLinkEngine.deleteItem` -> `SyncManager.deleteEntry` gets a list version (`HistoryStore.delete` for each twin, then `broadcastDelete(keys)`) | `Index.deleteItem` -> `SyncManager.deleteEntries(keys)` (the existing multi-key path) | `SyncEngine.deleteItem(id:)`: expand to the twins, then `deleted.add`, `removeFromHistory` and `broadcastDeletion(of:)` |

## Rule 3: the convenience item, and catching up on reconnect

### 3.1 Wanted keys (v2)

When the head has usable `Times`, the **"missing[0] is always wanted" exception goes**. A key is wanted only if it falls within the cap's newest entries, counting what this device holds and what is missing together. This is the `inside` set every platform already computes. Without `Times` nothing changes: every missing key, up to the cap.

- Windows `SyncRequests.Wanted`: remove `if (missing.Count > 0) inside.Add(0);`.
- Android `SyncManager.wantedKeys`: change `index == 0 || key in inside` to `key in inside`.
- HarmonyOS `SyncProtocol.wantedKeys`: change `i === 0 || kept.has(…)` to `kept.has(…)`.
- iOS `SyncEngine.wantedKeys`: change `$0.offset == 0 || kept.contains(…)` to `kept.contains(…)`.

The request plan stays the same: the first wanted key alone, marked as the convenience request, then the rest. Whether it really is a convenience item is decided by the answer (3.2).

**Android only:** when its last trim dropped entries for the character cap (`MAX_STORED_CHARS`), it passes `cap = local.size` to `wantedKeys`. Otherwise keys it evicted for size count as "inside" and are downloaded again on every connection (the Android finding about the character cap).

### 3.2 Fresh or quiet (v2 answers)

A v2 sync is **fresh** only if the answer to its convenience request added an entry C, the newest it added, with C fresh, that is, later than localNewest at that merge.

- **Fresh sync:** as today. C is the front of the session block and stack, placed on top. It goes on the clipboard subject to the 90-second window (and to 1.5), is protected from the trim once applied, and is announced. The other answers of the sync join its block quietly.
- **Not fresh** (C missing, not fresh, or the convenience answer was empty): **that answer and every later answer of the same sync are merged quietly**. Nothing goes on the clipboard, nothing is announced, nothing is placed on top, nothing is protected, and entries older than the kept 25 are dropped straight away. File bytes are still asked for (`fetch without applying`).
- A sync with no convenience request (Windows `allowConvenience: false`, Android `convenienceOwed = false`, HarmonyOS `allowFront = false`, iOS `asConvenience: false`) is never fresh.
- Expired (late) answers stay quiet, as today.

Implementation: the existing hook that is asked about the newest added entry before the trim also tests freshness. That hook is Windows `keepIf` -> `TakeConvenience`, Android `protectFront` -> `takeConvenienceSlot`, HarmonyOS `frontOk` -> `ConvenienceMemory.allows` and iOS `shouldApplyConvenience`. It returns false when the entry is not fresh, and records nothing in that case. The sync remembers that it is not fresh, so its later answers take the quiet path:

- Windows: a flag on `BatchGroups.Sync`; `ApplyAnswer` then behaves like `ApplyLate`.
- Android: a flag on `SyncState`; `handleSyncAnswer` then behaves like `handleLateAnswer`.
- HarmonyOS: a flag on `SyncLink`; `handleAnswer` then behaves like `handleLateAnswer`.
- iOS: a flag on `peerSyncs[connection]`; `applyAnswer` then behaves like the `late` branch.

### 3.3 Version 1 heads and batches

- **v1 `history_head`:** if `head.Newest` is not fresh, the head is ignored completely, as if it had failed verification. It is not added early, no stack is started and nothing is applied, and the batch then works on its own. This is in Windows `BatchGroups.HeadReceived`, Android `SyncManager.handleHistoryHead`, HarmonyOS `HistorySync.onHead` -> `applyHead`/`announceHead` and iOS `applyHistoryHead`.
- **v1 `history_batch`** (or a batch nobody asked for): N, the newest entry it adds, is applied, protected and placed on top as a block or stack **only if N is fresh**. Otherwise the whole batch is merged quietly. This is in Windows `BatchGroups.ApplyBatch` (`keepNewestAdded` only if fresh, else the `ApplyLate` behaviour) with `ClipLinkEngine.Peers.cs` `HandleHistoryBatch`; Android `handleHistoryBatch` (`Arrival.SyncByAge` spares and applies only if fresh); HarmonyOS `handleBatchV1` / `announceBatch`; and iOS `applyHistoryBatch` (`convenience` is nil unless fresh, and `registerBatch` is skipped, so these are ordinary cards by time).
- A batch that follows a head that was applied keeps today's behaviour: it joins the head's stack and applies nothing.

### 3.4 What the user notices

On reconnect, the clipboard and the top of the list only change for something **newer than anything this device already has**. An item this device trimmed, or one a partially paired peer still holds, no longer comes back to the top, overwrites the clipboard, or bounces on every reconnect.

A side effect: if a peer's clock is behind, its genuinely new copy can look older than this device's newest entry, so a reconnect stores it by time instead of applying it. Live entries are not affected by this rule.

### Old-peer story (rule 3)

The messages are the same `history_request` and `history_batch` as before. We may ask for fewer keys, which any peer answers in the usual way. Clipboard and placement decisions are local. An installed old peer still has its own "missing[0]" behaviour when it asks us. We answer as before, and because our history now stays "our 25 newest by time" (we no longer keep an old convenience item and drop a newer one), we stop feeding its bounce. The old peer's bug ends when it is updated.

## Rule 4: file hashes

- 4.1 Every **comparison** of file hashes ignores case: echo prints (`f:` + lowercase), contentKey, `PendingEntries` / `pendingEntries` / `pendingFiles` keys, "is this blob used by another entry", and fulfilling a pending entry from a local capture.
  - Windows: `FileTransferState.PendingEntries` uses `StringComparer.OrdinalIgnoreCase`.
  - Android `SyncManager.pendingEntries` and HarmonyOS `SyncManager.pendingEntries` are keyed by `hash.lowercase()`.
  - iOS already keys by `FileStore.key` (lowercase).
- 4.2 **Wire value unchanged:** `FileHash` is sent exactly as each platform sends it today. iOS stays uppercase, the others lowercase, unless 4.4 is adopted. Receivers accept either case, as today.
- 4.3 **Blob lookup on case-sensitive file systems.** Android `FileStore.exists` / `path` and HarmonyOS `FileStore.exists` / `getPath` resolve a hash to an existing blob by trying the given spelling, then all lowercase, then all uppercase. New blobs keep their current naming (the spelling they arrived with), so **no on-disk migration** is needed. A blob is deleted (release, `delete`, sweep) only when no remaining entry refers to it, comparing case-insensitively. This means Android `usesBlob` / `blobToRelease` and `sweepUnreferenced` use lowercase sets. HarmonyOS `deleteUnreferenced` already does. Windows (NTFS) and iOS (lowercase keys) need nothing here.
- 4.4 **Recommended, optional:** Android and HarmonyOS may send `FileHash` in uppercase for files they originate, as iOS already does. Every receiver accepts either case. Installed **old Windows** builds compare their own apply against an uppercase hash, so they would then stop re-publishing files received from Android or HarmonyOS. This needs 4.3 on the sender, because its own blob is lowercase. If it is not adopted, nothing else in this spec depends on it.

## Rule 5: normalising text for comparison only

- norm() is the one in Definitions: CRLF and CR become LF, then **one** trailing LF is removed. Nothing else changes: no trimming of spaces or tabs, no Unicode normalisation, no case folding.
- It is used for every text print: LastWrite, contentKey, the newest check and the fold.
- The text that is sent, stored, signed and written to the clipboard is **never** changed.
- Old peers are not affected.

**Test vectors** (every platform's unit tests use these):

| Input (escaped) | norm() | `t:` print hex |
| --- | --- | --- |
| `abc` | `abc` | `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` |
| `abc\n` | `abc` | same as above |
| `abc\r\n` | `abc` | same as above |
| `abc\n\n` | `abc\n` | `edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb` |
| `line1\r\nline2` | `line1\nline2` | `683376e290829b482c2655745caffa7a1dccfa10afaa62dac2b42dd6c68d0f83` |
| `line1\rline2\r` | `line1\nline2` | same as above |
| `  abc  ` | unchanged | `e1df0bfff7ba8ed81085b91ad7dde5d31777855835b80db6d99b56ef9f3aaa6b` |
| `日本語\r\n` | `日本語` | `77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5` |
| `a\r\n\r\n` | `a\n` | `87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0fde60c4cf25c7` |
| `\n` | (empty) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

File print vector: `f:` + lowercase(`ABCDEF…`) is `f:abcdef…`. The empty-file hash `E3B0C442…B855` (any case) gives the same print as the empty-text print's hex, but it never collides with it because of the kind prefix.

## Rule 6: other shared behaviour

### 6.1 Card time in local time

Every card, byline and detail view shows the entry's time converted from UTC (`Timestamp`) to the device's time zone, as `HH:mm` (or the platform's short-time format).

- Windows (`Format.cs`), Android (`Models.kt`) and iOS (`TimeLabel`) already do this.
- **HarmonyOS** `Index.syncedItemFor` replaces `entry.Timestamp.slice(11, 16)` with local hours and minutes from `unixMillis(canonicalTimestamp(entry.Timestamp))`.

This is display only.

### 6.2 Live entries: history first

A received live `entry` is added to the history **first**. It is applied to the clipboard (subject to 1.5) and listed **only if** the history took it: new by identity, not tombstoned, and not trimmed away at once because it is older than everything the full history keeps.

- Android and iOS already work this way.
- **Windows** (the live-entry branch in `ClipLinkEngine.Peers.cs`) moves `addToQueue` and `HandleIncomingFileEntry` after `addToHistory`. `HistoryAccess.addToHistory` returns false when the trim drops the entry straight away.
- **HarmonyOS** `SyncManager.handleMessage('entry')` calls `addToHistory` before `applyAndReport`, and only continues if it returned true. `HistoryAccess.addToHistory` returns false when the entry was trimmed at once.

### 6.3 The list never holds more than the history

HarmonyOS caps `syncedItems` at `MAX_HISTORY_ITEMS` (25) instead of 50. When `HistoryAccess` trims entries it reports them, as deletions are reported, and the list drops their cards. Other platforms already build the list from the history.

### 6.4 A file waiting for its bytes does not overwrite newer things

When a file entry is set to go on the clipboard once its bytes arrive, the device records when that was (`armedAt`) and its clipboard generation at that moment. When the bytes land, the file is applied only if all of these hold:

- the entry is still in the history and not deleted;
- the generation has not changed;
- no more than **10 minutes** have passed since `armedAt`.

Otherwise the bytes are just stored and the card is updated.

The generation is the platform's OS counter where it can read one (Windows sequence number, HarmonyOS `getChangeCount()`, iOS `changeCount`). On Android it is a counter that ClipLink increments on every clipboard write and every capture. Pending entries whose entry has left the history are dropped.

| Platform | Where |
| --- | --- |
| Windows | `PendingEntries` / `TryFulfillPendingEntry` |
| Android | `startApplying` / `tryFulfillPendingEntry` |
| HarmonyOS | `prepareFileEntry` / `tryFulfillPendingEntry` / `applyFileEntry`, and `requestMissingFiles` stops asking for dropped ones |
| iOS | `pendingFiles` `apply` flag / `fulfillPendingFile` |

### 6.5 A local copy goes out before an automatic apply

Before an **automatic** apply (not a Copy tap), a platform that can see a local copy it has not handled yet captures and publishes that copy first, then applies:

- Windows: the sequence number moved since the last tick;
- HarmonyOS: `hasUnseenChange()` with the app in front and the read permission granted;
- iOS: `hasUnseenChange` while active.

If it cannot read the clipboard, it applies as today. Android cannot see this, so nothing changes there. This fixes the Windows and iOS findings where a peer item overwrote a copy that was never synced.

### 6.6 Platform-only fixes this spec relies on

These are not shared behaviour, but each platform needs them:

- Windows: read the text once, and mark the sequence number seen only after a successful read (1.6).
- HarmonyOS: live entries are handled one at a time in arrival order (one queue per engine, or `HistorySync.enqueue`), so an older image cannot overtake a newer text.
- iOS: `sendProviders` checks own writes only for the Paste control (1.4), and the Share extension uses the newest check against the App Group history.

## Constants

| Name | Value | Where it is used |
| --- | --- | --- |
| History cap | 25 (unchanged) | trim, wanted keys, and the HarmonyOS list cap |
| Convenience window | 90 s (unchanged) | v2 fresh syncs |
| LastWrite lifetime | until replaced | 1.1 |
| Newest n for clipboard captures | 1. For a Windows file selection, the number of files | 1.3, 1.4 |
| Newest n for shares and drops | the number of items in the share | 1.4 |
| Pending file apply limit | 10 minutes | 6.4 |
| Windows busy-clipboard read retries | 3 ticks | 1.6 |

## Tests (every platform, using its existing test project)

1. **norm and print vectors** (Rule 5), and contentKey for text, image (decoded bytes), file (upper and lower case give the same key), and a malformed image or file (null).
2. **classify:**
   - auto and manual against the own-write check (including manual after a delete);
   - LastWrite match;
   - newest(1) match;
   - an A, B, A re-copy gives NEW;
   - a legacy `x:` print matches the raw hash.
3. **fold:**
   - a live twin on top hides the older one;
   - after a restart the newest timestamp wins;
   - a stack member that is a twin of a card above is hidden, and a stack left with 1 visible member becomes a plain card;
   - deleting a card returns every twin key.
4. **freshness:**
   - `wanted` without the index-0 exception (a missing key older than a full local history is not asked for);
   - a convenience answer older than localNewest is stored quietly, with nothing applied or protected, and the later answers of that sync are quiet too;
   - an empty history makes C fresh;
   - a v1 batch whose newest is not fresh is quiet;
   - a v1 head whose Newest is not fresh is ignored.
5. **hash case:** a pending entry stored under uppercase is fulfilled by a lowercase local hash; a blob is found under the other case; a blob is not deleted while an entry with the other case refers to it.
6. **6.2:** a live entry that is a duplicate, tombstoned, or trimmed at once is neither applied nor listed.
7. **6.4:** a pending file is not applied after the generation changed, or after 10 minutes.

Test files:

- Windows `windows/ClipLink.Tests` (`HistoryBatchTests.cs`, new `ContentPrintTests.cs`) and `ClipLink.EngineTests`.
- Android `app/src/test` (`SyncV2Test`, `HistoryStoreTest`, `BatchGroupsTest`, `SharedCopiesTest`, new `ContentPrintTest`).
- HarmonyOS `entry/src/test` (`HistoryBatch.test.ets`, `HistorySync.test.ets`, `SyncProtocol.test.ets`, `SyncedRows.test.ets`, new `ContentPrint.test.ets`; CRLF).
- iOS `CoreTests` (`SyncV2Tests`, `BatchGroupTests`, new `ContentPrintTests`). iOS cannot be compiled here, so keep its changes small and follow the patterns of the code around them.

## Docs to update

`docs/protocol.md`, the app-behaviour paragraphs only. The wire sections stay as they are.

- "What goes on the clipboard": only an entry newer than everything the device already has. Remove "It may be older than the newest entry the device already has". Say that older entries are stored by time, quietly.
- "How the apps list new entries": one card per content, the newest wins, and deleting a card deletes all its copies.
- Version 1: the newest new entry is applied only when it is newer than everything held.
- Step 3 of version 2: the newest missing entry is fetched only if it fits in the 25.

## Which rule fixes which finding

| Finding | Fixed by |
| --- | --- |
| HarmonyOS Paste re-sends a received item or a card Copy | 1.2, 1.3 step 1 (change count), 1.5 |
| The same copy arrives through OS clipboard sharing / the on-open capture runs before the sync | 1.3 step 4 once the entry is here; otherwise rule 2 (one card) and 1.5 on the other side |
| A re-copy always makes a new item / a single "last hash" | 1.3 (deliberate re-copies still go out) and rule 2 (one card, at the top) |
| HarmonyOS re-sends after its counter reset or a stale saved count | 1.6 (stale count) and 1.7 (persisted LastWrite) |
| iOS Paste control skips the own-write check / a received picture file comes back as a PNG | 1.4 (`holdsOwnWrite` on the Paste control) and 1.6 |
| HarmonyOS on-open capture reads the item the sync just wrote | 1.6 (clipboard reads and writes one at a time) |
| Windows echoes a received picture after a re-announce or a failed write | 1.2 read-back print, 1.6 |
| CRLF and trailing newlines | rule 5 |
| HarmonyOS share plus on-open capture / Android share plus capture / iOS share extension plus capture | 1.3 step 4 and 1.4 newest(n) |
| Windows, Android and iOS: an old item comes back at the top and onto the clipboard on reconnect; Android character-cap re-fetch | rule 3 (3.1 Android cap) |
| No content de-duplication for peer echoes (Windows, iOS) | rule 2 and 1.5 |
| File hash case (Windows echo, Android pending entries) | rule 4 |
| Windows reads the text twice / a busy clipboard loses the copy / an apply overwrites a copy | 1.6 and 6.5 |
| Android `apply()` sets the hash before writing | 1.2 (only after the write succeeds) |
| Android detail-screen copy / iOS system-menu copy | 1.4 (ClipLink's own UI copies) and rule 2 |
| iOS received item overwrites a copy that was never synced | 6.5 |
| HarmonyOS UTC card time | 6.1 |
| HarmonyOS list of 50 against a history of 25 | 6.3 |
| HarmonyOS live entry listed before the history accepts it | 6.2 |
| HarmonyOS stale pending file apply | 6.4 |
| HarmonyOS live entries handled out of order | 6.6 |
