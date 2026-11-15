// Step 4 of the build order in ../../../../README.md: local persistence.
// Mirrors windows/ClipLink/Engine/Identity/PassphraseKeyStore.cs and
// windows/ClipLink/Engine/Crypto/PassphraseAuth.cs.
//
// Security level deliberately kept at parity with Windows, not "improved"
// unilaterally: the Windows version doesn't put this key in a hardware
// keystore either — it's DPAPI-encrypted-at-rest, still loaded as plain
// bytes in-process. Preferences (app-sandboxed local storage) is a
// reasonable equivalent. HUKS symmetric-key import was considered, but its
// exact plaintext-import wire format isn't confirmed by any source found
// during research (unlike the well-confirmed ECC export format used in
// DeviceIdentity.ets) — not worth gambling another blind API-shape guess
// on, the way the PBKDF2 spike cost real time. Revisit if this ever
// actually matters (see docs/security.md).
//
// FIXED_SALT must byte-for-byte match PassphraseAuth.cs's FixedSalt, or
// two devices given the same passphrase derive different keys and can
// never auto-trust each other.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { taskpool, util } from '@kit.ArkTS';
import { pbkdf2Sha256Manual } from '../crypto/Pbkdf2';

const PREFERENCES_NAME = 'cliplink_passphrase_key';
const KEY_KEY = 'derived_key_base64';
const FIXED_SALT = 'ClipboardDaemonPassphraseSaltV1';
const ITERATIONS = 210_000;
const KEY_LEN_BYTES = 32;

const base64Helper = new util.Base64Helper();

// See crypto/Signing.ets's stringToBytes for the full explanation - this
// was the same bug (truncating UTF-16 code units into single bytes instead
// of real UTF-8 encoding). Here it meant a passphrase containing any
// non-ASCII character (accented letters, emoji, etc.) derived a different
// key on this device than Encoding.UTF8.GetBytes would derive on Windows
// from the identical passphrase, breaking cross-device passphrase
// auto-trust for anyone whose passcode wasn't pure ASCII.
const textEncoder = util.TextEncoder.create('utf-8');
function stringToBytes(s: string): Uint8Array {
  return textEncoder.encodeInto(s);
}

// Same intent as CryptographicOperations.FixedTimeEquals on the Windows
// side — don't let proof verification leak timing information about how
// many leading bytes matched.
function fixedTimeEquals(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff === 0;
}

// The derivation, run in a TaskPool worker: its 210,000 rounds of HMAC are
// synchronous calls (see Pbkdf2.ets), and on the UI thread they froze the app
// for seconds - the "setting passcode" state could not even paint, and a block
// that long risks the system's app-freeze kill. Same function, salt and
// rounds, so the key is byte-for-byte the one every other platform derives.
@Concurrent
async function deriveKeyOffThread(password: Uint8Array, salt: Uint8Array, iterations: number, keyLenBytes: number): Promise<Uint8Array> {
  return pbkdf2Sha256Manual(password, salt, iterations, keyLenBytes);
}

async function deriveKey(passphrase: string): Promise<Uint8Array> {
  const password: Uint8Array = stringToBytes(passphrase);
  const salt: Uint8Array = stringToBytes(FIXED_SALT);
  try {
    return await taskpool.execute(deriveKeyOffThread, password, salt, ITERATIONS, KEY_LEN_BYTES) as Uint8Array;
  } catch (e) {
    // No worker to run it on: here, as before, rather than not at all.
    return pbkdf2Sha256Manual(password, salt, ITERATIONS, KEY_LEN_BYTES);
  }
}

// How many proof verdicts are remembered before they are forgotten all at once.
const MAX_VERDICTS = 64;

export class PassphraseKeyStore {
  // verifyProof's answers, by device id and proof, for the key in verdictsFor
  // (Base64): a device on the LAN that is not trusted beacons its proof every
  // 2 s, and each was checked with a fresh HMAC. Kept by the key, so setting or
  // clearing the passcode starts them over.
  private verdicts: Map<string, boolean> = new Map<string, boolean>();
  private verdictsFor: string = '';

  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, PREFERENCES_NAME);
  }

  async hasPassphrase(context: common.UIAbilityContext): Promise<boolean> {
    const prefs = await this.getPrefs(context);
    return prefs.hasSync(KEY_KEY);
  }

  // stillWanted is asked after the (seconds-long) derivation, right before
  // the key is stored: false drops the result and resolves false. Index.ets
  // uses it so a Clear made while this was deriving isn't undone by it.
  async setPassphrase(context: common.UIAbilityContext, passphrase: string, stillWanted: () => boolean = () => true): Promise<boolean> {
    const key = await deriveKey(passphrase);
    const prefs = await this.getPrefs(context);
    if (!stillWanted()) return false;
    prefs.putSync(KEY_KEY, base64Helper.encodeToStringSync(key));
    await prefs.flush();
    return true;
  }

  // Devices already auto-trusted via the passcode stay trusted - this only
  // stops this device proving the passcode to new ones (same as Android).
  async clearPassphrase(context: common.UIAbilityContext): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.deleteSync(KEY_KEY);
    await prefs.flush();
  }

  async getKey(context: common.UIAbilityContext): Promise<Uint8Array | null> {
    const prefs = await this.getPrefs(context);
    if (!prefs.hasSync(KEY_KEY)) return null;
    const b64 = prefs.getSync(KEY_KEY, '') as string;
    if (b64.length === 0) return null;
    return base64Helper.decodeSync(b64);
  }

  // Same shape as PassphraseAuth.ComputeProof: HMAC-SHA256(key, deviceId),
  // base64-encoded.
  async computeProof(key: Uint8Array, deviceId: string): Promise<string> {
    const keyGen = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = await keyGen.convertKey({ data: key });
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(symKey);
    await mac.update({ data: stringToBytes(deviceId) });
    const result = await mac.doFinal();
    return base64Helper.encodeToStringSync(result.data);
  }

  async verifyProof(key: Uint8Array, deviceId: string, proofBase64: string): Promise<boolean> {
    const keyText: string = base64Helper.encodeToStringSync(key);
    if (keyText !== this.verdictsFor) {
      this.verdicts.clear();
      this.verdictsFor = keyText;
    }
    const asked: string = `${deviceId}\n${proofBase64}`;
    const known: boolean | undefined = this.verdicts.get(asked);
    if (known !== undefined) return known;
    const verdict: boolean = await this.checkProof(key, deviceId, proofBase64);
    // Read again: the passcode may have changed while this one was checked.
    if (keyText === this.verdictsFor) {
      if (this.verdicts.size >= MAX_VERDICTS) this.verdicts.clear();
      this.verdicts.set(asked, verdict);
    }
    return verdict;
  }

  private async checkProof(key: Uint8Array, deviceId: string, proofBase64: string): Promise<boolean> {
    let expected: Uint8Array;
    let actual: Uint8Array;
    try {
      const expectedBase64 = await this.computeProof(key, deviceId);
      expected = base64Helper.decodeSync(expectedBase64);
      actual = base64Helper.decodeSync(proofBase64);
    } catch (e) {
      // malformed base64 proof from a misbehaving/hostile peer — treat as
      // a verification failure, same as PassphraseAuth.cs does
      return false;
    }
    return fixedTimeEquals(expected, actual);
  }
}
