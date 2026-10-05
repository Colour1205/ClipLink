// "Share to ClipLink". module.json5's second skill lists EntryAbility in the
// system share panel; picking ClipLink there starts it with a sendData Want -
// in onCreate on a cold start, in onNewWant when it's already running (it's a
// singleton UIAbility). EntryAbility hands that Want here. Every shared file
// is copied into this app's cache straight away, while the sender's URI
// grant is still good, and the results wait in AppStorage until Index.ets has
// SyncManager and FileStore up to sync them - exactly like something copied
// on this device: a file becomes a 'file' entry, text a 'text' entry.
//
// Not a ShareExtensionAbility on purpose: every ExtensionAbility runs in a
// process of its own, while SyncManager and the peer connections live in
// Index.ets, in the main process - and a phone only keeps those connections
// in the foreground anyway, which is where this brings ClipLink.

import { AbilityConstant, common, Want, wantConstant } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import { safeFileName } from '../storage/FileNames';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'ClipLinkShare';

// AppStorage key for items waiting for Index.ets, and the eventHub event
// EntryAbility emits when it adds some - Index.ets also drains once it's
// ready, for a share that arrived before the page existed (a cold start).
export const PENDING_SHARES_KEY = 'pendingShares';
export const SHARED_IN_EVENT = 'sharedIn';

const SEND_DATA_ACTION = 'ohos.want.action.sendData';
const SYSTEM_SHARE_REASON = 'ReasonMessage_SystemShare';
// Same ceiling as Windows' ClipboardSync.MaxFileBytes.
export const MAX_SHARED_FILE_BYTES = 1024 * 1024 * 1024;
const COPY_DIR = 'share_in';
// uniformTypeDescriptor.UniformDataType.FOLDER / DIRECTORY.
const FOLDER_UTD = 'general.folder';
const DIRECTORY_UTD = 'general.directory';
// Names the cache copies apart, even two shares within one millisecond.
let copySerial: number = 0;

// Why a file couldn't be taken in (see copyFileIn).
export type CopyRefusal = 'too-large' | 'unreadable' | 'folder' | 'own';

// One shared item:
//   'file'   - path is this app's own cache copy, which Index.ets moves into
//              FileStore; fileName is the sanitised name to sync it under.
//   'text'   - text is what was shared.
//   'failed' - a file that couldn't be taken, and why ('too-large',
//              'unreadable', 'folder', or 'own' - see uriProblem), so the
//              toast can say; also a share with nothing usable in it.
export interface SharedIn {
  kind: 'file' | 'text' | 'failed';
  text?: string;
  path?: string;
  fileName?: string;
  reason?: CopyRefusal;
}

export function isShareWant(want: Want, launchParam: AbilityConstant.LaunchParam): boolean {
  return want.action === SEND_DATA_ACTION || launchParam.launchReasonMessage === SYSTEM_SHARE_REASON;
}

function copyDir(context: common.UIAbilityContext): string {
  return `${context.cacheDir}/${COPY_DIR}`;
}

// A fresh path in this app's cache for one file being taken in - shared, or
// pasted (see ClipboardWatcher). Whatever a process that died left there,
// sweepShareCopies deletes.
export function newCopyPath(context: common.UIAbilityContext): string {
  try {
    if (!fs.accessSync(copyDir(context))) fs.mkdirSync(copyDir(context));
  } catch (e) {
    // copyFileIn reports the file as unreadable
  }
  return `${copyDir(context)}/${Date.now()}_${copySerial++}`;
}

// A folder too: fs.copy copies one whole if that's what a URI names.
export function removeQuietly(path: string): void {
  try {
    if (!fs.accessSync(path)) return;
    if (fs.statSync(path).isDirectory()) {
      fs.rmdirSync(path);
    } else {
      fs.unlinkSync(path);
    }
  } catch (e) {
    // already gone, or never written
  }
}

function decodedOrRaw(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch (e) {
    return s; // a stray '%' - keep it as it is
  }
}

