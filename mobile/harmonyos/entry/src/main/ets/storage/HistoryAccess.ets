// Step 8 of the build order in ../../../../README.md: full sync.
// Mirrors windows/daemon/Storage/HistoryAccess.cs — same 25-item cap,
// oldest-first eviction, same file-blob cleanup on eviction for file-type
// entries. Preferences only stores flat ValueType entries, so (same
// tradeoff as TrustStore.ets) the whole history is kept as one
// JSON-serialized array under a single key.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';
import { FileStore } from './FileStore';
import { FilePayload } from './FilePayload';

const PREFERENCES_NAME = 'cliplink_history';
const HISTORY_KEY = 'entries';
const MAX_HISTORY_ITEMS = 25;

export class HistoryAccess {
  private fileStore: FileStore;
  // Every read-modify-write of the history runs one at a time. Each yields
  // at getPreferences/flush, so an add that read the old list before a
  // clear wrote [] could write it back afterwards - resurrecting cleared
  // entries whose file blobs had already been deleted.
  private chain: Promise<void> = Promise.resolve();

  constructor(fileStore: FileStore) {
    this.fileStore = fileStore;
  }

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.chain.then(work);
    this.chain = result.then(() => {}, () => {});
    return result;
  }

  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, PREFERENCES_NAME);
  }

  async getHistory(context: common.UIAbilityContext): Promise<ClipboardEntry[]> {
    const prefs = await this.getPrefs(context);
    const json = prefs.getSync(HISTORY_KEY, '[]') as string;
    try {
      return JSON.parse(json) as ClipboardEntry[];
    } catch (e) {
      // corrupt preferences value — regenerate rather than crash, same
      // policy HistoryAccess.cs/TrustStore.cs use on the Windows side
      return [];
    }
  }

  private async saveHistory(context: common.UIAbilityContext, entries: ClipboardEntry[]): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(HISTORY_KEY, JSON.stringify(entries));
    await prefs.flush();
  }

  // Timestamps compare in canonical form so a trimmed and an untrimmed
  // spelling of one instant (see Signing.ets) count as the same entry.
  private isSameEntry(a: ClipboardEntry, b: ClipboardEntry): boolean {
    return a.Content === b.Content && a.Type === b.Type && a.DeviceId === b.DeviceId
      && canonicalTimestamp(a.Timestamp) === canonicalTimestamp(b.Timestamp) && a.Signature === b.Signature;
  }

  // Returns true only if the entry was genuinely new (not a duplicate) -
  // matches HistoryAccess.cs's addToHistory return contract, which callers
  // rely on to decide whether to also apply/re-broadcast an entry.
  addToHistory(context: common.UIAbilityContext, entry: ClipboardEntry): Promise<boolean> {
    return this.serialized(async (): Promise<boolean> => {
      const entries = await this.getHistory(context);
      if (entries.some(e => this.isSameEntry(e, entry))) {
        return false;
      }
      entries.push(entry);
      await this.trimToLimit(entries);
      await this.saveHistory(context, entries);
      return true;
    });
  }

  // Oldest-first eviction once over the cap - also deletes the backing
  // FileStore blob for evicted file-type entries, same as Windows. Compared
  // in canonical form, which is fixed-width, so text order is time order.
  private async trimToLimit(entries: ClipboardEntry[]): Promise<void> {
    while (entries.length > MAX_HISTORY_ITEMS) {
      let oldestIndex = 0;
      for (let i = 1; i < entries.length; i++) {
        if (canonicalTimestamp(entries[i].Timestamp) < canonicalTimestamp(entries[oldestIndex].Timestamp)) {
          oldestIndex = i;
        }
      }
      const oldest = entries.splice(oldestIndex, 1)[0];
      this.releaseBlob(oldest);
    }
  }

  private releaseBlob(entry: ClipboardEntry): void {
    if (entry.Type !== 'file') return;
    try {
      const payload = JSON.parse(entry.Content) as FilePayload;
      this.fileStore.delete(payload.FileHash);
    } catch (e) {
      // malformed descriptor — nothing coherent to clean up
    }
  }

  // Deletes only the blobs the cleared entries referenced, like Android's
  // HistoryStore.clear - not the whole files directory, which can hold a
  // half-written .tmp an in-progress transfer still has open.
  clearHistory(context: common.UIAbilityContext): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const entries = await this.getHistory(context);
      for (const entry of entries) {
        this.releaseBlob(entry);
      }
      await this.saveHistory(context, []);
    });
  }
}
