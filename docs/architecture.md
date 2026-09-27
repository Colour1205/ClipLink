# Architecture

## Model

Pure P2P, no central server. Every device is a **node**. Nodes:

1. **Discover** each other on the local network (UDP broadcast / mDNS).
2. **Gossip** clipboard entries to every peer they can reach directly.
3. **Reconcile history** with each peer on connect, so a device that was offline catches up from whichever peer it talks to next (epidemic/gossip propagation — no single node needs to have been online the whole time).

There is no "server" role. A daemon (Windows) and a foreground app (iOS/Android/HarmonyOS) are both just nodes with different lifecycle constraints — see below.

## Node lifecycle by platform

| Platform | Runs as | Sync trigger |
|---|---|---|
| Windows | Background daemon + tray icon | Continuous — watches clipboard, listens for peers at all times |
| iOS | Foreground app + Background App Refresh + Share extension | On launch / foreground: announce presence (unicast beacons + /24 sweep when iOS blocks broadcast), pull history from any reachable peer, push local clipboard once; iOS-scheduled background rounds catch up history; "Share → ClipLink" sends from any app |
| Android | Foreground app (+ optional short-lived background window if OS allows) | Same as iOS |
| HarmonyOS | Foreground app | Same as iOS |

Mobile platforms cannot keep a socket open indefinitely, so they are **eventually-consistent by design**: they catch up when opened rather than staying live. The gossip/history-reconciliation protocol is what makes this safe — a phone that was closed for two days still gets fully caught up the next time it opens near any peer (or via relay, see `docs/protocol.md`).

## Core components (per node)

- **Discovery** — finds peers (LAN broadcast now; NAT traversal / relay fallback later for peers off-LAN).
- **Peer link** — authenticated, encrypted transport between two discovered nodes.
- **Clipboard watcher** — OS-specific hook that detects local clipboard changes.
- **History store** — local append-only log of clipboard entries (content, source device, timestamp, content hash) used both to answer "what did I miss" queries and to keep a scrollable history UI.
- **Sync/gossip engine** — decides what to send a newly connected peer (diff since last known state) and what to broadcast when the local clipboard changes.
- **Identity/pairing** — each device has a keypair; devices must be paired once (e.g. QR code / pairing code) before they trust each other's broadcasts.

See `docs/protocol.md` for the wire format and `docs/security.md` for the trust model.
