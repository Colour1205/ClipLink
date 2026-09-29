// Step 4 of the build order in ../../../../README.md: local persistence.
// Mirrors windows/daemon/Storage/FileStore.cs — content-addressed blob
// storage keyed by SHA-256 hex hash. Descriptor-only by design: this class
// never embeds file bytes in any message, matching FilePayload.cs's own
// comment to that effect. Chunked streaming (build order step 10) will
// write/read through this same directory.

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const SUBDIR = 'cliplink_files';
const HASH_CHUNK_SIZE = 256 * 1024;

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
// the file's size.
export async function sha256File(path: string): Promise<string> {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  const md = cryptoFramework.createMd('SHA256');
  try {
    const buffer = new ArrayBuffer(HASH_CHUNK_SIZE);
    let bytesRead = fs.readSync(file.fd, buffer);
    while (bytesRead > 0) {
      await md.update({ data: new Uint8Array(buffer.slice(0, bytesRead)) });
      bytesRead = fs.readSync(file.fd, buffer);
    }
  } finally {
    fs.closeSync(file);
  }
  const digest = (await md.digest()).data;
  let out = '';
  for (let i = 0; i < digest.length; i++) {
    out += digest[i].toString(16).padStart(2, '0');
  }
  return out;
}

export class FileStore {
  private baseDir: string;

  constructor(context: common.UIAbilityContext) {
    this.baseDir = `${context.filesDir}/${SUBDIR}`;
    if (!fs.accessSync(this.baseDir)) {
      fs.mkdirSync(this.baseDir);
    }
  }

  getPath(hash: string): string {
    return `${this.baseDir}/${checked(hash)}`;
  }

  getTempPath(hash: string): string {
    return `${this.baseDir}/${checked(hash)}.tmp`;
  }

  exists(hash: string): boolean {
    return isValidFileHash(hash) && fs.accessSync(this.getPath(hash));
  }

  delete(hash: string): void {
    if (this.exists(hash)) {
      fs.unlinkSync(this.getPath(hash));
    }
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
