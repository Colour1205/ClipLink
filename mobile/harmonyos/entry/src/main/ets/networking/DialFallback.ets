// Trusting a device is one-sided: it only decides whether THIS device accepts it. To keep two
// devices that hear each other from opening two connections, only one of them dials - the one
// whose key sorts after the other's. When both trust each other that is fine. But when only one
// does - the user just tapped Trust here, and the other device has not been asked yet - and
// the other's key is the larger, nobody dials: the other never trusts this device, so it does not
// dial, and this one waits for it to. The pairing request never reaches the other device.
//
// So a trusted device that should have dialled this one, but has not connected after a few
// seconds, is dialled by this one after all (and again every half minute while it stays
// unconnected). If it does trust this device it has long since connected and this never fires; if
// it does not, the dial is what raises the pairing request there. The same rule is in every
// platform's engine: change them together.

// How long a trusted device that should dial this one is given to do so.
export const DIAL_FALLBACK_WAIT_MS: number = 8000;
// How often it is dialled after that while it stays unconnected.
export const DIAL_FALLBACK_EVERY_MS: number = 30000;

export class DialFallback {
  private since: Map<string, number> = new Map();
  private lastDial: Map<string, number> = new Map();

  // True when a trusted device that should have dialled this one has waited long
  // enough, and was not dialled in the last DIAL_FALLBACK_EVERY_MS. Counts the call as
  // the dial.
  due(id: string, nowMs: number = Date.now()): boolean {
    let first: number | undefined = this.since.get(id);
    if (first === undefined) {
      first = nowMs;
      this.since.set(id, first);
    }
    if (nowMs - first < DIAL_FALLBACK_WAIT_MS) return false;
    const last: number | undefined = this.lastDial.get(id);
    if (last !== undefined && nowMs - last < DIAL_FALLBACK_EVERY_MS) return false;
    this.lastDial.set(id, nowMs);
    return true;
  }

  // It is connected (or gone): start counting again next time.
  connected(id: string): void {
    this.since.delete(id);
    this.lastDial.delete(id);
  }
}
