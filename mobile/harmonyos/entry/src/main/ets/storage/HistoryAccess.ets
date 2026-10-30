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
import { MergeResult, mergeBatch, trimOldest } from './HistoryBatch';

const PREFERENCES_NAME = 'cliplink_history';
const HISTORY_KEY = 'entries';
export const MAX_HISTORY_ITEMS = 25;

export class HistoryAccess {
  private fileStore: FileStore;
  private deleted: DeletedEntries = new DeletedEntries();
  // Every read-modify-write of the history runs one at a time. Each yields
  // at getPreferences/flush, so an add that read the old list before a
  // clear wrote [] could write it back afterwards - resurrecting cleared
  // entries whose file blobs had already been deleted.
  private chain: Promise<void> = Promise.resolve();
  // The saved history, parsed once (see loadHistory); null until it has
  // been read. The JSON is big - an image item is its PNG in Base64, so 25
  // items are around 10 MB - and parsing it on every read cost the UI
  // thread 15 ms a time: a peer's history batch, which adds each of its 25
  // items in turn, re-parsed it 25 times (0.4 s, measured) the moment the
  // peer connected.
  private cached: ClipboardEntry[] | null = null;
  // The key of the item the last sync put on the clipboard and on top of the
  // list: the trim does not drop it while it is set (the oldest other item
  // goes instead). Memory only: it ends with the app, and when a newer item
  // arrives (a live one, or another sync's).
  private protectedKey: string | null = null;

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

  // A copy of the list, as last saved: a caller may sort or add to it
  // without touching what the next caller reads.
  async getHistory(context: common.UIAbilityContext): Promise<ClipboardEntry[]> {
    return (await this.loadHistory(context)).slice();
  }

  private async loadHistory(context: common.UIAbilityContext): Promise<ClipboardEntry[]> {
    if (this.cached !== null) return this.cached;
    const prefs = await this.getPrefs(context);
    const json = prefs.getSync(HISTORY_KEY, '[]') as string;
    let entries: ClipboardEntry[];
    try {
      entries = JSON.parse(json) as ClipboardEntry[];
    } catch (e) {
      // corrupt preferences value — regenerate rather than crash, same
      // policy HistoryAccess.cs/TrustStore.cs use on the Windows side
      entries = [];
    }
    // Another read may have finished while this one waited for the store.
    if (this.cached === null) this.cached = entries;
    return this.cached;
  }

