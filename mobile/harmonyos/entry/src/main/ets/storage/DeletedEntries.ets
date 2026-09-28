// Deleting a synced item (or clearing them all) leaves a tombstone here, so
// a peer's next history_batch - or a relay of the same live entry - can't
// bring it back. Local only: peers are never told and keep their own copies.
// Same records as the Windows daemon's deleted{label}.json - {Key,
// DeletedAt} - capped at 2000, oldest dropped first. Kept as one JSON string
// under one preferences key, same tradeoff as HistoryAccess.ets.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ClipboardEntry } from '../crypto/Signing';

const PREFERENCES_NAME = 'cliplink_deleted';
const DELETED_KEY = 'entries';
const MAX_DELETED = 2000;

const textEncoder = util.TextEncoder.create('utf-8');

export interface DeletedEntry {
  Key: string;
  DeletedAt: number; // ms since the epoch
}

function sha256Hex(text: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: textEncoder.encodeInto(text) });
  const digest = md.digestSync().data;
  let out = '';
  for (let i = 0; i < digest.length; i++) {
    out += digest[i].toString(16).padStart(2, '0');
  }
  return out;
}

// What names one entry on every platform: its Signature exactly as stored.
// Every synced entry is signed - the fallback only covers one that isn't.
export function entryKey(entry: ClipboardEntry): string {
  if (entry.Signature) return entry.Signature;
  return `${entry.DeviceId}|${entry.Type}|${entry.Timestamp}|${sha256Hex(entry.Content)}`;
}

export class DeletedEntries {
  private prefs: preferences.Preferences | null = null;
  // Read once, then kept in step with every write: it's checked for every
  // entry of every history_batch, too often to re-parse 2000 records each time.
  private records: DeletedEntry[] | null = null;
  private keys: Set<string> = new Set();

  private async load(context: common.UIAbilityContext): Promise<DeletedEntry[]> {
    if (this.records !== null) return this.records;
    const prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
    // Another caller may have finished loading while this one waited.
    if (this.records !== null) return this.records;
    let records: DeletedEntry[];
    try {
      const parsed = JSON.parse(prefs.getSync(DELETED_KEY, '[]') as string) as DeletedEntry[];
      // Anything but an array would throw below, on every incoming entry.
      records = Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      // corrupt preferences value - start over rather than crash, same
      // policy as HistoryAccess.ets
      records = [];
    }
    // Oldest first, so add() trims the excess from the front.
    records.sort((a: DeletedEntry, b: DeletedEntry) => a.DeletedAt - b.DeletedAt);
    this.prefs = prefs;
    this.records = records;
    this.keys = new Set(records.map((r: DeletedEntry) => r.Key));
    return records;
  }

  async contains(context: common.UIAbilityContext, key: string): Promise<boolean> {
    await this.load(context);
    return this.keys.has(key);
  }

  // Records these keys as deleted now. One already recorded keeps its
  // original time, as on Windows. Nothing awaits between reading the
  // records and putSync, so two adds running at once can't lose each
  // other's keys.
  async add(context: common.UIAbilityContext, keys: string[]): Promise<void> {
    const records = await this.load(context);
    const now = Date.now();
    let changed = false;
    for (const key of keys) {
      if (this.keys.has(key)) continue;
      this.keys.add(key);
      records.push({ Key: key, DeletedAt: now });
      changed = true;
    }
    if (!changed) return;
    if (records.length > MAX_DELETED) {
      const dropped = records.splice(0, records.length - MAX_DELETED);
      for (const record of dropped) {
        this.keys.delete(record.Key);
      }
    }
    const prefs = this.prefs as preferences.Preferences;
    prefs.putSync(DELETED_KEY, JSON.stringify(records));
    await prefs.flush();
  }
}
