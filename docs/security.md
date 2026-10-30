# Security and trust model

This page says how ClipLink decides who to trust, how devices talk to each other, what is kept on a device, and what is known not to be perfect. It describes version 2.0. The wire formats are in [`protocol.md`](protocol.md).

In short: there is no ClipLink server and no account. Devices talk straight to each other, only after you have paired them, and everything they send is encrypted and signed.

## Identity

Each device makes a long-term P-256 key pair the first time it runs. The public key, as Base64, is the device's id. The private key stays on the device:

| Platform | Where the private key lives |
| --- | --- |
| Windows | In a file encrypted with DPAPI (tied to the Windows user) |
| Android | Android Keystore |
| HarmonyOS | HUKS, the system key store. The key cannot be read out |
| iOS | The Keychain, on this device only |

## Pairing

A device only accepts a peer it has been told to trust. There are three ways to pair, and none of them involves a server:

1. **QR code or pairing link.** The code carries the other device's public key and address. It is a link to the website (`https://cliplink.uaena.io/pair/#...`), so a phone's own camera opens ClipLink if it is installed. The key travels after the `#`, so it is never sent to a server.
2. **Address.** Type in the other device's address. The other device shows a pairing request, and nothing is trusted until it is accepted.
3. **Shared passcode.** Devices that have the same passcode trust each other with no scan. Each device sends a proof: an HMAC-SHA256 of its own id under a key made from the passcode (PBKDF2-SHA256, 210,000 rounds, a fixed salt, so every device makes the same key). The passcode itself is never sent. See "Known limits" for the catch.

A device's name is whatever it says it is, and two devices can use the same one. So every pairing prompt also shows the sender's **fingerprint**: the first 4 bytes of the SHA-256 of its id, as `XXXX·XXXX` (the id `abc` gives `BA78·16BF`). Each device shows its own fingerprint on its Settings (Windows) or Me (phones) screen, so you can compare them. It is only 32 bits, which is enough to tell your devices apart and to spot a copied name, but not to stop a determined attacker who is willing to generate a lot of keys. The real protection is the next section: a request has to be accepted by a person.

## Pairing requests, ignoring and blocking

A pairing request can come from any device on the network at any time while the app is running. What protects you is that **nothing is trusted until a person says so**, except a device that proves it has your passcode.

- A stranger's connection is held as the one pending request. Nothing is read from it and nothing is sent to it. A second stranger is turned away while one is waiting. A request nobody answers is dropped after 3 minutes, so one device cannot hold the slot forever.
- **Trust** adds the key to the trust list. **Ignore** closes that one connection and remembers nothing, so the device can ask again, except that for 2 minutes after you ignore a request from a device, new requests from it are closed without a prompt. **Block** (a deliberate action in the Devices tab) remembers the *key*: the device is untrusted and disconnected, its connection is refused before anything else is checked, it is never dialled and never listed, and a passcode proof from it is never looked at. Unblocking does not trust it again.
- Blocking is by key, not by address or name. A device that makes a new identity is a new device and is not stopped. Keys are compared by what they decode to, not as text, because one key can be written many ways.
- When the app is not in front, a request is a notification with **Trust** and **Ignore** (never Block). Where the system can ask for it, Trust needs the device to be unlocked (Android `setAuthenticationRequired`, iOS `authenticationRequired`), so a stranger's request cannot be answered from a lock screen.
- How long a request can be received with the app out of front depends on the platform. iOS suspends the app and closes its connections, so a request is only seen while the app is running. A push from a server would be needed to wake a suspended iPhone, and ClipLink has no server.
- A device that keeps asking can only raise prompts, one at a time. It cannot connect, read or write anything without a Trust.

**Removing a device.** Removing a device here drops its key from the trust list and sends it an `unpair` message over the encrypted link, so it stops trusting and redialling this device. If it was not connected, it is told the next time it connects. Removing a device on one of your devices does not remove it from your others. If a device is lost or stolen, remove it on each of the devices you still have.

## Talking to a peer