  private async saveHistory(context: common.UIAbilityContext, entries: ClipboardEntry[]): Promise<void> {
    this.cached = entries;
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

  private isProtected(entry: ClipboardEntry): boolean {
    return this.protectedKey !== null && entryKey(entry) === this.protectedKey;
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
      // A live item is the newest arrival: what an earlier sync spared is
      // trimmed by the normal rule from here on.
      this.protectedKey = null;
      await this.trimToLimit(entries);
      await this.saveHistory(context, entries);
      return true;
    });
  }

  // A peer's whole history_batch as one change: one read of the list, every
  // new entry added to it, one trim, one write. The entries must already be
  // verified and trusted (see SyncManager.handleHistoryBatch); the same
  // rules as addToHistory decide which are new - a duplicate, or one deleted
  // here, is not (checked in here too, for the same reason). `added` is only
  // what is new AND still in the history after the trim: an entry stored
  // just to be evicted again is not one to show or apply. With `newFront` the
  // newest of the new entries is the item this sync puts on the clipboard: the
  // trim spares it, even when it is the oldest of all, until a newer item
  // arrives (see mergeBatch and protectedKey). `frontOk` is asked once, with that
  // newest new entry, before the trim: only if it says yes is the entry the
  // front (the result's `front`) and spared.
  addBatch(context: common.UIAbilityContext, candidates: ClipboardEntry[], newFront: boolean = false,
    frontOk: (entry: ClipboardEntry) => boolean = (entry: ClipboardEntry): boolean => true): Promise<MergeResult> {
    return this.serialized(async (): Promise<MergeResult> => {
      const gone: Set<string> = new Set<string>();
      for (const entry of candidates) {
        const key: string = entryKey(entry);
        if (await this.deleted.contains(context, key)) gone.add(key);
      }
      const entries = await this.getHistory(context);
      const result: MergeResult = mergeBatch(entries, candidates, (a: ClipboardEntry, b: ClipboardEntry) => this.isSameEntry(a, b),
        (entry: ClipboardEntry) => gone.has(entryKey(entry)), MAX_HISTORY_ITEMS, newFront,
        (entry: ClipboardEntry) => this.isProtected(entry), frontOk);
      if (result.added.length === 0 && result.evicted.length === 0) return result;
      if (result.front !== null) this.protectedKey = entryKey(result.front);
      await this.saveHistory(context, entries);
      for (const evicted of result.evicted) {
        this.releaseBlobIfUnused(evicted, entries);
      }
      return result;
    });
  }

  // Which of these keys (entryKey) this device has already, or deleted: what a
  // history_head's keys are counted against (see HistoryBatch.applyHead).
  goneKeys(context: common.UIAbilityContext, keys: string[]): Promise<Set<string>> {
    return this.serialized(async (): Promise<Set<string>> => {
      const gone: Set<string> = new Set<string>();
      const known: Set<string> = new Set<string>((await this.loadHistory(context)).map((e: ClipboardEntry) => entryKey(e)));
      for (const key of keys) {
        if (known.has(key) || await this.deleted.contains(context, key)) gone.add(key);
      }
      return gone;
    });
  }

  // Oldest-first eviction once over the cap - also deletes the backing
  // FileStore blob for evicted file-type entries no remaining entry shares,
  // same as Windows. Compared in canonical form, which is fixed-width, so text
  // order is time order. The entry a sync spared (protectedKey) is not the one
  // that goes.
  private async trimToLimit(entries: ClipboardEntry[]): Promise<void> {
    for (const oldest of trimOldest(entries, MAX_HISTORY_ITEMS, (entry: ClipboardEntry) => this.isProtected(entry))) {
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
    return this.deleteEntries(context, [key]);
  }

  // deleteEntry for several keys at once (a peer's delete, or the tombstones in
  // its history_head): every key is tombstoned, whether this device has the
  // entry or not, and the entries it has go in one write.
  deleteEntries(context: common.UIAbilityContext, keys: string[]): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      await this.deleted.add(context, keys);
      const gone: Set<string> = new Set<string>(keys);
      if (this.protectedKey !== null && gone.has(this.protectedKey)) this.protectedKey = null;
      const entries = await this.getHistory(context);
      const kept = entries.filter(e => !gone.has(entryKey(e)));
      if (kept.length === entries.length) return;
      await this.saveHistory(context, kept);
      for (const entry of entries) {
        if (gone.has(entryKey(entry))) {
          this.releaseBlobIfUnused(entry, kept);
        }
      }
    });
  }

  // The tombstones a v2 history_head lists: the keys of the `limit` most
  // recent, the most recently deleted first.
  recentDeleted(context: common.UIAbilityContext, limit: number): Promise<string[]> {
    return this.deleted.recent(context, limit);
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
  // Returns every key tombstoned, for the delete message v2 peers get.
  clearHistory(context: common.UIAbilityContext, alsoDeletedKeys: string[]): Promise<string[]> {
    return this.serialized(async (): Promise<string[]> => {
      const entries = await this.getHistory(context);
      const keys: string[] = Array.from(new Set<string>([...entries.map(e => entryKey(e)), ...alsoDeletedKeys]));
      await this.deleted.add(context, keys);
      for (const entry of entries) {
        this.releaseBlob(entry);
      }
      this.protectedKey = null;
      await this.saveHistory(context, []);
      return keys;
    });
  }
}
