// Step 4 of the build order in ../../../../README.md: local persistence.
// Mirrors windows/daemon/Storage/FileStore.cs — content-addressed blob
// storage keyed by SHA-256 hex hash. Descriptor-only by design: this class
// never embeds file bytes in any message, matching FilePayload.cs's own
// comment to that effect. Chunked streaming (build order step 10) will
// write/read through this same directory.

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { FilePayload } from './FilePayload';

const SUBDIR = 'cliplink_files';
const TEMP_SUFFIX = '.tmp';
const HASH_CHUNK_SIZE = 256 * 1024;

// SHA-256 of no bytes at all: every empty file's hash.
export const EMPTY_FILE_HASH: string = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

// A descriptor for an empty file. Its bytes never stream - a sender has no
// chunk to send, on any platform - but they're known, so a receiver stores
// them itself (see SyncManager.handleIncomingFileEntry). The hash in either
// case: Windows and iOS send uppercase.
export function isEmptyFile(payload: FilePayload): boolean {
  return payload.FileSize === 0 && typeof payload.FileHash === 'string'
    && payload.FileHash.toLowerCase() === EMPTY_FILE_HASH;
}

// A hash nearly always comes from another device - a file entry, a
// file_request or a file_chunk - and every method below turns it into a path
// under baseDir. Only a real SHA-256 in hex (what every platform sends) is
// one: anything else, "../../preferences/cliplink_passphrase_key" say, let a
// peer read (file_request streams it back), overwrite (file_chunk) or delete
// (history eviction) files outside this store. Same rule as FileStore.cs's
// IsValidHash: getPath/getTempPath throw for it, exists is false and delete
// does nothing. The typeof check is for a descriptor whose FileHash isn't a
// string at all - JSON.parse(...) as FilePayload checks nothing.
const HASH_PATTERN: RegExp = new RegExp('^[0-9A-Fa-f]{64}$');

export function isValidFileHash(hash: string): boolean {
  return typeof hash === 'string' && HASH_PATTERN.test(hash);
}

function checked(hash: string): string {
  if (!isValidFileHash(hash)) {
    throw new Error('Not a file hash (64 hex digits).');
  }
  return hash;
}

// Lowercase SHA-256 hex of a file, read in chunks - bounded memory whatever
// the file's size. An empty file's is the known constant, without asking
// the crypto framework to digest nothing.
export async function sha256File(path: string): Promise<string> {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  const md = cryptoFramework.createMd('SHA256');
  let total = 0;
  try {
    const buffer = new ArrayBuffer(HASH_CHUNK_SIZE);
    let bytesRead = fs.readSync(file.fd, buffer);
    while (bytesRead > 0) {
      total += bytesRead;
      await md.update({ data: new Uint8Array(buffer.slice(0, bytesRead)) });
      bytesRead = fs.readSync(file.fd, buffer);
    }
  } finally {
    fs.closeSync(file);
  }
  if (total === 0) return EMPTY_FILE_HASH;
  const digest = (await md.digest()).data;
  let out = '';
  for (let i = 0; i < digest.length; i++) {
    out += digest[i].toString(16).padStart(2, '0');
  }
  return out;
}

export class FileStore {
  private baseDir: string;
  // Lowercase hashes this run has stored, is receiving (see getTempPath) or
  // has found here and may be about to rely on (see exists) - whatever the
  // history said, deleteUnreferenced leaves these alone.
  private inUse: Set<string> = new Set<string>();

  constructor(context: common.UIAbilityContext) {
    this.baseDir = `${context.filesDir}/${SUBDIR}`;
    if (!fs.accessSync(this.baseDir)) {
      fs.mkdirSync(this.baseDir);
    }
  }

  getPath(hash: string): string {
    return `${this.baseDir}/${checked(hash)}`;
  }

  // Where an incoming transfer writes before its bytes are verified - and
  // renamed to getPath(hash), so both count as in use from here on.
  getTempPath(hash: string): string {
    this.inUse.add(checked(hash).toLowerCase());
    return `${this.baseDir}/${hash}${TEMP_SUFFIX}`;
  }

  exists(hash: string): boolean {
    if (!isValidFileHash(hash) || !fs.accessSync(this.getPath(hash))) return false;
    this.inUse.add(hash.toLowerCase());
    return true;
  }

  delete(hash: string): void {
    if (this.exists(hash)) {
      fs.unlinkSync(this.getPath(hash));
    }
  }

  // Stores bytes this app holds in memory - a PasteButton read, or an empty
  // file (see isEmptyFile) - under their hash. An empty file is only
  // created: there's nothing to write. False if it couldn't be stored, and
  // then nothing is left under the hash - a cut-short blob would pass
  // exists() for the whole file.
  write(hash: string, data: Uint8Array): boolean {
    const path: string = this.getPath(hash);
    this.inUse.add(hash.toLowerCase());
    try {
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        if (data.byteLength > 0) {
          fs.writeSync(file.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer);
        }
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      try {
        fs.unlinkSync(path);
      } catch (removeErr) {
        // never created
      }
      return false;
    }
  }

  // Deletes every blob, and every half-written .tmp, that an earlier run
  // left here and no entry in `referenced` (lowercase hashes) points at: an
  // item deleted or evicted while its bytes were still arriving, bytes a
  // peer streamed for an entry this device dropped, a transfer cut off when
  // the app was killed. Never a hash in inUse, and never a file that isn't
  // named like one of these. Returns how many went. Only for
  // HistoryAccess.deleteUnreferencedFiles, which reads `referenced` under its
  // own lock.
  deleteUnreferenced(referenced: Set<string>): number {
    let names: string[];
    try {
      names = fs.listFileSync(this.baseDir);
    } catch (e) {
      return 0;
    }
    let deleted = 0;
    for (const name of names) {
      const isTemp: boolean = name.endsWith(TEMP_SUFFIX);
      const hash: string = isTemp ? name.substring(0, name.length - TEMP_SUFFIX.length) : name;
      if (!isValidFileHash(hash)) continue;
      const key: string = hash.toLowerCase();
      if (this.inUse.has(key) || (!isTemp && referenced.has(key))) continue;
      try {
        fs.unlinkSync(`${this.baseDir}/${name}`);
        deleted++;
      } catch (e) {
        // gone already - or the next start tries again
      }
    }
    return deleted;
  }

  // Takes over a file this app already holds its own copy of (something
  // shared to ClipLink - see share/ShareIntake.ets): hashes it in chunks and
  // moves it in under that hash, rather than reading it all into memory the
  // way the PasteButton path does. Returns the hash. The source is gone
  // afterwards: moved in, or deleted when these bytes are already stored.
  async importFile(path: string): Promise<string> {
    const hash = await sha256File(path);
    if (this.exists(hash)) {
      fs.unlinkSync(path);
      return hash;
    }
    this.inUse.add(hash);
    try {
      fs.moveFileSync(path, this.getPath(hash));
    } catch (e) {
      // cacheDir and filesDir share a partition, so the move is a rename;
      // copy + delete only in case some device mounts them apart.
      fs.copyFileSync(path, this.getPath(hash));
      fs.unlinkSync(path);
    }
    return hash;
  }
}
