// This device's human-readable name, sent to peers in the LAN beacon, the
// handshake and the pairing payload so their device lists can show
// "HUAWEI Mate 80 Pro" instead of a public-key fragment. The user can
// override it on the Me screen (DeviceSettings.getDeviceNameSync); a blank
// override means "use the system's name" below.

import { common } from '@kit.AbilityKit';
import { deviceInfo, settings } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// Same cap on every platform, counted in Unicode code points (not UTF-16
// units, so an emoji is one character), applied after trimming.
const MAX_NAME_CHARS = 64;
// A peer picks its own name, so it's untrusted text: C0/C1 controls (line
// breaks included), bidi marks/overrides/isolates (U+061C, U+200E-U+200F,
// U+202A-U+202E, U+2066-U+2069) and zero-width characters (U+200B-U+200D,
// U+FEFF) are removed, so a name can't reorder or hide the text shown next
// to it - e.g. the short id and address in a pairing prompt. Same set on
// every platform.
const UNSAFE_NAME_CHARS = new RegExp('[\\u0000-\\u001F\\u007F-\\u009F\\u061C\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069\\uFEFF]', 'g');

/**
 * Human-readable name of THIS device, permission-free.
 * 1. settings.general.DEVICE_NAME (Settings > About > Device name, if the system exposes it)
 * 2. deviceInfo.marketName (e.g. "HUAWEI Mate 80 Pro Max")
 * 3. brand + productModel (e.g. "HUAWEI SGT-AL10")
 * `context` must be a UIAbilityContext or ExtensionContext (settings API restriction).
 */
export function getLocalDeviceName(context: common.UIAbilityContext | common.ExtensionContext): string {
  try {
    const n: string = settings.getValueSync(context, settings.general.DEVICE_NAME, '');
    if (n !== undefined && n !== null && n.trim().length > 0) {
      return n.trim();
    }
  } catch (e) {
    hilog.warn(0x0000, 'DeviceName', 'settings DEVICE_NAME failed: %{public}s', JSON.stringify(e));
  }
  const market: string = deviceInfo.marketName;
  if (market && market.trim().length > 0) {
    return market.trim();
  }
  return `${deviceInfo.brand} ${deviceInfo.productModel}`.trim();
}

/**
 * Stripped of UNSAFE_NAME_CHARS, trimmed and capped at MAX_NAME_CHARS code
 * points; null when nothing is left. The one sanitiser for every name: what
 * this device sends, and what peers send in a beacon, a handshake or a
 * pairing code (and names stored by older builds, see TrustStore) - so a
 * peer can't make a row arbitrarily long or disguise the text around it.
 */
export function normalizeDeviceName(name: string): string | null {
  const trimmed: string = name.replace(UNSAFE_NAME_CHARS, '').trim();
  let count = 0;
  let i = 0;
  while (i < trimmed.length && count < MAX_NAME_CHARS) {
    const c: number = trimmed.charCodeAt(i);
    const next: number = i + 1 < trimmed.length ? trimmed.charCodeAt(i + 1) : 0;
    // A surrogate pair is one character - never split it.
    const isPair: boolean = c >= 0xD800 && c <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF;
    i += isPair ? 2 : 1;
    count++;
  }
  const capped: string = trimmed.substring(0, i);
  return capped.length > 0 ? capped : null;
}

/** The name this device goes by: the user's override if set, else the system's. */
export function effectiveDeviceName(override: string, systemName: string): string | null {
  const own: string | null = normalizeDeviceName(override);
  return own !== null ? own : normalizeDeviceName(systemName);
}