// The URI's last segment is the file's real name, extension included
// (file://media/Photo/12/IMG_.../IMG_20260101_120000.jpg,
// file://docs/storage/Users/currentUser/Download/report.pdf); a record's
// title defaults to that too, but a sender may put a caption there instead.
// A query (?networkid=... on a distributed file) isn't part of the name.
function sharedFileName(uri: string, title: string | undefined): string {
  const path: string = uri.split('?')[0].split('#')[0];
  const last: string = decodedOrRaw(path.substring(path.lastIndexOf('/') + 1));
  const name: string = last.includes('.') || title === undefined || title.length === 0 ? last : title;
  return safeFileName(name, 'file');
}

const ASCII_ESCAPE: RegExp = new RegExp('^[0-7][0-9A-Fa-f]$');

// Undoes the %XX escapes of ASCII characters only - which still shows every
// '.', '/' and NUL the file system will see, while a stray '%' elsewhere
// can't make the whole string undecodable (decodeURIComponent throws on
// one, and falling back to the raw string let "%2e%2e" pass as not "..").
function asciiUnescaped(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const hex: string = s.substring(i + 1, i + 3);
    if (s.charAt(i) === '%' && ASCII_ESCAPE.test(hex)) {
      out += String.fromCharCode(parseInt(hex, 16));
      i += 2;
    } else {
      out += s.charAt(i);
    }
  }
  return out;
}

// The index where a file URI's authority (or, from `from`, its path) ends:
// the first of `stops`, or the end.
function endOf(s: string, stops: string[], from: number): number {
  let end: number = s.length;
  for (const stop of stops) {
    const at: number = s.indexOf(stop, from);
    if (at >= 0 && at < end) end = at;
  }
  return end;
}

// Why a shared or pasted file:// URI must not be copied, or null when it's
// fine. ClipLink reads its own sandbox without any grant, so a URI that
// lands in there would send its private files (keys, trust list, history)
// to every paired device - and any app can hand EntryAbility such a Want
// (it's exported), not just the share panel, or put one on the pasteboard.
// fs.copy resolves a file URI with app_file_service's FileUri::GetRealPath,
// which uses the decoded path as it is - in this app's own sandbox - for
// three authorities: this app's bundle name ('own': ClipLink's own Share
// action, say, or a received file it put on the clipboard - synced
// already), none at all (file:///data/...), and the file manager's "docs",
// whose real files all live under /storage (file://docs/data/storage/...
// would be ClipLink's own). Every other authority is rebased onto a shared
// or media folder. A ".." segment is refused for all of them: fs.copy
// resolves it after that rebasing, so it climbs straight back out.
function uriProblem(context: common.UIAbilityContext, uri: string): 'own' | 'unreadable' | null {
  const rest: string = uri.substring('file://'.length);
  const authorityEnd: number = endOf(rest, ['/', '?', '#'], 0);
  const authority: string = asciiUnescaped(rest.substring(0, authorityEnd)).toLowerCase();
  if (authority === context.abilityInfo.bundleName.toLowerCase()) return 'own';
  const path: string = asciiUnescaped(rest.substring(authorityEnd, endOf(rest, ['?', '#'], authorityEnd)));
  const segments: string[] = path.split('/');
  if (authority.length === 0 || authority.includes('..') || path.includes('\u0000')
    || segments.some((segment: string) => segment === '..')) {
    return 'unreadable';
  }
  if (authority === 'docs') {
    const named: string[] = segments.filter((segment: string) => segment.length > 0 && segment !== '.');
    if (named.length === 0 || named[0] !== 'storage') return 'unreadable';
  }
  return null;
}

