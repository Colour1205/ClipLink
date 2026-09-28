// Step 9 of the build order in ../../../../README.md: foreground-only
// lifecycle wiring + minimal real UI. Replaces the diagnostic dashboard
// steps 3-8 were built and verified against (that history is preserved in
// git log and README.md) with an actual app screen: a floating pill bottom
// nav (Synced / Devices / Me, Immersive Material per API 26.0.0's
// uiMaterial), edge-to-edge layout with manually-computed safe-area
// padding (see EntryAbility.ets for the full-screen window setup), elastic
// (Spring) over-scroll, and auto-connect to already-trusted peers as soon
// as their beacon is heard (the actual "foreground lifecycle" requirement
// - sync starts on its own when the app opens, no manual taps needed).
//
// Sync itself (steps 3, 8) is unchanged under the hood - this is a UI/
// orchestration layer on top of ClipboardWatcher, Discovery, TcpServer,
// PeerConnection, and SyncManager, all built and verified in earlier steps.

import hilog from '@ohos.hilog';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window, promptAction, curves, LengthMetrics } from '@kit.ArkUI';
import { HdsNavigation, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigationTitleBarOptions,
  HdsNavigationMenuItemOptions, ScrollEffectType, TitleSize, hdsMaterial } from '@kit.UIDesignKit';
import { scanBarcode } from '@kit.ScanKit';
import { systemShare } from '@kit.ShareKit';
import { filePreview } from '@kit.PreviewKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import pasteboard from '@ohos.pasteboard';
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import picker from '@ohos.file.picker';
import uiMaterial from '@ohos.arkui.uiMaterial';
import unifiedDataChannel from '@ohos.data.unifiedDataChannel';
import { vibrator } from '@kit.SensorServiceKit';
import { ClipboardWatcher } from '../clipboard/ClipboardWatcher';
import { DeviceIdentity } from '../identity/DeviceIdentity';
import { TrustStore, TrustedDevice } from '../identity/TrustStore';
import { PassphraseKeyStore } from '../identity/PassphraseKeyStore';
import { DeviceSettings } from '../identity/DeviceSettings';
import { effectiveDeviceName, getLocalDeviceName, normalizeDeviceName } from '../identity/DeviceName';
import { FileStore } from '../storage/FileStore';
import { FilePayload } from '../storage/FilePayload';
import { Discovery, PeerBeacon } from '../networking/Discovery';
import { TcpServer, connectTcp } from '../networking/TcpTransport';
import { HandshakeReport, PeerConnection, PeerVerdict, TcpSocketAdapter, TcpSocketConnectionAdapter } from '../networking/PeerConnection';
import { SyncManager } from '../networking/SyncManager';
import { connection } from '@kit.NetworkKit';
import { signEntry, ClipboardEntry, canonicalTimestamp } from '../crypto/Signing';
import { ApplyResult } from '../clipboard/ClipboardApply';
import socket from '@ohos.net.socket';

const base64Helper = new util.Base64Helper();

// Must match Program.cs's own default TCP port (args[1], defaulting to
// "49000" when the tray launcher starts it - see DaemonLauncher.cs, which
// only ever passes the label, never a port override). On the LAN this
// constant is irrelevant - the real listening port is always exchanged
// live via the discovery beacon's tcpPort field. Off-LAN (see
// reconnectOffLanPeers/Program.cs's own off-LAN loop) there's no beacon to
// learn a real port from, so both platforms fall back to whatever they
// assume the other's default is - if these two numbers disagree, every
// off-LAN reconnect attempt silently dials the wrong port and never
// connects, with nothing in the log to say why.
const TCP_PORT = 49000;
// How long a pairing dial waits, after the handshake, to see whether the
// other side kept the connection (Index's connectToAddress). Accepting
// sends history straight away, and its first byte counts, so the full wait
// normally means the other side is holding it as a pairing request.
const PEER_VERDICT_WAIT_MS = 3000;

// Visible via `hdc shell hilog` - unlike Windows's Console.WriteLine, this
// app previously had NO console-visible debug output for its networking
// layer at all (only the in-app Activity Log, which requires the user to
// manually read and relay back). This is the HarmonyOS equivalent of the
// [conn]/[file] logging Program.cs already has, for the exact same reason:
// diagnosing a live connection issue without guessing.
const NET_LOG_DOMAIN = 0x0001;
const NET_LOG_TAG = 'ClipLinkNet';
function netLog(msg: string): void {
  hilog.info(NET_LOG_DOMAIN, NET_LOG_TAG, '%{public}s', msg);
}

// System haptic feedback for every tap/long-press, matching what
// bindContextMenu's own hapticFeedbackMode already gives the long-press
// menu. clickEffect (used throughout this file) is a visual bounce only -
// confirmed against Huawei's own ArkUI reference, it has no haptic
// component at all - so getting an actual system vibration on an ordinary
// Button/onClick requires calling the imperative @ohos.vibrator module
// directly, there's no declarative "add haptic to this click" attribute.
// 'haptic.effect.sharp' (not 'soft') per @ohos.vibrator's HapticFeedback
// enum docs: soft is described as a looser, lower-frequency vibration -
// which is what read as "a very short duration vibration" rather than a
// tick - while sharp is the higher-frequency, crisp preset, matching the
// short "tick" feel bindContextMenu's hapticFeedbackMode:ENABLED gives on
// long-press. Fire-and-forget: a missing/unsupported vibrator on some
// device should never block or throw out of a click handler over
// something this cosmetic.
function tapHaptic(): void {
  vibrator.startVibration({ type: 'preset', effectId: 'haptic.effect.sharp', count: 1 }, { usage: 'touch' })
    .catch(() => { /* no haptic hardware, or effect unsupported - fine to just skip it */ });
}

// Merged view of a device for the UI - could be trusted, discovered (via
// beacon), connected, or any combination. A device the user has never
// trusted but whose beacon we've heard is "discovered only"; a trusted
// device we haven't heard from recently is "trusted only".
interface DeviceRow {
  deviceId: string;
  // What the device calls itself (its latest beacon, else the trust store),
  // or null if it never said - see deviceRowTitle.
  name: string | null;
  // Every address this peer is reachable at, de-duplicated: the LAN IP the
  // beacon actually arrived from, the address the beacon advertises (which
  // is the Tailscale/off-LAN one when set), and whatever the trust store
  // cached from pairing. Previously a single field, and the beacon's LAN
  // IP overwrote the stored one - so a device paired over Tailscale showed
  // only its LAN address, or vice versa.
  addresses: string[];
  address: string | null;
  trusted: boolean;
  discovered: boolean;
  tcpPort: number | null;
  connected: boolean;
}

// How a device without a known name is shown - same on every platform.
function shortDeviceId(deviceId: string): string {
  return `${deviceId.slice(0, 12)}…`;
}

function deviceRowTitle(row: DeviceRow): string {
  return row.name !== null ? row.name : shortDeviceId(row.deviceId);
}

// Fixed order for the Devices list: trusted before merely discovered, then
// by name (case-insensitive, named before unnamed), then by id. Nothing
// that changes on its own - last beacon, connection state, arrival order -
// takes part, so a device coming online never makes the list jump.
function compareDeviceRows(a: DeviceRow, b: DeviceRow): number {
  if (a.trusted !== b.trusted) return a.trusted ? -1 : 1;
  if (a.name !== null && b.name === null) return -1;
  if (a.name === null && b.name !== null) return 1;
  if (a.name !== null && b.name !== null) {
    const an: string = a.name.toLowerCase();
    const bn: string = b.name.toLowerCase();
    if (an !== bn) return an < bn ? -1 : 1;
  }
  return a.deviceId < b.deviceId ? -1 : (a.deviceId > b.deviceId ? 1 : 0);
}

// A single synced clipboard item for the list UI - built from a verified
// ClipboardEntry (see SyncManager.onEntryApplied), not a raw log line.
interface SyncedItem {
  // Signature is unique per (content, type, deviceId, timestamp) - used as
  // the ForEach key below. `time` is deliberately truncated to HH:MM for
  // display and must NEVER be reused as a key: two copies from the same
  // source within the same minute would then collide on the same key,
  // and ArkUI would reuse the stale rendered node instead of updating its
  // text - the list visually "gets stuck" showing the first copy forever
  // even though new entries keep arriving and applying correctly.
  id: string;
  type: string;
  preview: string;
  content: string; // full, untruncated - what "Copy content"/"Select text" act on
  source: string;
  time: string;
  fromPeer: boolean;
}

// Wire shape for QR/pasted pairing exchange - matches windows/daemon/
// Networking/IpcMessage.cs's PairingInfo record exactly (PascalCase field
// names, since that's what .NET's default JSON serializer emits), so a
// code generated by this device can be scanned by a future Windows-side
// scanner and vice versa - a code Windows shows (via its "Show My QR Code"
// dialog, or pasted raw) can be scanned by this device.
interface PairingInfo {
  PublicKey: string;
  Address?: string;
  // Optional: the device's display name. Codes from older builds lack it.
  Name?: string;
}

// How a dial to a peer ended (Index's connectToAddress):
//   'unreachable'    - no TCP connection at all: the other device is off,
//                      not on Tailscale / this network, or ClipLink isn't
//                      listening there.
//   'silent'         - it accepted the connection but never sent a
//                      handshake (ClipLink there is stuck, or it's not
//                      ClipLink on that port).
//   'refused'        - it hung up around the handshake: it doesn't trust
//                      this device, the passcodes differ (or it has none),
//                      and its pairing screen isn't open - or it's busy
//                      with another pairing request.
//   'connected'      - already paired; now connected.
//   'passcode'       - newly paired just now through matching passcodes.
//   'prompt'         - a new pairing awaiting Accept on this device.
//   'awaiting-other' - this device already trusts it, but it's holding the
//                      connection as a pairing request of its own.
//   'busy'           - this device is already showing another device's
//                      pairing request, so this one was dropped.
type DialOutcome = 'unreachable' | 'silent' | 'refused' | 'connected' | 'passcode' | 'prompt' | 'awaiting-other' | 'busy';

interface DialResult {
  // The address that got through, or every address tried if none did.
  address: string;
  outcome: DialOutcome;
}

// Passed to settingsSwitchRow as its ONLY argument, deliberately: ArkUI
// passes a @Builder's single object-literal parameter by reference, so a
// state variable read into `isOn` at the call site still refreshes the row.
// With several positional parameters they're passed by value and the
// switch would keep showing whatever it first rendered with.
interface SwitchRowOptions {
  title: string;
  subtitle: string;
  isOn: boolean;
  icon: Resource;
  onChange: (isOn: boolean) => void;
  enabled?: boolean;
}

// settingsRow's single argument - same by-reference reasoning as
// SwitchRowOptions.
interface SettingsRowOptions {
  title: string;
  value: string;
  navigates: boolean;
  icon: Resource;
  onTap: () => void;
}

// One accent colour theme. Each colour resource has its own dark-mode shade
// in resources/dark/element/color.json (except navy, which is the original
// single-value brand_blue).
interface ThemeOption {
  key: string;
  name: string;
  color: Resource;
}

const THEMES: ThemeOption[] = [
  { key: 'navy', name: 'Navy', color: $r('app.color.brand_blue') },
  { key: 'teal', name: 'Teal', color: $r('app.color.theme_teal') },
  { key: 'green', name: 'Green', color: $r('app.color.theme_green') },
  { key: 'orange', name: 'Orange', color: $r('app.color.theme_orange') },
  { key: 'rose', name: 'Rose', color: $r('app.color.theme_rose') },
  { key: 'violet', name: 'Violet', color: $r('app.color.theme_violet') },
];

// Falls back to navy for an unset or no-longer-known stored key.
function themeFor(key: string): ThemeOption {
  const found: ThemeOption | undefined = THEMES.find((t: ThemeOption) => t.key === key);
  return found !== undefined ? found : THEMES[0];
}

// How far above bottomInsetVp the bottom glow reaches (about half the
// screen), how strong it is at the bottom edge, and how many colour stops
// trace its eased falloff (see Index's bottomGlow). Tall and faint, so it
// reads as a wash rather than a band.
const GLOW_HEIGHT_ABOVE_INSET: number = 460;
const GLOW_OPACITY: number = 0.13;
const GLOW_STOPS: number = 8;

// Strength of Index's accentTint(), the fill of tinted secondary buttons -
// the same 20% as the sys.color.comp_emphasize_secondary it replaces.
const ACCENT_TINT_ALPHA: number = 0.2;

const IMAGE_FILE_EXTENSIONS: string[] = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'];

// A 'file' entry is just "bytes with a name" at the wire level - whether it
// LOOKS like an image to the user only depends on its filename, not on the
// type tag. Image copying is common enough (Gallery/Files "Copy", or a
// Windows file-drop of a photo) that treating every one as an opaque
// undifferentiated file with no preview was a real gap, not a technicality.
function isImageFileName(name: string): boolean {
  const lower = name.toLowerCase();
  return IMAGE_FILE_EXTENSIONS.some(ext => lower.endsWith(ext));
}

// Extension -> MIME, via UDMF's own type table rather than a hand-rolled
// map. getTypeDescriptor is typed non-null but documented to return null
// for an unknown type id, hence the guard.
function mimeTypeForFileName(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  try {
    const typeId: string = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(fileName.substring(dot));
    const descriptor: uniformTypeDescriptor.TypeDescriptor = uniformTypeDescriptor.getTypeDescriptor(typeId);
    if (descriptor === null || descriptor === undefined) return 'application/octet-stream';
    const mimes: Array<string> = descriptor.mimeTypes;
    return mimes.length > 0 ? mimes[0] : 'application/octet-stream';
  } catch (e) {
    return 'application/octet-stream';
  }
}

function previewFor(entry: ClipboardEntry): string {
  if (entry.Type === 'text') {
    return entry.Content.length > 80 ? `${entry.Content.slice(0, 80)}...` : entry.Content;
  } else if (entry.Type === 'image') {
    return 'Image';
  } else if (entry.Type === 'file') {
    try {
      const payload = JSON.parse(entry.Content) as FilePayload;
      return payload.FileName;
    } catch (e) {
      return 'File';
    }
  }
  return entry.Content;
}

// Full-text view for the synced-item long-press menu's "Select text" option.
// A dialog rather than making the list card's own Text selectable in place,
// since the card only ever shows an 80-char preview - this shows the whole
// content, and .copyOption(LocalDevice) is what actually turns on ArkUI's
// native long-press-to-select-a-range behavior on a Text component.
@CustomDialog
struct SelectTextDialog {
  // Optional rather than a bare declaration: the framework injects this at
  // construction time (see showSelectTextDialog below, which never passes
  // it explicitly), but DevEco's Previewer linter
  // (mandatory-default-value-for-local-initialization) doesn't know that
  // and flags any non-optional field with no default - marking it optional
  // is what its own "correct code" examples do for exactly this case.
  controller?: CustomDialogController;
  content: string = '';

  build() {
    Column({ space: 12 }) {
      Scroll() {
        Text(this.content).fontSize(14).copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })

      Button('Close').fontSize(13).onClick(() => { tapHaptic(); this.controller?.close(); })
    }
    .width('100%')
    .padding(16)
  }
}

// SaveButton (security component) has to be the actually-tapped element to
// get its temporary photoAccessHelper grant - it can't be triggered from a
// plain MenuItem's onClick. Wrapping it in its own small dialog (opened from
// the long-press menu's "Save to gallery" item) keeps it out of the menu
// itself while still reusing a pattern (CustomDialogController) already
// proven to work in this file.
@CustomDialog
struct SaveImageDialog {
  controller?: CustomDialogController;
  onSave: (result: SaveButtonOnClickResult) => void = () => {};

  build() {
    Column({ space: 16 }) {
      Text('Save this image to your gallery?').fontSize(14)
      SaveButton({ text: SaveDescription.SAVE_TO_GALLERY, buttonType: ButtonType.Capsule })
        .fontSize(14)
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
          tapHaptic();
          this.onSave(result);
          this.controller?.close();
        })
      Button('Cancel').fontSize(13).onClick(() => { tapHaptic(); this.controller?.close(); })
    }
    .width('100%')
    .padding(20)
  }
}

@Entry
@Component
struct Index {
  @State ownDeviceId: string = '';
  @State receivedBeacons: PeerBeacon[] = [];
  @State trustedDevices: TrustedDevice[] = [];
  @State pendingChange: boolean = false;
  @State syncLog: string[] = [];
  @State syncedItems: SyncedItem[] = [];
  @State immersiveSupported: boolean = false;
  @State connectedCount: number = 0;
  @State topInsetVp: number = 0;
  @State bottomInsetVp: number = 0;
  // Window height, for placing the bottom glow's colour stops (see
  // bottomGlow) - a gradient's stops are fractions of the page's height.
  @State windowHeightVp: number = 0;
  // Light/dark, kept in AppStorage by EntryAbility. Colours that get an
  // alpha applied in code (see colorWithAlpha) are resolved from their
  // resources per mode, so they must re-resolve when this flips.
  @StorageProp('colorMode') colorMode: number = -1;
  @State currentTabIndex: number = 0;
  @State myPairingPayload: string = '';
  @State hasPassphrase: boolean = false;
  @State passphraseInput: string = '';
  // Manually-entered tailnet address for this device - see DeviceSettings.ets
  // for why this can't be auto-detected on HarmonyOS the way Windows does.
  @State tailscaleIp: string = '';
  @State savingTailscaleIp: boolean = false;
  // This device's display name (see DeviceName.ets): the system's, and the
  // user's saved override ('' = use the system's). ownDeviceName() picks.
  @State systemDeviceName: string = '';
  @State deviceNameOverride: string = '';
  // What's typed on the Device name screen, saved by saveDeviceName.
  @State deviceNameInput: string = '';
  @State savingDeviceName: boolean = false;
  // Mirror of DeviceSettings.getAutoApply, pushed into SyncManager too.
  @State autoApply: boolean = true;
  // DeviceSettings.getNoticeNewCopies - see onPageShow.
  @State noticeOnOpen: boolean = true;
  // DeviceSettings.getAccentThemeSync - a key from THEMES, see accent().
  @State accentTheme: string = '';
  // Appearance: the bottom glow (see bottomGlow) and how see-through card
  // surfaces are, 0-100% (see cardFill).
  @State bottomGlowOn: boolean = true;
  @State cardTransparency: number = 0;
  private readonly themes: ThemeOption[] = THEMES;
  // Resolved ARGB per `${colorMode}:${resource id}` - see resolveColor.
  private resolvedColors: Map<string, number> = new Map();
  // This device's own IPv4 addresses, for the Device card (Android shows the
  // same list).
  @State localAddresses: string[] = [];
  @State passcodeChanging: boolean = false;
  @State settingPassphrase: boolean = false;
  @State scanStatus: string = '';
  // Which synced item (by id) is open in the full-screen detail view - a tap
  // (not long-press) sets this, and geometryTransition morphs the tapped
  // card into the detail view using this same id, "一镜到底" style (see
  // openItemDetail/itemDetailView below). File entries never set this (no
  // meaningful full-screen preview for them) - tapping one just plays the
  // shared clickEffect() feedback every card gets, per request.
  @State selectedItemId: string = '';
  // List vs 2-column WaterFlow grid for the Synced tab - toggled by the
  // title bar's menu icon (see syncedTitleBar).
  @State syncedViewMode: string = 'waterfall';
  // Two-finger pinch zoom on the item detail image - imageZoomScale is what
  // Image.scale() actually reads; imageZoomBase is the scale it was at when
  // the current pinch gesture started, since GestureEvent.scale is relative
  // to THAT gesture's start, not cumulative across separate pinches. Reset
  // on every open/close so zoom never carries over onto the next item.
  @State imageZoomScale: number = 1;
  private imageZoomBase: number = 1;
  // Pan offset, only meaningful once imageZoomScale > 1 - see zoomableImage.
  @State imageOffsetX: number = 0;
  @State imageOffsetY: number = 0;
  private imageOffsetBaseX: number = 0;
  private imageOffsetBaseY: number = 0;
  // Which Me screen is showing - a real separate screen per section
  // (pairing/QR, passcode, diagnostics, activity log) rather than one
  // combined page, per request.
  @State meScreen: 'main' | 'pairing' | 'passcode' | 'network' | 'devicename' | 'diagnostics' | 'log' = 'main';
  // True only while the Pairing screen is open - see setMeScreen. This is
  // the live "I'm expecting to pair right now" signal broadcast in the LAN
  // beacon and checked by PeerConnection.create's relaxed trust gate; a
  // pairing handshake with an untrusted peer only proceeds at all when
  // this is true on BOTH ends independently.
  @State pairingOpen: boolean = false;
  // A connection that completed the full authenticated handshake but whose
  // peer wasn't already trusted - set only via the pairingOpen gate above,
  // and only resolved by the user tapping Accept/Reject on the prompt this
  // drives (see acceptPairing/rejectPairing). Not @State: PeerConnection
  // itself doesn't need reactive tracking, only the two id/address strings
  // that drive the prompt's UI do.
  @State pendingPairingPeerId: string = '';
  @State pendingPairingAddress: string = '';
  private pendingPairingConn: PeerConnection | null = null;
  @State pairByAddressInput: string = '';
  @State pairingInProgress: boolean = false;

