# Protocol

How ClipLink devices find each other, connect and share. This page is for people who build or test ClipLink. It describes how the current builds talk to each other, and how they keep older builds working.

All four apps (Windows, Android, HarmonyOS and iOS) follow this page, which is why they work together. The message shapes are written here, so there is no separate schema file. For who is trusted and why, see [security](security.md). For how the apps are built, see [architecture](architecture.md).

**Contents**

- [The short version](#the-short-version)
- [Words used on this page](#words-used-on-this-page)
- [Finding devices](#finding-devices)
- [Connecting](#connecting)
- [Messages](#messages)
- [Sharing history](#sharing-history)
- [Files](#files)
- [Device names](#device-names)
- [Pairing link, unpair and quiet time](#pairing-link-unpair-and-quiet-time)
- [Fingerprint](#fingerprint)
- [A handshake from this device itself](#a-handshake-from-this-device-itself)
- [Limits at a glance](#limits-at-a-glance)
- [Not built yet](#not-built-yet)

## The short version

1. Each device announces itself on the local network with a short message called a **beacon**.
2. Two devices that trust each other open a connection on port 49000.
3. The first message each way, the **handshake**, proves who they are and sets up encryption.
4. After that, every message is encrypted. New copies are sent as they happen. When the connection opens, each device tells the other what it has, and only the missing items are sent. Deleting an item deletes it on every paired device.

## Words used on this page

| Word | What it means |
| --- | --- |
| Peer | The other device on a connection |
| Beacon | A short announcement sent to the whole local network, saying "I am here" |
| Handshake | The first message each device sends on a new connection. It is not encrypted |
| Device id | The device's public key, written as text (Base64). It never changes |
| Entry | One item in the history: some text, a picture or a file |
| Base64 | A way to write any bytes as plain text |
| SHA-256 | A way to boil any data down to 32 bytes that identify it. Shown as 64 hex digits |
| Line | One message. Messages are sent as lines of text, one per message |
| Key | What identifies one entry: its signature. It is the same on every device |
| Sync version | Which way of sharing history a device speaks. 1 is the older way, 2 is the newer way |

## Finding devices

**Beacons.** Each device sends a beacon by UDP broadcast to port 49000. The Windows app sends one every 2 seconds. The beacon is one line of text, with fields separated by colons:

```
{tcpPort}:{deviceId}:{proof|-}:{address|-}:-:{name|-}
```

| Position | Field | What it holds |
| --- | --- | --- |
| 0 | `tcpPort` | The port this device accepts connections on |
| 1 | `deviceId` | This device's public key (Base64) |
| 2 | `proof` | The passcode proof, or `-` if no passcode is set |
| 3 | `address` | This device's own address outside the local network (a Tailscale address), or `-` |
| 4 | reserved | Always `-`. Receivers ignore it. Older builds wrote `1` here while their pairing screen was open |
| 5 | `name` | The device name, as Base64 of its text (with `=` padding), or `-` if not known |

- A beacon never contains clipboard content.
- A sender always writes all six fields, with `-` in position 4. The Base64 alphabet has no colon, so splitting on `:` is safe.
- A receiver ignores position 4 whatever it holds, so older builds (which may send `1`) and newer ones still hear each other.
- A receiver may get fewer than six. A missing, empty or `-` name, bad Base64 or bad text all mean "name not known". A bad name never makes the receiver throw the whole beacon away.
- Nobody checks a beacon, so anyone on the network can send one. The name in a beacon is only shown, and never saved. See [Device names](#device-names).

**When broadcast is blocked.** iOS often does not allow broadcast. The iPhone app also sends beacons straight to the addresses around its own on the local network, and the other apps hear them like any other beacon.

**Off the local network.** Beacons do not cross networks. A device that knows another device's address (typed in, in a pairing code, or sent in the beacon of a device it trusts) can connect to it directly. The Windows app retries a trusted device's saved address every 30 seconds.

## Connecting

**The connection.** Devices talk over TCP on port 49000.

**Who connects to whom.** Only one of two devices opens the connection: the one whose device id sorts after the other's. That way the two never open two connections at once.

**Who a device dials.** A device dials a device it trusts, at the address its beacon came from or one saved from an earlier connection, or an address the user gave it (typed in, or in a pairing code). It never dials a stranger just because it heard its beacon. The one exception is the passcode: a beacon whose proof matches this device's passcode makes its sender trusted on the spot (see [security](security.md)), and it is then dialled like any trusted device.

**Trust can be one-sided.** A device you have just trusted may not trust you yet. If its id sorts higher, it would wait for you to connect while you wait for it, and your pairing request would never arrive. So a trusted device that has not connected 8 seconds after it was first heard is connected to anyway, whatever the order, and again every 30 seconds while it stays unconnected. A device that already trusts you will have connected long before, so this does nothing there.

**The handshake.** The first line each way is JSON, and it is not encrypted:

```json
{"EphemeralPublicKey":"…","IdentityPublicKey":"…","Signature":"…","PassphraseProof":null,"DeviceName":"Colour's Laptop","Protocol":2,"Caps":["file-ack"]}
```

| Field | What it holds |
| --- | --- |
| `EphemeralPublicKey` | A key made fresh for this connection only |
| `IdentityPublicKey` | The device id |
| `Signature` | The device's signature over `EphemeralPublicKey`, which proves the device really owns that id |
| `PassphraseProof` | The passcode proof, or null if no passcode is set |
| `DeviceName` | The device name, as plain text, or missing if not known |
| `Protocol` | The sync version this device speaks (2 now). Missing, null or anything below 2 means 1 |
| `Caps` | A list of short names for other things this device can do. Missing, null or not a list means none. A name that is not text, or that the receiver does not know, is ignored. Names are compared exactly. Today there is one: `file-ack` (see [Files](#files)) |

A receiver ignores handshake fields it does not know, so older builds simply do not see `Caps`. A feature named in `Caps` is used on a connection only when both handshakes name it. The handshake is not signed beyond the fresh key, so someone on the path could remove a name; that only turns the feature off, back to how older builds work.

An acceptor writes its own handshake first and then reads the connecting device's, so a connecting device always sees the acceptor's handshake before the acceptor has decided anything.

**Encryption.** After the handshake the two sides combine their fresh keys into a shared secret. Its SHA-256 is the session key. Every later line is the Base64 of a 12-byte random nonce, a 16-byte tag and the encrypted message, using AES-256-GCM. A line that cannot be decrypted ends the connection. Details of why this is safe are in [security](security.md).

**Staying connected.** Each side sends a heartbeat (a short encrypted ping) regularly. The Windows app sends one every 5 seconds, and closes a connection that has received nothing at all for 15 seconds.

**Waiting and connected.** A device you trust is linked as soon as the handshake is done, but the other device may still be asking its user. While it waits, it sends nothing. So every app shows such a device as *waiting for it to accept*, not *connected*, and counts a device as connected only once a line from it has been decrypted.

**Refusals.**

- A device that has blocked your key reads your handshake, closes the connection and tells you nothing. To you it looks like a connection that came up and dropped at once, the same as a device that has stopped trusting you.
- A stranger that is not blocked can connect at any time, and is held for its user (see [security](security.md)). You see nothing until it is trusted, or the request is ignored or runs out.

**If a handshake does not arrive.** A connection that never sends its handshake is closed after 10 seconds (15 on Windows), so one stranger cannot keep a connection open.

## Messages

After the handshake, every message is an **envelope**, a small piece of JSON that says what it is:

```json
{"Type":"entry","Payload":"…"}
```

`Payload` is the message itself, written as text. A receiver skips a `Type` it does not know, and ignores fields it does not know.

| `Type` | When it is sent | What `Payload` holds |
| --- | --- | --- |
| `entry` | Right after something is copied on this device | One entry |
| `history_head` | Once, when a connection opens | The keys of this device's history and its deleted keys (see [Sharing history](#sharing-history)) |
| `history_request` | After a `history_head`, for the entries it is missing | `{"Keys": ["…"]}` |
| `history_batch` | In answer to a `history_request`. With an older device: once, when a connection opens | A list of entries |
| `delete` | When entries are deleted on this device | `{"Keys": ["…"]}` |
| `file_request` | When a device needs a file's bytes | `{"FileHash": "…"}` |
| `file_chunk` | In answer to `file_request` | One piece of a file (see [Files](#files)) |
| `file_ack` | After a `file_chunk` is written or ignored, only when both handshakes named `file-ack` | `{"FileHash": "…", "ChunkIndex": 7}` (see [Files](#files)) |
| `unpair` | When a device is removed | `{}` |

The heartbeat is not an envelope. It is the text `__ping__`, encrypted like any other line, and the receiver does not treat it as data.

**An entry** has five fields, and a picture can have a sixth:

| Field | What it holds |
| --- | --- |
| `Content` | The text; or a picture as Base64; or, for a file, a small description (see [Files](#files)) |
| `Type` | `text`, `image` or `file` |
| `DeviceId` | The device that made it |
| `Timestamp` | When it was made, in UTC, like `2026-10-13T14:20:05.1230000Z` |
| `Signature` | The maker's signature (Base64) |
| `Name` | Optional, for `image` only: the picture's original name, as a suggested file name (see below). Left out when it is not known |

The signature is over the text `Content:Type:DeviceId:Timestamp`, with the timestamp written as above. A receiver accepts an entry only if the signature is valid and the maker is a device it trusts. `Name` is not part of the signature.

**A picture's name.** A picture copied as a picture has no name of its own. A screenshot has only pixels. But when you use "Copy image" in a browser, or in some other apps, the clipboard also says where the picture came from. So the Windows app looks, in this order, at the file it came from (a one-file `CF_HDROP`, `FileNameW`, `FileName`), a virtual file (`FileGroupDescriptorW`), the copied HTML (`HTML Format`, when the copied part holds exactly one `<img>`) and the address (`UniformResourceLocatorW`, `UniformResourceLocator`). It asks the address only when the HTML holds no `<img>` at all, and uses it only when its last part ends in a picture's extension (such as `.png`, `.jpg` or `.webp`), because next to a picture's HTML, or for a linked picture, the address can be the page's or the link's. It takes the last part of the path or address, decoded, without the query or fragment. It skips `data:` and `blob:` addresses and names without a letter, and cuts the name to a safe length. It leaves the extension out, since it always sends the picture as PNG. So `<img src="https://example.com/a/after-like.png?x=1">` gives `"Name":"after-like"`. A picture dropped on the window gets its name the same way.

- **Optional.** A sender leaves the field out when it does not know a name, so an entry without one is exactly what older builds send. It is only for `image`. A receiver ignores it on any other type, and does not store or pass it on there (Windows reads it as no name on a `text` or `file` entry; HarmonyOS drops it).
- **Not signed, and why that is fine.** The signature covers only `Content:Type:DeviceId:Timestamp`, so adding the field changed nothing for older builds and the key stays the signature. The name is only a suggested file name. It travels like every message, inside the encrypted session, from a device that proved who it is in the handshake. A device that relays the entry could change or drop it, but it cannot change the picture.
- **Untrusted text.** A receiver treats `Name` like a received `FileName`: it keeps only a safe last part, with no folders, no control characters or invisible characters that disguise a name, no half characters (a surrogate without its pair), nothing Windows refuses in a file name, not a reserved device name (`CON`, `PRN`, `AUX`, `NUL`, `CONIN$`, `CONOUT$`, `COM1`–`COM9`, `LPT1`–`LPT9`, and `COM`/`LPT` with a superscript ¹, ² or ³), and not too long. If nothing usable is left, it uses its own name, such as "Image from <device> <date time>". It never takes the extension from `Name`. It picks the extension from the picture's bytes, and replaces any picture extension the name has.
- **Stored and passed on.** The name stays with the entry: in history on disk, in `history_batch` answers and in the `Newest` entry of a version 1 `history_head`. Windows and HarmonyOS keep it across a restart and pass it on. Windows cleans an incoming name before it keeps it. An incoming `Name` that is not a string, or a string that is not valid text (an escaped surrogate without its pair such as `"\ud800"`, or bytes that are not UTF-8), counts as no name on Windows and never costs the entry or the rest of a `history_batch`. A device that keeps a name still never stores or sends one with half characters, because a JSON reader may refuse the whole message over such a string.
- **Duplicates, deletes and keys do not change.** The key is still the signature. The same entry with and without a name is the same entry, and is kept once (whichever copy came first).
- **Older builds.** Every build reads only the entry fields it knows, so an entry with a name works unchanged on all of them. Windows (System.Text.Json) skips properties it does not know. Android (`ClipboardEntry.fromJson`, `org.json`) and iOS (`ClipboardEntry.from` in `WireModels.swift`) read the five fields by name and rebuild the entry, so they drop the name when they store or relay the entry. HarmonyOS 2.2 and older keep the parsed object as it came (`JSON.parse`), so they may store and relay the name untouched, but never read it.

**Removing a device.** A device that is removed sends `unpair` over the encrypted link. A receiver that trusts the sender drops it from its trust list, closes the connection and stops reconnecting to it. A receiver that does not trust the sender does nothing. Only a device can say this about itself, since the message arrives over its own proven connection and changes only whether the receiver trusts that device.

## Sharing history

**Two sync versions.** The handshake says which sync version a device speaks. A connection uses version 2 only when both devices say 2. If either one says nothing (an older build), the connection uses version 1, which is described at the end of this section. So nobody has to update at the same time as anyone else.

**Version 2: only what is missing.**

1. **The head.** When a connection opens, each side sends a `history_head`. It is small, because it holds no content, only keys:

```json
{"Keys":["…","…"],"Times":[1730000000123,1730000000100],"Deleted":["…"]}
```

| Field | What it holds |
| --- | --- |
| `Keys` | The key of every entry in this device's history (up to 25), newest first |
| `Times` | When each of those entries was made, in milliseconds since 1970 (UTC), in the same order. Optional |
| `Deleted` | The keys of entries the user deleted on this device, most recently deleted first, at most 500. May be empty |

A head is sent even when the history is empty, since the deleted list can matter on its own.

2. **Deletes first.** The receiver removes every entry listed in `Deleted` and remembers those keys as deleted.
3. **What is missing.** The receiver picks the keys it does not have, has not deleted and is not already asking another device for. Only entries that would still fit in its own 25 are worth fetching, and it uses `Times` to see which. The newest missing entry is fetched only when it fits in the 25 too (older builds always fetched it). Without `Times`, it fetches every missing entry.
4. **Two requests.** It sends two `history_request` messages one straight after the other. The first asks only for the newest missing entry, so that one arrives fast. The second asks for all the other wanted ones. A request holds at most 100 keys.
5. **The answers.** The other device answers each request with one `history_batch`: the entries it has for those keys, newest first (an empty list if it has none), in the same order as the requests. A request that nobody answers within 90 seconds is given up on, and the next connection tries again. If its answer still arrives later, the entries are added quietly: nothing goes on the clipboard and there is no notification.
6. **Checks.** Every entry is checked as always: a valid signature, a maker the device trusts, and not deleted here.

**What goes on the clipboard.** Only the newest missing entry, the one in the answer to the first request, can go on the clipboard, and only when it is newer than everything the device already has. If it is not, that answer and the rest of the sync are added by time, quietly: not on the clipboard, not at the top, no notification. The rest are only added to the history. An entry copied live is put on the clipboard as before. If two devices answer at the same time, the clipboard only changes for an entry that is newer than the one it was just set to (within the last 90 seconds), so it ends on the newest.

**Deleting.** When you delete entries on a device, it sends `delete` with their keys to every device connected with version 2. Those devices delete the entries and remember the keys. A device that was off hears about it in the `Deleted` list of the next head it gets. Any paired device can delete any entry, and a deleted entry does not come back: a device remembers deleted keys (up to 2000) and skips them whenever they are offered again. A device that gets `delete` does not pass it on, and it never changes the clipboard.

**How the apps list new entries.** This part is what the apps do, not what goes over the wire. ClipLink is for having what you copied on your other devices at hand, not for showing a timeline.

- An entry copied live goes to the top.
- The new entries a device gets when it connects show as one stack card, with the newest missing entry in front. Opening the stack puts the others directly below that entry.
- The list goes back to time order the next time the app starts.
- One card per content: when several entries hold the same text, picture or file, only the newest shows (text is compared ignoring CRLF against LF and one trailing newline). Deleting the card deletes every copy, in one `delete`.
- An entry whose content the device itself last put on its clipboard is listed but not put on the clipboard again, and there is no notification.
- While the app is open, the entry in front is not trimmed away by the 25 limit. The oldest of the others goes instead.

**Version 1: the whole history (older builds).** Each side sends its whole recent history (up to 25 entries) as a `history_batch` when the connection opens. The receiver adds what it does not already have, and skips entries the user deleted. The newest new entry goes on the clipboard only when it is newer than everything the device already had; otherwise the batch is added quietly, by time, and a `history_head` whose newest entry is not newer is ignored. When the history has two or more entries, a small `history_head` goes first, with `{"Newest": <the newest entry>, "Keys": ["…"]}`. It lets the receiver show the newest entry and how many are coming while the large batch is still on its way. A build that does not know `history_head` skips it. Deletes are not shared in version 1: a device only remembers what the user deleted on that device. A newer device talks to an older one in version 1, and never sends it `history_request` or `delete`.

**The rest of sharing.**

- **When something is copied**, the device signs it and sends it as an `entry` to everyone it is connected to.
- **A device that was off** catches up from the next device it connects to, which is why no device has to be on all the time.
- **No winner.** If two devices copy at almost the same moment, both entries are kept, ordered by timestamp. See [Not built yet](#not-built-yet).

## Files

A file's entry does not hold the file. `Content` is a small description:

```json
{"FileName":"photo.jpg","FileHash":"…64 hex digits…","FileSize":123456}
```

`FileHash` is the SHA-256 of the file's bytes, in hex (compare it ignoring upper and lower case), and `FileSize` is their length. The bytes travel separately.

**Asking for a file.** A device that does not have the bytes sends `file_request` to every device it is connected to. A device that has them answers with `file_chunk` messages:

```json
{"FileHash":"…","ChunkIndex":0,"IsLast":false,"DataBase64":"…"}
```

The receiver checks the SHA-256 of what arrived against `FileHash`, and throws the bytes away if they differ. A received name is cut down to a safe last part, so a file can never be written anywhere else.

**Sending a stream of chunks.** A sender sends a file as one stream of `file_chunk` messages on one connection. `ChunkIndex` starts at 0 and goes up by 1, and only the last chunk has `IsLast` set to true. A sender never carries on from the middle. If a stream is cut off, or the file is asked for again, it starts again at 0. It never sends the same file to the same device twice at once, and ignores a `file_request` for a file it is already sending to that device.

**Flow control.** A sender used to send chunks as fast as the network took them. A HarmonyOS phone cannot pause its socket, so whatever it could not handle yet piled up in memory, and a 290 MB file from Windows ran it out of memory. So when both handshakes name `file-ack`:

- The receiver sends `file_ack` once it is done with a chunk: after the chunk is written (and added to the hash), or straight away when it ignores the chunk or cannot use it. `ChunkIndex` is that chunk's index and `FileHash` is the chunk's `FileHash` as it arrived. Every chunk gets one, even one that is ignored; otherwise its sender would stall.
- An ack counts for every chunk up to and including `ChunkIndex`, so a sender takes the highest one. An ack for a chunk it has not sent, or an older one, changes nothing.
- The sender keeps at most **8 chunks** (2 MiB of file) sent but not yet acknowledged, and waits for an ack before sending more. This holds for every stream: a file sent the moment it is copied, and one sent because it was asked for. Each stream counts on its own, so a stream started again from chunk 0 starts with nothing unacknowledged.
- If chunks are waiting and no ack comes for **30 seconds**, the sender gives the stream up, as if it had been cut off. The connection stays open, so the receiver is not told: it sees no more chunks. So Windows and HarmonyOS give up a stream from a sender that named `file-ack` once nothing new has come for **45 seconds** (the 30 plus some slack) and every chunk that did come is written, and then ask for the file again as for any stream that broke off (see below). A stream from an older sender is left alone: it never stops part-way while the connection is open. (A peer that sends nothing at all is closed after 15 seconds by the heartbeat anyway.)
- An ack for a file the sender is not sending to that device, or has finished sending, is ignored.
- Acks are encrypted like every other message. They only pace the sender. They never change what is stored: the bytes are still checked against `FileHash` as always.

Eight chunks are enough to keep the network busy (at 50 MB/s and a Wi-Fi round trip of 10 to 30 ms, about 0.5 to 1.5 MB is on its way at any moment), while a receiver never has more than about 4 MB of lines waiting for it.

With an older device nothing changes, in either direction. A device whose handshake does not name `file-ack` is never sent `file_ack` (older builds skip it anyway, as an unknown `Type`), and its streams are not paced: chunks go to it as fast as the network takes them, and chunks from it arrive as fast as it sends them. That is why HarmonyOS still keeps its limit on lines waiting to be read (below) for older senders.

**Receiving a stream.**

- A receiver takes one stream for each file. Windows, Android, iOS and HarmonyOS keep the first sender's stream and ignore other senders' chunks for that file until it is stored or the stream is given up. (HarmonyOS 2.2.1 and older wrote each sender's stream to its own file and kept whichever finished first. Senders need not tell the two apart.)
- Chunk 0 starts the file again from empty, even in the middle of that sender's stream. A receiver ignores a stream it did not see start (a chunk other than 0 with no stream under way from that sender). It gives up on a stream with a gap and throws its bytes away, and does the same with any streams that were open when a connection closed.
- A receiver asks again for a file that a history entry still needs. It asks each device that connects, for every file entry it is missing bytes for. It also asks its other devices when a stream fails (a gap, a wrong hash, a closed connection, or a paced stream that stopped for 45 seconds), and asks a sender again when a stream it ignored ends and nobody else is sending that file. After failures it only asks a few times in a row (3 on Windows, Android and HarmonyOS), so a device with a bad copy is not asked for ever. HarmonyOS also stops asking for a file, until the app starts again, once its connection has twice been closed while that file came in faster than the phone could take it in (more than 128 MB of lines waiting to be read behind the one being read). Only an older sender, one without `file-ack`, can get that far ahead.

**The description must match the bytes.** A file on the sending device can change while it is being read (a download, a recording, a document saved again). So the Windows app works out the hash again as it stores the file, and does not send the file at all if the result is different. Stored under the wrong hash, those bytes would fail every receiver's check, and would also stand in for the real file on every later copy.

### Empty files

A file with no bytes has nothing to send. Its entry has `FileSize` 0 and, as `FileHash`, the SHA-256 of nothing: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (Windows writes it in capitals).

- A receiver makes the empty file itself and uses the entry straight away. It never sends a `file_request` for it. Only that exact pair counts. Size 0 with any other hash, or the empty hash with any other size, is fetched like any other file.
- A sender that is asked for it anyway answers with exactly one `file_chunk`: `ChunkIndex` 0, `IsLast` true and `DataBase64` empty (`""`).
- A receiver that has already made the file can still get that chunk. It must accept it or ignore it, without an error.

## Device names

Every device has a display name: the name the user typed in Settings if there is one, otherwise the device's own name from the operating system. It travels in three places, and it is optional in all of them.

**Cleaning a name.** A sender trims the name and cuts it to 64 characters, counting each Unicode code point as one (an emoji counts as one, and a pair of UTF-16 units is never split). A name from another device is untrusted text, so a receiver first removes every control character (U+0000 to U+001F and U+007F to U+009F) and the invisible direction and zero-width characters (U+061C, U+200B to U+200F, U+202A to U+202E, U+2066 to U+2069 and U+FEFF). Then it trims and cuts to 64 characters the same way. An empty result means "name not known". The phone apps do this before they store or show a name. The Windows app trims and cuts a name when it arrives, and removes those characters wherever it shows it.

**Where a name travels.**

| Where | How |
| --- | --- |
| Beacon | The sixth field, as Base64 (see [Finding devices](#finding-devices)) |
| Handshake | The `DeviceName` field, as plain text |
| Pairing code | The `Name` field of the pairing payload: `{"PublicKey":"…","Address":"100.64.0.1","Name":"Colour's Laptop"}` |

**What a receiver saves.** Nobody checks a beacon, so a name from a beacon is kept in memory only. It is shown for a device that is not trusted yet, and for a trusted device that has no saved name. It is never written to disk, on any platform.

A name in a handshake is not fully checked either: its signature covers only the fresh key, so someone who recorded a trusted device's handshake could replay it with a different name. A replayer cannot work out the session key, though, so it cannot send a line that decrypts. The only lines it could return are the receiver's own, and each side remembers the random nonces it has sent, so a line sent back to its sender is spotted and the connection is closed. So a handshake's name is **saved only once its connection has proved itself**:

- It may be kept in memory for that live connection and shown at once.
- It is written to the trust list only after the first encrypted line on that connection has decrypted correctly and is not one of the receiver's own lines sent back. This happens once per connection, and it updates the saved name if the new one is not empty and is different.
- Accepting a pairing request, or trusting a device by passcode, creates the trust record without a name. The first connection fills the name in.
- A connection that never proves itself, such as a replayed handshake, never saves a name.

In normal use the first line is the other device's `history_batch`, which every app sends as soon as it registers the connection. So the name is saved moments after connecting (or with the first heartbeat, within 5 seconds). An unknown name never replaces a known one, and saving a name never changes the saved address. A rename is saved at the next connection, not at the next beacon.

This stops replayed handshakes. It does not stop someone on the network path (ARP spoofing, say) who changes the name in a real handshake as it goes by. Closing that needs the name to be signed, which every app would have to change at the same time (see [security](security.md)).

## Pairing link, unpair and quiet time

**The pairing link.** The QR code on every platform is a link: `https://cliplink.uaena.io/pair/#<info>`. `<info>` is the pairing payload (shown under [Device names](#device-names)) as UTF-8 JSON, written as Base64url with no padding. A camera or scanner that reads it opens ClipLink if it is installed (App Links on Android and HarmonyOS, Universal Links on iOS, using the files in the website's `/.well-known/` folder), and the website, with the downloads, if it is not. The information is after the `#`, so it is never sent to a server.

Every place that takes pairing text (a scan, the address box, a paste) accepts the link or the bare JSON: `http` or `https`, the host in any case, and `/pair` with or without the last slash. A link whose information cannot be read is treated as plain text. "Copy pairing info" still copies the bare JSON. An app that a link opened starts pairing as if the code had been scanned inside the app, and nothing is trusted until both devices agree. The four apps (`PairingLink.cs`, `PairingLink.kt`, `PairingLink.ets` and `PairingLink.swift`) share one test example, in the Android and iOS tests.

**Unpair.** See [Messages](#messages). Without it, trust that exists on only one side makes the trusting device keep reconnecting for ever, and each connection used to raise a new pairing request on the other. `unpair` is also sent, where a link can still send, when a pairing request is ignored.

**Quiet time.** Each app keeps a short quiet time for each device, in memory only:

- For 2 minutes after the user taps Ignore on a request, a connection from that device that would only be a pairing request is closed with no prompt. This also covers a device that does not act on `unpair`. (A request that merely ran out without an answer sets no quiet time, since nobody refused it.)
- A device that was removed while it was **not connected** is told on its next connection, once and with no prompt, and is then let go.
- Removing a device over a live connection sets no quiet time at all: a real request from that device afterwards, such as the user trusting this device from there, must get through.
- Opening the pairing screen, pairing by address or code, and trusting the device all end any quiet time.

(`RequestQuiet` in each app.)

## Fingerprint

Device ids are Base64 P-256 public keys, and the first 36 characters are the same on every device. So the start of an id cannot tell two devices apart. Wherever a short form of an id is shown (the title of a device with no name, pairing prompts, log lines), every app shows its **fingerprint** instead: the first 4 bytes of the SHA-256 of the id's UTF-8 bytes, as capital hex, with `·` (U+00B7, a middle dot) between the two halves.

- As a title it reads `Device XXXX·XXXX`. A pairing prompt may show it on its own after the word "ID".
- Test example: the SHA-256 of `abc` begins `ba7816bf`, so the id `abc` shows as `Device BA78·16BF`.
- Each device shows its own fingerprint on its Settings (Windows) or Me (phones) screen, so you can compare it with the one in another device's pairing prompt.
- It is for showing only and is never sent. It is only 32 bits: enough to tell your own devices apart and to spot a copied name, but a determined attacker could make a key with a matching fingerprint (see [security](security.md)).

## A handshake from this device itself

A device can reach its own listener: its own address typed in to pair, a trusted device's saved address that now belongs to this device, or something on the path sending its connection straight back. The handshake that answers then carries its own `IdentityPublicKey`. Every app refuses such a connection on both sides (when it connects out and when it accepts), straight after reading the handshake and before any check of trust, passcode or pairing. Two of a device's own connections joined that way would share one session key, so each would take the other's lines as proof of the connection, and the device's own passcode proof would speak for its own id.

The check compares the keys, not just their text. A handshake whose key is the same text as the receiver's own id is refused. So is one that is different text but is the same key. Otherwise something that rewrote the id (a space inside the Base64, say) could turn the device's own connection into a pairing request from itself.

| App | How it compares the keys |
| --- | --- |
| Windows | Writes the decoded key out one standard way (DER, as Base64 with padding) and compares that with its own id |
| Android and iOS | Compare the decoded keys themselves |
| HarmonyOS | Compares the bytes the two ids decode to. This catches a different spelling of the same bytes (spaces in the Base64), but not a different encoding of the same key (a compressed point, say) |

Beacons and pairing codes (or a bare id given to trust) are also checked against the device's own id, and never add it, trust it or connect to it. Windows and iOS compare these by key. Android and HarmonyOS compare them as text, so a fake beacon with a rewritten copy of the device's own id shows up there as a nearby device, and the user could trust it. That only adds a row: a handshake under that id is still refused as this device's own (within the HarmonyOS limit above).

When the Windows app connects out, it can tell "that address is this PC" from a refusal. Pairing with its own address says so ("That's this PC."). If the address it connected to is the one saved for a trusted device, that device is no longer there (the router gave this PC the device's old address, say), so Windows clears the saved address instead of connecting to itself on every retry. It only ever clears a saved address this way, never because of where a beacon came from, since a beacon is unchecked and must not be able to wipe a real address. A cleared address is learned again the next time that device connects.

## Limits at a glance

| What | Limit |
| --- | --- |
| History | 25 entries |
| Keys in one `history_request` or `delete` | 100 |
| Deleted keys sent in a head | 500 (a device remembers up to 2000) |
| A request nobody answers | Dropped after 90 seconds |
| A name | 64 characters |
| A picture's `Name` (Windows) | 80 characters and 160 bytes of UTF-8. Cut, never refused |
| A file | 1 GB |
| File chunks sent and not yet acknowledged (`file-ack`) | 8 (2 MiB of file). No ack for 30 seconds: the sender gives the stream up. Nothing new for 45 seconds: the receiver does too |
| Lines waiting to be read on HarmonyOS, once a device is trusted | 128 MB behind the line being read next (which is not counted, so one line up to the line limit still gets through), then the connection is closed |
| Handshake time | 10 seconds (15 on Windows) |
| A handshake line, before anything is trusted | 8 KB on Android, 64 KB on HarmonyOS |
| Any other line | 64 MB on Android, 192 MB on HarmonyOS and iOS. Windows has no limit yet |
| Heartbeat (Windows) | Every 5 seconds. A silent connection is closed after 15 seconds |
| Pairing request held | 3 minutes, one at a time |
| Quiet time after Ignore | 2 minutes |
| Reconnect to a saved address | Every 30 seconds (Windows) |

## Not built yet

The things we want to add next are in the **To do** list in the [main README](../README.md#to-do). Two of them touch this page: a switch to hide a device from beacons, and syncing between devices that are not on the same network.