// A folder or an over-the-cap file, told from the granted URI itself before
// anything is copied - so a 4 GB video never lands in the cache first, even
// if the progress-listener cancel in copyIn turns out not to fire for this
// kind of URI. Async fs.open (it takes a URI too), so a cloud photo being
// fetched doesn't hold up the main thread. null: fine, or this URI only
// opens through fs.copy - whose own checks in copyIn still apply.
async function oversizedOrFolder(uri: string): Promise<'too-large' | 'folder' | null> {
  let file: fs.File;
  try {
    file = await fs.open(uri, fs.OpenMode.READ_ONLY);
  } catch (e) {
    return null;
  }
  try {
    const stat: fs.Stat = await fs.stat(file.fd);
    if (stat.isDirectory()) return 'folder';
    return stat.size > MAX_SHARED_FILE_BYTES ? 'too-large' : null;
  } catch (e) {
    return null;
  } finally {
    try {
      fs.closeSync(file);
    } catch (e) {
      // closed already
    }
  }
}

// Copies the file a file:// URI names to dest (a newCopyPath), or says why
// it won't - and then nothing is left at dest. A share and a PasteButton
// paste (see ClipboardWatcher) both bring a URI another app granted, so both
// take it this way, by the same rules: nothing in ClipLink's own sandbox
// (see uriProblem), no folder (isFolder: the sender already said so), nothing
// over MAX_SHARED_FILE_BYTES.
export async function copyFileIn(context: common.UIAbilityContext, uri: string, dest: string,
  isFolder: boolean): Promise<CopyRefusal | null> {
  if (!uri.startsWith('file://')) return 'unreadable';
  const problem: 'own' | 'unreadable' | null = uriProblem(context, uri);
  if (problem !== null) return problem;
  // Only files are synced (Windows skips folders too); fs.copy would copy
  // a whole folder.
  if (isFolder) return 'folder';
  const refused: 'too-large' | 'folder' | null = await oversizedOrFolder(uri);
  if (refused !== null) return refused;
  // The copy itself is fs.copy, not a read loop over that open: the
  // file-management copy is the API documented to consume another app's URI
  // grant, a pasteboard URI's included. Cancelled as soon as its progress
  // shows the file is over the cap, rather than filling the cache first.
  const signal: fs.TaskSignal = new fs.TaskSignal();
  let tooLarge: boolean = false;
  const options: fs.CopyOptions = {
    progressListener: (progress: fs.Progress) => {
      if (tooLarge || progress.totalSize <= MAX_SHARED_FILE_BYTES) return;
      tooLarge = true;
      try {
        signal.cancel();
      } catch (e) {
        // finished already - the size check below still catches it
      }
    },
    copySignal: signal,
  };
  const destUri: string = fileUri.getUriFromPath(dest);
  let copied: boolean = false;
  try {
    await fs.copy(uri, destUri, options);
    copied = true;
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'copying a file in failed: %{public}s', JSON.stringify(e));
  }
  if (!copied && !tooLarge) {
    // Once more the plain way, as the PasteButton path always used to copy
    // - in case the progress listener is what this URI's copy path objects
    // to. The size check below still applies.
    try {
      await fs.copy(uri, destUri);
      copied = true;
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'copying a file in failed again: %{public}s', JSON.stringify(e));
    }
  }
  let folder: boolean = false;
  try {
    if (copied && !tooLarge) {
      const stat: fs.Stat = fs.statSync(dest);
      folder = !stat.isFile();
      if (!folder && stat.size <= MAX_SHARED_FILE_BYTES) {
        return null;
      }
      tooLarge = !folder;
    }
  } catch (e) {
    // stat failed - treated as unreadable
  }
  removeQuietly(dest);
  return folder ? 'folder' : (tooLarge ? 'too-large' : 'unreadable');
}

async function copyIn(context: common.UIAbilityContext, uri: string, title: string | undefined,
  utd: string): Promise<SharedIn> {
  const fileName: string = sharedFileName(uri, title);
  const dest: string = newCopyPath(context);
  const refused: CopyRefusal | null = await copyFileIn(context, uri, dest, utd === FOLDER_UTD || utd === DIRECTORY_UTD);
  if (refused !== null) {
    return { kind: 'failed', fileName: fileName, reason: refused };
  }
  return { kind: 'file', path: dest, fileName: fileName };
}

