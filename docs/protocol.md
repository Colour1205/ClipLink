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
