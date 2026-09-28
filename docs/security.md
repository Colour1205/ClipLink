# Security & trust model (draft)

## Pairing

Devices must be explicitly paired before they trust each other's clipboard data. Suggested flow:

1. Each device generates a long-term keypair on first run (identity).
2. Pairing exchanges public keys out-of-band (QR code shown on one device, scanned by the other; or a short numeric code typed on both) — this prevents an unpaired device on the same LAN from silently joining the mesh.
3. Paired device public keys are stored locally; only peers with a known/trusted key are accepted on the peer link.

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
- The handshake's `DeviceName` isn't covered by its signature (only `EphemeralPublicKey` is), on every platform. Replaying a captured handshake of a trusted device with another `DeviceName` gets that name stored for the device: a rename only, since the replayer can't decrypt or send anything on the connection. Fix on all platforms together: store the handshake name only after the connection's first envelope decrypts, or sign `DeviceName` with the ephemeral key (see `docs/protocol.md`, Device names).
- `TrayLauncher`/`DaemonLauncher`'s path-guessing is fine for the current same-user dev layout but needs hardening before ever being installed to a shared location. *(Gone with the one-app merge.)*
