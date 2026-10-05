// Step 4 of the build order in ../../../../README.md: local persistence.
// Mirrors windows/ClipLink/Engine/Identity/DeviceIdentity.cs, but the private key
// never leaves HUKS (Hardware Universal Keystore) — no exportable bytes
// exist at all, unlike the Windows version's DPAPI-encrypted file. The
// public key format (X.509 SubjectPublicKeyInfo DER, base64) matches
// DeviceIdentity.cs's GetPublicKey() exactly, confirmed via the step-2
// spike's research — so the device ID string itself is directly
// interoperable, even though signatures need EcdsaDer's conversion.

import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { derToRaw, rawToDer } from '../crypto/EcdsaDer';

const KEY_ALIAS = 'cliplink-identity';
const base64Helper = new util.Base64Helper();

function genProperties(): Array<huks.HuksParam> {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY,
    },
    { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 },
  ];
}

function signSessionProperties(): Array<huks.HuksParam> {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
    { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 },
  ];
}

export class DeviceIdentity {
  private cachedPublicKeyBase64: string | null = null;

  // Generates the identity key on first use; a no-op on every later call
  // (the key persists in HUKS across app restarts and even reinstalls tied
  // to the same device, until explicitly deleted).
  async ensureKey(): Promise<void> {
    const exists = await huks.hasKeyItem(KEY_ALIAS, { properties: genProperties() });
    if (!exists) {
      await huks.generateKeyItem(KEY_ALIAS, { properties: genProperties() });
    }
  }

  // Base64 X.509 SubjectPublicKeyInfo DER — same shape and encoding as
  // DeviceIdentity.cs's GetPublicKey(), used the same way as a device ID.
  async getPublicKeyBase64(): Promise<string> {
    if (this.cachedPublicKeyBase64 !== null) return this.cachedPublicKeyBase64;
    await this.ensureKey();
    const result = await huks.exportKeyItem(KEY_ALIAS, { properties: genProperties() });
    this.cachedPublicKeyBase64 = base64Helper.encodeToStringSync(result.outData!);
    return this.cachedPublicKeyBase64;
  }

  // Raw 64-byte r||s signature — same shape as SigningService.cs's
  // ECDsa.SignData(data, SHA256), via HUKS (DER) + EcdsaDer's conversion.
  async sign(data: Uint8Array): Promise<Uint8Array> {
    return derToRaw(await this.signRawDer(data));
  }

  // Diagnostic-only: the unconverted DER bytes straight from HUKS, to
  // isolate whether a verify failure is in EcdsaDer's conversion or
  // elsewhere (key setup, algorithm mismatch).
  async signRawDer(data: Uint8Array): Promise<Uint8Array> {
    await this.ensureKey();
    const props = signSessionProperties();
    const initResult = await huks.initSession(KEY_ALIAS, { properties: props });
    await huks.updateSession(initResult.handle, { properties: props, inData: data });
    const finishResult = await huks.finishSession(initResult.handle, { properties: props });
    return finishResult.outData!;
  }
}

// Verifies a raw 64-byte r||s signature (the wire format - see EcdsaDer.ets)
// against a claimed peer's identity public key (base64 X.509 SPKI DER, same
// format getPublicKeyBase64() produces). Standalone rather than a
// DeviceIdentity method since it verifies an ARBITRARY peer's claimed key,
// not this device's own HUKS-held one - matches SigningService.cs's
// Verify(), which likewise imports the claimed signer's key ad hoc.
export async function verifyRawSignature(peerPublicKeyBase64: string, data: Uint8Array, rawSignature: Uint8Array): Promise<boolean> {
  const base64Helper = new util.Base64Helper();
  let peerPublicKeyBytes: Uint8Array;
  try {
    peerPublicKeyBytes = base64Helper.decodeSync(peerPublicKeyBase64);
  } catch (e) {
    return false; // malformed base64 from a misbehaving/hostile peer
  }

  try {
    const keyGen = cryptoFramework.createAsyKeyGenerator('ECC256');
    const keyPair = await keyGen.convertKey({ data: peerPublicKeyBytes }, null);
    const verifier = cryptoFramework.createVerify('ECC256|SHA256');
    await verifier.init(keyPair.pubKey);
    await verifier.update({ data });
    return await verifier.verify(null, { data: rawToDer(rawSignature) });
  } catch (e) {
    return false; // malformed key/signature - treat as verification failure, not a crash
  }
}