- **Presence beacons** (UDP broadcast) carry the device's id, name and port, its Tailscale address if one is set, and a passcode proof if a passcode is set. They never contain clipboard content. They are not authenticated, so a name in a beacon is only shown, never saved.
- **The connection** is TCP. Each side sends a handshake first: a fresh P-256 key made for this connection, signed with the device's long-term key. Each side checks the other's signature and that the other is trusted (or is a pairing request). The two fresh keys give a shared secret, and its SHA-256 is the session key. So a stolen long-term key cannot decrypt old sessions, and someone in the middle cannot swap in their own key without the real private key.
- **Everything after the handshake** is AES-256-GCM, with a random 12-byte nonce and a 16-byte tag on each message. A message that fails to decrypt ends the connection. Each side remembers the nonces it sent until the connection has proved itself, and ends the connection if one comes back to it: this stops a device from being tricked into talking to itself or into repeating a replayed handshake.
- **Entries are signed.** Each clipboard entry is signed by the device that made it (ECDSA P-256 over its content, type, device id and time). A device only accepts an entry whose signature is valid and whose signer is trusted.
- **Files** are checked against the SHA-256 in their signed entry before they are stored, and a received name is cut to a safe last part, so a peer cannot write a file anywhere else or store other bytes under a hash it chose.
- **Limits against abuse.** The handshake has a time limit (15 seconds on Windows, 10 on the phone apps). The Android, HarmonyOS and iOS apps limit how long a line can be, and drop what is too big. Files are limited to 1 GB.
- **Names.** A device name from a handshake is only saved once the connection has proved itself, so a replayed handshake cannot rename a device. See [`protocol.md`](protocol.md#device-names).
- **A device connecting to itself** is refused on every platform, straight after the handshake is read, before any trust, passcode or pairing check. Otherwise it could trust itself or show its own pairing request. See [`protocol.md`](protocol.md#a-handshake-from-this-device-itself).

## What is kept on a device

- The history is the last 25 items, plus the files they point to, in the app's own private storage (on Windows, the user's `AppData` folder). It is **not encrypted separately**: it is as protected as the user's own files and the operating system's app separation. It can hold anything you copied, such as a password, so the apps let you clear it.
- If you delete an item, the device remembers that, so a peer's history cannot bring it back. The delete is sent to your other paired devices, which delete it too. Any paired device can delete any item, which is fine since all of them are yours.
- The trust list, the blocked list, the device name and the optional Tailscale address are stored in the same private storage. On Windows the trust list is a plain JSON file.
- The passcode itself is never stored. Only the key made from it is: encrypted with DPAPI on Windows, with the Android Keystore on Android, in the Keychain on iOS, and in the app's private preferences on HarmonyOS.
- Nothing is sent to the developer or anyone else. There are no accounts, no analytics and no crash reports. See the [privacy policy](https://cliplink.uaena.io/privacy.html).

## Known limits

These are known and not fixed:

- **A short passcode can be guessed offline.** The passcode proof is in the beacon, which anyone on the network can read. Someone who captures one can try passcodes against it on their own computer, offline. The 210,000 rounds slow that down but do not stop it. There is no minimum length, because the passcode can be any length. Use a long passcode, or pair with a QR code.
- **Windows does not limit the length of a line it reads** from a connection. The Android, HarmonyOS and iOS apps do. The 15-second handshake limit stops a stranger holding a connection open, but not from sending a lot of data inside those 15 seconds, and a trusted peer is not limited.
- **A device name can be changed by someone on the network path** (ARP spoofing, say) while a real handshake passes, because the handshake's signature does not cover the name. The real device then proves the connection, and the changed name is saved. Closing this needs the name to be signed, which is a change to the protocol on every platform at once.
- **The history is not encrypted on disk**, and Windows keeps the trust list in a plain file (see above).
- **No re-keying.** A connection uses one session key for its whole life. A leaked session key exposes that connection's traffic, but no other.
- **Old entries can come back.** Nothing checks how old an entry is. An entry that has fallen out of the last 25 can be sent again by a device that still has it. Entries you deleted stay deleted.
- **Beacon tricks.** A fake beacon cannot impersonate a device, because the handshake is signed, but it can cause wasted connection attempts. On Android and HarmonyOS, a beacon with a re-written copy of a device's own id can add a row to the list of nearby devices (its handshake is still refused). On HarmonyOS, a handshake from a device itself that uses a different encoding of the same key is not recognised as its own.

## Found a problem?

If you find a way around any of this, please open an issue at https://github.com/Colour1205/ClipLink/issues, and leave out anything private.
