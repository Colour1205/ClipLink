# Protocol (draft)

Concrete message shapes live in `protocol/schema/`. This doc covers behavior.

## Transport

- **Discovery**: UDP broadcast on the LAN subnet, periodic "hello" beacon containing device ID + a short capability/version string. mDNS/Bonjour-style service advertisement is an acceptable alternative/addition.
- **Peer link**: once two nodes discover each other, they open a direct TCP connection secured with the pairing-derived key (see `docs/security.md`). All clipboard data and history sync happens over this link — the broadcast channel only ever carries presence beacons, never clipboard content.

## Message types

- `HELLO` — presence beacon (broadcast, unencrypted metadata only: device id, display name, protocol version).
- `CLIP_PUSH` — "here is a new clipboard entry" (sent to all currently-connected peers when the local clipboard changes).
- `HISTORY_REQUEST` — "send me everything you have after vector-clock/timestamp X".
- `HISTORY_RESPONSE` — batch of clipboard entries answering a `HISTORY_REQUEST`.
- `ACK` — optional delivery acknowledgement, used to prune what still needs to be gossiped further.

## Device names

Every device has a display name: the user's "Device name" override if set, otherwise the OS's own device/computer name. It is carried in three places. All of them are optional on receipt, so builds without names keep working in both directions: older peers ignore the new fields, and newer peers accept messages that don't have them.

**Normalisation.** A sender trims the name, then caps it at 64 characters before encoding it. Characters are counted as Unicode code points (scalars), not UTF-16 units and not user-perceived characters: an emoji counts as one, a combining accent as one of its own, and a surrogate pair is never split. Receivers apply the same rule, and an empty result means "unknown". Each platform trims with its own built-in whitespace set. These sets differ only on a few invisible control characters (U+0085, U+001C–U+001F, U+FEFF), so one platform may keep such a character at the edge of a name where another trims it. The name is only a label, so this is harmless.

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

**Handshake JSON** (the first, unencrypted line on every TCP connection) gains an optional field, `"DeviceName": "<string>"`. It is a plain JSON string with the same 64-character cap. Senders always include it when the name is known. If it is absent, `null` or empty, the name is unknown. Example:

```json
{"EphemeralPublicKey":"…","IdentityPublicKey":"…","Signature":"…","PassphraseProof":null,"DeviceName":"Colour's Laptop"}
```

**Pairing payload** (the QR code / "copy pairing info" JSON) gains an optional `"Name"`: `{"PublicKey":"…","Address":"100.64.0.1","Name":"Colour's Laptop"}`. Parsers must treat `Name` as optional.

**What receivers store.** A trusted peer's stored name is updated whenever its handshake or beacon carries a non-empty name that differs from the stored one. An unknown name never overwrites a known one, and updating a name never changes the stored address (the reverse also holds). For devices that are discovered but not trusted, the name is kept in memory only, together with their latest beacon.

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
