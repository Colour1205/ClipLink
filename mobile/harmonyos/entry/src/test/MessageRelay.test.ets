import { describe, it, expect } from '@ohos/hypium';
import socket from '@ohos.net.socket';
import { MessageRelay } from '../main/ets/networking/PeerConnection';

// A 'message' event's payload, as the socket delivers it: only the bytes
// matter here.
function info(byte: number): socket.SocketMessageInfo {
  const message: ArrayBuffer = new Uint8Array([byte]).buffer as ArrayBuffer;
  return { message: message, remoteInfo: { address: '192.168.1.40', family: 'IPv4', port: 49000, size: 1 } };
}

function firstByte(received: socket.SocketMessageInfo): number {
  return new Uint8Array(received.message)[0];
}

// The adapters in PeerConnection.ets listen to the socket from the moment
// they are made and hand the events on through a MessageRelay, so what a
// peer sends before the channel asks (its handshake, written the moment it
// accepts the dial) is not lost. See the relay's own comment.
export default function messageRelayTest() {
  describe('MessageRelay', () => {
    it('replaysWhatArrivedBeforeAnyoneListenedInOrder', 0, () => {
      const relay = new MessageRelay();
      relay.message(info(1));
      relay.message(info(2));
      const seen: number[] = [];
      relay.onMessage((received: socket.SocketMessageInfo) => { seen.push(firstByte(received)); });
      expect(seen.length).assertEqual(2);
      expect(seen[0]).assertEqual(1);
      expect(seen[1]).assertEqual(2);
    });

    it('deliversStraightAwayOnceSomeoneListens', 0, () => {
      const relay = new MessageRelay();
      const seen: number[] = [];
      relay.onMessage((received: socket.SocketMessageInfo) => { seen.push(firstByte(received)); });
      relay.message(info(7));
      expect(seen.length).assertEqual(1);
      expect(seen[0]).assertEqual(7);
    });

    it('replaysEachHeldMessageOnlyOnce', 0, () => {
      const relay = new MessageRelay();
      relay.message(info(1));
      let count: number = 0;
      relay.onMessage(() => { count++; });
      relay.message(info(2));
      expect(count).assertEqual(2);
    });

    it('tellsALateCloseListenerTheSocketAlreadyClosed', 0, () => {
      const relay = new MessageRelay();
      relay.close();
      let closed: boolean = false;
      relay.onClose(() => { closed = true; });
      expect(closed).assertTrue();
    });

    it('tellsACloseListenerWhenTheSocketCloses', 0, () => {
      const relay = new MessageRelay();
      let closed: boolean = false;
      relay.onClose(() => { closed = true; });
      expect(closed).assertFalse();
      relay.close();
      expect(closed).assertTrue();
    });
  });
}
