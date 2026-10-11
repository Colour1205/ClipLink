// The Trust and Ignore buttons on the pairing notification (see Index.ets's
// postPairingNotification). A notification button on HarmonyOS is a
// WantAgent that starts an ability, so the answer arrives as a Want on
// EntryAbility - in onNewWant, ClipLink being a singleton that is already
// running - and is handed to the page through the ability's event hub, the
// same route a share takes (see share/ShareIntake.ets).

import { Want } from '@kit.AbilityKit';

// Emitted on the ability's eventHub with (action, deviceId).
export const PAIRING_ACTION_EVENT: string = 'cliplink.pairingAction';

export const PAIRING_ACTION_TRUST: string = 'trust';
export const PAIRING_ACTION_IGNORE: string = 'ignore';
// The notification itself, not one of its buttons: only brings the app up.
export const PAIRING_ACTION_OPEN: string = 'open';

// Want parameter names - the same two are read back below.
export const PAIRING_ACTION_PARAM: string = 'pairingAction';
export const PAIRING_DEVICE_PARAM: string = 'pairingDeviceId';

export interface PairingAnswer {
  action: string;
  deviceId: string;
}

// The answer a Want carries, or null if it is not one.
export function readPairingAnswer(want: Want): PairingAnswer | null {
  const params: Record<string, Object> | undefined = want.parameters;
  if (params === undefined) return null;
  const action: Object | undefined = params[PAIRING_ACTION_PARAM];
  const deviceId: Object | undefined = params[PAIRING_DEVICE_PARAM];
  if (typeof action !== 'string' || typeof deviceId !== 'string') return null;
  return { action: action, deviceId: deviceId };
}
