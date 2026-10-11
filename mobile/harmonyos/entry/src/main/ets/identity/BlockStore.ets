// The devices this one has blocked. A blocked device never gets a pairing
// prompt, is never dialled, is never trusted by a shared passcode, and its
// handshake is refused before anything else about it is decided - so it
// cannot be a source of spam, however often it asks.
//
// Blocking is blocking a KEY. Someone who generates a new identity is a new
// device and is not stopped by this; what it does stop is the usual case, one
// phone or PC that keeps asking.
//
// Mirrors the Windows and Android block stores: a list of ids with the name
// each had when it was blocked (what the Devices tab shows for it - it may
// never beacon again). Preferences only stores flat values, so the list is one
// JSON string under a single key, like TrustStore; not encrypted at rest,
// same as the trust store beside it.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { normalizeDeviceName } from './DeviceName';
import { sameIdentityKey } from '../networking/PeerConnection';

const PREFERENCES_NAME = 'cliplink_block_store';
const DEVICES_KEY = 'blocked_devices';

export interface BlockedDevice {
  deviceId: string;
  name?: string;
}

export class BlockStore {
  private prefs: preferences.Preferences | null = null;

  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (this.prefs === null) {
      this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    }
    return this.prefs;
  }

  async getAll(context: common.UIAbilityContext): Promise<BlockedDevice[]> {
    const prefs = await this.getPrefs(context);
    const json = prefs.getSync(DEVICES_KEY, '[]') as string;
    try {
      const devices = JSON.parse(json) as BlockedDevice[];
      for (const d of devices) {
        if (typeof d.name === 'string') d.name = normalizeDeviceName(d.name) ?? undefined;
      }
      return devices.filter((d: BlockedDevice) => typeof d.deviceId === 'string' && d.deviceId.length > 0);
    } catch (e) {
      // Corrupt value - an empty list rather than a crash on startup, the
      // policy every store here follows.
      return [];
    }
  }

  private async saveAll(context: common.UIAbilityContext, devices: BlockedDevice[]): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(DEVICES_KEY, JSON.stringify(devices));
    await prefs.flush();
  }

  // Compared as keys, not text: the Base64 decoder skips what is not Base64,
  // so one key can be spelt several ways and still verify as itself. Compared
  // as text alone, that would be a way round the block.
  async isBlocked(context: common.UIAbilityContext, deviceId: string): Promise<boolean> {
    const devices = await this.getAll(context);
    return devices.some((d: BlockedDevice) => sameIdentityKey(d.deviceId, deviceId));
  }

  // Adds the device, or - if it is already blocked - keeps its name unless a
  // better one is given.
  async block(context: common.UIAbilityContext, deviceId: string, name?: string): Promise<void> {
    const devices = await this.getAll(context);
    const known: string | undefined = name !== undefined && name.trim().length > 0 ? name : undefined;
    const existing = devices.find((d: BlockedDevice) => sameIdentityKey(d.deviceId, deviceId));
    if (existing === undefined) {
      devices.push({ deviceId: deviceId, name: known });
    } else {
      existing.name = known ?? existing.name;
    }
    await this.saveAll(context, devices);
  }

  async unblock(context: common.UIAbilityContext, deviceId: string): Promise<void> {
    const devices = await this.getAll(context);
    await this.saveAll(context, devices.filter((d: BlockedDevice) => !sameIdentityKey(d.deviceId, deviceId)));
  }
}
