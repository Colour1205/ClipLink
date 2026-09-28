// HarmonyOS apps are sandboxed and have no equivalent of Windows's
// TailscaleHelper.cs (which shells out to `tailscale ip -4` to learn this
// device's own tailnet address) - there's no API to ask another installed
// app for its state, and Tailscale doesn't expose one. This is the
// phone-side substitute: the user copies their tailnet IP from the
// Tailscale app once and pastes it in here, and it's used exactly the way
// Windows uses its auto-detected one - carried in the LAN beacon (so a
// trusted peer can cache it for later off-LAN reconnects, see SyncManager's
// off-LAN reconnect loop and Discovery.ets's ownAddress) and in the QR/
// manual pairing payload (see Index.ets's refreshPairingPayload).

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFERENCES_NAME = 'cliplink_device_settings';
const TAILSCALE_IP_KEY = 'tailscale_ip';
// auto_apply shares its key name with the Android app's DeviceSettings.kt.
// HarmonyOS can't read the clipboard on open (READ_PASTEBOARD is ACL-only)
// or get wallpaper colours, so a new-copy hint and a colour theme picker
// stand in for Android's autoCapture and dynamicColor. Android's keepAlive
// has no working equivalent (see Index.ets's Sync section).
const AUTO_APPLY_KEY = 'auto_apply';
const NOTICE_NEW_COPIES_KEY = 'notice_new_copies';
const ACCENT_THEME_KEY = 'accent_theme';
const LAST_SEEN_CLIP_COUNT_KEY = 'last_seen_clip_count';
const BOTTOM_GLOW_KEY = 'bottom_glow';
const CARD_TRANSPARENCY_KEY = 'card_transparency';
// The user's own name for this device (see DeviceName.ets); '' means use
// the system's.
const DEVICE_NAME_KEY = 'device_name';

export class DeviceSettings {
  private async getPrefs(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, PREFERENCES_NAME);
  }

  private async getBool(context: common.UIAbilityContext, key: string, fallback: boolean): Promise<boolean> {
    const prefs = await this.getPrefs(context);
    return prefs.getSync(key, fallback) as boolean;
  }

  private async setBool(context: common.UIAbilityContext, key: string, value: boolean): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(key, value);
    await prefs.flush();
  }

  // Put a received item straight onto this device's clipboard. Off, items
  // still arrive and are listed - they just wait for Copy/Share/Save.
  getAutoApply(context: common.UIAbilityContext): Promise<boolean> {
    return this.getBool(context, AUTO_APPLY_KEY, true);
  }

  setAutoApply(context: common.UIAbilityContext, value: boolean): Promise<void> {
    return this.setBool(context, AUTO_APPLY_KEY, value);
  }

  // Highlight the Paste button when something new was copied (including
  // while ClipLink was in the background).
  getNoticeNewCopies(context: common.UIAbilityContext): Promise<boolean> {
    return this.getBool(context, NOTICE_NEW_COPIES_KEY, true);
  }

  setNoticeNewCopies(context: common.UIAbilityContext, value: boolean): Promise<void> {
    return this.setBool(context, NOTICE_NEW_COPIES_KEY, value);
  }

  // Key of the chosen colour theme (see Index.ets's THEMES); '' means the
  // default. Synchronous so the page can read it in aboutToAppear, before
  // its first frame, instead of flashing the default colour and switching.
  getAccentThemeSync(context: common.UIAbilityContext): string {
    const prefs = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    return prefs.getSync(ACCENT_THEME_KEY, '') as string;
  }

  async setAccentTheme(context: common.UIAbilityContext, key: string): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(ACCENT_THEME_KEY, key);
    await prefs.flush();
  }

  // Appearance settings, read synchronously for the same no-flash reason
  // as getAccentThemeSync.
  getBottomGlowSync(context: common.UIAbilityContext): boolean {
    const prefs = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    return prefs.getSync(BOTTOM_GLOW_KEY, true) as boolean;
  }

  setBottomGlow(context: common.UIAbilityContext, value: boolean): Promise<void> {
    return this.setBool(context, BOTTOM_GLOW_KEY, value);
  }

  // Percent, 0 = opaque cards (the default).
  getCardTransparencySync(context: common.UIAbilityContext): number {
    const prefs = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    return prefs.getSync(CARD_TRANSPARENCY_KEY, 0) as number;
  }

  async setCardTransparency(context: common.UIAbilityContext, percent: number): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(CARD_TRANSPARENCY_KEY, percent);
    await prefs.flush();
  }

  // ClipboardWatcher's lastSeenCount, kept across restarts. Synchronous for
  // the same reason as getAccentThemeSync: it must be restored before the
  // first "anything new on the clipboard?" check.
  getLastSeenClipCountSync(context: common.UIAbilityContext): number {
    const prefs = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    return prefs.getSync(LAST_SEEN_CLIP_COUNT_KEY, -1) as number;
  }

  async setLastSeenClipCount(context: common.UIAbilityContext, count: number): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(LAST_SEEN_CLIP_COUNT_KEY, count);
    await prefs.flush();
  }

  // Synchronous for the same reason as getAccentThemeSync: the first beacon
  // should already carry the chosen name, not the system's.
  getDeviceNameSync(context: common.UIAbilityContext): string {
    const prefs = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
    return prefs.getSync(DEVICE_NAME_KEY, '') as string;
  }

  async setDeviceName(context: common.UIAbilityContext, name: string): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(DEVICE_NAME_KEY, name.trim());
    await prefs.flush();
  }

  async getTailscaleIp(context: common.UIAbilityContext): Promise<string> {
    const prefs = await this.getPrefs(context);
    return prefs.getSync(TAILSCALE_IP_KEY, '') as string;
  }

  async setTailscaleIp(context: common.UIAbilityContext, ip: string): Promise<void> {
    const prefs = await this.getPrefs(context);
    prefs.putSync(TAILSCALE_IP_KEY, ip.trim());
    await prefs.flush();
  }
}