  private watcher: ClipboardWatcher = new ClipboardWatcher();
  private discovery: Discovery = new Discovery();
  private tcpServer: TcpServer = new TcpServer();
  private trustStore: TrustStore = new TrustStore();
  private passphraseKeyStore: PassphraseKeyStore = new PassphraseKeyStore();
  private deviceSettings: DeviceSettings = new DeviceSettings();
  private mainWindow: window.Window | null = null;
  private onAvoidAreaChange = (data: window.AvoidAreaOptions): void => {
    if (data.type !== window.AvoidAreaType.TYPE_SYSTEM) return;
    this.topInsetVp = px2vp(data.area.topRect.height);
    this.bottomInsetVp = px2vp(data.area.bottomRect.height);
  };
  private onWindowSizeChange = (size: window.Size): void => {
    this.windowHeightVp = px2vp(size.height);
  };
  private syncManager: SyncManager | null = null;
  private fileStore: FileStore | null = null;
  private connectingTo: Set<string> = new Set();
  private offLanReconnectTimerId: number = -1;
  // Real Navigation/NavDestination stacks, one per tab that needs its own
  // sub-navigation. Immersive material (systemMaterial) is only rendered by
  // the system inside a Navigation/NavDestination title bar (or a
  // BarPosition.End Tabs bottom bar) - confirmed against Huawei's own
  // @ohos.arkui.uiMaterial reference (updated 2026-09-20): "其他组件仅在
  // Navigation/NavDestination标题栏...中生效。在其他区域中设置沉浸光感效果不生效"
  // ("all other components only take effect inside a Navigation/
  // NavDestination title bar... elsewhere, setting it has no effect at
  // all"). A plain Button anywhere else - which is what every back button
  // here used to be - can NEVER show this effect, regardless of styling.
  // Two separate stacks (not one shared) since the Synced tab's list<->
  // detail navigation and the Me tab's main<->sub-screen navigation are
  // fully independent of each other.
  private syncedNavStack: NavPathStack = new NavPathStack();
  private meNavStack: NavPathStack = new NavPathStack();
  // Devices used to be the one tab with no Navigation at all - just a
  // Column with its title in normal flow, which is why its content could
  // never scroll behind anything and its header had no material. It gets
  // the same stack/destination treatment as the other two now.
  private devicesNavStack: NavPathStack = new NavPathStack();
  // One Scroller per scrollable that sits under an HDS title bar, handed to
  // that page's bindToScrollable. The gradient blur is driven by the bound
  // scroller's offset, so it must be the exact instance the List/Scroll/
  // WaterFlow was constructed with - a fresh Scroller would leave the bar
  // with nothing to react to and the blur would never fade in.
  private syncedListScroller: Scroller = new Scroller();
  private syncedFlowScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();
  private devicesScroller: Scroller = new Scroller();
  private meMainScroller: Scroller = new Scroller();
  private pairingScroller: Scroller = new Scroller();
  private passcodeScroller: Scroller = new Scroller();
  private networkScroller: Scroller = new Scroller();
  private deviceNameScroller: Scroller = new Scroller();
  private diagnosticsScroller: Scroller = new Scroller();
  private logScroller: Scroller = new Scroller();
  // Deterministic for a given (key, deviceId) pair - computed once whenever
  // the passphrase changes (or at startup, if one was already set) and
  // reused on every beacon tick, rather than re-deriving it every 2 seconds.
  // Discovery.start()'s getProof callback is synchronous (it runs inside a
  // setInterval tick), but computing an HMAC via cryptoFramework is async -
  // this cache is what bridges the two.
  private cachedProof: string | null = null;

  aboutToAppear(): void {
    this.immersiveSupported = uiMaterial.isImmersiveMaterialSupported();
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.accentTheme = this.deviceSettings.getAccentThemeSync(ctx);
      this.bottomGlowOn = this.deviceSettings.getBottomGlowSync(ctx);
      this.cardTransparency = this.deviceSettings.getCardTransparencySync(ctx);
      this.watcher.restoreSeen(this.deviceSettings.getLastSeenClipCountSync(ctx));
      this.deviceNameOverride = this.deviceSettings.getDeviceNameSync(ctx);
    } catch (e) {
      // unreadable prefs - keep the defaults
    }
    // Here rather than later so the very first beacon already carries it.
    this.systemDeviceName = getLocalDeviceName(getContext(this) as common.UIAbilityContext);

    // Initial (home) route on each stack, pushed with animation off (the
    // `false` second argument) - matches Huawei's own documented pattern
    // for a Navigation that pushes its first page from aboutToAppear
    // (arkts-navigation-faq's "router、navigation动画冲突" entry). hideNavBar
    // makes the pushed page itself the visible "home" screen rather than a
    // separate NavBar underneath it.
    this.syncedNavStack.pushPath({ name: 'syncedList' }, false);
    this.meNavStack.pushPath({ name: 'meMain' }, false);
    this.devicesNavStack.pushPath({ name: 'devicesMain' }, false);

