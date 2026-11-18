// Step 7 of the build order in ../../../../README.md: signing/verification
// + trust store integration. Mirrors windows/ClipLink/Engine/Crypto/SigningService.cs
// and windows/ClipLink/Engine/Storage/ClipboardEntry.cs exactly.
//
// Timestamp handling is the one subtlety here. ClipboardEntry.cs's
// Timestamp is a real DateTime, and SigningService.cs signs over
// `entry.Timestamp.ToString("o")` - .NET's round-trip format, 7 fractional
// digits (e.g. "2026-09-19T18:46:00.1234567Z"). JS's Date only has
// millisecond precision, so re-parsing an incoming timestamp into a Date
// and reformatting it would silently truncate/alter any real sub-
// millisecond precision a Windows-originated entry has - and then this
// device's re-derived signing string would no longer match what the
// signer actually signed, breaking verification for most genuine
// Windows-sent entries.
// The fix: never parse Timestamp into a Date at all. Treat it as an opaque
// string straight out of JSON, both when verifying (use the exact string
// as received) and when originating a new entry (generate a valid "o"-
// format string directly). This is safe because .NET's "o" format is
// specifically designed to round-trip losslessly - parsing a well-formed
// "o" string and reformatting it with "o" reproduces the identical string.
//
// The one catch: Windows SIGNS over ToString("o") but SENDS entries
// serialized by System.Text.Json, which trims trailing fractional zeros
// ("...:56.1234500Z" goes out as "...:56.12345Z", and "...:56.0000000Z" as
// "...:56Z"). That is the same instant but not the signed text, so it fails
// a verify over the raw string - about one in ten Windows entries, and
// every entry from this device that Windows relays in a history_batch.
// verifiedEntry() repairs that by string surgery only (never a Date), see
// paddedDotNetTimestamp().

import { util } from '@kit.ArkTS';
import { DeviceIdentity, verifyRawSignature } from '../identity/DeviceIdentity';

const base64Helper = new util.Base64Helper();

export interface ClipboardEntry {
  Content: string;
  Type: string;
  DeviceId: string;
  Timestamp: string; // always opaque - see file header
  Signature?: string;
  // The picture's original file name, without a folder, when the copy had one
  // (a picture copied in a browser, say). Only on an image entry, and missing
  // when unknown: a screenshot never had a name. It is not signed - the
  // signature stays over Content:Type:DeviceId:Timestamp - because it is only
  // the name a save suggests, and every entry already arrives inside the
  // encrypted, authenticated session of a trusted device. It is still text
  // from another device, so it is read through entryNameOf here and cut to a
  // safe last part (storage/PictureNames.ets) before it names a file. Builds
  // that do not know it ignore it.
  Name?: string;
}

// A Name longer than this is cut to it when an entry is stored. A real one is
// far shorter; this only keeps a misbehaving peer from filling the history.
export const MAX_ENTRY_NAME_LENGTH: number = 255;

// The entry's Name as this device keeps it: only on an image entry, only text,
// without any half of a surrogate pair that has lost its other half, not
// empty, and at most MAX_ENTRY_NAME_LENGTH characters (never cutting a pair in
// two). null for every other case, which includes every entry from a build
// that does not send a name. A lone half has to go because this device relays
// the Name in history batches: written back out it is not valid text, and
// Windows refuses to read an entry that holds one, so one bad Name from any
// peer would otherwise spoil every batch that carried it.
export function entryNameOf(entry: ClipboardEntry): string | null {
  if (entry.Type !== 'image') return null;
  const name: string | undefined = entry.Name;
  if (typeof name !== 'string' || name.length === 0) return null;
  const whole: string = withoutLoneSurrogates(name);
  if (whole.length === 0) return null;
  if (whole.length <= MAX_ENTRY_NAME_LENGTH) return whole;
  let cut: string = whole.substring(0, MAX_ENTRY_NAME_LENGTH);
  const last: number = cut.charCodeAt(cut.length - 1);
  if (last >= 0xD800 && last <= 0xDBFF) cut = cut.substring(0, cut.length - 1);
  return cut;
}

// The text with every half of a surrogate pair that is not next to its other
// half removed. Text without such a half comes back as it was.
export function withoutLoneSurrogates(text: string): string {
  let kept: string = '';
  let changed: boolean = false;
  let i: number = 0;
  while (i < text.length) {
    const unit: number = text.charCodeAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      const next: number = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
      if (next >= 0xDC00 && next <= 0xDFFF) {
        kept += text.substring(i, i + 2);
        i += 2;
        continue;
      }
      changed = true;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      changed = true;
    } else {
      kept += text.charAt(i);
    }
    i++;
  }
  return changed ? kept : text;
}

// The copy of a received entry that is stored, applied and relayed: the five
// signed fields with `timestamp` as its Timestamp, plus its Name when
// entryNameOf keeps one. Fields this build does not know are left out, so a
// peer cannot store anything else here from now on; Windows, which reads an
// entry into a class, never relayed them either. (History that a 2.2 build
// stored kept each entry as it was parsed, so an entry from then can still
// carry a field of its own until it leaves the history. That is harmless:
// every build ignores fields it does not know.)
export function storedEntry(entry: ClipboardEntry, timestamp: string): ClipboardEntry {
  const stored: ClipboardEntry = {
    Content: entry.Content,
    Type: entry.Type,
    DeviceId: entry.DeviceId,
    Timestamp: timestamp,
    Signature: entry.Signature,
  };
  const name: string | null = entryNameOf(entry);
  if (name !== null) stored.Name = name;
  return stored;
}

