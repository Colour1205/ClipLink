// ohos.permission.READ_PASTEBOARD: reading the system clipboard without the
// PasteButton tap. A restricted (ACL) permission Huawei approved for ClipLink,
// declared for EntryAbility with usedScene "inuse" (module.json5), so it works
// while the app is in use only. The user can still refuse it, or take it away
// in Settings, so everything that uses it has the PasteButton as its fallback.

import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const READ_PASTEBOARD: Permissions = 'ohos.permission.READ_PASTEBOARD';
const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'ClipLinkNet';

function plog(message: string): void {
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', `pasteboard permission: ${message}`);
}

// Whether the app holds it now.
export function isPasteboardReadGranted(): boolean {
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const status: abilityAccessCtrl.GrantStatus =
      abilityAccessCtrl.createAtManager().checkAccessTokenSync(info.appInfo.accessTokenId, READ_PASTEBOARD);
    plog(`check -> ${status}`);
    return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (e) {
    const be = e as BusinessError;
    plog(`check failed ${be.code} ${be.message}`);
    return false;
  }
}

// Asks for it (the system's own prompt, worded with the reason in
// module.json5). True if it is held afterwards.
export async function requestPasteboardRead(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const result: PermissionRequestResult =
      await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [READ_PASTEBOARD]);
    plog(`request -> authResults=${JSON.stringify(result.authResults)} dialogShown=${JSON.stringify(result.dialogShownResults)}`);
    return result.authResults.length > 0 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (e) {
    const be = e as BusinessError;
    plog(`request failed ${be.code} ${be.message}`);
    return false;
  }
}
