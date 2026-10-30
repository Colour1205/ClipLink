// Step 5 of the build order in ../../../../README.md: networking.
// Raw TCP transport only - connectivity proof, nothing else. No
// encryption, no handshake, no framing beyond what's sent (that's step 6,
// mirroring PeerConnection.cs). Deliberately kept this thin so step 5 can
// be verified on-device (both listen and connect) before any protocol
// logic gets layered on top of unproven transport.

import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { TcpSocketAdapter } from './PeerConnection';

const decoder = util.TextDecoder.create('utf-8');
// How long a failed bind waits before the next try, doubling up to the
// maximum - see TcpServer.start. The same pauses as Android's serveTcp.
const BIND_RETRY_MIN_MS = 1000;
const BIND_RETRY_MAX_MS = 30000;

export class TcpServer {
  private server: socket.TCPSocketServer | null = null;
  private connectionCallback: ((conn: socket.TCPSocketConnection) => void) | null = null;
  private errorCallback: ((error: BusinessError, retryInMs: number) => void) | null = null;
  // Set by stop(): a start() still waiting to try again gives up.
  private stopped: boolean = false;

  onConnection(callback: (conn: socket.TCPSocketConnection) => void): void {
    this.connectionCallback = callback;
  }

  // A bind that failed, and how long until the next try.
  onError(callback: (error: BusinessError, retryInMs: number) => void): void {
    this.errorCallback = callback;
  }

  // Binds the port and keeps trying - 1 s, 2 s, 4 s ... 30 s apart - until it
  // does, or stop() is called. The one failed bind used to be logged and
  // that was all: the port was still held by the copy of this app that was
  // just killed (its connections' TIME_WAIT, or its socket not yet released
  // after a quick restart), and for the rest of the session nothing could
  // dial in - a peer whose key sorts after this device's only connected
  // once this side's dial fallback reached it, half a minute at a time.
  async start(port: number): Promise<void> {
    this.stopped = false;
    let pause: number = BIND_RETRY_MIN_MS;
    while (!this.stopped) {
      try {
        await this.listen(port);
        return;
      } catch (e) {
        this.errorCallback?.(e as BusinessError, pause);
      }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, pause); });
      pause = Math.min(pause * 2, BIND_RETRY_MAX_MS);
    }
  }

  private async listen(port: number): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.connectionCallback?.(conn);
    });
    try {
      await server.listen({ address: '0.0.0.0', port });
    } catch (e) {
      // Its descriptor goes with it: the next try binds a fresh one.
      server.close().catch(() => { /* never listened - fine */ });
      throw e as Error;
    }
    if (this.stopped) {
      // stop() came while this bind was in flight.
      server.close().catch(() => { /* fine */ });
      return;
    }
    this.server = server;
    // Without this, a connection that's been idle for a while (this app
    // only sends when the clipboard actually changes, so idle is the
    // common case) can get silently dropped by an intermediate NAT or
    // firewall along the path - especially plausible over Tailscale/
    // WireGuard, where the "connection" is really just a NAT mapping that
    // times out without periodic traffic. TCP keepalive pings keep that
    // mapping (and any stateful firewall's idea of the connection) alive
    // without needing real application data to flow. Individual accepted
    // TCPSocketConnections don't expose setExtraOptions themselves in this
    // SDK - only the server does, applying to connections it accepts.
    await server.setExtraOptions({ keepAlive: true }).catch(() => { /* best-effort - not fatal if unsupported */ });
  }

  stop(): void {
    this.stopped = true;
    this.server?.close().catch(() => { /* already closed or never started - fine */ });
    this.server = null;
  }
}

// Connects out to a peer and returns the socket, wrapped - caller owns
// framing, sending, and closing from here. Wrapped before connect(): the
// adapter listens from the moment it is made, and the peer's first bytes
// can arrive before connect() resolves (see MessageRelay in
// PeerConnection.ets - a bare TCPSocket drops them).
export async function connectTcp(address: string, port: number, timeoutMs: number = 5000): Promise<TcpSocketAdapter> {
  const client = socket.constructTCPSocketInstance();
  const link = new TcpSocketAdapter(client);
  try {
    await client.connect({ address: { address, port }, timeout: timeoutMs });
  } catch (e) {
    // The caller never gets this socket, so nothing else would close it.
    client.close().catch(() => { /* never opened - fine */ });
    throw e as Error;
  }
  // See TcpServer.start's matching comment - keeps an idle connection (and
  // any NAT mapping it depends on, e.g. over Tailscale) alive without
  // needing real traffic to flow.
  await client.setExtraOptions({ keepAlive: true }).catch(() => { /* best-effort - not fatal if unsupported */ });
  return link;
}

export function decodeMessage(message: ArrayBuffer): string {
  return decoder.decodeToString(new Uint8Array(message));
}
