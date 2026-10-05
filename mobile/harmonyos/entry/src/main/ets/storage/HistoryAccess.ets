// Step 8 of the build order in ../../../../README.md: full sync.
// Mirrors windows/ClipLink/Engine/Storage/HistoryAccess.cs — same 25-item cap,
// oldest-first eviction, same file-blob cleanup on eviction for file-type
// entries. Preferences only stores flat ValueType entries, so (same
// tradeoff as TrustStore.ets) the whole history is kept as one
// JSON-serialized array under a single key.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';
import { FileStore, isEmptyFile, isValidFileHash } from './FileStore';
import { FilePayload } from './FilePayload';
import { DeletedEntries, entryKey } from './DeletedEntries';

const PREFERENCES_NAME = 'cliplink_history';
const HISTORY_KEY = 'entries';
const MAX_HISTORY_ITEMS = 25;

export class HistoryAccess {
  private fileStore: FileStore;
  private deleted: DeletedEntries = new DeletedEntries();
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

  // Deleted or cleared on this device (see DeletedEntries.ets).
  isDeleted(context: common.UIAbilityContext, entry: ClipboardEntry): Promise<boolean> {
    return this.deleted.contains(context, entryKey(entry));
  }

  // Returns true only if the entry was genuinely new (not a duplicate) -
  // matches HistoryAccess.cs's addToHistory return contract, which callers
  // rely on to decide whether to also apply/re-broadcast an entry. A deleted
  // entry counts as not new: checked in here too, not just by the caller, so
  // one that passed that check just before its delete ran stays deleted.
  addToHistory(context: common.UIAbilityContext, entry: ClipboardEntry): Promise<boolean> {
    return this.serialized(async (): Promise<boolean> => {
      if (await this.deleted.contains(context, entryKey(entry))) {
        return false;
      }
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
  // FileStore blob for evicted file-type entries no remaining entry shares,
  // same as Windows. Compared
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
      this.releaseBlobIfUnused(oldest, entries);
    }
  }

  // Entries come from peers too, so their FileHash is only a blob to
  // release if it's a real hash (see FileStore's isValidFileHash) - never a
  // path to delete.
  private filePayloadOf(entry: ClipboardEntry): FilePayload | null {
    if (entry.Type !== 'file') return null;
    try {
      const payload: FilePayload = JSON.parse(entry.Content) as FilePayload;
      return isValidFileHash(payload.FileHash) ? payload : null;
    } catch (e) {
      return null; // malformed descriptor — nothing coherent to clean up
    }
  }

  private fileHashOf(entry: ClipboardEntry): string | null {
    const payload: FilePayload | null = this.filePayloadOf(entry);
    return payload !== null ? payload.FileHash : null;
  }

  private releaseBlob(entry: ClipboardEntry): void {
    const hash = this.fileHashOf(entry);
    if (hash !== null) {
      this.fileStore.delete(hash);
    }
  }

  // FileStore is keyed by content hash, so one blob backs every entry for
  // the same file (copied twice, say) - it only goes once none of
  // `remaining` points at it any more.
  private releaseBlobIfUnused(entry: ClipboardEntry, remaining: ClipboardEntry[]): void {
    const hash = this.fileHashOf(entry);
    if (hash !== null && !remaining.some(e => this.fileHashOf(e) === hash)) {
      this.fileStore.delete(hash);
    }
  }

  // Removes one entry (by entryKey) from this device and tombstones it -
  // the tombstone even when the entry is no longer in the capped history,
  // so a peer that still has it can't send it back. Its file blob goes too
  // unless an entry that stays still points at the same bytes.
  deleteEntry(context: common.UIAbilityContext, key: string): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      await this.deleted.add(context, [key]);
      const entries = await this.getHistory(context);
      const kept = entries.filter(e => entryKey(e) !== key);
      if (kept.length === entries.length) return;
      await this.saveHistory(context, kept);
      for (const entry of entries) {
        if (entryKey(entry) === key) {
          this.releaseBlobIfUnused(entry, kept);
        }
      }
    });
  }

  // For bytes that finished arriving after the entry waiting on them was
  // deleted or cleared (see SyncManager.handleFileChunk): kept only if an
  // entry still in history points at them, or they'd sit in FileStore for
  // good.
  deleteFileIfUnused(context: common.UIAbilityContext, hash: string): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const entries = await this.getHistory(context);
      if (!entries.some(e => this.fileHashOf(e) === hash)) {
        this.fileStore.delete(hash);
      }
    });
  }

  // Startup housekeeping: deletes the FileStore blobs no history entry
  // points at (see FileStore.deleteUnreferenced), and stores the empty file
  // an entry received before empty files were handled here is still waiting
  // for (see SyncManager.handleIncomingFileEntry). Serialized with every
  // history write, so an entry added meanwhile is either counted here, or
  // its blob is already in use and left alone. Returns how many went.
  deleteUnreferencedFiles(context: common.UIAbilityContext): Promise<number> {
    return this.serialized(async (): Promise<number> => {
      const entries = await this.getHistory(context);
      const referenced: Set<string> = new Set<string>();
      for (const entry of entries) {
        const payload: FilePayload | null = this.filePayloadOf(entry);
        if (payload === null) continue;
        referenced.add(payload.FileHash.toLowerCase());
        if (isEmptyFile(payload) && !this.fileStore.exists(payload.FileHash)) {
          // On failure it's left waiting, as before - the next start tries again.
          this.fileStore.write(payload.FileHash, new Uint8Array(0));
        }
      }
      return this.fileStore.deleteUnreferenced(referenced);
    });
  }

  // Deletes only the blobs the cleared entries referenced, like Android's
  // HistoryStore.clear - not the whole files directory, which can hold a
  // half-written .tmp an in-progress transfer still has open. Every cleared
  // entry is tombstoned first, plus alsoDeletedKeys (entries the caller knows
  // of that aren't in the capped history any more), so peers can't refill it.
  clearHistory(context: common.UIAbilityContext, alsoDeletedKeys: string[]): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const entries = await this.getHistory(context);
      await this.deleted.add(context, [...entries.map(e => entryKey(e)), ...alsoDeletedKeys]);
      for (const entry of entries) {
        this.releaseBlob(entry);
      }
      await this.saveHistory(context, []);
    });
  }
}
