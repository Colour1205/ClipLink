import { describe, it, expect } from '@ohos/hypium';
import { encodeBeacon, parseBeacon, PeerBeacon } from '../main/ets/networking/Discovery';

const ID = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELJdLZfH8G9XIDYe6E1HXjg728AExFbYPZCfEVXyR9VQ=';
const SENDER = '192.168.1.40';

function parsed(text: string): PeerBeacon {
  const beacon: PeerBeacon | null = parseBeacon(text, SENDER);
  if (beacon === null) throw new Error(`not a beacon: ${text}`);
  return beacon;
}

// The beacon's wire form is "{tcpPort}:{deviceID}:{proof}:{address}:-:{name}".
// The fifth field once said the sender's Pairing screen was open; it is kept
// as "-" so old and new builds still read each other, and nothing reads it.
// (These cases stay clear of the name field: the local unit-test runtime's
// Base64Helper is a stub - see IdentityKey.test.)
export default function beaconTest() {
  describe('encodeBeacon', () => {
    it('alwaysWritesTheFifthFieldAsADash', 0, () => {
      const full = encodeBeacon(49152, ID, 'proof', '100.64.0.1', null).split(':');
      expect(full.length).assertEqual(6);
      expect(full[4]).assertEqual('-');
      const bare = encodeBeacon(49152, ID, null, null, null).split(':');
      expect(bare.length).assertEqual(6);
      expect(bare[4]).assertEqual('-');
    });

    it('putsADashWhereAFieldIsMissing', 0, () => {
      expect(encodeBeacon(49152, ID, null, null, null)).assertEqual(`49152:${ID}:-:-:-:-`);
      expect(encodeBeacon(49152, ID, 'proof', '100.64.0.1', null)).assertEqual(`49152:${ID}:proof:100.64.0.1:-:-`);
    });
  });

  describe('parseBeacon', () => {
    it('readsTheFieldsOfASixFieldBeacon', 0, () => {
      const beacon = parsed(`49152:${ID}:proof:100.64.0.1:-:-`);
      expect(beacon.tcpPort).assertEqual(49152);
      expect(beacon.deviceId).assertEqual(ID);
      expect(beacon.proof).assertEqual('proof');
      expect(beacon.address).assertEqual('100.64.0.1');
      expect(beacon.name).assertNull();
      expect(beacon.senderIp).assertEqual(SENDER);
    });

    it('ignoresTheFifthFieldOfAnOldBuild', 0, () => {
      const old = parsed(`49152:${ID}:proof:100.64.0.1:1:-`);
      const current = parsed(`49152:${ID}:proof:100.64.0.1:-:-`);
      expect(old.tcpPort).assertEqual(current.tcpPort);
      expect(old.deviceId).assertEqual(current.deviceId);
      expect(old.proof).assertEqual(current.proof);
      expect(old.address).assertEqual(current.address);
      expect(old.name).assertEqual(current.name);
      expect(old.senderIp).assertEqual(current.senderIp);
    });

    it('stillReadsAFiveFieldBeacon', 0, () => {
      const beacon = parsed(`49152:${ID}:proof:100.64.0.1:1`);
      expect(beacon.deviceId).assertEqual(ID);
      expect(beacon.proof).assertEqual('proof');
      expect(beacon.address).assertEqual('100.64.0.1');
      expect(beacon.name).assertNull();
    });

    it('stillReadsAFourFieldBeacon', 0, () => {
      const beacon = parsed(`49152:${ID}:-:100.64.0.1`);
      expect(beacon.proof).assertNull();
      expect(beacon.address).assertEqual('100.64.0.1');
      expect(beacon.name).assertNull();
    });

    it('readsDashesAsMissingFields', 0, () => {
      const beacon = parsed(`49152:${ID}:-:-:-:-`);
      expect(beacon.proof).assertNull();
      expect(beacon.address).assertNull();
      expect(beacon.name).assertNull();
    });

    it('refusesADatagramTooShortToBeABeacon', 0, () => {
      expect(parseBeacon('', SENDER)).assertNull();
      expect(parseBeacon('49152', SENDER)).assertNull();
      expect(parseBeacon(`49152:${ID}`, SENDER)).assertNull();
    });

    it('readsWhatItSends', 0, () => {
      const beacon = parsed(encodeBeacon(49152, ID, 'proof', '100.64.0.1', null));
      expect(beacon.tcpPort).assertEqual(49152);
      expect(beacon.deviceId).assertEqual(ID);
      expect(beacon.proof).assertEqual('proof');
      expect(beacon.address).assertEqual('100.64.0.1');
    });
  });
}
