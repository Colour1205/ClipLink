# Protocol

How ClipLink devices find each other, connect and share. This page is for people who build or test ClipLink. It describes version 2.0.

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
4. After that, every message is encrypted. New copies are sent as they happen, and the recent history is swapped when the connection opens.

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
{"EphemeralPublicKey":"…","IdentityPublicKey":"…","Signature":"…","PassphraseProof":null,"DeviceName":"Colour's Laptop"}
```

| Field | What it holds |
| --- | --- |
| `EphemeralPublicKey` | A key made fresh for this connection only |
| `IdentityPublicKey` | The device id |
| `Signature` | The device's signature over `EphemeralPublicKey`, which proves the device really owns that id |
| `PassphraseProof` | The passcode proof, or null if no passcode is set |
| `DeviceName` | The device name, as plain text, or missing if not known |

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
| `history_batch` | Once, when a connection opens | A list of entries |
| `file_request` | When a device needs a file's bytes | `{"FileHash": "…"}` |
| `file_chunk` | In answer to `file_request` | One piece of a file (see [Files](#files)) |
| `unpair` | When a device is removed | `{}` |

The heartbeat is not an envelope. It is the text `__ping__`, encrypted like any other line, and the receiver does not treat it as data.

**An entry** has five fields:

| Field | What it holds |
| --- | --- |
| `Content` | The text; or a picture as Base64; or, for a file, a small description (see [Files](#files)) |
| `Type` | `text`, `image` or `file` |
| `DeviceId` | The device that made it |
| `Timestamp` | When it was made, in UTC, like `2026-10-13T14:20:05.1230000Z` |
| `Signature` | The maker's signature (Base64) |

The signature is over the text `Content:Type:DeviceId:Timestamp`, with the timestamp written as above. A receiver accepts an entry only if the signature is valid and the maker is a device it trusts.

**Removing a device.** A device that is removed sends `unpair` over the encrypted link. A receiver that trusts the sender drops it from its trust list, closes the connection and stops reconnecting to it. A receiver that does not trust the sender does nothing. Only a device can say this about itself, since the message arrives over its own proven connection and changes only whether the receiver trusts that device.

## Sharing history

- **When a connection opens**, each side sends a `history_batch` with its recent history (at most 25 entries). The receiver adds what it does not already have, and skips entries the user deleted.
- **When something is copied**, the device signs it and sends it as an `entry` to everyone it is connected to.
- **A device that was off** catches up from the next device it connects to, which is why no device has to be on all the time.
- **No winner.** If two devices copy at almost the same moment, both entries are kept, ordered by timestamp. See [Not built yet](#not-built-yet).
- **Deleted entries.** If you delete an entry on a device, that device remembers it (up to 2000 deletions on Windows), so a peer's history cannot bring it back. Nothing about a deletion is sent to other devices.

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

**Receiving a stream.**

- A receiver takes one stream for each file. Windows, Android and iOS keep the first sender's stream and ignore other senders' chunks for that file until it is stored or the stream is given up. HarmonyOS writes each sender's stream to its own file and keeps whichever finishes first.
- Chunk 0 starts the file again from empty, even in the middle of that sender's stream. A receiver ignores a stream it did not see start (a chunk other than 0 with no stream under way from that sender). It gives up on a stream with a gap and throws its bytes away, and does the same with any streams that were open when a connection closed.
- A receiver asks again for a file that a history entry still needs. It asks each device that connects, for every file entry it is missing bytes for. It also asks its other devices when a stream fails (a gap, a wrong hash or a closed connection), and asks a sender again when a stream it ignored ends and nobody else is sending that file. After failures it only asks a few times in a row (3 on Windows, Android and HarmonyOS), so a device with a bad copy is not asked for ever.

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
| A name | 64 characters |
| A file | 1 GB |
| Handshake time | 10 seconds (15 on Windows) |
| A handshake line, before anything is trusted | 8 KB on Android, 64 KB on HarmonyOS |
| Any other line | 64 MB on Android, 192 MB on HarmonyOS and iOS. Windows has no limit yet |
| Heartbeat (Windows) | Every 5 seconds. A silent connection is closed after 15 seconds |
| Pairing request held | 3 minutes, one at a time |
| Quiet time after Ignore | 2 minutes |
| Reconnect to a saved address | Every 30 seconds (Windows) |

## Not built yet

The things we want to add next are in the **To do** list in the [main README](../README.md#to-do). Two of them touch this page: a switch to hide a device from beacons, and syncing between devices that are not on the same network.
