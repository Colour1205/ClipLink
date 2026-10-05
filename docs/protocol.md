# Protocol (draft)

Concrete message shapes live in `protocol/schema/`. This doc covers behavior.

## Transport

- **Discovery**: UDP broadcast on the LAN subnet, periodic "hello" beacon containing device ID + a short capability/version string. mDNS/Bonjour-style service advertisement is an acceptable alternative/addition.
- **Peer link**: once two nodes discover each other, they open a direct TCP connection secured with the pairing-derived key (see `docs/security.md`). All clipboard data and history sync happens over this link — the broadcast channel only ever carries presence beacons, never clipboard content.

## Message types

- `HELLO` — presence beacon (broadcast, unencrypted metadata only: device id, display name, protocol version). Nothing in it is authenticated, so its display name is only shown, never persisted (see [Device names](#device-names)).
- `CLIP_PUSH` — "here is a new clipboard entry" (sent to all currently-connected peers when the local clipboard changes).
- `HISTORY_REQUEST` — "send me everything you have after vector-clock/timestamp X".
- `HISTORY_RESPONSE` — batch of clipboard entries answering a `HISTORY_REQUEST`.
- `ACK` — optional delivery acknowledgement, used to prune what still needs to be gossiped further.

## Device names

Every device has a display name: the user's "Device name" override if set, otherwise the OS's own device/computer name. It is carried in three places. All of them are optional on receipt, so builds without names keep working in both directions: older peers ignore the new fields, and newer peers accept messages that don't have them.

**Normalisation.** A sender trims the name, then caps it at 64 characters before encoding it. Characters are counted as Unicode code points (scalars), not UTF-16 units and not user-perceived characters: an emoji counts as one, a combining accent as one of its own, and a surrogate pair is never split. A peer's name is untrusted text, so receivers first remove every control character (C0 and C1: U+0000–U+001F and U+007F–U+009F) and the invisible bidi and zero-width characters (U+061C, U+200B–U+200F, U+202A–U+202E, U+2066–U+2069 and U+FEFF), then trim and cap it by the same rule; an empty result means "unknown". The mobile apps do this before they store or show a peer's name. Windows trims and caps the name when it arrives and removes those characters wherever it shows it. Each platform trims with its own built-in whitespace set, and these sets differ only on a few invisible characters (U+0085, U+001C–U+001F, U+FEFF). So a sender may leave one of them at the edge of the name it sends, but every receiver removes it, since they are all in the set above.

**Beacon** (UDP broadcast, one line of colon-separated fields). The 6th field is the name:

```
{tcpPort}:{deviceId}:{proof|-}:{address|-}:{pairing 1|-}:{name|-}
```

| Index | Field | Value |
|---|---|---|
| 0 | `tcpPort` | TCP port the sender accepts peer connections on |
| 1 | `deviceId` | sender's public key (Base64) |
| 2 | `proof` | passphrase proof, or `-` when no passcode is set |
| 3 | `address` | sender's own off-LAN (Tailscale) address, or `-` |
| 4 | `pairing` | `1` while the sender's pairing screen is open, otherwise `-` |
| 5 | `name` | standard Base64 (with `=` padding) of the UTF-8 display name, or `-` when unknown |

- Senders always emit the pairing field (`1` or `-`), so the name is always at index 5.
- The Base64 alphabet has no `:`, so splitting the line on `:` is still safe.
- For receivers, index 5 is optional. A missing field, `-`, an empty value, bad Base64 or bad UTF-8 all mean the name is unknown (null). A bad name field never causes the beacon to be rejected.
- The beacon is unauthenticated, so its name is for display only: receivers keep it in memory and never persist it (see **What receivers store** below).

**Handshake JSON** (the first, unencrypted line on every TCP connection) gains an optional field, `"DeviceName": "<string>"`. It is a plain JSON string with the same 64-character cap. Senders always include it when the name is known. If it is absent, `null` or empty, the name is unknown. Example:

```json
{"EphemeralPublicKey":"…","IdentityPublicKey":"…","Signature":"…","PassphraseProof":null,"DeviceName":"Colour's Laptop"}
```

**Pairing payload** (the QR code / "copy pairing info" JSON) gains an optional `"Name"`: `{"PublicKey":"…","Address":"100.64.0.1","Name":"Colour's Laptop"}`. Parsers must treat `Name` as optional.

**What receivers store.** Beacons are unauthenticated: anyone on the LAN can broadcast one under any device id, with any name. So a name that arrives in a beacon is **never written to the trust store or persisted anywhere**, on every platform. Receivers keep it in memory only, together with the device's latest beacon (the nearby / seen-peers cache), and use it only for display: for a discovered device that isn't trusted, and for a trusted device only while it has no stored name yet. Receiving the same or a different name in a beacon never causes a disk write.

A trusted peer's stored name comes only from the handshake's `DeviceName` (and, on Windows, from a pairing payload's `Name` when a device is trusted straight from its payload: it arrives out of band, together with the key it names). The handshake's `DeviceName` is not authenticated by the handshake itself: its signature covers only `EphemeralPublicKey`, so anyone who captured one of a trusted device's cleartext handshakes can replay it with any `DeviceName`. A replayer can't derive the session key, though, so it has no line of its own that decrypts. The only such lines it has are the receiver's own, which it could echo back, since one session key serves both directions. So, on every platform, a handshake's name is **stored only once its connection has proved itself**:

- It may be kept in memory for that live connection and shown right away (a pairing prompt, or a trusted device that has no stored name yet).
- It is written to the trust store only after the first encrypted line received on that connection (an envelope, or a heartbeat ping) has decrypted and authenticated with the session key, and isn't one of the receiver's own lines echoed back. Until then each side remembers the nonces of the lines it has sent, and a received line carrying one of them (a reflected line) ends the connection, just like a line that fails to decrypt. This happens once per connection, and updates the stored name if the handshake's is non-empty and differs from it.
- Accepting a pairing request, or auto-trusting a device by passcode (from its beacon or its handshake), creates or updates the trust record without a name. That connection fills the name in once it has proved itself.
- A connection that never proves itself (a replayed handshake, say) never writes a name.

This stops replayed handshakes, not an attacker on the network path (ARP spoofing on the LAN, say), who can change `DeviceName` in a genuine handshake as it passes: the real device then proves the session, and the changed name is stored. Only signing `DeviceName` together with the ephemeral key closes that, a protocol change every platform would have to make together (see `docs/security.md`).

In normal use the first line is the peer's `history_batch`, which every platform sends as soon as it registers the connection, so the name is stored moments after connecting (otherwise with its first heartbeat, within 3-5 seconds: the peer's ping interval). An unknown name never overwrites a known one, and updating a name never changes the stored address (the reverse also holds). As a result, a trusted peer's rename is stored at its next connection, not at its next beacon.

**Fingerprint.** Device ids are Base64 P-256 SPKI public keys, and their first 36 characters are the same key header on every device, so a prefix of an id can't tell devices apart. Wherever a short form of an id is shown (the title of a device with no name, pairing prompts, log lines), every platform shows its fingerprint instead: the first 4 bytes of the SHA-256 of the id's UTF-8 bytes, as uppercase hex, with `·` (U+00B7 MIDDLE DOT) between the two halves. As a title it reads `Device XXXX·XXXX`, and a pairing prompt may show it bare after an "ID" label. Test vector: SHA-256(`abc`) begins `ba7816bf`, so the id `abc` shows as `Device BA78·16BF`. Each device shows its own fingerprint on its Settings (Windows) or Me (phones) screen, so the user can compare it with the one another device's pairing prompt shows. The fingerprint is for display only: it never goes on the wire. It is only 32 bits, enough to tell your own devices apart and to spot a copied name, but a determined attacker can generate a key whose fingerprint matches a given device's (see `docs/security.md`, Pairing).

## A handshake from this device itself

A device can reach its own listener: its own address typed in to pair, a trusted peer's stored address that is now its own, or something on the path relaying its dial straight back. The handshake that answers then carries its own `IdentityPublicKey`. Every platform refuses such a connection (closes it, with no session) on both the dialling and the accepting side, and does so straight after reading the handshake, before any trust, passcode or pairing check. Two of a device's own connections wired together like that would derive one session key, so each would accept the other's lines as proof of the session, and the device's own passcode proof would vouch for its own id.

The check compares public keys, not just their text. A handshake whose `IdentityPublicKey` is the same text as the receiver's own id is refused at once. One that is different text but decodes to the receiver's own key is refused as well. Otherwise a reflector that re-encodes the id (a space inside the Base64, say) could turn the device's own connection into a pairing request from itself. How the keys are compared differs:

- Windows re-encodes the decoded key canonically (its DER SubjectPublicKeyInfo, as standard Base64 with padding) and compares that with its own id. Android and iOS compare the decoded keys themselves (the curve point).
- HarmonyOS compares the bytes the two ids decode to. It catches a different spelling of the same bytes (whitespace in the Base64, say), but not a different DER encoding of the same key (a compressed point, say).

Beacons and pairing payloads (or a bare id given to trust) are checked for the device's own id too, and never add it, trust it or dial it. Windows and iOS compare them by key, as above. Android and HarmonyOS compare them as text, so a spoofed beacon carrying a re-spelt copy of the device's own id shows up there as a discovered device, and the user could trust it. That only adds a row: a handshake under that id is still refused as this device's own, within the limit above on HarmonyOS.

Where it dialled, a device can tell "that address is this device" from a refusal. Pairing with its own address says so (Windows: "That's this PC."). If the address it dialled is the one stored for a trusted peer (the off-LAN reconnect address), the peer is no longer there: DHCP has given this device the peer's old LAN address, say, or the peer came in through a loopback forward that was stored as `127.0.0.1`. Windows then clears that stored address instead of dialling itself on every reconnect pass. Only the stored address is cleared this way, never because of an address a beacon came from: beacons are unauthenticated, so a reflector answering at a beacon's address must not wipe a peer's real address. A cleared address is learned again the next time the peer connects.

## Files

A `file` entry's content is a small descriptor, `{"FileName":"…","FileHash":"…","FileSize":…}`: the SHA-256 of the file's bytes as 64 hex digits (in either case; compare ignoring case) and their length. The bytes travel separately. A receiver that doesn't have them sends `file_request` `{"FileHash"}` to every connected peer. A peer that has them answers with `file_chunk` messages `{"FileHash","ChunkIndex","IsLast","DataBase64"}`, the last one with `IsLast: true`. The receiver checks the SHA-256 of what arrived against `FileHash` and discards the bytes on a mismatch.

**Chunk streams.** A sender sends a file as one stream of `file_chunk` messages on one connection: `ChunkIndex` starts at 0 and goes up by 1, and only the last chunk has `IsLast: true`. A sender never resumes a stream. If it is cut off or asked again, it starts again at 0. It never streams the same file to the same peer twice at once, and ignores a `file_request` for a file it is already streaming to that peer. Receivers rely on these rules:

- A receiver takes one stream per file. Windows, Android and iOS keep the first sender's stream, and ignore every other sender's chunks for that file until the file is stored or the stream is abandoned. HarmonyOS writes each sender's stream to a file of its own and keeps whichever is stored first.
- Chunk 0 starts the file over in a fresh, empty file, even in the middle of that sender's stream. A receiver ignores a stream it didn't see start (a chunk other than 0, with no stream of that file under way from that sender). It abandons a stream with a gap and discards its bytes, and does the same with the streams a connection was sending when it closed.
- A receiver asks again for a file that a history entry still needs. It asks each peer that connects, for every file entry whose bytes it is missing, not just new ones. It also asks its other peers after a stream fails (a gap, a hash mismatch or a closed connection), and asks a sender again when a stream it ignored ends and nobody else is sending that file. After failures it asks only a few times in a row (3 on Windows, Android and HarmonyOS), so a peer with a bad copy isn't asked forever.

Older Windows, Android and HarmonyOS builds kept one transfer per file hash, whichever peer sent the chunks, and asked for a file only once, when its entry was new. A sender that resumed a stream or skipped an index would have its chunks ignored by current builds, and the file would be asked for again.

`FileHash` and `FileSize` describe exactly the bytes the sender stored to send. A file on the sending device can be written while it is being read (a download, a recording, a document saved again). So Windows hashes a file again as it stores it, and doesn't send it at all if the result differs from the hash it described. Stored under the wrong hash, those bytes would fail every receiver's check, and would also stand in for the real file on every later copy of it.

**Empty files.** A 0-byte file has no bytes to stream. Its entry has `FileSize` 0 and, as `FileHash`, the SHA-256 of empty input: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (Windows writes it in uppercase).

- A receiver creates such a file itself, as an empty file under that hash, and applies the entry right away. It never sends a `file_request` for it. Only that exact pair counts: size 0 with any other hash, or the empty hash with any other size, is fetched like any other file.
- A sender that is asked for it anyway (by an older build) answers with exactly one `file_chunk`: `ChunkIndex` 0, `IsLast` true and `DataBase64` `""`. Older iOS builds already sent this chunk, but older Windows, Android and HarmonyOS builds sent no chunk at all, so a receiver waiting for one never finished. Of the older receivers, Windows and iOS builds finish the file with the empty chunk. Older Android and HarmonyOS builds refuse to decode an empty `DataBase64` (HarmonyOS's Base64 decoder throws on an empty string), so they drop the chunk and keep waiting, as they always have.
- A receiver that has already created the file can still get that chunk (it asked before it created it, or the sender streams new files to connected peers unasked). It must accept it, or ignore it, without error.

## Clipboard entry (conceptual shape)

```
id            : ulid/uuid, globally unique, generated at capture time
device_id     : id of the device that captured it
created_at    : capture timestamp (UTC)
content_type  : text | image | file-ref | ...
content       : raw bytes or reference (large payloads may be chunked/streamed separately)
content_hash  : dedupe key
```

## Reconciliation

Each node keeps a per-peer "last known state" (a logical clock or last-seen entry id per device). On connect:

1. Both sides exchange their per-device high-water marks.
2. Each side sends `HISTORY_REQUEST` for anything the other has that it doesn't.
3. New local clipboard changes are pushed live via `CLIP_PUSH` to whoever is currently connected, and picked up by everyone else next time they reconcile with any node that has it — this is what makes offline devices eventually consistent without a central server.

## Open questions / future work

- Off-LAN relay/NAT traversal for syncing when devices aren't on the same network.
- Large payloads (images, files) — chunking and backpressure.
- Conflict handling when two devices copy near-simultaneously (currently: both entries are kept, ordered by timestamp, no "winner").
