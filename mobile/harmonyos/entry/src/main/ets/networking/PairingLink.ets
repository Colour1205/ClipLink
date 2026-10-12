// A pairing code as a link: https://cliplink.uaena.io/pair/#<the pairing info>.
//
// The QR code carries this instead of the bare JSON, so the system scanner (or
// any scanner app) that reads it opens the ClipLink app if it is installed (the
// module.json5 skill claims /pair as an App Link) and the website, with the
// downloads, if it is not. The pairing info - the same {PublicKey, Address,
// Name} JSON as ever - is the part after the #, base64url without padding. A
// fragment is never sent to a server, so the website never sees a device's
// address.
//
// Everything that takes pairing text in (the pair-by-address box, a pasted
// code, a scan, a link that opened the app) accepts both the link and the bare
// JSON, via unwrapPairingLink. "Copy pairing info" still copies the bare JSON.
// The same format is in every platform's app (Windows PairingLink.cs, Android
// PairingLink.kt, iOS PairingLink.swift): change them together.

import { util } from '@kit.ArkTS';
import { Want } from '@kit.AbilityKit';

export const PAIRING_LINK_EVENT: string = 'cliplink.pairingLink';

const PAIRING_LINK_PREFIX: string = 'https://cliplink.uaena.io/pair/#';

// http or https, with or without the slash after /pair; the host in any case.
const PAIRING_LINK_PATTERN: RegExp = new RegExp('^https?://cliplink\\.uaena\\.io/pair/?#(.+)$', 'i');

const base64Helper = new util.Base64Helper();
const textEncoder = util.TextEncoder.create('utf-8');

export function wrapPairingLink(pairingJson: string): string {
  const base64: string = base64Helper.encodeToStringSync(textEncoder.encodeInto(pairingJson));
  return PAIRING_LINK_PREFIX + base64.replace(new RegExp('=+$'), '').replace(new RegExp('\\+', 'g'), '-').replace(new RegExp('/', 'g'), '_');
}

export function isPairingLink(text: string): boolean {
  return PAIRING_LINK_PATTERN.test(text.trim());
}

// The pairing info inside a link, or the text as it was: not a ClipLink
// pairing link, or one whose info cannot be read.
export function unwrapPairingLink(text: string): string {
  const match: RegExpMatchArray | null = text.trim().match(PAIRING_LINK_PATTERN);
  if (match === null) return text;
  try {
    let base64: string = match[1].replace(new RegExp('-', 'g'), '+').replace(new RegExp('_', 'g'), '/');
    while (base64.length % 4 !== 0) base64 += '=';
    // fatal: bytes that are not UTF-8 throw instead of turning into U+FFFD.
    const json: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(base64Helper.decodeSync(base64));
    return json.length > 0 ? json : text;
  } catch (e) {
    return text;
  }
}

// ---- a link that opened the app ----------------------------------------
//
// EntryAbility takes it from the Want (onCreate on a cold start, onNewWant
// while running), queues it here and emits PAIRING_LINK_EVENT; Index.ets takes
// it when its engine is ready (a cold start emits before the page exists, so
// the queue, not the event, is what is relied on).

let pendingPairingLink: string | null = null;

// The pairing link a Want carries, if it is one of ClipLink's.
export function readPairingLink(want: Want): string | null {
  const uri: string | undefined = want.uri;
  return uri !== undefined && isPairingLink(uri) ? uri : null;
}

export function queuePairingLink(link: string): void {
  pendingPairingLink = link;
}

export function takePendingPairingLink(): string | null {
  const link: string | null = pendingPairingLink;
  pendingPairingLink = null;
  return link;
}
