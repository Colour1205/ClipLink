// Step 4 of the build order in ../../../../README.md: local persistence.
// Mirrors windows/ClipLink/Engine/Identity/TrustStore.cs. Preferences only stores
// flat ValueType entries (no nested objects/arrays), so the whole trusted-
// device list is kept as one JSON-serialized string under a single key —
// same tradeoff the Windows version makes with a single JSON file, and
// same gap: not encrypted at rest (flagged in docs/security.md finding #8,
// carried over here rather than silently "fixed" on one platform only).

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { normalizeDeviceName } from './DeviceName';

const PREFERENCES_NAME = 'cliplink_trust_store';
const DEVICES_KEY = 'trusted_devices';

export interface TrustedDevice {
  publicKey: string;
  address?: string;
  // The peer's own display name, the latest its handshake sent - written
  // only once that connection's first envelope decrypted (see
  // PeerConnection.onSessionProven), since the handshake's signature
  // doesn't cover the name. Never from a beacon, which anyone on the LAN
  // can forge (beacon names stay in memory, see Index.ets's deviceRows).
  // Absent in records written before names existed, for a peer that never
  // sent one, or until a paired peer's first connection proves itself.
  name?: string;
}

export class TrustStore {
  private prefs: preferences.Preferences | null = null;
  // The list as isTrusted last parsed it, and the stored text it was parsed
  // from. isTrusted runs for every beacon (every 2 s from each device on the
  // LAN, someone else's included) and every received entry, and parsed the
  // list each time. Kept by its text rather than dropped on save, so it can
  // never be out of date: what is stored is read every time, and only parsed
  // again when it changed.
  private parsed: TrustedDevice[] = [];
  private parsedFrom: string | null = null;
  // Every read-modify-write of the list runs one at a time (as
  // HistoryAccess.serialized does), so two changes never write over each
  // other - a removal undone by an update that read the list before it.
  private chain: Promise<void> = Promise.resolve();

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.chain.then(work);
    this.chain = result.then(() => {}, () => {});
    return result;
  }

  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (this.prefs === null) {
      this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    }
    return this.prefs;
  }

  // A list of its own for each caller, which may change it.
  private async loadAll(context: common.UIAbilityContext): Promise<TrustedDevice[]> {
    const prefs = await this.getPrefs(context);
    return this.parse(prefs.getSync(DEVICES_KEY, '[]') as string);
  }

  // The stored list, shared: read it, never change it.
  private async current(context: common.UIAbilityContext): Promise<TrustedDevice[]> {
    const prefs = await this.getPrefs(context);
    const json = prefs.getSync(DEVICES_KEY, '[]') as string;
    if (json !== this.parsedFrom) {
      this.parsed = this.parse(json);
      this.parsedFrom = json;
    }
    return this.parsed;
  }

  private parse(json: string): TrustedDevice[] {
    try {
      const devices = JSON.parse(json) as TrustedDevice[];
      // Older builds stored names unsanitised - clean them on the way out
      // rather than trusting what's on disk.
      for (const d of devices) {
        if (typeof d.name === 'string') d.name = normalizeDeviceName(d.name) ?? undefined;
      }
      return devices;
    } catch (e) {
      // corrupt preferences value — regenerate rather than crash startup,
      // same policy HistoryAccess.cs/TrustStore.cs use on the Windows side
      return [];
    }
  }

  private async saveAll(context: common.UIAbilityContext, devices: TrustedDevice[]): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(DEVICES_KEY, JSON.stringify(devices));
    await prefs.flush();
  }

  // Adds the record, or updates its address - never its name, which only
  // rememberName writes (see TrustedDevice.name). No address keeps the
  // stored one.
  trust(context: common.UIAbilityContext, publicKey: string, address?: string): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const devices = await this.loadAll(context);
      const existing = devices.find(d => d.publicKey === publicKey);
      if (existing) {
        existing.address = address ?? existing.address;
      } else {
        devices.push({ publicKey, address });
      }
      await this.saveAll(context, devices);
    });
  }

  // The address of a device that's trusted already - never adds a record, so
  // a device removed while its connection was being set up stays removed
  // (trust() would write it back). Resolves whether the device is still
  // trusted. No address writes nothing.
  updateAddress(context: common.UIAbilityContext, publicKey: string, address?: string): Promise<boolean> {
    return this.serialized(async (): Promise<boolean> => {
      const devices = await this.loadAll(context);
      const existing = devices.find(d => d.publicKey === publicKey);
      if (existing === undefined) return false;
      if (address !== undefined && existing.address !== address) {
        existing.address = address;
        await this.saveAll(context, devices);
      }
      return true;
    });
  }

  // Name-only update for a device that's already trusted: never adds a
  // record and never touches the address. Resolves true only when something
  // changed, so a caller can skip needless refreshes. Only for a handshake's
  // name, once its connection has decrypted an envelope - never a beacon's
  // (see TrustedDevice.name).
  async rememberName(context: common.UIAbilityContext, publicKey: string, name: string): Promise<boolean> {
    if (name.length === 0) return false;
    return this.serialized(async (): Promise<boolean> => {
      const devices = await this.loadAll(context);
      const existing = devices.find(d => d.publicKey === publicKey);
      if (existing === undefined || existing.name === name) return false;
      existing.name = name;
      await this.saveAll(context, devices);
      return true;
    });
  }

  untrust(context: common.UIAbilityContext, publicKey: string): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const devices = await this.loadAll(context);
      await this.saveAll(context, devices.filter(d => d.publicKey !== publicKey));
    });
  }

  async isTrusted(context: common.UIAbilityContext, publicKey: string): Promise<boolean> {
    const devices = await this.current(context);
    return devices.some(d => d.publicKey === publicKey);
  }

  async getAllTrustedDevices(context: common.UIAbilityContext): Promise<TrustedDevice[]> {
    return this.loadAll(context);
  }

  async getTrustedDevicesWithAddress(context: common.UIAbilityContext): Promise<TrustedDevice[]> {
    const devices = await this.loadAll(context);
    return devices.filter(d => d.address !== undefined && d.address !== null && d.address.length > 0);
  }
}