// Was `new Uint8Array(Array.from(s).map(c => c.charCodeAt(0)))` - that
// takes each UTF-16 code unit's raw numeric value and truncates it into a
// SINGLE byte (Uint8Array silently wraps mod 256), which only happens to
// produce correct bytes for pure ASCII (codepoints 0-127, where the UTF-16
// code unit and the UTF-8 byte are numerically identical). Any character
// outside that range (e.g. a "smart quote" like U+2019, accented letters,
// emoji) got mangled into a different, wrong byte instead of its real
// multi-byte UTF-8 encoding - and since .NET's Encoding.UTF8.GetBytes on
// the Windows side encodes correctly, the two sides disagreed on what was
// actually signed, and every entry containing so much as one non-ASCII
// character failed verification here on receipt (or the other way, if the
// entry was signed on this device and Windows verified it).
const textEncoder = util.TextEncoder.create('utf-8');
function stringToBytes(s: string): Uint8Array {
  return textEncoder.encodeInto(s);
}

// Matches .NET's DateTime.ToString("o") for a freshly-generated UTC
// timestamp: yyyy-MM-ddTHH:mm:ss.fffffffZ, exactly 7 fractional digits.
// JS's toISOString() gives exactly 3 - extend with "0001", i.e. one extra
// 100ns tick (this device has no finer time source than milliseconds, so
// the tick is invisible). .NET parsing this string and reformatting via
// "o" reproduces it exactly, byte for byte. The final 1 matters: with
// "0000" there, Windows' JSON serializer trimmed the zeros whenever it
// relayed the entry, and peers verifying the raw text rejected it.
export function nowAsDotNetRoundTrip(): string {
  const iso = new Date().toISOString(); // "...ss.SSSZ"
  return `${iso.slice(0, -1)}0001Z`;
}

const DOTNET_TIMESTAMP = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,7}))?(Z|[+-]\d{2}:\d{2})?$/;

// What ToString("o") wrote before System.Text.Json trimmed it: the fraction
// right-padded to 7 digits (".0000000" when it was dropped), suffix kept.
// null when the timestamp already has 7 digits (nothing was trimmed) or
// isn't a shape .NET produces.
export function paddedDotNetTimestamp(timestamp: string): string | null {
  const match = DOTNET_TIMESTAMP.exec(timestamp);
  if (match === null) return null;
  const fraction: string = match[2] ?? '';
  if (fraction.length === 7) return null;
  return `${match[1]}.${(fraction + '0000000').slice(0, 7)}${match[3] ?? ''}`;
}

// The form to compare and sort on: trimmed and untrimmed spellings of one
// instant become equal, and "...:56Z" no longer sorts after "...:56.5Z"
// just because 'Z' > '.'.
export function canonicalTimestamp(timestamp: string): string {
  return paddedDotNetTimestamp(timestamp) ?? timestamp;
}

// The text an entry's signature is over. Name is not part of it, so an entry
// signs and verifies the same with or without one.
export function signedText(entry: ClipboardEntry): string {
  return `${entry.Content}:${entry.Type}:${entry.DeviceId}:${entry.Timestamp}`;
}

function signableData(entry: ClipboardEntry): Uint8Array {
  return stringToBytes(signedText(entry));
}

export async function signEntry(identity: DeviceIdentity, content: string, type: string, deviceId: string): Promise<ClipboardEntry> {
  const entry: ClipboardEntry = { Content: content, Type: type, DeviceId: deviceId, Timestamp: nowAsDotNetRoundTrip() };
  const signature = await identity.sign(signableData(entry));
  entry.Signature = base64Helper.encodeToStringSync(signature);
  return entry;
}

// Returns the entry exactly as its signer signed it, or null when the
// signature doesn't hold. Callers must store and relay what this returns,
// not what arrived: if the timestamp was trimmed in transit, the returned
// copy carries the padded, signed text, which every platform can verify. It
// is always a fresh copy made by storedEntry, so an image's Name is kept and
// nothing else unknown is.
//
// Verifies against entry.DeviceId itself - matches how Program.cs always
// calls SigningService.Verify(entry, entry.DeviceId) in practice.
export async function verifiedEntry(entry: ClipboardEntry): Promise<ClipboardEntry | null> {
  if (!entry.Signature) return null;
  let sigBytes: Uint8Array;
  try {
    sigBytes = base64Helper.decodeSync(entry.Signature);
  } catch (e) {
    return null; // malformed base64 from a misbehaving/hostile peer
  }
  if (await verifyRawSignature(entry.DeviceId, signableData(entry), sigBytes)) {
    return storedEntry(entry, entry.Timestamp);
  }
  const padded = paddedDotNetTimestamp(entry.Timestamp);
  if (padded === null) return null;
  const restored: ClipboardEntry = storedEntry(entry, padded);
  return (await verifyRawSignature(restored.DeviceId, signableData(restored), sigBytes)) ? restored : null;
}
