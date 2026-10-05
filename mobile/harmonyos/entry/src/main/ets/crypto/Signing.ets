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

function signableData(entry: ClipboardEntry): Uint8Array {
  return stringToBytes(`${entry.Content}:${entry.Type}:${entry.DeviceId}:${entry.Timestamp}`);
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
// copy carries the padded, signed text, which every platform can verify.
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
    return entry;
  }
  const padded = paddedDotNetTimestamp(entry.Timestamp);
  if (padded === null) return null;
  const restored: ClipboardEntry = {
    Content: entry.Content,
    Type: entry.Type,
    DeviceId: entry.DeviceId,
    Timestamp: padded,
    Signature: entry.Signature,
  };
  return (await verifyRawSignature(restored.DeviceId, signableData(restored), sigBytes)) ? restored : null;
}
