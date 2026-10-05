# Security & trust model (draft)

## Pairing

Devices must be explicitly paired before they trust each other's clipboard data. Suggested flow:

1. Each device generates a long-term keypair on first run (identity).
2. Pairing exchanges public keys out-of-band (QR code shown on one device, scanned by the other; or a short numeric code typed on both) — this prevents an unpaired device on the same LAN from silently joining the mesh.
3. Paired device public keys are stored locally; only peers with a known/trusted key are accepted on the peer link.

A device's name is whatever it claims, and two devices can claim the same one, so every pairing prompt also shows the requester's fingerprint: the first 4 bytes of the SHA-256 of its id, as `XXXX·XXXX` (the id `abc` gives `BA78·16BF`; see `docs/protocol.md`, Device names). Each device shows its own fingerprint on its Settings (Windows) or Me (phones) screen, so the user can compare the two. It isn't a prefix of the id, because every id starts with the same 36 characters. The fingerprint is only 32 bits, though: enough to tell your own devices apart and to spot a copied name, but a determined attacker can generate a key with a matching fingerprint (a few billion key generations, within reach of one PC). The real protection is still that a pairing request only gets through while the Pairing screen is open, and has to be accepted on both devices.

## Transport security

- Presence beacons (`HELLO`) are unauthenticated by nature (broadcast) and must never contain clipboard content — only device id + metadata.
- The actual peer TCP link is encrypted and mutually authenticated using the paired keys (e.g. Noise protocol or TLS with pinned certs derived from the device keypair).

## Data at rest

- Local history store should be encrypted at rest (or at least access-restricted) since it accumulates sensitive clipboard content (passwords, tokens, etc. users may copy).
- Consider a "don't sync sensitive content" heuristic later (e.g. skip content that looks like a password-manager copy) — out of scope for v1.

## Threat model notes (draft, revisit before shipping)

- LAN-local attacker should not be able to join the mesh without completing pairing.
- A compromised/unpaired device should not be able to read or inject clipboard entries.
- Lost/stolen device: needs a way to revoke its trust from the others (unpair) — TBD.

## Windows daemon security review (2026-09-18)

Self-review of the implemented Windows daemon, thinking as an attacker. Ordered by severity; none of these are fixed yet.

### Critical
1. **Local IPC has no authentication.** *(Gone since the Windows daemon and tray became one app: the engine runs in-process with typed calls and no control pipe; the app's only pipe forwards a second launch's "activate"/"share" to the running copy and is opened `CurrentUserOnly`.)* `IpcServer` opens a named pipe (`ClipboardDaemonIPC_<label>`) with a fully predictable name and no ACL/secret. Any process running as the same Windows user can connect and issue `trust_device`, `set_passphrase`, `untrust_device`, `list_trusted`/`list_connections` — full control of the daemon, completely bypassing every network-level protection (ECDH, signing, trust checks). This is the top priority fix.
- **Peer-supplied file hashes and names were used as paths.** *(Fixed with the one-app merge.)* A `file_request`'s, `file_chunk`'s or file entry's `FileHash` went straight into `FileStore` paths, so a trusted (or compromised) peer could have any file the user can read streamed to it, create `*.partial` files anywhere, or get any file deleted when the entry naming it was deleted or trimmed from history; and a received `FileName` was joined onto `ReceivedFiles` as it came, so a rooted or `..\` name wrote the file anywhere (the Startup folder, say). `FileStore` now only takes 64-hex-digit SHA-256 hashes (`FileStore.IsValidHash`), and received names are cut to a safe last segment (`FileNames.Safe`).
2. **Handshake has no timeout — one connection can freeze the whole daemon.** The accept loop `await`s `PeerConnection.CreateAsync` before looping back to accept the next connection. A peer that opens a TCP connection and never sends handshake data blocks the daemon from accepting *any* other connection (including legitimate devices) until the OS-level socket timeout eventually fires (can be minutes).