    const context = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window) => {
      const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInsetVp = px2vp(avoidArea.topRect.height);
      this.bottomInsetVp = px2vp(avoidArea.bottomRect.height);
      // The HDS title bar positions itself from the LIVE safe area
      // (avoidLayoutSafeArea), so content clearance has to follow changes
      // too (split screen, floating window, rotation) or the two disagree.
      this.mainWindow = win;
      win.on('avoidAreaChange', this.onAvoidAreaChange);
      this.windowHeightVp = px2vp(win.getWindowProperties().windowRect.height);
      win.on('windowSizeChange', this.onWindowSizeChange);
    }).catch(() => { /* fall back to zero insets if the query fails */ });

    this.watcher.onPasteboardChanged(() => {
      if (this.noticeOnOpen) this.pendingChange = true;
    });
    this.watcher.startListening();

    const fileStore = new FileStore(context);
    this.fileStore = fileStore;
    const syncManager = new SyncManager(fileStore, this.trustStore, context);
    syncManager.onEntryApplied((entry: ClipboardEntry, result: ApplyResult, fromPeer: boolean) => {
      netLog(`entry received: type=${entry.Type} result=${result}`);
      if (result === 'applied') this.noteOwnClipboardWrite();
      this.syncedItems = [this.syncedItemFor(entry, fromPeer), ...this.syncedItems].slice(0, 50);
    });
    syncManager.onLog((message: string) => {
      this.log(message);
    });
    // The connections Map lives inside SyncManager and isn't itself
    // reactive - without this the Devices tab's connected-device count
    // never updated after the first render even though the underlying
    // count was always correct (see SyncManager.ets's onConnectionsChanged).
    // Deliberately does nothing but assign the count. This callback is
    // invoked synchronously from inside SyncManager.registerConnection,
    // BEFORE conn.listen() - so anything that throws here aborts the rest
    // of registerConnection and the connection's read loop is never
    // started. That is exactly what happened when this callback also
    // rebuilt a connected-ID set: every link was registered but never
    // listened on, so no traffic flowed and the peer redialled every 2s.
    // Per-row status is derived in deviceRows() instead.
    syncManager.onConnectionsChanged((count: number) => {
      netLog(`connections=${count}`);
      this.connectedCount = count;
    });
    this.syncManager = syncManager;

    this.tcpServer.onConnection((conn: socket.TCPSocketConnection) => {
      const identity = new DeviceIdentity();
      // Without capturing this, a device that only ever DIALED OUT to pair
      // (rather than being dialed) would never learn an address for
      // whoever just connected to it - meaning it could never later
      // reconnect off-LAN on its own (see reconnectOffLanPeers), only ever
      // be reconnected TO. getRemoteAddress() is what makes reconnect work
      // in both directions regardless of who initiated the original pairing.
      conn.getRemoteAddress()
        .then((addr: socket.NetAddress) => addr.address)
        .catch(() => null)
        .then((remoteAddress: string | null) => {
          PeerConnection.create(new TcpSocketConnectionAdapter(conn), identity, this.trustStore, context, this.pairingOpen, this.passphraseKeyStore, this.ownDeviceName())
            .then((peerConn: PeerConnection | null) => {
              if (peerConn === null) {
                conn.close().catch(() => { /* already closed - fine */ });
                return;
              }
              this.handleNewConnection(peerConn, remoteAddress);
            });
        });
    });
    this.tcpServer.start(TCP_PORT).catch((e: BusinessError) => {
      this.log(`TCP server error: ${e.message}`);
    });

    this.discovery.onPeerDiscovered((beacon: PeerBeacon) => {
      const existingIndex = this.receivedBeacons.findIndex(b => b.deviceId === beacon.deviceId);
      if (existingIndex === -1) {
        this.receivedBeacons = [beacon, ...this.receivedBeacons].slice(0, 30);
      } else {
        // A known name is never forgotten over a beacon that lacks one.
        if (beacon.name === null) beacon.name = this.receivedBeacons[existingIndex].name;
        const updated = this.receivedBeacons.slice();
        updated[existingIndex] = beacon;
        this.receivedBeacons = updated;
      }
      void this.maybeRememberPeerName(beacon.deviceId, beacon.name);
      void this.maybeAutoTrustViaPassphrase(beacon);
      void this.maybeAutoConnect(beacon);
      void this.maybeConnectForPairing(beacon);
    });

    const identity = new DeviceIdentity();
    identity.getPublicKeyBase64().then((id: string) => {
      this.ownDeviceId = id;
      netLog(`ownDeviceId=${id}`);
      this.refreshPairingPayload();
      void this.loadHistoryIntoList();
      // Same helper the foreground restart uses, and its failure is
      // surfaced rather than swallowed - a bind failure here means no
      // peer is ever discovered, which previously looked like "sync just
      // doesn't work" with nothing in the log to say why.
      this.startDiscovery().catch((e: BusinessError) => {
        this.log(`discovery failed to start: ${e.message}`);
      });
      void this.refreshPassphraseState();
      // Must run AFTER ownDeviceId is actually set, not just after this
      // .then() is scheduled - reconnectOffLanPeers's tie-breaker compares
      // against this.ownDeviceId, and calling it any earlier (e.g. from
      // aboutToAppear's own body, outside this callback) raced this
      // assignment: it ran with ownDeviceId still '' (empty string, before
      // the async key lookup resolved), so EVERY peer's key compared as
      // ">= ours" against the empty string and got skipped - a false
      // "let them reconnect to us instead" reading, not a real decision.
      // That's what made a cold start silently miss its immediate
      // reconnect attempt and sit waiting for the next 30s interval tick
      // instead, even though this call was already here.
      void this.reconnectOffLanPeers();
    });

    void this.refreshTrustedDevices();
    void this.loadTailscaleIp();
    void this.loadSyncSettings();
    this.refreshLocalAddresses();
    // setInterval doesn't fire immediately - the explicit call above (now
    // correctly sequenced after ownDeviceId is set) is what actually makes
    // a just-reopened app try reconnecting right away instead of sitting
    // disconnected from any off-LAN (e.g. Tailscale) peer for up to 30s.
    this.offLanReconnectTimerId = setInterval(() => { void this.reconnectOffLanPeers(); }, 30000);
  }

  // ArkUI page-visibility hook - fires whenever this page becomes visible
  // again, including resuming the app from the background (aboutToAppear
  // does NOT re-run for that; it only runs once when the page is first
  // built, e.g. a genuine cold start). A backgrounded app can easily have
  // had its TCP connections quietly die (mobile OSes are aggressive about
  // suspending background network activity), so foregrounding is exactly
  // the other moment - besides a cold start - that deserves an immediate
  // reconnect attempt instead of waiting on the 30s interval. ownDeviceId
  // is already populated by now (it was set back when the page first
  // appeared), so unlike the cold-start call in aboutToAppear, there's no
  // ordering race to worry about here.
  //
  // reconnectOffLanPeers alone only re-dials trusted peers with a cached
  // off-LAN (e.g. Tailscale) address - it has no path for a same-LAN peer
  // at all. A same-LAN reconnect is entirely beacon-driven: it only
  // happens when discovery's own UDP socket delivers a fresh 'message'
  // event to maybeAutoConnect. If the OS suspended or invalidated that
  // socket while the app was backgrounded (this app requests no
  // continuousTask grant, so it has no protection from that), it can sit
  // silently dead, which is why a same-LAN peer could take "seemingly
  // forever" to reconnect after foregrounding.
  //
  // The restart MUST be sequenced, not fire-and-forget. An earlier version
  // called stop() (which did not await its socket close) and then start()
  // on the next line; the new bind hit the still-open fixed port, threw
  // EADDRINUSE, and because the call was `void`-ed nothing retried - so
  // discovery died on the FIRST foreground and stayed dead, taking
  // clipboard sync with it. stop() now awaits the close, this awaits
  // stop(), and a failed bind is retried once rather than swallowed.
  onPageShow(): void {
    void this.restartDiscovery();
    void this.reconnectOffLanPeers();
    this.refreshLocalAddresses();
    // HarmonyOS's closest equivalent of Android's "send my clipboard when I
    // open ClipLink": reading the clipboard needs READ_PASTEBOARD (an ACL-only
    // restricted permission) or a PasteButton tap, so the app can't send it
    // on its own - but getChangeCount needs no permission, so it can at
    // least point at the Paste button when something new was copied while
    // ClipLink was in the background ('update' callbacks can't run then).
    if (this.noticeOnOpen && this.watcher.hasUnseenChange()) {
      this.pendingChange = true;
    }
  }

  private async restartDiscovery(): Promise<void> {
    if (this.ownDeviceId.length === 0) return;
    await this.discovery.stop();
    try {
      await this.startDiscovery();
    } catch (e) {
      const be = e as BusinessError;
      this.log(`discovery restart failed (${be.message}) - retrying`);
      setTimeout(() => {
        this.startDiscovery().catch((retryErr: BusinessError) => {
          this.log(`discovery restart retry failed: ${retryErr.message}`);
        });
      }, 1000);
    }
  }

  // Single definition of how discovery is started, so the cold-start path
  // and the foreground-restart path cannot drift apart.
  private startDiscovery(): Promise<void> {
    return this.discovery.start(
      this.ownDeviceId,
      TCP_PORT,
      () => this.cachedProof,
      () => this.tailscaleIp.length > 0 ? this.tailscaleIp : null,
      () => this.pairingOpen,
      () => this.ownDeviceName(),
    );
  }

  // The name this device sends in beacons, handshakes and its pairing code:
  // the Me screen's override if set, else the system's. Read fresh each
  // time, so a rename reaches the next beacon/handshake without a restart.
  private ownDeviceName(): string | null {
    return effectiveDeviceName(this.deviceNameOverride, this.systemDeviceName);
  }

  aboutToDisappear(): void {
    this.mainWindow?.off('avoidAreaChange', this.onAvoidAreaChange);
    this.mainWindow?.off('windowSizeChange', this.onWindowSizeChange);
    this.watcher.stopListening();
    void this.discovery.stop();
    this.tcpServer.stop();
    if (this.offLanReconnectTimerId !== -1) {
      clearInterval(this.offLanReconnectTimerId);
      this.offLanReconnectTimerId = -1;
    }
  }

  // System/gesture back button for the item-detail view and Me sub-screens
  // used to be handled here, since both were plain @State-driven overlays
  // with no real back-stack concept. Now that both are real NavDestinations
  // (see syncedPageMap/mePageMap), each one's own .onBackPressed() handler
  // intercepts system back before it would ever reach this page-level
  // hook - closeItemDetail/setMeScreen('main') are called from there
  // instead, via the same animateTo-wrapped pop this uses for the visible
  // back buttons. Nothing left here needs handling; false lets the
  // system's default (exit) behavior proceed once at a top-level tab.
  onBackPress(): boolean {
    return false;
  }

  // Every navigation into/out of the Me tab's sub-screens goes through
  // this - not just a plain field assignment - because leaving/entering
  // 'pairing' has to flip pairingOpen in lockstep (see its own doc comment).
  // Also drives the real push/pop on meNavStack, since immersive material
  // requires the back button to live in an actual NavDestination title bar
  // (see mePageMap) rather than plain content - this single call site is
  // what keeps meScreen/pairingOpen and the nav stack in sync regardless of
  // whether a sub-screen is entered via settingsRow's onTap or left via its
  // own title bar back button / a system back gesture (onBackPressed).
  // Set when pairing was opened from the Devices tab's + button rather
  // than from Me, so backing out of pairing returns to where it started
  // instead of stranding the user on a Me screen they never opened.
  @State pairingReturnTab: number = -1;

  private openPairingFromDevices(): void {
    this.pairingReturnTab = this.currentTabIndex;
    this.currentTabIndex = 2;
    this.setMeScreen('pairing');
  }

  private setMeScreen(screen: 'main' | 'pairing' | 'passcode' | 'network' | 'devicename' | 'diagnostics' | 'log'): void {
    const previous = this.meScreen;
    this.meScreen = screen;
    this.pairingOpen = screen === 'pairing';
    if (screen !== 'passcode') this.passcodeChanging = false;
    if (screen === 'main' && previous !== 'main') {
      this.meNavStack.pop(true);
      if (this.pairingReturnTab >= 0) {
        this.currentTabIndex = this.pairingReturnTab;
        this.pairingReturnTab = -1;
      }
    } else if (screen !== 'main' && previous === 'main') {
      this.meNavStack.pushPath({ name: screen }, true);
    } else if (screen !== 'main' && screen !== previous) {
      // Sub-screen to sub-screen: only happens via the Devices tab's "+"
      // while Me was left on another sub-screen (e.g. Tailscale IP). Without
      // this, meScreen/pairingOpen said 'pairing' while the stack still
      // showed the old screen - pairing mode open with no Pairing screen.
      this.meNavStack.replacePath({ name: screen }, false);
    }
  }

  private async refreshTrustedDevices(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.trustedDevices = await this.trustStore.getAllTrustedDevices(context);
  }

  // Keeps a trusted device's stored name current from its beacons, so the
  // Devices list still names it once it's off the LAN. Checked against the
  // in-memory list first - this runs on every beacon, every 2 seconds.
  private async maybeRememberPeerName(deviceId: string, name: string | null): Promise<void> {
    if (name === null) return;
    const known: TrustedDevice | undefined = this.trustedDevices.find((d: TrustedDevice) => d.publicKey === deviceId);
    if (known === undefined || known.name === name) return;
    const context = getContext(this) as common.UIAbilityContext;
    if (await this.trustStore.rememberName(context, deviceId, name)) {
      await this.refreshTrustedDevices();
    }
  }

  // A peer's name for prompts and toasts: the one just received if given,
  // else the latest from its beacon or trust record, else its short id.
  private peerLabel(deviceId: string, name: string | null = null): string {
    if (name !== null && name.length > 0) return name;
    const beacon: PeerBeacon | undefined = this.receivedBeacons.find((b: PeerBeacon) => b.deviceId === deviceId);
    if (beacon !== undefined && beacon.name !== null) return beacon.name;
    const known: TrustedDevice | undefined = this.trustedDevices.find((d: TrustedDevice) => d.publicKey === deviceId);
    if (known !== undefined && known.name !== undefined && known.name.length > 0) return known.name;
    return shortDeviceId(deviceId);
  }

  // The actual "foreground lifecycle" requirement: connect automatically
  // to any already-trusted device as soon as its beacon is heard, no user
  // action needed. Tie-breaker matches Discovery.cs's Windows logic
  // (only the smaller-public-key side initiates) so both devices don't
  // simultaneously dial each other.
  private async maybeAutoConnect(beacon: PeerBeacon): Promise<void> {
    if (beacon.deviceId === this.ownDeviceId) return;
    if (this.syncManager?.isConnected(beacon.deviceId)) return;
    if (this.connectingTo.has(beacon.deviceId)) return;
    if (beacon.deviceId >= this.ownDeviceId) return;

    // Reserved synchronously, before the first await below - the
    // has()-check-then-add() pair has to stay atomic from this point on, or
    // two beacon packets for the same peer arriving close together (e.g. a
    // burst flushed at once on resume from backgrounding) can both pass the
    // has() check above (neither has added yet) while the first call is
    // still awaiting trustStore.isTrusted(), and both end up dialing - a
    // genuine duplicate connection to the same peer. See
    // SyncManager.ets's registerConnection for what that duplicate then
    // causes (split-brain between the two ends).
    this.connectingTo.add(beacon.deviceId);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const isTrusted = await this.trustStore.isTrusted(context, beacon.deviceId);
      if (!isTrusted) return;
      await this.connectToBeacon(beacon);
    } finally {
      this.connectingTo.delete(beacon.deviceId);
    }
  }

  // Sibling to maybeAutoConnect, for UNTRUSTED peers - only attempts a
  // handshake at all when BOTH this device's own Pairing screen is open
  // (this.pairingOpen) AND the beacon says the sender's is too
  // (beacon.pairing) - two independent, live, local "I'm expecting to
  // pair right now" signals, not just one side's assumption. Same
  // tie-breaker as maybeAutoConnect so both sides don't dial each other
  // simultaneously; the handshake that results is what actually surfaces
  // the accept/reject prompt (see handleNewConnection).
  private async maybeConnectForPairing(beacon: PeerBeacon): Promise<void> {
    if (!this.pairingOpen || !beacon.pairing) return;
    if (beacon.deviceId === this.ownDeviceId) return;
    if (this.syncManager?.isConnected(beacon.deviceId)) return;
    if (this.connectingTo.has(beacon.deviceId)) return;
    if (this.pendingPairingConn !== null) return; // already have a candidate awaiting a decision
    if (beacon.deviceId >= this.ownDeviceId) return;

    // See maybeAutoConnect's identical fix - reserved before the first
    // await so a second beacon for the same peer can't slip through the
    // has() check above while this call is still awaiting isTrusted().
    this.connectingTo.add(beacon.deviceId);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (await this.trustStore.isTrusted(context, beacon.deviceId)) return; // maybeAutoConnect already handles this case
      await this.connectToBeacon(beacon);
    } finally {
      this.connectingTo.delete(beacon.deviceId);
    }
  }

  // Single funnel for every freshly-created PeerConnection, whichever of
  // the three places created it (incoming TCP, LAN beacon dial, or manual
  // Pair by Address) - an already-trusted peer is registered immediately
  // like today; a pairing candidate (only possible because pairingOpen was
  // true - see PeerConnection.create) gets an explicit local accept/reject
  // prompt instead, never auto-registered.
  private handleNewConnection(peerConn: PeerConnection, address: string | null): void {
    netLog(`handleNewConnection: peer=${peerConn.peerDeviceId.slice(0, 16)}... address=${address ?? 'null'} wasAlreadyTrusted=${peerConn.wasAlreadyTrusted} newlyTrustedViaPassphrase=${peerConn.newlyTrustedViaPassphrase}`);
    if (peerConn.wasAlreadyTrusted) {
      // Registered FIRST, before any trust-store write or activity-log
      // append. Those are conveniences; starting the connection's read
      // loop is not. Doing them first meant that if any of them threw,
      // registerConnection was skipped entirely - the link stayed
      // unregistered and unlistened, isConnected() stayed false, and the
      // peer redialled every 2s forever while no clipboard data moved.
      this.syncManager?.registerConnection(peerConn);
      if (peerConn.newlyTrustedViaPassphrase) {
        // The handshake itself carried a matching passphrase proof - same
        // auto-trust the LAN beacon already does passively, just over a
        // direct connection instead (works off-LAN, e.g. via Pair by
        // Address over Tailscale). Persist it so future reconnects don't
        // need the passphrase proof again.
        const context = getContext(this) as common.UIAbilityContext;
        void this.trustStore.trust(context, peerConn.peerDeviceId, address ?? undefined, peerConn.peerName ?? undefined).then(() => { void this.refreshTrustedDevices(); });
        this.log(`auto-paired via passcode: ${peerConn.peerDeviceId.slice(0, 12)}...`);
      } else {
        if (address !== null) {
          // Already trusted, but now we know a real address for this peer
          // (e.g. captured off an incoming connection whose remote endpoint
          // we just read, or a fresh dial) - back-fill it. trust() upserts
          // the address on an existing entry (see TrustStore.ets), so this
          // is what actually fixes a trust record that was written back
          // when the accept loop didn't capture an address at all (an old
          // bug - it always passed null), instead of leaving it permanently
          // stuck with no address to reconnect off-LAN with.
          // Its handshake's name rides along; trust() never erases a
          // stored name when this one is unknown.
          const context = getContext(this) as common.UIAbilityContext;
          void this.trustStore.trust(context, peerConn.peerDeviceId, address, peerConn.peerName ?? undefined).then(() => { void this.refreshTrustedDevices(); });
        } else if (peerConn.peerName !== null) {
          void this.maybeRememberPeerName(peerConn.peerDeviceId, peerConn.peerName);
        }
        this.log(`connected: ${peerConn.peerDeviceId.slice(0, 12)}...`);
      }
      return;
    }
    if (this.pendingPairingConn !== null) {
      // Already showing a prompt for a different candidate - don't juggle
      // two at once; whichever arrived second just doesn't get to pair
      // this round (nothing stops them from opening pairing mode again).
      peerConn.close();
      return;
    }
    this.pendingPairingConn = peerConn;
    this.pendingPairingPeerId = peerConn.peerDeviceId;
    this.pendingPairingAddress = address ?? '';
    this.getUIContext().showAlertDialog({
      title: 'Pairing request',
      message: `${this.peerLabel(peerConn.peerDeviceId, peerConn.peerName)} wants to pair with this device. Only accept if you expect this - your Pairing screen being open is what let this request reach you at all.`,
      primaryButton: { value: 'Accept', action: () => { void this.acceptPairing(); } },
      secondaryButton: { value: 'Reject', action: () => { this.rejectPairing(); } },
      cancel: () => { this.rejectPairing(); },
    });
  }

  async acceptPairing(): Promise<void> {
    const conn = this.pendingPairingConn;
    if (conn === null) return;
    if (conn.isClosed) {
      // The other side rejected or gave up while this prompt was up.
      // Trusting it anyway would pair this side only.
      this.pendingPairingConn = null;
      this.pendingPairingPeerId = '';
      this.pendingPairingAddress = '';
      promptAction.showToast({ message: 'The other device cancelled the pairing request - try again.' });
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const address = this.pendingPairingAddress.length > 0 ? this.pendingPairingAddress : undefined;
    await this.trustStore.trust(context, conn.peerDeviceId, address, conn.peerName ?? undefined);
    await this.refreshTrustedDevices();
    this.pendingPairingConn = null;
    this.pendingPairingPeerId = '';
    this.pendingPairingAddress = '';
    this.log(`paired: ${conn.peerDeviceId.slice(0, 12)}...`);
    this.syncManager?.registerConnection(conn);
    promptAction.showToast({ message: 'Paired.' });
  }

  rejectPairing(): void {
    this.pendingPairingConn?.close();
    this.pendingPairingConn = null;
    this.pendingPairingPeerId = '';
    this.pendingPairingAddress = '';
  }

  private async connectToBeacon(beacon: PeerBeacon): Promise<void> {
    try {
      const client = await connectTcp(beacon.senderIp, beacon.tcpPort);
      const identity = new DeviceIdentity();
      const context = getContext(this) as common.UIAbilityContext;
      const conn = await PeerConnection.create(new TcpSocketAdapter(client), identity, this.trustStore, context, this.pairingOpen, this.passphraseKeyStore, this.ownDeviceName());
      if (conn === null) {
        client.close().catch(() => { /* already closed - fine */ });
        this.log(`connect failed: ${beacon.deviceId.slice(0, 12)}...`);
        return;
      }
      this.handleNewConnection(conn, beacon.senderIp);
    } catch (e) {
      const be = e as BusinessError;
      this.log(`connect error (${beacon.senderIp}:${beacon.tcpPort}): ${be.message}`);
    }
  }

  // Off-LAN reconnect: for trusted peers whose only known address is a
  // cached one (e.g. a Tailscale IP, learned at pairing time or seen in a
  // beacon) rather than something LAN discovery can actually hear, dial out
  // periodically instead of waiting for a beacon that will never arrive
  // off-LAN - mirrors Program.cs's own off-LAN reconnect loop.
  private async reconnectOffLanPeers(): Promise<void> {
    if (this.ownDeviceId.length === 0) {
      // Identity hasn't resolved yet (this fires very early relative to the
      // async key lookup - both aboutToAppear's cold-start call, now
      // sequenced after it, AND onPageShow's, which is NOT, can still race
      // it). Every tie-breaker comparison below is against ownDeviceId, so
      // running this now would just compare against '' and get every
      // peer's key wrong (">= ours" for literally any non-empty key) -
      // bail instead of doing a guaranteed-wrong pass; the 30s interval or
      // the next onPageShow will retry once it's actually set.
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const devices = await this.trustStore.getTrustedDevicesWithAddress(context);
    netLog(`reconnectOffLanPeers: ownId=${this.ownDeviceId.slice(0, 16)}... ${devices.length} trusted-with-address device(s)`);
    for (const device of devices) {
      const shortId = device.publicKey.slice(0, 16);
      if (device.publicKey === this.ownDeviceId) continue;
      if (this.syncManager?.isConnected(device.publicKey)) {
        netLog(`  ${shortId}...: already connected, skipping`);
        continue;
      }
      if (this.connectingTo.has(device.publicKey)) {
        netLog(`  ${shortId}...: already attempting, skipping`);
        continue;
      }
      // Same tie-breaker as maybeAutoConnect - only the smaller-key side
      // initiates, so both sides don't simultaneously dial each other.
      if (device.publicKey >= this.ownDeviceId) {
        netLog(`  ${shortId}...: peer key >= ours, expecting THEM to reconnect to us instead`);
        continue;
      }
      if (device.address === undefined || device.address === null || device.address.length === 0) {
        netLog(`  ${shortId}...: no cached address, can't dial - needs one more successful connection to backfill`);
        continue;
      }

      netLog(`  ${shortId}...: dialing ${device.address}:${TCP_PORT}`);
      this.connectingTo.add(device.publicKey);
      try {
        const outcome = await this.connectToAddress(device.address, TCP_PORT);
        netLog(`  ${shortId}...: dial ${outcome}`);
      } finally {
        this.connectingTo.delete(device.publicKey);
      }
    }
  }

  // How a dial ended (see DialOutcome). The periodic off-LAN reconnect loop
  // only logs it; pairByAddress/scanToPair turn it into a message that says
  // which step actually failed. forPairing also waits to see whether the
  // other side kept the connection (see PeerConnection.waitForPeerVerdict):
  // without that, a device that refused this one still looked like a
  // success here, and the Pairing screen raised an Accept prompt for a
  // connection that was already closed - accepting it wrote trust on this
  // side only.
  private async connectToAddress(address: string, port: number, forPairing: boolean = false): Promise<DialOutcome> {
    let client: socket.TCPSocket;
    try {
      client = await connectTcp(address, port);
    } catch (e) {
      netLog(`connectToAddress ${address}:${port}: TCP connect failed - ${JSON.stringify(e)}`);
      return 'unreachable';
    }
    try {
      const identity = new DeviceIdentity();
      const context = getContext(this) as common.UIAbilityContext;
      const report = new HandshakeReport();
      const conn = await PeerConnection.create(new TcpSocketAdapter(client), identity, this.trustStore, context, this.pairingOpen, this.passphraseKeyStore, this.ownDeviceName(), report);
      if (conn === null) {
        netLog(`connectToAddress ${address}:${port}: TCP connected but no usable handshake (${report.timedOut ? 'no answer' : 'peer closed, or refused locally'})`);
        client.close().catch(() => { /* already closed - fine */ });
        return report.timedOut ? 'silent' : 'refused';
      }
      let verdict: PeerVerdict | null = null;
      if (forPairing) {
        verdict = await conn.waitForPeerVerdict(PEER_VERDICT_WAIT_MS);
        netLog(`connectToAddress ${address}:${port}: peer verdict ${verdict}`);
        if (verdict === 'closed') {
          conn.close();
          // Closed because it's already holding a request from this same
          // device (e.g. its own beacon-triggered dial got there first) -
          // and that request is the Accept prompt showing here right now.
          const pending: PeerConnection | null = this.pendingPairingConn;
          if (pending !== null && pending.peerDeviceId === conn.peerDeviceId) return 'prompt';
          return 'refused';
        }
      }
      netLog(`connectToAddress ${address}:${port}: handshake succeeded, peer=${conn.peerDeviceId.slice(0, 16)}... wasAlreadyTrusted=${conn.wasAlreadyTrusted}`);
      this.handleNewConnection(conn, address);
      if (!conn.wasAlreadyTrusted) {
        // handleNewConnection drops a second candidate while another
        // device's request is still showing.
        return this.pendingPairingConn === conn ? 'prompt' : 'busy';
      }
      if (conn.newlyTrustedViaPassphrase) return 'passcode';
      // Trusted here but silent there: it's holding this as a pairing
      // request, not using it as a connection.
      return verdict === 'quiet' ? 'awaiting-other' : 'connected';
    } catch (e) {
      netLog(`connectToAddress ${address}:${port}: handshake threw - ${JSON.stringify(e)}`);
      client.close().catch(() => { /* already closed - fine */ });
      return 'refused';
    }
  }

  // Trusting a freshly-discovered device also immediately attempts to
  // connect to it (rather than waiting for its next beacon) - feels more
  // responsive when the user just tapped Trust specifically to connect.
  async trustAndConnect(beacon: PeerBeacon): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await this.trustStore.trust(context, beacon.deviceId, beacon.senderIp, beacon.name ?? undefined);
    await this.refreshTrustedDevices();
    await this.connectToBeacon(beacon);
  }

  async untrustDevice(deviceId: string): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    // Before the record (and the name it may hold) is gone.
    const label: string = this.peerLabel(deviceId);
    await this.trustStore.untrust(context, deviceId);
    await this.refreshTrustedDevices();
    // Explicit confirmation matters here: a just-untrusted device doesn't
    // vanish from the Devices list if it's still actively beaconing (it
    // reappears as "discovered" with a Trust button instead of "trusted"
    // with Remove) - without this, tapping Remove on a device that's still
    // on the LAN looks like it silently did nothing.
    this.log(`untrusted ${deviceId.slice(0, 12)}...`);
    promptAction.showToast({ message: `Removed ${label}` });
  }

  // Recomputes the QR/manual pairing payload - called whenever ownDeviceId,
  // tailscaleIp or the device name changes, since the QR code needs to
  // reflect whichever is current rather than whatever was true when the
  // screen first opened.
  private refreshPairingPayload(): void {
    const pairingInfo: PairingInfo = { PublicKey: this.ownDeviceId };
    if (this.tailscaleIp.length > 0) {
      pairingInfo.Address = this.tailscaleIp;
    }
    const name: string | null = this.ownDeviceName();
    if (name !== null) {
      pairingInfo.Name = name;
    }
    this.myPairingPayload = JSON.stringify(pairingInfo);
  }

  private async loadTailscaleIp(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.tailscaleIp = await this.deviceSettings.getTailscaleIp(context);
    this.refreshPairingPayload();
  }

  private async loadSyncSettings(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.autoApply = await this.deviceSettings.getAutoApply(context);
    this.syncManager?.setAutoApply(this.autoApply);
    this.noticeOnOpen = await this.deviceSettings.getNoticeNewCopies(context);
    // onPageShow has usually already run by now using the default (on), so
    // settle the hint against the real setting.
    this.pendingChange = this.noticeOnOpen && this.watcher.hasUnseenChange();
  }

  private async setAutoApply(value: boolean): Promise<void> {
    this.autoApply = value;
    this.syncManager?.setAutoApply(value);
    const context = getContext(this) as common.UIAbilityContext;
    await this.deviceSettings.setAutoApply(context, value);
  }

  private async setNoticeNewCopies(value: boolean): Promise<void> {
    this.noticeOnOpen = value;
    // Turning it back on should point at a copy made while it was off.
    this.pendingChange = value && this.watcher.hasUnseenChange();
    const context = getContext(this) as common.UIAbilityContext;
    await this.deviceSettings.setNoticeNewCopies(context, value);
  }

  private async setBottomGlow(value: boolean): Promise<void> {
    this.bottomGlowOn = value;
    await this.deviceSettings.setBottomGlow(getContext(this) as common.UIAbilityContext, value);
  }

  private async saveCardTransparency(percent: number): Promise<void> {
    await this.deviceSettings.setCardTransparency(getContext(this) as common.UIAbilityContext, percent);
  }

  private async setAccentTheme(key: string): Promise<void> {
    if (key === this.selectedThemeKey()) return;
    this.accentTheme = key;
    const context = getContext(this) as common.UIAbilityContext;
    await this.deviceSettings.setAccentTheme(context, key);
  }

  // IPv4 only and no loopback, matching Android's localAddresses(). Includes
  // any VPN interface the system reports as a network (e.g. Tailscale).
  private refreshLocalAddresses(): void {
    try {
      const found: string[] = [];
      for (const net of connection.getAllNetsSync()) {
        const props = connection.getConnectionPropertiesSync(net);
        for (const link of props.linkAddresses) {
          const addr: string = link.address.address;
          if (addr.includes(':') || addr.startsWith('127.') || found.includes(addr)) continue;
          found.push(addr);
        }
      }
      this.localAddresses = found;
    } catch (e) {
      this.localAddresses = [];
    }
  }

  async clearPassphrase(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await this.passphraseKeyStore.clearPassphrase(context);
    this.passcodeChanging = false;
    this.passphraseInput = '';
    await this.refreshPassphraseState();
    promptAction.showToast({ message: 'Passcode cleared.' });
  }

  private confirmClearHistory(): void {
    this.getUIContext().showAlertDialog({
      title: 'Clear synced history?',
      message: 'Removes every synced item and any files saved for them from this device. Paired devices keep their own copies, and may send them back when they next reconnect.',
      primaryButton: { value: 'Cancel', action: () => {} },
      secondaryButton: { value: 'Clear', fontColor: $r('sys.color.warning'), action: () => { void this.clearSyncedHistory(); } },
    });
  }

  private async clearSyncedHistory(): Promise<void> {
    // An open preview would be left showing an item that no longer exists.
    if (this.syncedNavStack.size() > 1) {
      this.syncedNavStack.pop(false);
    }
    this.selectedItemId = '';
    // Emptied before the await, so an item that arrives while the clear is
    // running (and is saved after it) stays listed instead of being wiped.
    this.syncedItems = [];
    await this.syncManager?.clearHistory();
    promptAction.showToast({ message: 'History cleared.' });
  }

  async saveTailscaleIp(): Promise<void> {
    if (this.savingTailscaleIp) return; // already running - ignore a double-tap
    this.savingTailscaleIp = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const trimmed = this.tailscaleIp.trim();
      await this.deviceSettings.setTailscaleIp(context, trimmed);
      this.tailscaleIp = trimmed;
      this.refreshPairingPayload();
      promptAction.showToast({ message: trimmed.length > 0 ? 'Tailscale IP saved.' : 'Tailscale IP cleared.' });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Failed to save: ${be.message ?? e}`, duration: 3000 });
    } finally {
      this.savingTailscaleIp = false;
    }
  }

  // Empty saves "no override" - the system's name is used again. Trimmed and
  // capped here, so the field shows exactly what will be sent. Beacons read
  // it fresh (see startDiscovery); the next handshake picks it up too.
  async saveDeviceName(): Promise<void> {
    if (this.savingDeviceName) return; // already running - ignore a double-tap
    this.savingDeviceName = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const saved: string = normalizeDeviceName(this.deviceNameInput) ?? '';
      await this.deviceSettings.setDeviceName(context, saved);
      this.deviceNameOverride = saved;
      this.deviceNameInput = saved;
      this.refreshPairingPayload();
      promptAction.showToast({ message: saved.length > 0 ? 'Device name saved.' : 'Using the system device name.' });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Failed to save: ${be.message ?? e}`, duration: 3000 });
    } finally {
      this.savingDeviceName = false;
    }
  }

  private async refreshPassphraseState(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.hasPassphrase = await this.passphraseKeyStore.hasPassphrase(context);
    if (this.hasPassphrase && this.ownDeviceId.length > 0) {
      const key = await this.passphraseKeyStore.getKey(context);
      if (key !== null) {
        this.cachedProof = await this.passphraseKeyStore.computeProof(key, this.ownDeviceId);
      }
    } else {
      this.cachedProof = null;
    }
  }

  async setPassphrase(): Promise<void> {
    if (this.settingPassphrase) return; // already running - ignore a double-tap
    const passphrase = this.passphraseInput.trim();
    if (passphrase.length === 0) {
      promptAction.showToast({ message: 'Enter a passcode first.' });
      return;
    }
    // PassphraseKeyStore.setPassphrase runs PBKDF2 at 210,000 iterations
    // (fixed to match the Windows side - see PassphraseKeyStore.ets) via
    // cryptoFramework, awaited per round - this can take several seconds
    // on-device. Without this pending state the button looked broken:
    // nothing visibly happened until it finally resolved.
    this.settingPassphrase = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await this.passphraseKeyStore.setPassphrase(context, passphrase);
      this.passphraseInput = '';
      this.passcodeChanging = false;
      await this.refreshPassphraseState();
      promptAction.showToast({ message: 'Passcode set — matching devices will auto-trust.', duration: 3000 });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Failed to set passcode: ${be.message ?? e}`, duration: 3000 });
    } finally {
      this.settingPassphrase = false;
    }
  }

  // Mirrors Program.cs's auto-trust block in discovery.PeerDiscovered: if
  // this device wasn't already trusted, but it proved knowledge of the same
  // passphrase we have configured, trust it now - an alternative to QR/
  // manual pairing for "these are all my own devices". Excludes our own id
  // for the same reason Windows does: UDP broadcasts loop back to the
  // sender on localhost.
  private async maybeAutoTrustViaPassphrase(beacon: PeerBeacon): Promise<void> {
    if (beacon.deviceId === this.ownDeviceId) return;
    if (beacon.proof === null) return;
    const context = getContext(this) as common.UIAbilityContext;
    if (await this.trustStore.isTrusted(context, beacon.deviceId)) return;
    const key = await this.passphraseKeyStore.getKey(context);
    if (key === null) return;
    const verified = await this.passphraseKeyStore.verifyProof(key, beacon.deviceId, beacon.proof);
    if (!verified) return;
    this.log(`auto-trusting ${beacon.deviceId.slice(0, 12)}... (shared passcode)`);
    await this.trustStore.trust(context, beacon.deviceId, beacon.address ?? undefined, beacon.name ?? undefined);
    await this.refreshTrustedDevices();
  }

  // Manual pairing via QR: scans another device's pairing code (shown via
  // its own "Show My QR Code" - see myPairingPayload/QRCode in meTab below)
  // and trusts it. Accepts either the {PublicKey, Address} JSON payload
  // this device (and Windows's QrCodeForm) produce, or a bare public key
  // string, matching the same flexible-payload handling Program.cs's
  // trust_device IPC command does for a pasted key.
  // Scanning is now purely "how do I find the other device's address" -
  // NOT "trust it". It never writes to the trust store directly; it dials
  // the scanned address (same as Pair by Address below) and lets the
  // normal handleNewConnection accept/reject prompt decide. That prompt
  // only appears at all if THIS device's Pairing screen is open (which it
  // has to be, to reach this button) - and the connection only completes
  // in the first place if the OTHER device's Pairing screen is open too
  // (see PeerConnection.create's relaxed gate), so scanning someone's code
  // alone can no longer trust them unilaterally the way it used to.
  // Every address worth trying for a peer, best-first. A QR code (and the
  // trust store) carries whatever the peer ADVERTISES for itself, which is
  // its Tailscale IP when it has one configured - and that address is
  // useless if Tailscale isn't up on THIS device. Any LAN address we've
  // actually received a beacon from is both more likely to work and
  // cheaper, so it goes first.
  private addressCandidatesFor(deviceId: string, advertised: string | undefined): string[] {
    const candidates: string[] = [];
    if (deviceId.length > 0) {
      for (const b of this.receivedBeacons) {
        if (b.deviceId !== deviceId) continue;
        if (b.senderIp.length > 0 && !candidates.includes(b.senderIp)) candidates.push(b.senderIp);
      }
    }
    if (advertised !== undefined && advertised.length > 0 && !candidates.includes(advertised)) {
      candidates.push(advertised);
    }
    return candidates;
  }

  // Tries each candidate in order, stopping at the first that completes a
  // handshake. If none does, report the most informative failure: a
  // refusal (ClipLink answered) over silence (something answered) over
  // unreachable.
  private async connectToFirstReachable(candidates: string[], port: number): Promise<DialResult> {
    let outcome: DialOutcome = 'unreachable';
    for (const addr of candidates) {
      const tried = await this.connectToAddress(addr, port, true);
      if (tried !== 'unreachable' && tried !== 'refused' && tried !== 'silent') {
        return { address: addr, outcome: tried };
      }
      if (tried === 'refused' || (tried === 'silent' && outcome === 'unreachable')) outcome = tried;
    }
    return { address: candidates.join(' or '), outcome: outcome };
  }

  // The pairing screen's feedback for a dial. It used to be one message
  // for every failure - "make sure the other device's Pairing screen is
  // open" - which was misleading whenever the real problem was the network
  // (or the other device not listening), and ignored the passcode path.
  private pairingOutcomeMessage(result: DialResult): string {
    switch (result.outcome) {
      case 'connected':
        return `Already paired with ${result.address} - connected.`;
      case 'passcode':
        return `Paired with ${result.address} using your passcode.`;
      case 'prompt':
        return `Reached ${result.address} - accept the pairing prompt on both devices to finish.`;
      case 'awaiting-other':
        return `Reached ${result.address} - accept the request on that device to finish.`;
      case 'busy':
        return 'Another pairing request is already waiting here - accept or reject it first.';
      case 'refused':
        return `${result.address} answered but didn't accept this device. Set the same passcode on both, or open its Pairing screen (and finish any other pairing request there), then try again.`;
      case 'silent':
        return `${result.address} accepted the connection but ClipLink there didn't respond - try restarting it on that device.`;
      default:
        return `Couldn't connect to ${result.address}. Check ClipLink is running there and both devices are on Tailscale (or the same network).`;
    }
  }

  async scanToPair(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const result = await scanBarcode.startScanForResult(context);
      let pairingInfo: PairingInfo | null = null;
      try {
        pairingInfo = JSON.parse(result.originalValue) as PairingInfo;
      } catch (e) {
        // not JSON - fall through to bare-key handling below
      }
      const scannedKey: string = pairingInfo !== null && typeof pairingInfo.PublicKey === 'string' ? pairingInfo.PublicKey : '';
      const publicKey = scannedKey.length > 0 ? scannedKey : result.originalValue;
      if (publicKey.length === 0) {
        this.scanStatus = 'scanned code was empty';
        return;
      }
      const address: string | undefined = pairingInfo !== null && typeof pairingInfo.Address === 'string' ? pairingInfo.Address : undefined;
      // Optional - codes from older builds carry no name.
      const sentName: string | undefined = pairingInfo !== null ? pairingInfo.Name : undefined;
      const scannedName: string | null = typeof sentName === 'string' ? normalizeDeviceName(sentName) : null;
      if (address === undefined) {
        this.scanStatus = `${this.peerLabel(publicKey, scannedName)} has no address in its code - if it's on the same network, just keep this screen open and its beacon will trigger pairing automatically.`;
        return;
      }
      const candidates = this.addressCandidatesFor(publicKey, address);
      this.scanStatus = `Connecting to ${candidates[0]}...`;
      const dial = await this.connectToFirstReachable(candidates, TCP_PORT);
      this.scanStatus = this.pairingOutcomeMessage(dial);
    } catch (e) {
      const be = e as BusinessError;
      if (be.code === 1000500002) {
        // user canceled the scan - routine, not an error
        return;
      }
      this.scanStatus = `scan failed: ${be.message}`;
    }
  }

  // Manual counterpart to scanToPair, for when there's no QR to scan (e.g.
  // Windows has no camera) - type/paste an address directly. Accepts either
  // a bare IP or the full {PublicKey,Address} pairing JSON (only the
  // address is actually used either way; the peer's real identity comes
  // from the signature-verified handshake, not from anything typed here).
  async pairByAddress(): Promise<void> {
    if (this.pairingInProgress) return;
    const raw = this.pairByAddressInput.trim();
    if (raw.length === 0) {
      promptAction.showToast({ message: 'Enter an address first.' });
      return;
    }
    let address = raw;
    let pastedKey = '';
    try {
      const parsed = JSON.parse(raw) as PairingInfo;
      if (typeof parsed.Address === 'string' && parsed.Address.length > 0) {
        address = parsed.Address;
      }
      if (typeof parsed.PublicKey === 'string') {
        pastedKey = parsed.PublicKey;
      }
    } catch (e) {
      // not JSON - treat the raw input as a bare address
    }
    this.pairingInProgress = true;
    try {
      // Same LAN-first ordering as scanToPair - pasted pairing text carries
      // the peer's advertised (often Tailscale) address too.
      const candidates = this.addressCandidatesFor(pastedKey, address);
      const result = await this.connectToFirstReachable(candidates, TCP_PORT);
      promptAction.showToast({ message: this.pairingOutcomeMessage(result), duration: 3500 });
    } finally {
      this.pairingInProgress = false;
    }
  }

  // See pairingScreen's "Copy Pairing Info" button - setData needs no
  // permission (unlike getData/PasteButton), so this can run from a plain
  // onClick with no security-component dance.
  async copyPairingPayload(): Promise<void> {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.myPairingPayload);
    await pasteboard.getSystemPasteboard().setData(data);
    this.noteOwnClipboardWrite();
    promptAction.showToast({ message: 'Pairing info copied — paste it into Windows\' Trust a Device dialog.', duration: 3000 });
  }

  async copyDeviceId(): Promise<void> {
    if (this.ownDeviceId.length === 0) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.ownDeviceId);
      await pasteboard.getSystemPasteboard().setData(data);
      this.noteOwnClipboardWrite();
      promptAction.showToast({ message: 'Device ID copied.' });
    } catch (e) {
      promptAction.showToast({ message: 'Could not copy — try again.' });
    }
  }

  // After this app writes to the clipboard, the clipboard holds OUR data -
  // so it must not be flagged as a new copy to send, and any earlier "new
  // copy" hint now points at content that's been overwritten.
  private noteOwnClipboardWrite(): void {
    this.markClipboardSeen();
    this.pendingChange = false;
  }

  private markClipboardSeen(): void {
    const count: number = this.watcher.markSeen();
    if (count >= 0) {
      void this.deviceSettings.setLastSeenClipCount(getContext(this) as common.UIAbilityContext, count);
    }
  }

  async onPasteButtonClick(result: PasteButtonOnClickResult) {
    if (result !== PasteButtonOnClickResult.SUCCESS) {
      promptAction.showToast({ message: 'Tap did not grant access — try again.' });
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const change = await this.watcher.readCurrentClipboard(context);
    this.markClipboardSeen();
    this.pendingChange = false;
    if (change === null) {
      promptAction.showToast({ message: 'Clipboard unchanged since last sync.' });
      return;
    }
    if (change.type === 'unsupported') {
      promptAction.showToast({ message: `Unsupported clipboard content: ${change.detail}` });
      return;
    }

    const identity = new DeviceIdentity();
    const myDeviceId = await identity.getPublicKeyBase64();

    // "file" is different from text/image: the signed entry only ever
    // carries a small FilePayload descriptor (see storage/FilePayload.ets),
    // never the bytes themselves - those get cached into FileStore first
    // (so a file_request from a peer, or fulfilling our own pending entry,
    // can find them) and streamed separately by SyncManager.broadcastEntry.
    let entryContent = change.content;
    if (change.type === 'file') {
      const fileStore = this.fileStore;
      if (fileStore === null) {
        promptAction.showToast({ message: 'File store not ready yet — try again.' });
        return;
      }
      const bytes = base64Helper.decodeSync(change.content);
      const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      if (!fileStore.exists(change.hash)) {
        const file = fs.openSync(fileStore.getPath(change.hash), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, ab);
        } finally {
          fs.closeSync(file);
        }
      }
      const payload: FilePayload = { FileName: change.fileName ?? 'file', FileHash: change.hash, FileSize: bytes.byteLength };
      entryContent = JSON.stringify(payload);
    }

    const entry = await signEntry(identity, entryContent, change.type, myDeviceId);
    await this.syncManager?.broadcastEntry(entry);

    // broadcastEntry only sends to peers and records history - it never
    // touches syncedItems, which is what onEntryApplied (received-entry
    // path) populates. Without this, the device that actually captured
    // and sent something never saw it in its own Synced list at all -
    // only the receiving peer did.
    this.syncedItems = [this.syncedItemFor(entry, false), ...this.syncedItems].slice(0, 50);

    const count = this.syncManager?.connectionCount ?? 0;
    promptAction.showToast({
      message: count > 0 ? `Synced ${change.type} to ${count} device(s).` : `Captured ${change.type} — no devices connected yet.`,
    });
  }

  async runSelfTest() {
    try {
      const identity = new DeviceIdentity();
      await identity.getPublicKeyBase64();
      const testBytes = new Uint8Array([1, 2, 3]);
      await identity.sign(testBytes);
      const context = getContext(this) as common.UIAbilityContext;
      await this.trustStore.isTrusted(context, 'self-test-probe');
      promptAction.showToast({ message: 'Self-test passed — identity, signing, and trust store all working.' });
    } catch (e) {
      const be = e as BusinessError;
      promptAction.showToast({ message: `Self-test failed: ${be.message ?? e}` });
    }
  }

  // "Copy" only makes sense for text - for image/file it used to dump the
  // raw base64/JSON descriptor onto the clipboard as literal text, which
  // was never useful. Those two types get Share + Save instead (see
  // shareItem/showSaveImageDialog/saveFileToDocuments below).
  copyItemContent(item: SyncedItem): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.content);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => { this.noteOwnClipboardWrite(); promptAction.showToast({ message: 'Copied to clipboard.' }); })
      .catch(() => { promptAction.showToast({ message: 'Could not copy — try again.' }); });
  }

  showSelectTextDialog(item: SyncedItem): void {
    const dialogController: CustomDialogController = new CustomDialogController({
      builder: SelectTextDialog({ content: item.content }),
      alignment: DialogAlignment.Bottom,
    });
    dialogController.open();
  }

  // Real system share sheet (@kit.ShareKit's systemShare) - unlike
  // SaveButton, this is a normal API call, not gated behind a security
  // component. Images get materialized to a temp file first since
  // systemShare needs a URI, not raw base64.
  // Hands a stored file to the system so the user can actually open it.
  // Two tiers, because neither alone covers everything:
  //   1. Preview Kit's openPreview - the real "view this file" surface on
  //      HarmonyOS NEXT (pdf/office/txt/html/av/images). canPreview tells
  //      us up front whether it will take the file.
  //   2. An implicit Want with ohos.want.action.viewData for anything
  //      Preview Kit declines, so a third-party handler can claim it.
  // The action is written as a literal on purpose: ACTION_VIEW_DATA only
  // exists on the DEPRECATED @ohos.ability.wantConstant; the modern
  // @ohos.app.ability.wantConstant.Action enum has just ACTION_SEND_TO_DATA.
  // FLAG_AUTH_READ_URI_PERMISSION is the only public way to lend another
  // app read access to a file in this sandbox - grantUriPermission is
  // system-api only.
  // A card with something to show opens the in-app detail view; a file we
  // cannot preview has nothing to show, so hand it straight to the system
  // instead of opening an empty viewer.
  private activateItem(item: SyncedItem): void {
    if (item.type === 'file' && this.imagePreviewUri(item) === null) {
      void this.openFileWithSystem(item);
      return;
    }
    this.openItemDetail(item);
  }

  async openFileWithSystem(item: SyncedItem): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const fileStore = this.fileStore;
    if (fileStore === null) {
      promptAction.showToast({ message: 'File store not ready — try again.' });
      return;
    }
    let payload: FilePayload;
    try {
      payload = JSON.parse(item.content) as FilePayload;
    } catch (e) {
      promptAction.showToast({ message: 'That item is not a file.' });
      return;
    }
    if (!fileStore.exists(payload.FileHash)) {
      promptAction.showToast({ message: "File hasn't finished downloading yet." });
      return;
    }
    const uri: string = fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
    const mime: string = mimeTypeForFileName(payload.FileName);

    if (canIUse('SystemCapability.FileManagement.FilePreview.Core')) {
      try {
        const previewable: boolean = await filePreview.canPreview(context, uri);
        if (previewable) {
          await filePreview.openPreview(context, { title: payload.FileName, uri: uri, mimeType: mime });
          return;
        }
      } catch (e) {
        // fall through to the implicit Want
      }
    }

    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: mime,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION | wantConstant.Flags.FLAG_START_WITHOUT_TIPS,
    };
    try {
      await context.startAbility(want);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 16000019 || err.code === 16000001) {
        promptAction.showToast({ message: `No app on this device can open ${payload.FileName}.` });
      } else {
        promptAction.showToast({ message: `Could not open file (${err.code}).` });
      }
    }
  }

  async shareItem(item: SyncedItem): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      let uri: string;
      let utd: string;
      if (item.type === 'image') {
        const path = `${context.cacheDir}/shared_image.png`;
        const bytes = base64Helper.decodeSync(item.content);
        const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, ab);
        } finally {
          fs.closeSync(file);
        }
        uri = fileUri.getUriFromPath(path);
        utd = 'general.png';
      } else {
        const fileStore = this.fileStore;
        if (fileStore === null) {
          promptAction.showToast({ message: 'File store not ready — try again.' });
          return;
        }
        const payload = JSON.parse(item.content) as FilePayload;
        if (!fileStore.exists(payload.FileHash)) {
          promptAction.showToast({ message: "File hasn't finished downloading yet." });
          return;
        }
        uri = fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
        utd = 'general.file';
      }
      const sharedData = new systemShare.SharedData({ utd, uri });
      const controller = new systemShare.ShareController(sharedData);
      await controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL });
    } catch (e) {
      promptAction.showToast({ message: 'Could not open share sheet.' });
    }
  }

  showSaveImageDialog(item: SyncedItem): void {
    const dialogController: CustomDialogController = new CustomDialogController({
      builder: SaveImageDialog({ onSave: (result: SaveButtonOnClickResult) => { void this.saveImageOnClick(item, result); } }),
      alignment: DialogAlignment.Bottom,
    });
    dialogController.open();
  }

  // Wired to a SaveButton (security component - see save_button.d.ts),
  // which is what actually grants the temporary photoAccessHelper access
  // this needs; it can't be invoked imperatively from a plain Button, the
  // SaveButton itself has to be the tapped component (see SaveImageDialog).
  async saveImageOnClick(item: SyncedItem, result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      promptAction.showToast({ message: 'Save was not authorized.' });
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const file = fs.openSync(uri, fs.OpenMode.WRITE_ONLY);
      try {
        const bytes = base64Helper.decodeSync(item.content);
        const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
        fs.writeSync(file.fd, ab);
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: 'Saved to gallery.' });
    } catch (e) {
      promptAction.showToast({ message: 'Could not save image.' });
    }
  }

  // Files aren't media-library content, so this goes through
  // DocumentViewPicker.save() - a normal system file-save picker, not
  // gated behind a security component the way SaveButton/photoAccessHelper
  // is - confirmed against @ohos.file.picker.d.ts rather than assumed.
  async saveFileToDocuments(item: SyncedItem): Promise<void> {
    const fileStore = this.fileStore;
    if (fileStore === null) {
      promptAction.showToast({ message: 'File store not ready — try again.' });
      return;
    }
    try {
      const payload = JSON.parse(item.content) as FilePayload;
      if (!fileStore.exists(payload.FileHash)) {
        promptAction.showToast({ message: "File hasn't finished downloading yet." });
        return;
      }
      const context = getContext(this) as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.save({ newFileNames: [payload.FileName] });
      if (uris.length === 0) return; // user canceled the picker

      const srcFile = fs.openSync(fileStore.getPath(payload.FileHash), fs.OpenMode.READ_ONLY);
      const destFile = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const buffer = new ArrayBuffer(256 * 1024);
        let bytesRead = fs.readSync(srcFile.fd, buffer);
        while (bytesRead > 0) {
          fs.writeSync(destFile.fd, buffer.slice(0, bytesRead) as ArrayBuffer);
          bytesRead = fs.readSync(srcFile.fd, buffer);
        }
      } finally {
        fs.closeSync(srcFile);
        fs.closeSync(destFile);
      }
      promptAction.showToast({ message: 'File saved.' });
    } catch (e) {
      promptAction.showToast({ message: 'Could not save file.' });
    }
  }

  // Tapping (not long-pressing) a text/image card morphs it into a
  // full-screen detail view via geometryTransition - the "一镜到底"
  // continuous-shot pattern from transitions-collection's
  // ListLongTakeTransition sample: the state change that swaps which view
  // is rendered has to happen INSIDE animateTo (not a .transition()
  // modifier alone) for the geometry interpolation to actually run.
  // Only meaningful for 'file' entries - a real 'image' entry already
  // carries its bytes inline as base64 (see itemDetailView/syncedItemCard).
  // Returns a file:// URI ArkUI's Image can load directly (same
  // fileUri.getUriFromPath pattern shareItem/saveFileToDocuments already
  // use), or null if this isn't an image file, or its bytes haven't
  // finished downloading yet (nothing to preview until they have).
  private imagePreviewUri(item: SyncedItem): string | null {
    if (item.type !== 'file') return null;
    try {
      const payload = JSON.parse(item.content) as FilePayload;
      if (!isImageFileName(payload.FileName)) return null;
      const fileStore = this.fileStore;
      if (fileStore === null || !fileStore.exists(payload.FileHash)) return null;
      return fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
    } catch (e) {
      return null;
    }
  }

  // 'image' entries only exist as in-memory base64 (see itemDetailView) -
  // dragging out to another app needs a real file:// URI, same as
  // shareItem's image branch, so materialize to a cache file first. Synchronous
  // because onDragStart itself is synchronous (it returns the drag preview
  // info directly, not a Promise) - fs's *Sync APIs are what make that
  // possible without restructuring the drag callback.
  private materializeDragImage(item: SyncedItem): string | null {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const path = `${context.cacheDir}/dragged_image.png`;
      const bytes = base64Helper.decodeSync(item.content);
      const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, ab);
      } finally {
        fs.closeSync(file);
      }
      return fileUri.getUriFromPath(path);
    } catch (e) {
      return null;
    }
  }

  // Builds the UnifiedData payload a card's onDragStart hands to the
  // system so dropping it in another app (or another list position, once
  // reordering exists) carries real content - not just a picture of the
  // card. null means "nothing draggable yet" (e.g. a file entry whose
  // bytes haven't finished downloading), in which case onDragStart skips
  // setData and the drag simply carries no payload.
  private dragDataFor(item: SyncedItem): unifiedDataChannel.UnifiedData | null {
    if (item.type === 'text') {
      const text = new unifiedDataChannel.PlainText();
      text.textContent = item.content;
      return new unifiedDataChannel.UnifiedData(text);
    }
    if (item.type === 'image') {
      const uri = this.materializeDragImage(item);
      if (uri === null) return null;
      const image = new unifiedDataChannel.Image();
      image.imageUri = uri;
      return new unifiedDataChannel.UnifiedData(image);
    }
    if (item.type === 'file') {
      try {
        const payload = JSON.parse(item.content) as FilePayload;
        const fileStore = this.fileStore;
        if (fileStore === null || !fileStore.exists(payload.FileHash)) return null;
        const uri = fileUri.getUriFromPath(fileStore.getPath(payload.FileHash));
        if (isImageFileName(payload.FileName)) {
          const image = new unifiedDataChannel.Image();
          image.imageUri = uri;
          image.details = { name: payload.FileName };
          return new unifiedDataChannel.UnifiedData(image);
        }
        const file = new unifiedDataChannel.File();
        file.uri = uri;
        file.details = { name: payload.FileName };
        return new unifiedDataChannel.UnifiedData(file);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  // File entries have no meaningful full-screen preview unless they're
  // recognizably an image (see imagePreviewUri) - otherwise tapping one
  // does nothing beyond the shared clickEffect() every card already gets.
  openItemDetail(item: SyncedItem): void {
    if (item.type === 'file' && this.imagePreviewUri(item) === null) return;
    this.imageZoomScale = 1;
    this.imageZoomBase = 1;
    this.imageOffsetX = 0;
    this.imageOffsetY = 0;
    this.imageOffsetBaseX = 0;
    this.imageOffsetBaseY = 0;
    // Set BEFORE the push, not inside animateTo like the old selectedItemId
    // assignment was - the 'itemDetail' NavDestination's builder (see
    // syncedPageMap) reads this synchronously the moment the push mounts
    // it, so it has to already be correct by then.
    this.selectedItemId = item.id;
    // Per Huawei's own Navigation shared-element-transition guide
    // (arkts-navigation-animation#共享元素转场): the push call itself must run
    // inside animateTo, and pushPath's own default transition must be
    // disabled (the `false` argument) so it doesn't layer on top of the
    // geometryTransition-driven animation and produce a broken double
    // animation.
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) }, () => {
      this.syncedNavStack.pushPath({ name: 'itemDetail' }, false);
    });
  }

  closeItemDetail(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 328, 36) }, () => {
      this.syncedNavStack.pop(false);
    });
  }

  // Reads syncManager.isConnected() directly; connectedCount changing is
  // what re-runs this builder
  // for why: that used to only "live update" incidentally, as a side
  // effect of being called inside the same @Builder that also reads
  // connectedCount.
  // Every activity-log line goes through here so each one carries a
  // wall-clock time to the second. The log was previously bare strings
  // with no time at all, which made it useless for working out the order
  // or spacing of events.
  private log(message: string): void {
    const d = new Date();
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    const ss = d.getSeconds().toString().padStart(2, '0');
    // Writes syncLog DIRECTLY. This must never call this.log() - doing so
    // recurses forever and every caller dies of a stack overflow, which is
    // precisely what silently killed connection registration and the paste
    // button when the timestamp rewrite accidentally replaced this line.
    this.syncLog = [`${hh}:${mm}:${ss}  ${message}`, ...this.syncLog].slice(0, 30);
  }

  private deviceRows(): DeviceRow[] {
    const rows = new Map<string, DeviceRow>();
    // Accumulates rather than overwrites - see DeviceRow.addresses.
    const addAddress = (row: DeviceRow, value: string | null | undefined): void => {
      if (value === null || value === undefined) return;
      const v: string = value.trim();
      if (v.length === 0) return;
      if (!row.addresses.includes(v)) row.addresses.push(v);
      if (row.address === null) row.address = v;
    };
    for (const t of this.trustedDevices) {
      const row: DeviceRow = {
        deviceId: t.publicKey,
        name: t.name !== undefined && t.name.length > 0 ? t.name : null,
        addresses: [],
        address: null,
        trusted: true,
        discovered: false,
        tcpPort: null,
        connected: this.syncManager?.isConnected(t.publicKey) ?? false,
      };
      rows.set(t.publicKey, row);
    }
    for (const b of this.receivedBeacons) {
      if (b.deviceId === this.ownDeviceId) continue;
      let row = rows.get(b.deviceId);
      if (row === undefined) {
        row = {
          deviceId: b.deviceId,
          name: null,
          addresses: [],
          address: null,
          trusted: false,
          discovered: true,
          tcpPort: b.tcpPort,
          connected: this.syncManager?.isConnected(b.deviceId) ?? false,
        };
        rows.set(b.deviceId, row);
      }
      row.discovered = true;
      row.tcpPort = b.tcpPort;
      row.connected = this.syncManager?.isConnected(b.deviceId) ?? false;
      // The beacon is the latest word on its name.
      if (b.name !== null) row.name = b.name;
      // senderIp is where the packet really came from (the LAN address, so
      // it goes first); b.address is what the peer advertises for itself
      // (its Tailscale IP when configured).
      addAddress(row, b.senderIp);
      addAddress(row, b.address);
    }
    // The trust store's cached address (last pairing/connection address)
    // after the live ones - it may be the same as either, or older.
    for (const t of this.trustedDevices) {
      const row = rows.get(t.publicKey);
      if (row !== undefined) addAddress(row, t.address);
    }
    return Array.from(rows.values()).sort(compareDeviceRows);
  }

  private syncedItemFor(entry: ClipboardEntry, fromPeer: boolean): SyncedItem {
    return {
      id: entry.Signature ?? `${entry.DeviceId}:${entry.Timestamp}`,
      type: entry.Type,
      preview: previewFor(entry),
      content: entry.Content,
      source: this.sourceLabelFor(entry.DeviceId),
      time: entry.Timestamp.slice(11, 16),
      fromPeer,
    };
  }

  // The list used to be filled only by live callbacks, so it came up empty
  // after every restart even though up to 25 entries were saved (Android
  // rebuilds its list from history the same way). Needs ownDeviceId, to tell
  // this device's own entries from peers'.
  private async loadHistoryIntoList(): Promise<void> {
    const saved: ClipboardEntry[] = (await this.syncManager?.getHistory()) ?? [];
    // Timestamps are .NET round-trip ISO strings, which sort as text once
    // canonicalised (a relay may have trimmed their fraction).
    const restored: SyncedItem[] = saved
      .slice()
      .sort((a: ClipboardEntry, b: ClipboardEntry) => {
        const at = canonicalTimestamp(a.Timestamp);
        const bt = canonicalTimestamp(b.Timestamp);
        return at < bt ? 1 : (at > bt ? -1 : 0);
      })
      .map((entry: ClipboardEntry) => this.syncedItemFor(entry, entry.DeviceId !== this.ownDeviceId));
    // Anything that arrived live while this was loading stays on top.
    const liveIds: Set<string> = new Set(this.syncedItems.map((i: SyncedItem) => i.id));
    this.syncedItems = [...this.syncedItems, ...restored.filter((i: SyncedItem) => !liveIds.has(i.id))].slice(0, 50);
  }

  // Human-readable label for whichever device an item came from. A raw
  // public key fragment ("MFkwEwYHKoZI...") was being used as the card's
  // byline, which is both meaningless to read and visually identical for
  // every peer. Prefer the peer's address, fall back to a plain phrase.
  private sourceLabelFor(deviceId: string): string {
    if (deviceId === this.ownDeviceId) return 'This device';
    const known = this.trustedDevices.find(d => d.publicKey === deviceId);
    if (known !== undefined && known.address !== undefined && known.address.length > 0) {
      return known.address;
    }
    return 'Other device';
  }

  // The app's one accent colour, from the chosen theme. HarmonyOS gives apps
  // no wallpaper palette (Android's "use wallpaper colours") and no
  // user-facing system accent, so the Me screen offers a theme picker
  // instead. Read during build, so every call site re-renders on a change.
  private accent(): ResourceColor {
    return themeFor(this.accentTheme).color;
  }

  private selectedThemeKey(): string {
    return themeFor(this.accentTheme).key;
  }

  private selectedThemeName(): string {
    return themeFor(this.accentTheme).name;
  }

  private materialCard(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
  }

  // Per "组件适配沉浸光感" (component adaptation guide): buttons take
  // systemMaterial directly as a component-level immersive-material
  // attribute. interactive (press deforms) and lightEffect (light follows
  // the finger) are the tactile feedback replacing the plain default press
  // state - lightEffect.color is the one app accent color, reused here and
  // everywhere else it applies, rather than defaulting to white.
  //
  // Per the systemMaterial reference, a Button's material only renders in
  // a Navigation/NavDestination title bar or a bottom TabBar - in page
  // content (every current caller) it's inactive and the Button's
  // backgroundColor is what shows. So those buttons set
  // backgroundColor(accentTint()) BEFORE .systemMaterial() (set after, it
  // would stack on top of an active material); materialColor carries the
  // same tint for wherever the material does render.
  private buttonMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: this.accentTint(),
      interactive: true,
      colorInvert: true,
      lightEffect: { color: this.accent() },
    });
  }

  // The accent as a translucent fill for tinted secondary buttons - the
  // theme's stand-in for sys.color.comp_emphasize_secondary ("20% brand
  // background", i.e. the system blue at alpha 0x33), which is what these
  // buttons used before and why they stayed blue under every theme.
  // Translucent also because a material's materialColor must not be
  // opaque (it would hide the material entirely).
  private accentTint(): ResourceColor {
    return this.colorWithAlpha(themeFor(this.accentTheme).color, ACCENT_TINT_ALPHA);
  }

  // The long-press menu's own material - THICK is the documented default
  // for menus (vs. THIN for buttons/cards), for a more opaque backdrop
  // behind menu text.
  private menuMaterial(): uiMaterial.ImmersiveMaterial {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      interactive: true,
      lightEffect: { color: this.accent() },
    });
  }

  // ---------------------------------------------------------------------
  // Design tokens.
  //
  // Every color here is either a sys.color.* token (which the system
  // re-resolves per light/dark theme automatically) or a saturated chip
  // fill that carries its own white glyph. That split is deliberate: the
  // old scheme tinted the whole CARD per type (#EAF2FF/#F3E8FF/#FFF4E5)
  // and colored the preview TEXT to match, so in dark mode the text
  // followed the theme to near-white while the card stayed a fixed pale
  // tint - white on cream, i.e. invisible. Surfaces and text now come
  // exclusively from tokens; type identity moved onto a small solid icon
  // chip, which stays legible against any background in either theme
  // because it supplies both its own fill and its own contrast.
  // ---------------------------------------------------------------------

  // Surface for every card. An opaque app colour rather than
  // sys.color.comp_background_list_card: that token is translucent in dark
  // mode (about 10% white - measured on-device as RGB 25 over black, but
  // warm-tinted once the bottom glow was behind it), so the glow showed
  // through the cards. card_surface is the same colour it resolves to over
  // the black page (#191919), and white in light mode.
  private cardSurface(): ResourceColor {
    return $r('app.color.card_surface');
  }

  // A card's backgroundColor: card_surface with the "Card transparency"
  // setting applied as the colour's own alpha, so only the surface fades -
  // an .opacity() on the card would fade its text and icons too.
  //
  // Deliberately not a .background(builder) layer: those never re-render
  // (on-device, the fill ignored the slider whether the value was read in
  // the builder, passed in as an argument, or held by a child component
  // with its own @StorageProp - a background layer isn't part of the page's
  // UI tree, so its updates are never flushed). A plain attribute is.
  private cardFill(): ResourceColor {
    if (this.cardTransparency <= 0) {
      return this.cardSurface();
    }
    return this.colorWithAlpha($r('app.color.card_surface'), 1 - this.cardTransparency / 100);
  }

  // A colour resource's ARGB for the current light/dark mode. Cached per
  // mode; reading colorMode here is also what re-runs the caller's
  // attribute when the mode flips.
  private resolveColor(res: Resource): number {
    const key: string = `${this.colorMode}:${res.id}`;
    let argb: number | undefined = this.resolvedColors.get(key);
    if (argb === undefined) {
      try {
        argb = getContext(this).resourceManager.getColorSync(res.id);
      } catch (e) {
        // This runs mid-render, where a throw would take the page down -
        // a mid grey is a visible but harmless stand-in. Not cached, so
        // the next render tries again.
        return 0xFF808080;
      }
      this.resolvedColors.set(key, argb);
    }
    return argb;
  }

  // '#AARRGGBB' for a colour resource with its alpha scaled by `alpha`
  // (0-1). A string rather than a number: ArkUI reads a number whose top
  // byte is 0 as opaque RGB, so a fully transparent colour would come out
  // solid.
  private colorWithAlpha(res: Resource, alpha: number): string {
    const argb: number = this.resolveColor(res);
    const a: number = Math.round(((argb >>> 24) & 0xFF) * Math.min(1, Math.max(0, alpha)));
    const rgb: number = argb & 0xFFFFFF;
    return `#${a.toString(16).padStart(2, '0')}${rgb.toString(16).padStart(6, '0')}`;
  }

  // Icon for a content type. 'link' and 'key' are display-only refinements
  // of a 'text' entry (see chipKindFor) - the sync protocol itself only
  // knows text/image/file.
  private typeIcon(kind: string): Resource {
    if (kind === 'image') return $r('app.media.ic_chip_image');
    if (kind === 'file') return $r('app.media.ic_chip_file');
    if (kind === 'link') return $r('app.media.ic_chip_link');
    if (kind === 'key') return $r('app.media.ic_chip_key');
    return $r('app.media.ic_chip_text');
  }

  // Narrows a stored item down to the chip it should show. A URL and a raw
  // key blob are both stored as 'text' but are worth telling apart at a
  // glance - they were previously indistinguishable.
  // List rows get the short preview; grid cells are tall enough to show
  // the real body, which is what the 80-char preview was hiding behind an
  // ellipsis. Capped so one long note cannot blow past itemConstraintSize.
  private cardBodyText(item: SyncedItem): string {
    if (this.syncedViewMode === 'list' || item.type !== 'text') return item.preview;
    const full: string = item.content;
    return full.length > 280 ? `${full.slice(0, 280)}...` : full;
  }

  private chipKindFor(item: SyncedItem): string {
    if (item.type === 'image') return 'image';
    if (item.type === 'file') return 'file';
    if (this.looksLikeOpaqueData(item.preview)) return 'key';
    const t: string = item.preview.trim();
    if (t.startsWith('http://') || t.startsWith('https://')) return 'link';
    return 'text';
  }

  // True when a preview is machine noise rather than something a human
  // copied on purpose - a key, hash, token or base64 blob. Long, unbroken,
  // and drawn only from a hex/base64-ish alphabet. These dominated the
  // list visually while carrying almost no scannable information, so the
  // card renders them as a labeled, monospaced, single-line fragment
  // instead of two lines of raw characters.
  private looksLikeOpaqueData(text: string): boolean {
    if (text.length < 40) return false;
    if (text.includes(' ')) return false;
    return /^[A-Za-z0-9+/=_-]+\.{0,3}$/.test(text);
  }

  // Real official long-press menu (bindContextMenu, confirmed to support
  // systemMaterial via ContextMenuOptions) instead of a hand-rolled
  // gesture+conditional-row hack - gets the native menu animation/backdrop
  // for free. "Copy" only for text; image/file get Share (real system
  // share sheet) and Save (gallery for images via a SaveButton-backed
  // dialog since SaveButton must be the tapped element itself; a document
  // picker for files, which needs no security component).
  @Builder
  itemActionMenu(item: SyncedItem) {
    Menu() {
      if (item.type === 'text') {
        // Colour is baked into these assets, like every other icon here -
        // see settingsRow for why (.fillColor cannot reach stroke-drawn
        // art). MenuItem is the strictest case of it: MenuItemOptions has
        // no colour field at all, so even a fill-based icon could not be
        // tinted from code. The light/dark resource pair is what makes it
        // adapt.
        MenuItem({ content: 'Copy', startIcon: $r('app.media.ic_menu_copy') }).onClick(() => { tapHaptic(); this.copyItemContent(item); })
      } else {
        MenuItem({ content: 'Share', startIcon: $r('app.media.ic_menu_share') }).onClick(() => { tapHaptic(); void this.shareItem(item); })
        if (item.type === 'image') {
          MenuItem({ content: 'Save to gallery', startIcon: $r('app.media.ic_menu_save_gallery') }).onClick(() => { tapHaptic(); this.showSaveImageDialog(item); })
        } else {
          // Same shape as the preview title bar's Open button
          // (sys.symbol.arrow_right_up_and_square), drawn in this menu's
          // stroke style.
          MenuItem({ content: 'Open', startIcon: $r('app.media.ic_menu_open') }).onClick(() => { tapHaptic(); void this.openFileWithSystem(item); })
          MenuItem({ content: 'Save file', startIcon: $r('app.media.ic_menu_save_file') }).onClick(() => { tapHaptic(); void this.saveFileToDocuments(item); })
        }
      }
    }
  }

  // Small square chip carrying a type's identity - a real thumbnail when
  // the item has an image, otherwise a solid colored tile with a glyph.
  // Shared by the list card and (at a larger size) nothing else, so the
  // size is a parameter rather than a second near-duplicate builder.
  @Builder
  typeChip(item: SyncedItem, size: number) {
    if (item.type === 'image') {
      Image(`data:image/png;base64,${item.content}`)
        .width(size)
        .height(size)
        .borderRadius(size / 3.2)
        .objectFit(ImageFit.Cover)
    } else if (this.imagePreviewUri(item) !== null) {
      Image(this.imagePreviewUri(item) as string)
        .width(size)
        .height(size)
        .borderRadius(size / 3.2)
        .objectFit(ImageFit.Cover)
    } else {
      Stack() {
        // White is baked into the chip SVGs rather than applied with
        // .fillColor(), which does not reach stroke-drawn art (see the
        // settingsRow note). The chip fill is always a saturated theme
        // colour, so one fixed white asset is correct.
        Image(this.typeIcon(this.chipKindFor(item)))
          .width(size * 0.52)
          .height(size * 0.52)
      }
      .width(size)
      .height(size)
      // The chosen theme colour for every type (the glyph carries the
      // type), so the cards follow the theme picker like everything else.
      .backgroundColor(this.accent())
      .borderRadius(size / 3.2)
    }
  }

  @Builder
  syncedItemCard(item: SyncedItem) {
    Row({ space: 12 }) {
      this.typeChip(item, 44)

      Column({ space: 3 }) {
        if (this.looksLikeOpaqueData(item.preview)) {
          // Machine noise: label what it is, then show a short fragment
          // rather than two lines of characters nobody can read. The full
          // value is still one tap away in the detail view.
          Text(item.type === 'file' ? 'File' : 'Encoded data')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.preview.slice(0, 24))
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
        } else {
          Text(this.cardBodyText(item))
            .fontSize(14)
            // font_primary, not the type accent - a themed token that
            // inverts with the background instead of a fixed accent that
            // could land the same color as whatever is behind it.
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            // Grid cells are narrow but tall, so 2 lines truncated almost
            // every note to an ellipsis. Show the body instead, capped so
            // one long note can't grow a cell past itemConstraintSize.
            .maxLines(this.syncedViewMode === 'list' ? 2 : 8)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // BREAK_WORD (the default) for prose - BREAK_ALL here was
            // splitting ordinary words mid-character ("bro/wn fox",
            // "develo/per.huawei"). The unbreakable-blob case that
            // originally motivated BREAK_ALL no longer reaches this
            // branch: looksLikeOpaqueData catches it above and renders a
            // short labeled fragment instead.
            .wordBreak(WordBreak.BREAK_WORD)
        }
        // This builder is ALSO the grid fallback for every non-image item
        // (see syncedGridCard), where a half-width cell can't fit
        // "time · source" and truncated it to a meaningless "20:53 · ...".
        // Drop the source in grid; the list has room for it.
        Text(this.syncedViewMode === 'list' ? `${item.time} · ${item.source}` : item.time)
          .fontSize(11)
          .fontColor($r('sys.color.font_secondary'))
          // One line, always - a byline that wraps competes with the
          // content preview above it for the eye.
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    .backgroundColor(this.cardFill())
    .alignItems(VerticalAlign.Center)
    // Per the official Shape Clipping reference: a child that still ends
    // up measuring wider than its parent (e.g. any other future
    // unbreakable content) is NOT clipped to the parent's bounds by
    // default - it paints straight through. Explicit clip(true) is the
    // defense-in-depth backstop so a card can never bleed into its
    // WaterFlow neighbor regardless of content, matching Huawei's own
    // example of pairing clip(true) with borderRadius.
    .clip(true)
    // Shared id with itemDetailView below - this is what makes the card
    // visually morph into the full-screen view instead of just cutting
    // between them ("一镜到底").
    .geometryTransition(item.id, { follow: true })
    // The "consistent animation for all clicks" - a single universal
    // attribute rather than a hand-built press-state gesture, so every
    // tappable surface (including file cards, which don't navigate
    // anywhere) gets identical feedback.
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => { tapHaptic(); this.activateItem(item); })
    // Lets a card be dragged straight out into another app (e.g. dropping
    // a synced image into a chat) - draggable() + onDragStart() are the
    // universal attribute pair every draggable component uses (confirmed
    // against CommonMethod in common.d.ts); the actual payload is built by
    // dragDataFor() and attached via event.setData(), not the return value
    // - the return value only controls the drag preview/extra info, not
    // what gets dropped.
    .draggable(true)
    .onDragStart((event: DragEvent) => {
      const data = this.dragDataFor(item);
      if (data !== null) {
        event.setData(data);
      }
      return { extraInfo: item.preview };
    })
    // systemMaterial belongs in bindContextMenu's OWN options (third
    // argument), not as an attribute on the Menu() inside the builder -
    // that's the actual mechanism ContextMenuOptions exposes, confirmed
    // against common.d.ts; setting it on Menu() itself (the earlier
    // attempt) silently did nothing, which is why the menu had no material.
    // hapticFeedbackMode gives a tactile tick the instant the menu opens -
    // the framework's own built-in option (confirmed in common.d.ts), not
    // a manual vibrator call. Needs ohos.permission.VIBRATE declared in
    // module.json5 (a normal/system_grant permission, unlike
    // READ_PASTEBOARD - safe to just declare, no ACL/AppGallery process).
    .bindContextMenu(this.itemActionMenu(item), ResponseType.LongPress, {
      systemMaterial: this.menuMaterial(),
      hapticFeedbackMode: HapticFeedbackMode.ENABLED,
      // See syncedGridCard's identical options for why preview is set.
      preview: MenuPreviewMode.IMAGE,
      previewBorderRadius: 18,
      targetSpace: LengthMetrics.vp(12),
    })
  }

  // Grid-mode counterpart to syncedItemCard - an item with a real image
  // (native 'image' type, or a 'file' entry imagePreviewUri recognizes)
  // gets the photo featured full-width on top with the caption below,
  // instead of the same fixed 44x44 thumbnail every card uses in list
  // mode. Image now gets an explicit .height(220) alongside
  // constraintSize's maxHeight, not maxHeight alone - per the official
  // WaterFlow reference, "When the main axis size of a FlowItem changes
  // after it is displayed, WaterFlow clears the affected layout
  // information and recalculates..."; a base64 Image decodes
  // asynchronously, so its intrinsic size (and therefore its FlowItem's
  // measured size) still changes once, after the initial layout pass,
  // even with a maxHeight cap on top of it - that's what was letting a
  // card's box visually bridge into its neighboring WaterFlow column
  // (confirmed via on-device pixel measurement: the column gap band
  // between two cards vanished exactly where a larger image card sat). A
  // fixed .height() removes that async-driven change at the source
  // instead of just capping its result. ImageFit.Cover crops to fill that
  // fixed box instead of squeezing/distorting the image. Trade-off: this
  // gives up the "landscape images end up shorter" masonry height
  // variety the box used to have - every image card is now a uniform
  // 220, which cost less than another round of overlapping cards. Non-image
  // items don't get this treatment - the compact row card already fits a
  // 2-column cell fine without manufacturing a fake masonry effect for
  // plain text.
  // Text-ish card for GRID mode. Deliberately not syncedItemCard: that one
  // leads with a 44pt chip, which in a half-width cell ate roughly a third
  // of the line length and forced everything to wrap early. Here the body
  // gets the full width and the type marker shrinks to a small glyph in
  // the bottom-left, beside the timestamp.
  @Builder
  syncedGridTextCard(item: SyncedItem) {
    Column({ space: 8 }) {
      if (this.looksLikeOpaqueData(item.preview)) {
        Text(item.type === 'file' ? 'File' : 'Encoded data')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.preview.slice(0, 24))
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .wordBreak(WordBreak.BREAK_ALL)
          .width('100%')
      } else {
        Text(this.cardBodyText(item))
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .wordBreak(WordBreak.BREAK_WORD)
          .width('100%')
      }

      Row({ space: 6 }) {
        // The chip tile, shrunk - not a bare Image. The chip SVGs have white
        // baked in (they normally sit on a saturated tile), and fillColor
        // cannot retint stroke-drawn art, so drawing one directly onto a
        // white card left it invisible. Keeping the tile keeps the type
        // colour legible and matches the list card's language.
        this.typeChip(item, 18)
        Text(item.time)
          .fontSize(10)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(18)
    .backgroundColor(this.cardFill())
    .alignItems(HorizontalAlign.Start)
    .clip(true)
    .geometryTransition(item.id, { follow: true })
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => { tapHaptic(); this.activateItem(item); })
    .draggable(true)
    .onDragStart((event: DragEvent) => {
      const data = this.dragDataFor(item);
      if (data !== null) {
        event.setData(data);
      }
      return { extraInfo: item.preview };
    })
    .bindContextMenu(this.itemActionMenu(item), ResponseType.LongPress, {
      systemMaterial: this.menuMaterial(),
      hapticFeedbackMode: HapticFeedbackMode.ENABLED,
      preview: MenuPreviewMode.IMAGE,
      previewBorderRadius: 18,
      targetSpace: LengthMetrics.vp(12),
    })
  }

  @Builder
  syncedGridCard(item: SyncedItem) {
    if (item.type !== 'image' && this.imagePreviewUri(item) === null) {
      this.syncedGridTextCard(item)
    } else {
      Column({ space: 6 }) {
        Image(item.type === 'image' ? `data:image/png;base64,${item.content}` : this.imagePreviewUri(item) as string)
          .width('100%')
          .height(220)
          .constraintSize({ maxHeight: 220 })
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
        Text(this.looksLikeOpaqueData(item.preview) ? 'Image' : item.preview)
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // See syncedItemCard's identical comment - wordBreak is what
          // actually lets textOverflow truncate an unbroken blob instead
          // of it painting past the card at full width.
          .wordBreak(WordBreak.BREAK_ALL)
          .padding({ left: 4, right: 4 })
        // Time only here - the full "time · source" byline does not fit a
        // half-width grid cell and truncated to a meaningless "· ...".
        // The source is still on the list card and in the detail view.
        Text(item.time)
          .fontSize(10)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 4, right: 4, bottom: 4 })
      }
      .width('100%')
      .padding(8)
      .borderRadius(18)
      .backgroundColor(this.cardFill())
      .alignItems(HorizontalAlign.Start)
      // See syncedItemCard's identical comment - clip(true) backstop so
      // this card can never bleed into its WaterFlow neighbor.
      .clip(true)
      // Same shared-id morph, click/drag/long-press wiring as
      // syncedItemCard - only one of the two card variants is ever
      // mounted for a given item at a time (list XOR grid mode), so
      // reusing item.id here doesn't conflict with the other variant.
      .geometryTransition(item.id, { follow: true })
      .clickEffect({ level: ClickEffectLevel.MIDDLE })
      .onClick(() => { tapHaptic(); this.activateItem(item); })
      .draggable(true)
      .onDragStart((event: DragEvent) => {
        const data = this.dragDataFor(item);
        if (data !== null) {
          event.setData(data);
        }
        return { extraInfo: item.preview };
      })
      .bindContextMenu(this.itemActionMenu(item), ResponseType.LongPress, {
        systemMaterial: this.menuMaterial(),
        hapticFeedbackMode: HapticFeedbackMode.ENABLED,
        // Without preview, THIS overload of bindContextMenu documents the
        // menu as appearing "at the click position" - i.e. anchored to the
        // finger, which is on top of the card, which is why it covered it.
        // MenuPreviewMode.IMAGE lifts a snapshot of the card and lays the
        // preview and the menu out as ONE region, so the menu is placed
        // relative to the card instead of the touch point. previewBorderRadius
        // matches the card's own 18 so the lifted snapshot doesn't show
        // different corners from the card beneath it.
        preview: MenuPreviewMode.IMAGE,
        previewBorderRadius: 18,
        targetSpace: LengthMetrics.vp(12),
      })
    }
  }

  // Full-screen "one shot" detail view for a tapped text/image card - see
  // openItemDetail/closeItemDetail and the geometryTransition id shared
  // with syncedItemCard above. Takes the item directly as a parameter
  // rather than looking it up via a getter inside the @Builder - a getter
  // call from inside a @Builder is what was actually producing the blank
  // black screen (the caller already has the item in hand from the same
  // find() it used to decide whether to show this view at all, so this
  // also avoids a redundant second lookup).
  // Two-finger pinch zoom, clamped to [1x, 4x] - imageZoomScale/imageZoomBase
  // are reset in openItemDetail so a previous item's zoom never carries over.
  // GestureEvent.scale is relative to THIS gesture's start, not cumulative,
  // which is why onActionStart snapshots the current scale into
  // imageZoomBase rather than multiplying onto imageZoomScale directly.
  @Builder
  zoomableImage(src: string) {
    Image(src)
      .width('100%')
      .constraintSize({ maxHeight: '65%' })
      .objectFit(ImageFit.Contain)
      .borderRadius(20)
      .scale({ x: this.imageZoomScale, y: this.imageZoomScale })
      .translate({ x: this.imageOffsetX, y: this.imageOffsetY })
      // Parallel, not Sequence - pinch and pan need to both be live at once
      // (pinching with two fingers while drifting them sideways is one
      // continuous gesture to the user, not two separate ones).
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PinchGesture()
            .onActionStart(() => { this.imageZoomBase = this.imageZoomScale; })
            .onActionUpdate((event: GestureEvent) => {
              this.imageZoomScale = Math.max(1, Math.min(4, this.imageZoomBase * event.scale));
            }),
          // offsetX/offsetY are relative to THIS gesture's start, same
          // reasoning as the pinch scale handling above - onActionStart
          // snapshots the running offset so each new drag adds on top of
          // where the last one left off instead of resetting to it.
          PanGesture()
            .onActionStart(() => {
              this.imageOffsetBaseX = this.imageOffsetX;
              this.imageOffsetBaseY = this.imageOffsetY;
            })
            .onActionUpdate((event: GestureEvent) => {
              // Only meaningful once zoomed in - at 1x the image already
              // fills the frame, and panning it here would just be a
              // confusing swipe that goes nowhere (this is also what makes
              // it safe to have Tabs.scrollable(false) above: panning an
              // unzoomed image is a no-op, not a competing gesture).
              if (this.imageZoomScale <= 1) return;
              // offsetX/offsetY come back in real screen vp, but translate()
              // is applied to THIS node's own (pre-scale) coordinate space -
              // once .scale() is also active, the same requested translate
              // paints as visibly less screen movement the higher the scale
              // goes (exactly the "faster at low zoom, slower at high zoom"
              // reported). Multiplying the raw offset by the current scale
              // is what cancels that out and keeps the point under the
              // finger actually under the finger at any zoom level.
              this.imageOffsetX = this.imageOffsetBaseX + event.offsetX * this.imageZoomScale;
              this.imageOffsetY = this.imageOffsetBaseY + event.offsetY * this.imageZoomScale;
            })
            .onActionEnd(() => {
              if (this.imageZoomScale <= 1) {
                this.imageOffsetX = 0;
                this.imageOffsetY = 0;
              }
            })
        )
      )
  }

  // The back button and Copy/Share live in the HDS title bar (see
  // syncedPageMap's 'itemDetail' branch and detailTitleBar), which floats
  // over this content - the top padding below is what keeps the content's
  // resting position clear of it. NOTE: systemMaterial is declared on
  // CommonMethod (common.d.ts:22642), so it applies to ANY component, and
  // is inert only when the app-level MaterialState is DISABLE or
  // uiMaterial.isImmersiveMaterialSupported() is false.
  @Builder
  itemDetailView(item: SyncedItem) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (item.type === 'image' || this.imagePreviewUri(item) !== null) {
        Column({ space: 16 }) {
          this.zoomableImage(item.type === 'image' ? `data:image/png;base64,${item.content}` : this.imagePreviewUri(item) as string)
          Text(`${item.time} · ${item.source}`).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height('100%')
        // Room for the floating title bar above and the tab pill below.
        // Padding is fine here: an image preview doesn't scroll.
        .padding({ left: 20, right: 20, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
        .justifyContent(FlexAlign.Center)
      } else {
        // The Scroll fills the whole screen and the clearance goes on the
        // content INSIDE it - same fix as the Synced list. With the padding
        // on a container around the Scroll (as before), the Scroll's
        // viewport stopped at the bars, so text was cut off at their edge
        // instead of scrolling underneath the title bar and tab pill.
        Scroll(this.detailScroller) {
          Column({ space: 16 }) {
            Text(item.content).fontSize(16).fontColor($r('sys.color.font_primary')).copyOption(CopyOptions.LocalDevice)
            Text(`${item.time} · ${item.source}`).fontSize(12).fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 20, right: 20, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
        // Scroll defaults to EdgeEffect.None - every other scrollable here
        // bounces, so the preview felt dead without this.
        .edgeEffect(EdgeEffect.Spring)      }
    }
    .width('100%')
    .height('100%')
    // Reverted the immersive-material backdrop experiment: systemMaterial
    // is meant to sit behind a simple leaf component (a button, a tab bar)
    // per every official example - wrapping real foreground content
    // (Image/Text/Scroll) in it directly isn't the documented pattern and
    // was actually washing the content out. A flat dark surface is the
    // correct backdrop for a full-bleed content viewer - and per Huawei's
    // "如何实现沉浸式页面" FAQ, THIS is the component whose background
    // should actually extend behind the status bar (the black backdrop
    // bleeds all the way up, matching a real full-bleed image viewer).
    // Follows the theme instead of a hardcoded black. A fixed black
    // backdrop meant that in light mode the page animated white -> grey ->
    // black as it opened, and the frosted title bar's colorInvert had to
    // swing its label from dark to light mid-transition, which read as the
    // nav text "failing to invert". With a themed surface the detail view
    // starts the same colour family as the page behind it, so the material
    // and its labels stay put.
    // Plain - no bottom glow on the full-bleed preview.
    .backgroundColor($r('sys.color.background_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // Content component gets geometryTransition, per Huawei's Navigation
    // FAQ ("给内容组件设置geometryTransition属性，不要设置到NavDestination上") -
    // NOT the NavDestination wrapping it in syncedPageMap. id must match
    // syncedItemCard's exactly (item.id) for the morph to connect the two.
    .geometryTransition(item.id, { follow: true })
    .transition(TransitionEffect.OPACITY)
  }


  // Height of the HDS title bar in HdsNavDestinationTitleMode.MINI (fixed
  // at 56vp per the enum's own doc), BELOW the status bar. Content starts
  // this far down (plus topInsetVp) at rest and scrolls up underneath it.
  private readonly TITLE_BAR_HEIGHT: number = 56;
  // What a scrollable has to reserve at the bottom so its last item can
  // settle clear of the floating tab pill (content still scrolls THROUGH
  // this region - it's clearance for the resting position, not a wall).
  private readonly TAB_PILL_CLEARANCE: number = 84;
  // The Synced tab additionally has the paste dock sitting above the pill,
  // so its scrollables need to reserve that too or the last card comes to
  // rest underneath the paste button.
  private readonly SYNCED_BOTTOM_CLEARANCE: number = 152;

  // The soft theme-colour glow along the bottom of every page (except the
  // preview): the accent at the screen edge fading out well above the
  // Synced tab's Paste button, the same height on every page so it doesn't
  // jump between tabs. Set as the page container's linearGradient, which
  // draws over its backgroundColor and under its content; the containers
  // all expandSafeArea to the full screen, so the stops are fractions of
  // the window height. An empty colour list is no gradient at all.
  //
  // An attribute rather than a .background(builder) layer for the same
  // reason as cardFill - the layer version kept its old colour after a
  // theme switch and ignored the on/off switch.
  private bottomGlow(): LinearGradientOptions {
    if (!this.bottomGlowOn) {
      return { colors: [] };
    }
    const glowHeight: number = this.bottomInsetVp + GLOW_HEIGHT_ABOVE_INSET;
    const fraction: number = this.windowHeightVp > 0 ? Math.min(1, glowHeight / this.windowHeightVp) : 0.55;
    const accent: Resource = themeFor(this.accentTheme).color;
    // Fades to the accent at zero alpha rather than plain transparent
    // (black at zero alpha), which would grey the mid-tones in light mode.
    const colors: Array<[ResourceColor, number]> = [[this.colorWithAlpha(accent, 0), 0]];
    // Smoothstep rather than a straight fade: it holds near full strength
    // at the bottom and eases into nothing at the top, so there's no
    // visible edge where the glow ends. t is 1 at the glow's top, 0 at the
    // screen's bottom edge.
    for (let i = GLOW_STOPS; i >= 0; i--) {
      const t: number = i / GLOW_STOPS;
      const eased: number = t * t * (3 - 2 * t);
      colors.push([this.colorWithAlpha(accent, GLOW_OPACITY * (1 - eased)), 1 - fraction * t]);
    }
    return { direction: GradientDirection.Bottom, colors: colors };
  }

  // Every page's title bar is the HDS (UIDesignKit) system title bar with
  // ScrollEffectType.GRADIENT_BLUR, replacing the old hand-built frosted
  // "glass" Row. Per the HdsNavigation reference, GRADIENT_BLUR "gradually
  // intensifies or lessens across the screen, featuring soft, seamless
  // edges" and is the type recommended for non-immersive list pages - the
  // blur is strongest behind the status bar and fades out below the title
  // instead of stopping at a hard frosted edge. enableScrollEffect makes it
  // fade in as content actually scrolls underneath (driven by the page's
  // bindToScrollable scroller) rather than sitting over an empty page.
  //
  // systemMaterialEffect ADAPTIVE lets the system apply immersive material
  // to the bar's own back/menu buttons where the device supports it.
  //
  // These return plain option objects rather than being @Builders: the
  // title bar is data handed to HdsNavDestination.titleBar(), and a method
  // (not a local variable) is how a builder body is allowed to compute it.
  private hdsTitleBar(title: string, isRoot: boolean, menu: HdsNavigationMenuItemOptions[]): HdsNavigationTitleBarOptions {
    return {
      // Every destination ignores the top safe area so content can scroll up
      // behind the status bar - without this the title bar followed it and
      // drew its title and menu on top of the clock and battery (seen
      // on-device). With it, the bar's content sits below the status bar
      // while its blur still reaches the top of the screen.
      avoidLayoutSafeArea: true,
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      },
      content: {
        title: {
          mainTitle: title,
          mainTitleSize: isRoot ? TitleSize.TITLE_ML : TitleSize.TITLE_S,
        },
        menu: { value: menu },
      },
    };
  }

  // Synced tab: one menu icon that flips between list and grid. It shows
  // the layout you'd switch TO, the usual convention for a two-state view
  // toggle. viewMode is passed in (read at the call site) rather than read
  // here so the title bar re-evaluates when it changes.
  private syncedTitleBar(viewMode: string): HdsNavigationTitleBarOptions {
    const toGrid: boolean = viewMode === 'list';
    return this.hdsTitleBar('Synced', true, [{
      content: {
        label: toGrid ? 'Grid view' : 'List view',
        icon: toGrid ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet'),
        action: () => {
          tapHaptic();
          this.syncedViewMode = toGrid ? 'waterfall' : 'list';
        },
      },
    }]);
  }

  // Item preview: Copy for text, Share for images/files, and Open (left of
  // Share) for files - the same split itemActionMenu's long-press menu
  // uses. Open is files-only because openFileWithSystem hands the system a
  // stored file; an 'image' item is only base64 in memory. copyItemContent
  // is deliberately text-only (copying an image's raw base64, or a file's
  // JSON descriptor, as literal text was a real, already-fixed bug). No
  // Delete here by request: it's a much easier accidental tap from a
  // full-bleed preview than from the long-press menu it already lives in.
  private detailTitleBar(itemId: string): HdsNavigationTitleBarOptions {
    const item: SyncedItem | undefined = this.syncedItems.find(i => i.id === itemId);
    if (item === undefined) return this.hdsTitleBar('', false, []);
    if (item.type === 'text') {
      return this.hdsTitleBar('', false, [{
        content: {
          label: 'Copy',
          icon: $r('sys.symbol.rectangle_on_rectangle'),
          action: () => { tapHaptic(); this.copyItemContent(item); },
        },
      }]);
    }
    const share: HdsNavigationMenuItemOptions = {
      content: {
        label: 'Share',
        icon: $r('sys.symbol.share'),
        action: () => { tapHaptic(); void this.shareItem(item); },
      },
    };
    if (item.type === 'file') {
      return this.hdsTitleBar('', false, [{
        content: {
          label: 'Open',
          icon: $r('sys.symbol.arrow_right_up_and_square'),
          action: () => { tapHaptic(); void this.openFileWithSystem(item); },
        },
      }, share]);
    }
    return this.hdsTitleBar('', false, [share]);
  }

  // Wraps the list and the item-detail view as two NavDestinations on their
  // own stack, rather than the plain if/else-driven @State toggle this used
  // to be. Two reasons this had to change, both confirmed against Huawei's
  // own docs while investigating why the detail view's back button never
  // showed immersive material:
  // 1. Consistency: every screen's chrome comes from the destination's own
  //    title bar (now the HDS one - see hdsTitleBar), instead of each
  //    screen positioning its own floating button with its own offsets.
  // 2. geometryTransition (the "一镜到底" shared-element morph the list card
  //    and detail view already relied on) is ONLY supported between two
  //    NavDestinations - a transition between Navigation's NavBar and a
  //    NavDestination is explicitly NOT supported by the system
  //    (arkts-navigation-faq). Since the back button has to live in a real
  //    NavDestination for immersive material to work, the list side of the
  //    animation has to be a NavDestination too, not plain NavBar content,
  //    or the shared-element morph would just stop working.
  // HdsNavigation rather than plain Navigation: per the HdsNavDestination
  // reference, an HdsNavDestination only has routing and its HDS title bar
  // behaviour when hosted by an HdsNavigation - on its own it degrades to a
  // plain container.
  @Builder
  syncedTab() {
    HdsNavigation(this.syncedNavStack) {
      // Intentionally empty - hideNavBar means this NavBar content is
      // never actually shown. 'syncedList' (pushed in aboutToAppear) is
      // the real home screen; see syncedPageMap below.
    }
    .hideNavBar(true)
    .navDestination(this.syncedPageMap)
    .width('100%')
    .height('100%')
    // Not shifted down by topInsetVp (an earlier fix here was reverted) -
    // per Huawei's own "如何实现沉浸式页面" FAQ, the correct pattern for a
    // fullscreen window (EntryAbility.ets's setWindowLayoutFullScreen) is
    // NOT to shift a whole container away from the status bar - it's to
    // let it draw there, and apply expandSafeArea selectively to whichever
    // specific component's background/content should bleed through, while
    // readable elements (titles, buttons) use their own topInsetVp-based
    // padding/margin to stay clear. Shifting the whole Navigation fixed
    // clipping but also blocked every child from ever reaching the status
    // bar at all, including the scrollable content that's supposed to
    // extend behind it - see syncedListContent for the per-component split
    // this replaced it with.
  }


  @Builder
  syncedPageMap(name: string) {
    if (name === 'syncedList') {
      HdsNavDestination() {
        this.syncedListContent()
      }
      // syncedViewMode is read here, in the attribute expression itself, so
      // the title bar (and its list/grid icon) re-evaluates when it flips.
      .titleBar(this.syncedTitleBar(this.syncedViewMode))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // Both scrollers: only one of List/WaterFlow exists at a time, and
      // whichever is showing drives the blur.
      .bindToScrollable([this.syncedListScroller, this.syncedFlowScroller])
      .hideBackButton(true)
      // Checked the SDK's own common.d.ts/nav_destination.d.ts directly
      // (the doc site wasn't loading) - expandSafeArea (used below, on
      // syncedListContent's Stack) only extends where content is allowed
      // to DRAW; it never changes what a component is LAID OUT/measured
      // against. ignoreLayoutSafeArea is the one that actually grows the
      // LAYOUT box - the declaration's own comment names List/Grid/
      // WaterFlow/Swiper/Tabs by name as the scrollable components this
      // matters for, which is exactly the symptom here (grid content
      // overlapping/spilling because its container's real layout size
      // was smaller than what was visible).
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'itemDetail') {
      HdsNavDestination() {
        if (this.syncedItems.find(i => i.id === this.selectedItemId)) {
          this.itemDetailView(this.syncedItems.find(i => i.id === this.selectedItemId) as SyncedItem)
        }
      }
      .titleBar(this.detailTitleBar(this.selectedItemId))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.detailScroller])
      // The HDS bar's own back button, rather than a custom one. Its tap
      // and the system back gesture both land in onBackPressed below
      // (deliberately no backIcon.action as well - the HDS reference
      // advises against setting both), so either one goes through the
      // animateTo-wrapped pop in closeItemDetail instead of a plain
      // default pop that would skip the geometryTransition morph.
      .hideBackButton(false)
      .onBackPressed(() => { this.closeItemDetail(); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    }
  }

  // Approximate height of the floating title-row + paste-button card
  // (measured by eye, not queried from the framework - a Stack overlay
  // has no built-in way to ask its sibling for its rendered size). Used
  // as top clearance for the list/grid below so the first item starts
  // visibly below the card on load; scrolling still passes items behind
  // it afterward since it's a Stack overlay, not normal Column flow. This
  // is on top of topInsetVp (added at each use site below) since the
  // header row now starts after the status bar, not at y=0.
  // Top clearance for the Synced scrollables: enough that the first card
  // rests below the floating title bar while still scrolling up behind it.
  private syncedTopClearance(): number {
    return this.topInsetVp + this.TITLE_BAR_HEIGHT + 8;
  }

  // The paste action, docked directly above the floating tab pill so it
  // reads as part of the bottom navigation cluster rather than as content.
  //
  // Always present, not conditional on pendingChange: HarmonyOS will not
  // let an app read the clipboard silently, so this button is the ONLY way
  // to push what's on this device - hiding it whenever the app hadn't
  // already noticed a change meant the one manual escape hatch vanished
  // exactly when someone would reach for it. pendingChange now only
  // controls emphasis.
  //
  // PasteButton is a system security component: its label and icon come
  // from a fixed system enum and are localized by the system (hence 粘贴
  // on a Chinese-locale device), so the surrounding capsule - not the
  // button - is what carries the immersive material.
  // Sits INSIDE the Synced content Stack as an ordinary bottom-aligned
  // child - deliberately NOT a full-screen overlay mounted beside Tabs.
  // As an overlay the security component's click was rejected outright:
  // onClick never fired at all (verified with logging), regardless of
  // hitTestBehavior or whether the frosted wrapper was present. Ordinary
  // content flow is the arrangement PasteButton accepts.
  //
  // Always present, not conditional on pendingChange: HarmonyOS will not
  // let an app read the clipboard silently, so this button is the ONLY way
  // to push what's on this device - hiding it whenever the app hadn't
  // already noticed a change removed the one manual escape hatch exactly
  // when someone would reach for it.
  @Builder
  pasteDock() {
    Row({ space: 10 }) {
      // The "Point out new copies" hint lives on the capsule, never on
      // PasteButton itself: a security component's look must not change at
      // runtime or its tap can come back TEMPORARY_AUTHORIZATION_FAILED.
      if (this.pendingChange) {
        // Its own solid pill: the dock Row's systemMaterial doesn't render
        // in page content (per Huawei's 开启沉浸光感 guide, generic
        // components only get material in title bars and the bottom tab
        // bar), so without a background this label sat bare over the cards.
        // Points at Paste, which is what sends it.
        Text('New item →')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_on_primary'))
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor(this.accent())
          .shadow(ShadowStyle.OUTER_DEFAULT_SM)
      }
      PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
        .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => { tapHaptic(); void this.onPasteButtonClick(result); })
    }
    .padding(14)
    .borderRadius(34)
    .alignItems(VerticalAlign.Center)
    .systemMaterial(new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      applyShadow: true,
      colorInvert: true,
      materialColor: $r('sys.color.comp_background_primary'),
    }))
    .margin({ bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE + 10 })
  }

  // Empty states - a headline plus one line of explanation, centered,
  // rather than a stray line of small gray text against a blank screen.
  @Builder
  emptyState(headline: string, detail: string, art: Resource) {
    Column({ space: 8 }) {
      Image(art)
        .width(120)
        .height(120)
        .margin({ bottom: 8 })
      Text(headline)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.Center)
      Text(detail)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
    }
    // Fills its container and centers, rather than sizing to its own text:
    // as a bare-height child of a TopStart-aligned Stack it was landing at
    // the very top of the screen, tucked up behind the floating title bar.
    .width('100%')
    .height('100%')
    .padding({ left: 40, right: 40, top: this.topInsetVp, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  // Stack, not Column: the title row + paste-button card float as an
  // overlay ON TOP of the list/grid (last child = top z-order in a Stack)
  // rather than being laid out above it in the document flow - that's
  // what lets scrolled content pass visibly behind them, the same way the
  // floating tab-bar pill already does via Tabs' barOverlap.
  @Builder
  syncedListContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.syncedItems.length === 0) {
        this.emptyState('Nothing synced yet', 'Copy something on this or another trusted device and it will appear here.', $r('app.media.ic_empty_synced'))
      } else if (this.syncedViewMode === 'list') {
        List({ space: 10, scroller: this.syncedListScroller }) {
          ForEach(this.syncedItems, (item: SyncedItem) => {
            ListItem() { this.syncedItemCard(item) }
          }, (item: SyncedItem) => item.id)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        // contentStartOffset/contentEndOffset, NOT top/bottom padding.
        // A List paints its own background across its full border box but
        // CLIPS its items to the padding box, so padding-based clearance
        // meant items were cut off at a hard edge exactly where the
        // floating bar began instead of sliding underneath it. (Verified
        // on-device: with the list temporarily tinted, the tint reached
        // y=0 behind both bars while the cards still stopped at the bar's
        // edge - so the box was already full-screen and padding was the
        // thing clipping.) These two attributes set the resting offset of
        // the content without clipping, which is exactly the
        // content-under-floating-chrome case they exist for.
        .contentStartOffset(this.syncedTopClearance())
        .contentEndOffset(this.bottomInsetVp + this.SYNCED_BOTTOM_CLEARANCE)
        // alwaysEnabled: a List only bounces by default once it's taller
        // than the screen, so a short list felt dead.
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })        // Per Huawei's "如何实现沉浸式页面" FAQ: this is the component whose
        // own background/content should actually draw behind the status
        // bar (unlike the title row below, which stays clear via
        // topInsetVp padding instead) - lets list cards scroll up and
        // remain visible through/behind the status bar area as you scroll,
        // matching how other apps handle this rather than leaving a gap.
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else {
        // Same WaterFlow pattern devicesTab uses below - a 2-column grid
        // rather than a single stacked list, per request.
        WaterFlow({ scroller: this.syncedFlowScroller }) {
          ForEach(this.syncedItems, (item: SyncedItem) => {
            // .width('100%') directly on FlowItem, not just on
            // syncedGridCard's own inner Column two levels down - per the
            // official FlowItem reference, FlowItem itself has no
            // component-specific attributes, so its cross-axis box comes
            // entirely from whatever universal attributes are set on it;
            // leaving it unset was what let a FlowItem's actual box drift
            // wider than its column after a reflow (see itemConstraintSize
            // below).
            FlowItem() { this.syncedGridCard(item) }.width('100%')
          }, (item: SyncedItem) => item.id)
        }
        .width('100%')
        .height('100%')
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        // Per the official WaterFlow reference: "When the main axis size
        // of a FlowItem changes after it is displayed, WaterFlow clears
        // the affected layout information and recalculates..." - an
        // async-decoding base64 Image (see syncedGridCard) is exactly
        // this case, and the resulting reflow was what let a card's box
        // visually bridge into its neighboring column (confirmed via
        // pixel measurement on-device: the columnsGap band between two
        // cards fully vanished exactly where a larger image card sat).
        // itemConstraintSize applies a hard constraintSize to every
        // FlowItem directly (not a nested grandchild), so no single
        // item's post-reflow box can ever exceed this regardless of what
        // its content does.
        .itemConstraintSize({ maxHeight: 320 })
        .padding({ left: 16, right: 16 })
        // Same contentStartOffset/contentEndOffset treatment as the List
        // branch. An earlier revision claimed these were "List-only" after
        // grepping water_flow.d.ts and finding nothing - that was wrong:
        // WaterFlowAttribute extends ScrollableCommonMethod (water_flow.d.ts:489)
        // and it is ScrollableCommonMethod that declares them
        // (common.d.ts:25367/25382), so WaterFlow inherits both.
        //
        // The workaround that claim produced - vertical padding plus
        // clip(false) - caused cards to flash out of existence at the
        // chrome. A scrollable's viewport IS its content rect (border box
        // minus padding), and items are only PAINTED while they intersect
        // that rect; clip(false) merely removes the clipping rectangle, it
        // does not widen the draw range, so items stopped being drawn
        // exactly at the inner edge of the frosted bar. Dropping the
        // vertical padding makes the content rect equal the border box
        // (the full screen), so items keep painting all the way under the
        // bars, and these two offsets supply the resting clearance instead.
        .contentStartOffset(this.syncedTopClearance())
        .contentEndOffset(this.bottomInsetVp + this.SYNCED_BOTTOM_CLEARANCE)
        // WaterFlow doesn't default to Spring the way List does - without
        // this the grid view felt visually inconsistent with the list
        // view's bounce feedback at the scroll ends. alwaysEnabled so a
        // grid shorter than the screen still bounces.
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })        // See the List branch's identical comment above.
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // The page title and List/Grid toggle live in the HDS title bar
      // (syncedTitleBar); only the paste action is pinned here, bottom
      // aligned above the tab pill. It must stay in this content Stack
      // rather than being an overlay beside Tabs - see pasteDock.
      this.pasteDock()
    }
    // LayoutPolicy.matchParent, not '100%' - per common.d.ts's own note on
    // ignoreLayoutSafeArea: "if its width or height is set to
    // LayoutPolicy.matchParent, both its size AND position will change;
    // otherwise, only its position will change." A percentage width/
    // height wouldn't actually grow when the parent's own safe-area
    // layout box grows - matchParent is what lets this Stack's true size
    // expand into the safe area rather than just being repositioned
    // within its old (too-small) size.
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    // On the Stack itself, not a nested grandchild - this is the
    // NavDestination's actual direct child, so it's the box that
    // determines how much room the List/WaterFlow and the floating header
    // both have to work with. Mirrors itemDetailView's identical call on
    // its own top-level Stack, the one other NavDestination on this stack
    // confirmed to reach the true screen edges - applying it one level
    // deeper (as it was, only on the List/WaterFlow) left this Stack
    // itself bounded above the true edges, so nothing inside it could
    // ever visually reach past that boundary no matter what padding or
    // z-order the children used.
    //
    // ignoreLayoutSafeArea added alongside expandSafeArea - per the SDK's
    // own doc comment, "ignoreLayoutSafeArea takes effect first, and
    // expandSafeArea takes effect on the basis of the former": the first
    // actually grows this Stack's LAYOUT box (what WaterFlow/List measure
    // their own size against), the second controls what's allowed to
    // DRAW past that box's original edges. Both were needed - expandSafeArea
    // alone left the true layout size unchanged, which is what was letting
    // WaterFlow's masonry math work against a too-small box while content
    // visually painted past it, reading as cards overlapping/spilling off
    // screen.
    // Explicit page background so cards read as cards. comp_background_list_card
    // (what every card uses) is near-white in light mode, and with the page
    // itself defaulting to white too, the cards were white-on-white with no
    // edge at all. background_secondary is the grouped-list backdrop the
    // system pairs with that card token, and both re-resolve per theme, so
    // the pairing holds in dark mode instead of inverting into another
    // same-on-same collision. It is also what the frosted bars sample.
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  deviceCard(row: DeviceRow) {
    Row({ space: 12 }) {
      // Device glyph with the status dot badged onto it, rather than a
      // bare dot - tells you WHAT the device is, not just that it exists.
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image($r('app.media.ic_device_desktop'))
          .width(26)
          .height(26)
        Row()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(row.connected ? $r('sys.color.confirm') : $r('sys.color.icon_secondary'))
      }
      .width(28)
      .height(28)

      Column({ space: 2 }) {
        // The name it gives itself, else its short id.
        Text(deviceRowTitle(row))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Every address, LAN first - a peer can legitimately be reachable at
        // both a LAN IP and a Tailscale IP, and which one it is paired on
        // matters when diagnosing a connection.
        Text(row.addresses.length > 0 ? row.addresses.join(' · ') : 'Unknown address')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.connected ? 'Connected' : row.trusted ? 'Trusted · not connected' : 'Discovered nearby')
          .fontSize(12)
          .fontColor(row.connected ? $r('sys.color.confirm') : $r('sys.color.font_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!row.trusted && row.discovered) {
        // Deliberately a plain solid button, no systemMaterial: material
        // WOULD render here (it is a CommonMethod attribute, available on
        // every component - see itemDetailView's note correcting the
        // earlier claim otherwise), but a frosted primary action competes
        // with the frosted nav chrome for attention. Chrome is frosted,
        // actions are solid. Note also that where material does take
        // effect on a mid/high-tier device it RESETS backgroundColor to
        // transparent, so the two can't simply be combined - materialColor
        // is the documented way to tint a material.
        // Sized to its label and sitting beside the device, not stretched
        // to the full card width underneath it - a full-width button read
        // as the card's primary action when it's a secondary one.
        Button('Trust')
          .fontSize(13)
          .fontColor($r('sys.color.font_on_primary'))
          .backgroundColor(this.accent())
          .height(34)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            tapHaptic();
            const beacon = this.receivedBeacons.find(b => b.deviceId === row.deviceId);
            if (beacon) void this.trustAndConnect(beacon);
          })
      } else if (row.trusted) {
        // Destructive, so it stays quiet: a tinted secondary surface
        // rather than a filled brand button competing with Trust.
        Button('Remove')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .height(34)
          .padding({ left: 16, right: 16 })
          .onClick(() => { tapHaptic(); void this.untrustDevice(row.deviceId); })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(18)
    // One neutral card surface for every state - the connected case is
    // already carried by the dot and the status line, so tinting the
    // whole card for it as well just made the list noisier. Both tokens
    // re-resolve per theme, which the old hardcoded '#FFFFFF'/'#EAF2FF'
    // pair did not: the device name follows the theme to near-white in
    // dark mode, and against a card frozen at white that was invisible.
    .backgroundColor(this.cardFill())
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
  }

  @Builder
  devicesContent() {
    List({ space: 10, scroller: this.devicesScroller }) {
      ListItem() {
        // Summary line reads as a status, not a stat: the count is the
        // part worth emphasizing, the rest is context.
        Text(this.connectedCount === 0
          ? 'No devices connected'
          : `${this.connectedCount} device${this.connectedCount === 1 ? '' : 's'} connected`)
          .fontSize(13)
          .fontColor(this.connectedCount > 0 ? $r('sys.color.confirm') : $r('sys.color.font_secondary'))
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .padding({ left: 4, bottom: 2 })
      }
      if (this.deviceRows().length === 0) {
        ListItem() {
          // Not this.emptyState here - that one fills and centers its
          // container, which inside a ListItem would mean centering
          // within a single row. Plain copy is right for a list that
          // still has its summary line above it.
          Text('Trusted devices, and nearby devices on the same network, will show up here.')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 4, top: 8 })
        }
      } else {
        ForEach(this.deviceRows(), (row: DeviceRow) => {
          ListItem() { this.deviceCard(row) }
          // Key includes connected/trusted/discovered, not just deviceId -
          // ArkUI's ForEach reuses a child node whenever its key is
          // unchanged, so a deviceId-only key meant a connect/disconnect
          // never actually re-invoked deviceCard(row) with the new
          // status, leaving the card frozen at whatever it was first
          // rendered with (while the live connectedCount text above kept
          // updating) - same failure mode already documented on
          // SyncedItem.id above. The name is in it for the same reason.
        }, (row: DeviceRow) => `${row.deviceId}:${row.connected}:${row.trusted}:${row.discovered}:${row.addresses.join(',')}:${row.name ?? ''}`)
      }
    }
    // Single column, not the old 2-column WaterFlow: this list is
    // realistically 1-3 devices, and a masonry grid made each one a
    // cramped half-width tile for no benefit. A full-width row also has
    // space to put the action button beside the device instead of
    // stacked under it.
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    .padding({ left: 16, right: 16 })
    // See the Synced list's note - offsets, not padding, so device cards
    // slide under the floating bars instead of being clipped at them.
    .contentStartOffset(this.topInsetVp + this.TITLE_BAR_HEIGHT + 8)
    .contentEndOffset(this.bottomInsetVp + this.TAB_PILL_CLEARANCE)
    // Usually only 1-3 devices, so without alwaysEnabled it never bounced.
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })    // See syncedListContent's note - page backdrop the card token pairs with.
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // Bottom-right "+" on the Devices tab: the primary thing you come to
  // this tab to do is add a device, and that was previously buried three
  // taps deep under Me > Pairing. Mirrors pasteDock's structure - a
  // full-screen, hit-test-transparent overlay that parks one control in a
  // corner - so it sits above the floating tab pill without absolute
  // positioning.
  @Builder
  addDeviceFab() {
    Column() {
      Button() {
        Text('+')
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_on_primary'))
      }
      .type(ButtonType.Circle)
      .width(56)
      .height(56)
      .backgroundColor(this.accent())
      .onClick(() => { tapHaptic(); setTimeout(() => { this.openPairingFromDevices(); }, 50); })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.End)
    .padding({ right: 20, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE + 10 })
    // See pasteDock's note on None vs Transparent.
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  devicesPageMap(name: string) {
    if (name === 'devicesMain') {
      HdsNavDestination() {
        this.devicesContent()
      }
      .titleBar(this.hdsTitleBar('Devices', true, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.devicesScroller])
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    }
  }

  @Builder
  devicesTab() {
    HdsNavigation(this.devicesNavStack) {
    }
    .hideNavBar(true)
    .navDestination(this.devicesPageMap)
    .width('100%')
    .height('100%')
  }

  // Small caption label above a settings group, matching the grouped-list
  // convention (SubHeader-style) instead of every row/card looking equal
  // weight.
  @Builder
  sectionHeader(text: string) {
    Text(text.toUpperCase())
      .fontSize(11)
      .fontColor($r('sys.color.font_secondary'))
      .fontWeight(FontWeight.Medium)
      .padding({ left: 4, bottom: 2 })
  }

  // A single row inside a grouped settings card - consistent height/padding
  // and a trailing chevron when it navigates, so every row in the list
  // reads as the same kind of control. One options object for the same
  // reason as settingsSwitchRow: with positional parameters ArkUI passed
  // them by value, so values like "Passcode auto-trust: On" or the Tailscale
  // IP kept showing whatever they were on first render.
  @Builder
  settingsRow(opts: SettingsRowOptions) {
    Row({ space: 12 }) {
        // No .fillColor() here. Image.fillColor only recolors an SVG's
        // FILL, not its STROKE - verified on-device by zooming a rendered
        // icon: the fill-drawn parts tinted correctly while every
        // stroke-drawn part stayed black regardless of the colour passed.
        // Since this icon set is stroke-based line art, colour is baked
        // into the asset instead and light/dark ship as a
        // resources/base + resources/dark qualifier pair.
      Image(opts.icon)
        .width(22)
        .height(22)
      Text(opts.title).fontSize(14).layoutWeight(1)
      if (opts.value.length > 0) {
        // Capped so a long value (a device name can be 64 characters)
        // ellipsizes instead of squeezing the title out.
        Text(opts.value).fontSize(13).fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '55%' })
      }
      if (opts.navigates) {
        Image($r('app.media.ic_chevron_right'))
          .width(16)
          .height(16)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => { tapHaptic(); opts.onTap(); })
  }

  // Colour theme picker: one swatch per entry in `themes`, the selected one
  // ringed and ticked. Tapping recolours everything that uses accent()
  // straight away (switches, the selected tab, buttons, press highlights).
  @Builder
  themePicker() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Image($r('app.media.ic_settings_palette'))
          .width(22)
          .height(22)
        Text('Theme').fontSize(14).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Text(this.selectedThemeName()).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      Row() {
        // Key includes the selected state so a swatch's ring/tick actually
        // re-renders when the selection moves (a key-only ForEach reuses the
        // old node - see deviceRows' ForEach for the same issue).
        ForEach(this.themes, (theme: ThemeOption) => {
          Stack() {
            Circle({ width: 34, height: 34 }).fill(theme.color)
            if (theme.key === this.selectedThemeKey()) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([Color.White])
            }
          }
          .width(44)
          .height(44)
          .borderRadius(22)
          .borderWidth(theme.key === this.selectedThemeKey() ? 2 : 0)
          .borderColor(theme.color)
          .accessibilityText(theme.name)
          .onClick(() => { tapHaptic(); void this.setAccentTheme(theme.key); })
        }, (theme: ThemeOption) => `${theme.key}:${theme.key === this.selectedThemeKey()}`)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 14 })
  }

  // How see-through card surfaces are (see cardFill). The API 26
  // immersive-material Slider: like Toggle, Slider gets the material
  // app-wide under ohos.arkui.UIMaterial.state "enable" and treats the
  // systemMaterial argument only as an on-flag (per 组件适配沉浸光感; its
  // light/press feedback needs the default block type and a visible
  // style, both kept here). Updates live while dragging, saves on release.
  @Builder
  cardTransparencyRow() {
    Column({ space: 4 }) {
      Row({ space: 12 }) {
        Image($r('app.media.ic_settings_cards'))
          .width(22)
          .height(22)
        Text('Card transparency').fontSize(14).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Text(`${Math.round(this.cardTransparency)}%`).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      Slider({ value: this.cardTransparency, min: 0, max: 100, step: 5 })
        .width('100%')
        .selectedColor(this.accent())
        .systemMaterial(new uiMaterial.ImmersiveMaterial())
        .accessibilityText('Card transparency')
        .onChange((value: number, mode: SliderChangeMode) => {
          this.cardTransparency = value;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            void this.saveCardTransparency(value);
          }
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 6 })
  }

  // A settings row whose trailing control is an on/off switch.
  //
  // The switch is the API 26 immersive-material Toggle. Per Huawei's
  // "组件适配沉浸光感" guide, ToggleType.Switch already gets it app-wide
  // because module.json5 sets ohos.arkui.UIMaterial.state to "enable", and
  // for a Switch the ImmersiveMaterial passed to systemMaterial is only an
  // on-flag - the component uses its own built-in thumb/shadow parameters,
  // varying by device tier. It's set explicitly anyway so the switch keeps
  // the material style even if the app-level switch is ever changed.
  // No switchStyle/switchPointColor overrides, since those would fight
  // the material's own thumb styling.
  @Builder
  settingsSwitchRow(opts: SwitchRowOptions) {
    Row({ space: 12 }) {
      Image(opts.icon)
        .width(22)
        .height(22)
      Column({ space: 2 }) {
        Text(opts.title).fontSize(14).fontColor($r('sys.color.font_primary'))
        if (opts.subtitle.length > 0) {
          Text(opts.subtitle).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: opts.isOn })
        .selectedColor(this.accent())
        .systemMaterial(new uiMaterial.ImmersiveMaterial())
        .enabled(opts.enabled ?? true)
        // Without this a screen reader announced every switch as just
        // "switch, on/off" with nothing to tell them apart.
        .accessibilityText(opts.title)
        .accessibilityDescription(opts.subtitle)
        .onChange((isOn: boolean) => { tapHaptic(); opts.onChange(isOn); })
    }
    .width('100%')
    .padding({ left: 14, right: 10, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }


  // Wraps the Me tab's main screen and every sub-screen as NavDestinations
  // on their own stack - same reasoning as syncedTab/syncedPageMap: a
  // plain Button in ordinary content (which is what subScreenHeader's back
  // button used to be) can never show immersive material, only a real
  // NavDestination title bar can. setMeScreen (above) is what actually
  // drives push/pop on meNavStack; this only renders whichever route is
  // currently on top.
  @Builder
  meTab() {
    HdsNavigation(this.meNavStack) {
      // Intentionally empty - hideNavBar means this is never shown;
      // 'meMain' (pushed in aboutToAppear) is the real home screen.
    }
    .hideNavBar(true)
    .navDestination(this.mePageMap)
    .width('100%')
    .height('100%')
    // Not shifted by topInsetVp - see syncedTab's identical comment.
  }

  // Each branch below is the same shape - a NavDestination with a native
  // string title (a real title bar, so immersive material actually works,
  // per the doc-confirmed restriction above), and system back routed
  // through setMeScreen so it stays in sync with
  // pairingOpen exactly like the visible back button does. Inlined per
  // screen rather than factored into one shared helper taking the content
  // as a callback parameter - ArkTS's declarative UI syntax only
  // recognizes direct calls to actual @Builder methods inside a @Builder
  // body, not a plain function-typed parameter invoked as a closure
  // ('content()' does not meet UI component syntax was the compiler error
  // that first attempt produced).
  @Builder
  mePageMap(name: string) {
    if (name === 'meMain') {
      HdsNavDestination() {
        this.meMainContent()
      }
      .titleBar(this.hdsTitleBar('Me', true, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.meMainScroller])
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'pairing') {
      // Sub-screens use the HDS bar's own back button. Its tap and the
      // system back gesture both land in onBackPressed, which routes
      // through setMeScreen so meScreen/pairingOpen stay in step with the
      // stack (a default pop would leave pairing mode open).
      HdsNavDestination() {
        this.pairingScreenContent()
      }
      .titleBar(this.hdsTitleBar('Pairing', false, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.pairingScroller])
      .hideBackButton(false)
      .onBackPressed(() => { this.setMeScreen('main'); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'passcode') {
      HdsNavDestination() {
        this.passcodeScreenContent()
      }
      .titleBar(this.hdsTitleBar('Passcode auto-trust', false, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.passcodeScroller])
      .hideBackButton(false)
      .onBackPressed(() => { this.setMeScreen('main'); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'network') {
      HdsNavDestination() {
        this.networkScreenContent()
      }
      .titleBar(this.hdsTitleBar('Tailscale IP', false, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.networkScroller])
      .hideBackButton(false)
      .onBackPressed(() => { this.setMeScreen('main'); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'devicename') {
      HdsNavDestination() {
        this.deviceNameScreenContent()
      }
      .titleBar(this.hdsTitleBar('Device name', false, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.deviceNameScroller])
      .hideBackButton(false)
      .onBackPressed(() => { this.setMeScreen('main'); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'diagnostics') {
      HdsNavDestination() {
        this.diagnosticsScreenContent()
      }
      .titleBar(this.hdsTitleBar('Diagnostics', false, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.diagnosticsScroller])
      .hideBackButton(false)
      .onBackPressed(() => { this.setMeScreen('main'); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    } else if (name === 'log') {
      HdsNavDestination() {
        this.activityLogScreenContent()
      }
      .titleBar(this.hdsTitleBar('Activity log', false, []))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .bindToScrollable([this.logScroller])
      .hideBackButton(false)
      .onBackPressed(() => { this.setMeScreen('main'); return true; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    }
  }

  // Primary "Me" screen: identity + a real settings list, one row per
  // section (pairing/QR, passcode, diagnostics, activity log), each
  // navigating to its OWN separate screen - not one page with everything
  // clumped together.
  @Builder
  meMainContent() {
      Scroll(this.meMainScroller) {
        Column({ space: 16 }) {
          // No in-flow page title here - "Me" lives in the HDS title bar
          // (see mePageMap), which this content scrolls underneath.
          this.sectionHeader('Device')
          Column() {
            Column({ space: 4 }) {
              Text('Your device ID').fontSize(12).fontColor($r('sys.color.font_secondary'))
              Text(this.ownDeviceId.length > 0 ? this.ownDeviceId : 'Generating identity…')
                .fontSize(11)
                .fontColor($r('sys.color.font_primary'))
                .copyOption(CopyOptions.LocalDevice)
                .wordBreak(WordBreak.BREAK_ALL)
              if (this.localAddresses.length > 0) {
                Text(this.localAddresses.join('  •  '))
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .margin({ top: 6 })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(14)
            Divider().color($r('sys.color.comp_divider'))
            // What other devices list this one as - see DeviceName.ets.
            this.settingsRow({ title: 'Device name', value: this.ownDeviceName() ?? 'Not set', navigates: true, icon: $r('app.media.ic_device_phone'), onTap: () => { this.deviceNameInput = this.deviceNameOverride; this.setMeScreen('devicename'); } })
            Divider().color($r('sys.color.comp_divider'))
            this.settingsRow({ title: 'Copy device ID', value: '', navigates: false, icon: $r('app.media.ic_menu_copy'), onTap: () => { void this.copyDeviceId(); } })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardFill())

          this.sectionHeader('Sync')
          Column() {
            this.settingsSwitchRow({
              title: 'Copy received items automatically',
              subtitle: 'Puts whatever arrives straight onto this device\'s clipboard.',
              isOn: this.autoApply,
              icon: $r('app.media.ic_settings_autocopy'),
              onChange: (isOn: boolean) => { void this.setAutoApply(isOn); },
            })
            Divider().color($r('sys.color.comp_divider'))
            // Android's "Send my clipboard when I open ClipLink" can't be
            // ported as-is (see onPageShow) - this is what HarmonyOS allows.
            this.settingsSwitchRow({
              title: 'Point out new copies',
              subtitle: 'HarmonyOS only lets ClipLink read the clipboard when you tap Paste, so this highlights Paste when you\'ve copied something new, including while ClipLink was closed.',
              isOn: this.noticeOnOpen,
              icon: $r('app.media.ic_settings_notice'),
              onChange: (isOn: boolean) => { void this.setNoticeNewCopies(isOn); },
            })
            // No "Keep syncing in the background" (Android's keepAlive): the
            // only continuous-task mode open to apps, multiDeviceConnection,
            // was tried and failed on-device - the system's usage check
            // ("check failed, not use 6") suspended it and froze the app
            // about a minute after leaving it, since a plain TCP link to a
            // PC isn't a HarmonyOS distributed/casting connection.
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardFill())

          this.sectionHeader('Appearance')
          Column() {
            this.themePicker()
            Divider().color($r('sys.color.comp_divider'))
            this.settingsSwitchRow({
              title: 'Bottom glow',
              subtitle: 'A soft wash of your theme colour along the bottom of each page.',
              isOn: this.bottomGlowOn,
              icon: $r('app.media.ic_settings_glow'),
              onChange: (isOn: boolean) => { void this.setBottomGlow(isOn); },
            })
            Divider().color($r('sys.color.comp_divider'))
            this.cardTransparencyRow()
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardFill())

          this.sectionHeader('Pairing')
          Column() {
            this.settingsRow({ title: 'QR code & scan', value: '', navigates: true, icon: $r('app.media.ic_settings_qr'), onTap: () => { this.setMeScreen('pairing'); } })
            Divider().color($r('sys.color.comp_divider'))
            this.settingsRow({ title: 'Passcode auto-trust', value: this.hasPassphrase ? 'On' : 'Off', navigates: true, icon: $r('app.media.ic_settings_passcode'), onTap: () => { this.setMeScreen('passcode'); } })
            Divider().color($r('sys.color.comp_divider'))
            this.settingsRow({ title: 'Tailscale IP', value: this.tailscaleIp.length > 0 ? this.tailscaleIp : 'Not set', navigates: true, icon: $r('app.media.ic_settings_network'), onTap: () => { this.setMeScreen('network'); } })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardFill())

          this.sectionHeader('Support')
          Column() {
            this.settingsRow({ title: 'Diagnostics', value: '', navigates: true, icon: $r('app.media.ic_settings_diagnostics'), onTap: () => { this.setMeScreen('diagnostics'); } })
            Divider().color($r('sys.color.comp_divider'))
            this.settingsRow({ title: 'Activity log', value: `${this.syncLog.length}`, navigates: true, icon: $r('app.media.ic_settings_log'), onTap: () => { this.setMeScreen('log'); } })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardFill())

          this.sectionHeader('Data')
          Column() {
            this.settingsRow({ title: 'Clear synced history', value: '', navigates: false, icon: $r('app.media.ic_settings_trash'), onTap: () => { this.confirmClearHistory(); } })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardFill())
        }
        .width('100%')
        // topInsetVp restored - meTab's Navigation is no longer shifted as
        // a whole (see meTab's comment), so "Me" needs its own clearance
        // again to stay readable below the status bar.
        .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.START)))
      // Per Huawei's "如何实现沉浸式页面" FAQ - this Scroll's own background
      // draws behind the status bar instead of leaving a gap; the "Me"
      // title inside it stays clear via its own topInsetVp padding above.
      .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // Pairing: QR display + scan, mirrors Windows's QrCodeForm/
  // TrustDeviceForm pair but adapted to a device that actually has a
  // camera - scanning replaces Windows's paste-the-key fallback. The back
  // header used to be the first child here (this.subScreenHeader('Pairing'))
  // - it's now supplied via subScreenDestination's .title() instead (see
  // mePageMap), so this is just the scrollable body.
  @Builder
  pairingScreenContent() {
    Scroll(this.pairingScroller) {
      Column({ space: 16 }) {
        Column({ space: 8 }) {
          Text('This screen open = pairable.').fontSize(13).fontWeight(FontWeight.Medium)
          Text('A pairing request only reaches this device while this screen is open, and only completes once you tap Accept here - keep it open on BOTH devices at the same time while pairing. Leaving this screen closes the window; nothing pairs silently in the background.')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())
        .alignItems(HorizontalAlign.Start)

        Column({ space: 12 }) {
          if (this.myPairingPayload.length > 0) {
            QRCode(this.myPairingPayload)
              .width(220)
              .height(220)
              .color(Color.Black)
              .backgroundColor(Color.White)
              .borderRadius(16)
          }
          Text('Scan this on another device (with its own Pairing screen open) to find it.').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Button('Scan a Device\'s QR Code').fontSize(14).fontColor(this.accent()).backgroundColor(this.accentTint()).systemMaterial(this.buttonMaterial())
            .onClick(() => { tapHaptic(); void this.scanToPair(); })
          if (this.scanStatus.length > 0) {
            Text(this.scanStatus).fontSize(12).fontColor($r('sys.color.font_secondary'))
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())

        // Windows has no camera to scan the QR above with (see
        // TrustDeviceForm.cs) - this covers that, plus any cross-network
        // (Tailscale) case where you'd rather paste an address than type
        // it. Either way this only ever FINDS the peer; accept/reject still
        // decides whether it's actually trusted, same as everything else
        // on this screen.
        Column({ space: 10 }) {
          Text('Pair by address').fontSize(14).fontWeight(FontWeight.Medium)
          Text('No camera on the other device (e.g. Windows)? Type or paste its address - or its pairing text copied below - here instead.')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          TextInput({ placeholder: 'e.g. 100.x.x.x or pasted pairing text', text: this.pairByAddressInput })
            .type(InputType.Normal)
            .fontSize(14)
            .enabled(!this.pairingInProgress)
            .onChange((value: string) => { this.pairByAddressInput = value; })
          Button(this.pairingInProgress ? 'Connecting...' : 'Pair by Address')
            .fontSize(14)
            .fontColor(this.accent())
            .backgroundColor(this.accentTint())
            .systemMaterial(this.buttonMaterial())
            .enabled(!this.pairingInProgress)
            .onClick(() => { tapHaptic(); void this.pairByAddress(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())
        .alignItems(HorizontalAlign.Start)

        Column({ space: 10 }) {
          Text('This device\'s pairing info').fontSize(14).fontWeight(FontWeight.Medium)
          Text('Copy this and send it to the other device (e.g. paste it into ITS Pair by Address field above) so it knows where to find this one.')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          Button('Copy Pairing Info').fontSize(14).fontColor(this.accent()).backgroundColor(this.accentTint()).systemMaterial(this.buttonMaterial())
            .enabled(this.myPairingPayload.length > 0)
            .onClick(() => { tapHaptic(); void this.copyPairingPayload(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // topInsetVp + a fixed offset here: the HDS title bar floats over
      // this content rather than reserving space for it, so this
      // padding is what keeps the initial view starting below the bar
      // instead of hidden under it - scrolling still passes content
      // behind it afterward, which is the point of STACK over STANDARD.
      .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // Passcode auto-trust: mirrors Windows's PasscodeForm/PassphraseAuth -
  // any device that later enters the same passcode auto-trusts this one
  // over the LAN beacon, no QR needed. Back header moved to
  // subScreenDestination's .title() - see pairingScreenContent's comment.
  @Builder
  passcodeScreenContent() {
    Scroll(this.passcodeScroller) {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          Text('Devices entering the same passcode trust each other automatically.').fontSize(12).fontColor($r('sys.color.font_secondary'))
          if (this.hasPassphrase && !this.passcodeChanging) {
            Text('Passcode is set on this device.').fontSize(13).fontColor($r('sys.color.confirm'))
            // Change and Clear, as on Android. Clearing only stops this
            // device proving the passcode to new devices - ones it already
            // auto-trusted stay trusted.
            Row({ space: 10 }) {
              Button('Change Passcode')
                .fontSize(14)
                .fontColor(this.accent())
                .backgroundColor(this.accentTint())
                .systemMaterial(this.buttonMaterial())
                .onClick(() => { tapHaptic(); this.passphraseInput = ''; this.passcodeChanging = true; })
              Button('Clear')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .onClick(() => { tapHaptic(); void this.clearPassphrase(); })
            }
          } else {
            TextInput({ placeholder: this.hasPassphrase ? 'Enter a new shared passcode' : 'Enter a shared passcode', text: this.passphraseInput })
              .type(InputType.Password)
              .fontSize(14)
              .enabled(!this.settingPassphrase)
              .onChange((value: string) => { this.passphraseInput = value; })
            Row({ space: 10 }) {
              Button(this.settingPassphrase ? 'Setting...' : 'Set Passcode')
                .fontSize(14)
                .fontColor(this.accent())
                .backgroundColor(this.accentTint())
                .systemMaterial(this.buttonMaterial())
                .enabled(!this.settingPassphrase)
                .onClick(() => { tapHaptic(); void this.setPassphrase(); })
              if (this.passcodeChanging) {
                Button('Cancel')
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
                  .enabled(!this.settingPassphrase)
                  .onClick(() => { tapHaptic(); this.passphraseInput = ''; this.passcodeChanging = false; })
              }
            }
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // No topInsetVp compensation - see pairingScreenContent's comment.
      .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // HarmonyOS has no sandboxed way to ask the Tailscale app for this
  // device's own tailnet IP the way the Windows daemon shells out to
  // `tailscale ip -4` - see DeviceSettings.ets. This is the manual
  // substitute: paste it in once (Tailscale's own app shows it), and it
  // gets broadcast in the LAN beacon and the QR/manual pairing payload
  // exactly like Windows's auto-detected one would, so other devices can
  // cache it and reconnect over it once you're off the same LAN.
  // Back header moved to subScreenDestination's .title() - see
  // pairingScreenContent's comment.
  @Builder
  networkScreenContent() {
    Scroll(this.networkScroller) {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          Text('HarmonyOS can\'t detect this automatically - copy your tailnet IP from the Tailscale app and paste it here so other devices can reach this one off your local network.').fontSize(12).fontColor($r('sys.color.font_secondary'))
          TextInput({ placeholder: 'e.g. 100.x.x.x', text: this.tailscaleIp })
            .type(InputType.Normal)
            .fontSize(14)
            .enabled(!this.savingTailscaleIp)
            .onChange((value: string) => { this.tailscaleIp = value; })
          Button(this.savingTailscaleIp ? 'Saving...' : 'Save')
            .fontSize(14)
            .fontColor(this.accent())
            .backgroundColor(this.accentTint())
            .systemMaterial(this.buttonMaterial())
            .enabled(!this.savingTailscaleIp)
            .onClick(() => { tapHaptic(); void this.saveTailscaleIp(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // No topInsetVp compensation - see pairingScreenContent's comment.
      .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // This device's display name - what other devices' lists, pairing prompts
  // and toasts show for it (see DeviceName.ets). Same shape as the Tailscale
  // IP screen above; the system's name is the placeholder, so leaving the
  // field empty visibly means "use that".
  @Builder
  deviceNameScreenContent() {
    Scroll(this.deviceNameScroller) {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          Text('Other devices show this name instead of this device\'s ID. Leave it empty to use the name from system settings.').fontSize(12).fontColor($r('sys.color.font_secondary'))
          TextInput({ placeholder: this.systemDeviceName.length > 0 ? this.systemDeviceName : 'Device name', text: this.deviceNameInput })
            .type(InputType.Normal)
            .fontSize(14)
            .enabled(!this.savingDeviceName)
            .onChange((value: string) => { this.deviceNameInput = value; })
          Button(this.savingDeviceName ? 'Saving...' : 'Save')
            .fontSize(14)
            .fontColor(this.accent())
            .backgroundColor(this.accentTint())
            .systemMaterial(this.buttonMaterial())
            .enabled(!this.savingDeviceName)
            .onClick(() => { tapHaptic(); void this.saveDeviceName(); })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(this.cardFill())
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // Back header moved to subScreenDestination's .title() - see
  // pairingScreenContent's comment.
  @Builder
  diagnosticsScreenContent() {
    Scroll(this.diagnosticsScroller) {
      Column({ space: 16 }) {
        Column() {
          this.settingsRow({ title: 'Run self-test', value: '', navigates: false, icon: $r('app.media.ic_settings_diagnostics'), onTap: () => { void this.runSelfTest(); } })
          Divider().color($r('sys.color.comp_divider'))
          this.settingsRow({ title: 'Immersive material', value: this.immersiveSupported ? 'Supported' : 'Not supported', navigates: false, icon: $r('app.media.ic_settings_diagnostics'), onTap: () => {} })
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor(this.cardFill())
      }
      .width('100%')
      // No topInsetVp compensation - see pairingScreenContent's comment.
      .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // syncLog is where every connect/disconnect/trust/untrust/auto-trust
  // event gets recorded (see e.g. untrustDevice, connectToBeacon,
  // maybeAutoTrustViaPassphrase). Back header moved to
  // subScreenDestination's .title() - see pairingScreenContent's comment.
  @Builder
  activityLogScreenContent() {
    Scroll(this.logScroller) {
      Column({ space: 16 }) {
        if (this.syncLog.length === 0) {
          Text('Nothing logged yet.').fontSize(12).fontColor($r('sys.color.font_secondary'))
        } else {
          Column({ space: 6 }) {
            ForEach(this.syncLog, (line: string, index: number) => {
              Text(line).fontSize(12).fontColor($r('sys.color.font_secondary'))
            }, (line: string, index: number) => `${index}-${line}`)
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor(this.cardFill())
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      // No topInsetVp compensation - see pairingScreenContent's comment.
      .padding({ left: 16, right: 16, top: this.topInsetVp + this.TITLE_BAR_HEIGHT + 8, bottom: this.bottomInsetVp + this.TAB_PILL_CLEARANCE })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .edgeEffect(EdgeEffect.Spring)    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)))
    .backgroundColor($r('sys.color.background_secondary'))
    .linearGradient(this.bottomGlow())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // Root cause of the persistently-unreadable tab labels, found in Huawei's
  // own "设置沉浸式系统材质反色" (immersive material color-invert) sample:
  // colorInvert only auto-adjusts text/icon color for BottomTabBarStyle's
  // labelStyle/iconStyle (which use color-invert-aware resource tokens like
  // $r('sys.color.font_primary')) - it does NOT apply to an arbitrary
  // custom @Builder's Text with a hardcoded hex fontColor, which is what
  // every earlier attempt here used. Hardcoded hex can't be "inverted" by
  // the material at all. Switching to the framework's own tab-bar-style
  // class, with colorInvert: true on the material, is what actually makes
  // this work per the sample.
  // Real per-tab icons now, filled when that tab is selected. Every tab
  // previously passed the same sys.media.ohos_icon_mask_svg placeholder,
  // which is why all three rendered as identical blank rounded squares.
  tabBarStyle(text: string, index: number): BottomTabBarStyle {
    // Filled artwork for BOTH states, differentiated only by colour.
    // The outline variants are stroke-only (fill="none"), but the tab bar
    // rasterises icons as filled shapes - so the clipboard's outer rect
    // came out as a solid black square rather than an outline, which is
    // the "black blob" in the unselected tabs and the dark shape that
    // flashes mid-transition. Filled art renders correctly under that
    // treatment; state now reads from colour, which is the more common
    // tab-bar convention anyway.
    let icon: Resource;
    if (index === 0) {
      icon = $r('app.media.ic_tab_synced_filled');
    } else if (index === 1) {
      icon = $r('app.media.ic_tab_devices_filled');
    } else {
      icon = $r('app.media.ic_tab_me_filled');
    }
    return BottomTabBarStyle.of(icon, text)
      .labelStyle({ selectedColor: this.accent(), unselectedColor: $r('sys.color.font_secondary') })
      .iconStyle({ selectedColor: this.accent(), unselectedColor: $r('sys.color.font_secondary') });
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // Matches the official API 26.0.0 barFloatingStyle sample (ts-container-tabs
      // reference doc, "示例24 TabBar悬浮样式") as closely as possible. Two things
      // an earlier guess-and-check pass got wrong:
      // - barMode/barHeight/scrollable aren't part of the canonical sample at all
      //   and aren't needed for a fixed 3-tab bar.
      // - Tabs has defaulted expandSafeArea to
      //   expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]) since API 11.
      //   An explicit .expandSafeArea([SafeAreaType.SYSTEM]) (no edge argument,
      //   which expands ALL edges) plus a manually-computed barBottomMargin were
      //   fighting that built-in behavior instead of relying on it.
      Tabs({ index: this.currentTabIndex, barPosition: BarPosition.End }) {
        TabContent() { this.syncedTab() }
          .tabBar(this.tabBarStyle('Synced', 0))
        TabContent() { this.devicesTab() }
          .tabBar(this.tabBarStyle('Devices', 1))
        TabContent() { this.meTab() }
          .tabBar(this.tabBarStyle('Me', 2))
      }
      // Off: a left/right swipe on the Synced tab is claimed by the zoomed
      // image's pan gesture (see zoomableImage) - if Tabs also treated that
      // swipe as "switch tab", the two would fight over the same gesture.
      // Tapping the tab bar itself still switches tabs fine; this only
      // removes the swipe-to-switch shortcut.
      .scrollable(false)
      .barOverlap(true)
      .barFloatingStyle({
        adaptToHandedness: true,
        // ULTRA_THIN with applyShadow off, matching the official
        // barFloatingStyle sample. THIN + applyShadow drew a hard white
        // rim highlight right around the pill, which against a light page
        // read as an outline drawn on the bar rather than as material.
        // The thinner style keeps the frost and the colour inversion but
        // drops that ring.
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          applyShadow: false,
          interactive: true,
          lightEffect: { color: this.accent() },
          colorInvert: true,
        }),
      })
      .width('100%')
      .height('100%')
      .onChange((index: number) => { this.currentTabIndex = index; })
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])

      // Mounted as a sibling of Tabs, not inside a tab's content: it has to
      // sit above the floating tab pill in z-order and be positioned
      // against the real screen bottom, and only the root Stack spans
      // that. Synced-only, since pasting is meaningless on Devices/Me.
      if (this.currentTabIndex === 1) {
        this.addDeviceFab()
      }
    }
    .width('100%')
    .height('100%')
    // Status bar treatment: removed the old decorative strip entirely
    // instead of trying to fake a blur over it. Per Huawei's own "如何实现
    // 沉浸式页面" FAQ, the correct pattern for a fullscreen window
    // (EntryAbility.ets's setWindowLayoutFullScreen) isn't a separate bar -
    // it's letting the actual scrollable content's own background draw
    // through via expandSafeArea (see syncedListContent/meMainContent/
    // devicesTab/itemDetailView), the same way real apps show list cards
    // or images genuinely visible behind the status bar icons, rather than
    // a flat rectangle pretending to blur nothing behind it.
  }
}
