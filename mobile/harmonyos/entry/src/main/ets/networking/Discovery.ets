// Step 5 of the build order in ../../../../README.md: networking.
// Mirrors windows/daemon/Networking/Discovery.cs exactly — same port, same
// beacon format ("{tcpPort}:{deviceID}:{proof}:{address}:{pairing}:{name}",
// "-" for absent fields), same 2-second send interval. Device IDs are base64
// (from DeviceIdentity.ets / DeviceIdentity.cs), which never contains ":", so
// splitting on ":" is safe - and so is the name, sent as Base64 of its UTF-8
// for exactly that reason. Older builds stop reading after the pairing field,
// and a beacon from one simply has no name.
//
// Whether LAN broadcast actually works without any extra permission beyond
// INTERNET was flagged as a genuine unknown in the step-2 spike, deferred
// here since it needs real socket code to test - this is that test.

import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { normalizeDeviceName } from '../identity/DeviceName';

const PORT = 49000;
const BROADCAST_ADDRESS = '255.255.255.255';
const SEND_INTERVAL_MS = 2000;
// Standard Base64 with padding - what every platform's name field uses.
const BASE64_PATTERN = new RegExp('^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$');

const base64Helper = new util.Base64Helper();
const nameEncoder = util.TextEncoder.create('utf-8');
// Deliberately NOT fatal: this one decoder is shared by every beacon, and a
// fatal decoder that throws mid-conversion may not reset its state - one bad
// name from any device could then garble or drop every name after it. A
// lenient decoder turns bad bytes into U+FFFD instead, which the round trip
// in decodeBeaconName catches.
const nameDecoder = util.TextDecoder.create('utf-8');

// "-" when there's no name to send.
function encodeBeaconName(name: string | null): string {
  const normalized: string | null = name !== null ? normalizeDeviceName(name) : null;
  if (normalized === null) return '-';
  return base64Helper.encodeToStringSync(nameEncoder.encodeInto(normalized));
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

// Null for "-", empty, bad Base64 or bad UTF-8 - an unreadable name never
// costs the rest of the beacon. Stray whitespace around the field is
// tolerated, as the Windows, Android and iOS decoders do.
function decodeBeaconName(rawField: string | undefined): string | null {
  if (rawField === undefined) return null;
  const field: string = rawField.trim();
  if (field.length === 0 || field === '-') return null;
  if (!BASE64_PATTERN.test(field)) return null;
  try {
    const bytes: Uint8Array = base64Helper.decodeSync(field);
    const text: string = nameDecoder.decodeToString(bytes);
    // Valid UTF-8 re-encodes to exactly the bytes it came from; anything
    // the decoder had to replace with U+FFFD doesn't.
    if (!sameBytes(nameEncoder.encodeInto(text), bytes)) return null;
    return normalizeDeviceName(text);
  } catch (e) {
    return null;
  }
}

export interface PeerBeacon {
  tcpPort: number;
  deviceId: string;
  proof: string | null;
  address: string | null;
  // True only while the sender's own Pairing screen is open - the signal
  // that makes it safe/expected to attempt a pairing handshake with an
  // otherwise-untrusted device found this way, instead of trying one with
  // every stranger's beacon on the LAN. See Index.ets's pairingOpen and
  // PeerConnection.create's pairingModeOpen gate.
  pairing: boolean;
  // The sender's display name, or null when it sent none (an older build)
  // or it didn't decode. See decodeBeaconName.
  name: string | null;
  senderIp: string;
}

export class Discovery {
  private udp: socket.UDPSocket | null = null;
  private sendTimerId: number = -1;
  private peerCallback: ((beacon: PeerBeacon) => void) | null = null;
  private errorCallback: ((context: string, error: BusinessError) => void) | null = null;
  private decoder = util.TextDecoder.create('utf-8');

  onPeerDiscovered(callback: (beacon: PeerBeacon) => void): void {
    this.peerCallback = callback;
  }

  // Surfaced explicitly rather than swallowed - a bind/send failure here
  // (e.g. broadcast blocked) is itself a finding worth seeing, same lesson
  // as every other spike in this project so far.
  onError(callback: (context: string, error: BusinessError) => void): void {
    this.errorCallback = callback;
  }

  // getProof, getOwnAddress, getPairingOpen and getOwnName are all called
  // fresh on every beacon, not just once at start - each can change live (a
  // passphrase set later, a manually-entered Tailscale IP, the Pairing
  // screen opening/closing, or the device renamed on the Me screen) and must
  // take effect without a restart, same reasoning as Discovery.cs's own
  // getProof callback.
  async start(deviceId: string, tcpPort: number, getProof: () => string | null, getOwnAddress: () => string | null, getPairingOpen: () => boolean, getOwnName: () => string | null): Promise<void> {
    const udp = socket.constructUDPSocketInstance();
    this.udp = udp;

    udp.on('message', (info: socket.SocketMessageInfo) => {
      const text = this.decoder.decodeToString(new Uint8Array(info.message));
      const parts = text.split(':');
      if (parts.length < 3) return; // malformed/old-format beacon, ignore

      const beacon: PeerBeacon = {
        tcpPort: Number(parts[0]),
        deviceId: parts[1],
        proof: parts[2] === '-' ? null : parts[2],
        address: parts.length > 3 && parts[3] !== '-' ? parts[3] : null,
        pairing: parts.length > 4 && parts[4] === '1',
        name: parts.length > 5 ? decodeBeaconName(parts[5]) : null,
        senderIp: info.remoteInfo.address,
      };
      this.peerCallback?.(beacon);
    });

    try {
      await udp.bind({ address: '0.0.0.0', port: PORT });
      await udp.setExtraOptions({ broadcast: true });
    } catch (e) {
      this.errorCallback?.('bind/setExtraOptions', e as BusinessError);
      throw e as Error;
    }

    this.sendTimerId = setInterval(() => {
      const proof = getProof() ?? '-';
      const addr = getOwnAddress() ?? '-';
      // Always sent, even as "-", so the name is always the 6th field.
      const pairing = getPairingOpen() ? '1' : '-';
      const name = encodeBeaconName(getOwnName());
      const message = `${tcpPort}:${deviceId}:${proof}:${addr}:${pairing}:${name}`;
      udp.send({ data: message, address: { address: BROADCAST_ADDRESS, port: PORT } })
        .catch((e: BusinessError) => {
          this.errorCallback?.('send', e);
        });
    }, SEND_INTERVAL_MS);
  }

  // Awaits the socket close instead of firing it off. A caller that stops
  // and immediately restarts discovery (see Index.ets's onPageShow) would
  // otherwise race the old socket's release and get EADDRINUSE from the
  // new bind on the same fixed port - which killed discovery for the rest
  // of the session, because the failed start was never retried.
  async stop(): Promise<void> {
    if (this.sendTimerId !== -1) {
      clearInterval(this.sendTimerId);
      this.sendTimerId = -1;
    }
    const udp = this.udp;
    this.udp = null;
    if (udp !== null) {
      try {
        await udp.close();
      } catch (e) {
        // already closed or never opened - fine
      }
    }
  }
}