### High
3. **No size limit on any line read from the network** (handshake, envelope, chunk) — `ReadLineAsync()` will buffer an attacker-supplied line of unbounded length, a memory-exhaustion vector.
4. **Abandoned file transfers are never cleaned up.** `HandleFileChunk` opens a `FileStream` per hash with no timeout or cap on concurrent transfers; sending `file_chunk` messages for bogus hashes and never sending `IsLast` leaks file handles and disk space indefinitely.
5. **Passphrase auto-trust proof is broadcast in cleartext**, enabling offline brute-force of a weak user-chosen passphrase by anyone who passively captures one beacon (no live throttling applies to an offline attack).
   - So a short passcode can be guessed offline from one captured beacon proof, and a longer passcode is safer. No minimum length is enforced, by design (the passcode can be set, changed or cleared at any time, at any length).

### Medium
6. **Trust revocation doesn't propagate.** `Untrust` only edits the local trust store — revoking a stolen device on one of your devices leaves it fully trusted on every other device until each is separately revoked.
7. **Old signed entries can be replayed once evicted from the 25-item history cap** — dedup only checks "is this still in my current history," with no timestamp-freshness requirement.
8. **`TrustStore`'s file isn't DPAPI-protected**, unlike the identity and passphrase keys — plain JSON revealing paired devices + their Tailscale addresses to anyone with local file access.

### Low
- No re-keying on long-lived connections (one compromised session key exposes that connection's whole lifetime of traffic).
- Beacon spoofing (fake deviceId + port) can't achieve impersonation (the identity-signed handshake blocks it) but can cause wasted/nuisance connection attempts against a victim's real address.
- The handshake's `DeviceName` isn't covered by its signature (only `EphemeralPublicKey` is), so a captured handshake of a trusted device can be replayed with any `DeviceName`. *(A replay can no longer rename a device.)* No platform stores a handshake's name until a line received on that connection has decrypted with its session key and isn't one of the receiver's own lines echoed back. A replayer can't derive the key, so echoing is its only way to get a line that decrypts (one key serves both directions), and a reflected line ends the connection. A replayed connection may show its name while it lasts (until it sends a line that doesn't decrypt or is reflected, or the heartbeat times it out), but never writes it. Pairing and passcode auto-trust store a device without a name, and its connection fills it in once proven (see `docs/protocol.md`, Device names). Still open: an attacker on the network path (ARP spoofing on the LAN, say) can change `DeviceName` in a genuine handshake as it passes; the real device then proves the session and the changed name is stored. Only signing `DeviceName` with the ephemeral key closes that, a protocol change on every platform.
- **A device could connect to itself.** *(Fixed.)* Dialling one of its own addresses, or a reflector on the path relaying its dial back into its own listener, produced a handshake carrying its own identity. The two ends derived one session key, so each took the other's lines as proof of the session. With a passcode set, its own passcode proof vouched for its own id, and while the pairing screen was open the connection became a pairing request from itself. A reflector that re-encoded the id (a space inside the Base64) also got past the text comparison that some paths had. A handshake carrying the receiver's own identity is now refused straight after it's read, before any trust, passcode or pairing check, and the comparison is of the decoded key in its canonical form, not only of the text (see `docs/protocol.md`, A handshake from this device itself). When a trusted peer's stored address answers as this device, that address is cleared, but an address a beacon came from never clears anything, so a reflector can't use this to wipe a peer's real address.
- **File bytes are only ever stored under their own hash.** Received bytes are checked against the entry's signed `FileHash` before they're stored. The only file a receiver creates without receiving it is a 0-byte one, and only for exactly `FileSize` 0 with the SHA-256 of empty input, so no peer can get other bytes stored under a hash of its choosing. On the sending side, a file on this PC that changes between being hashed and being stored to send isn't sent at all (see `docs/protocol.md`, Files).
- `TrayLauncher`/`DaemonLauncher`'s path-guessing is fine for the current same-user dev layout but needs hardening before ever being installed to a shared location. *(Gone with the one-app merge.)*