// When getSharedData can't parse the Want (1003703001), the granted file
// URIs are still in the Want itself - Huawei's documented fallback.
function recordsFromWant(want: Want): systemShare.SharedRecord[] {
  const uris: string[] = [];
  if (want.uri !== undefined && want.uri.length > 0) uris.push(want.uri);
  const stream: Object | undefined = want.parameters !== undefined ? want.parameters[wantConstant.Params.PARAMS_STREAM] : undefined;
  if (Array.isArray(stream)) {
    for (const item of stream as Object[]) {
      if (typeof item === 'string' && !uris.includes(item as string)) uris.push(item as string);
    }
  }
  return uris.map((uri: string): systemShare.SharedRecord => {
    const record: systemShare.SharedRecord = { utd: 'general.file', uri: uri };
    return record;
  });
}

// Everything the Want carries, files already copied into the cache. Shares
// are either files (up to 50, see module.json5) or one text/link.
export async function intakeShare(context: common.UIAbilityContext, want: Want): Promise<SharedIn[]> {
  let records: systemShare.SharedRecord[];
  try {
    const data: systemShare.SharedData = await systemShare.getSharedData(want);
    records = data.getRecords();
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'getSharedData failed, reading the Want: %{public}s', JSON.stringify(e));
    records = recordsFromWant(want);
  }
  const out: SharedIn[] = [];
  for (let i = 0; i < records.length; i++) {
    const r: systemShare.SharedRecord = records[i];
    const uri: string = r.uri ?? '';
    if (uri.startsWith('file://')) {
      out.push(await copyIn(context, uri, r.title, r.utd));
    } else {
      // Text and links come as content; a non-file uri is a link too.
      const text: string = r.content !== undefined && r.content.length > 0 ? r.content : uri;
      if (text.length > 0) out.push({ kind: 'text', text: text });
    }
  }
  hilog.info(LOG_DOMAIN, LOG_TAG, 'share received: %{public}d record(s)', records.length);
  // Nothing usable at all (getSharedData failed and the Want had no URI to
  // fall back on, or only empty records): still reported, so Index's toast
  // says it couldn't be added instead of ClipLink opening without a word.
  if (out.length === 0) out.push({ kind: 'failed', reason: 'unreadable' });
  return out;
}

export function enqueueShares(items: SharedIn[]): void {
  if (items.length === 0) return;
  const pending: SharedIn[] = AppStorage.get<SharedIn[]>(PENDING_SHARES_KEY) ?? [];
  AppStorage.setOrCreate<SharedIn[]>(PENDING_SHARES_KEY, pending.concat(items));
}

// Everything waiting, removed from AppStorage - so each item is taken once.
export function takePendingShares(): SharedIn[] {
  const pending: SharedIn[] = AppStorage.get<SharedIn[]>(PENDING_SHARES_KEY) ?? [];
  if (pending.length > 0) AppStorage.setOrCreate<SharedIn[]>(PENDING_SHARES_KEY, []);
  return pending;
}

// Cache copies nothing is waiting on any more - left by a process that died
// between copying a share (or a paste) and syncing it. Called at onCreate,
// before the new Want's own copies exist. Also the one copy older builds
// kept of whatever file was pasted last, which nothing ever deleted.
export function sweepShareCopies(context: common.UIAbilityContext): void {
  removeQuietly(`${context.cacheDir}/incoming_clipboard_file`);
  const dir: string = copyDir(context);
  try {
    if (!fs.accessSync(dir)) return;
    const waiting: SharedIn[] = AppStorage.get<SharedIn[]>(PENDING_SHARES_KEY) ?? [];
    for (const name of fs.listFileSync(dir)) {
      const path: string = `${dir}/${name}`;
      if (!waiting.some((s: SharedIn) => s.path === path)) removeQuietly(path);
    }
  } catch (e) {
    // the cache is the system's to clear too
  }
}
