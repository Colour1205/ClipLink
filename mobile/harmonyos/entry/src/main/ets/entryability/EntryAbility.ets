import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { enqueueShares, intakeShare, isShareWant, SHARED_IN_EVENT, SharedIn, sweepShareCopies } from '../share/ShareIntake';
import { PAIRING_ACTION_EVENT, PairingAnswer, readPairingAnswer } from '../networking/PairingActions';
import { PAIRING_LINK_EVENT, queuePairingLink, readPairingLink } from '../networking/PairingLink';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // Index.ets resolves a few colour resources in code (to apply an alpha
    // to them), and needs to know when light/dark flips to re-resolve them.
    AppStorage.setOrCreate<number>('colorMode', this.context.config.colorMode);
    // Likewise for the language: text Index.ets builds in code (not $r
    // resources, which follow the language by themselves) is built again
    // when this changes.
    AppStorage.setOrCreate<string>('language', this.context.config.language ?? '');
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    sweepShareCopies(this.context);
    this.acceptShare(want, launchParam);
    this.acceptPairingLink(want);
  }

  // ClipLink is a singleton UIAbility, so a share while it's running
  // arrives here rather than in onCreate (onForeground never sees the Want).
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.acceptShare(want, launchParam);
    this.acceptPairingAnswer(want);
    this.acceptPairingLink(want);
  }

  // A scanner read another device's pairing QR code, which is a link to the
  // website's /pair page (see networking/PairingLink.ets): queued for Index.ets,
  // which shows the pairing screen and starts pairing once its engine is ready.
  private acceptPairingLink(want: Want): void {
    const link: string | null = readPairingLink(want);
    if (link === null) return;
    queuePairingLink(link);
    this.context.eventHub.emit(PAIRING_LINK_EVENT);
  }

  // A Trust or Ignore button on the pairing notification, or the
  // notification itself (see networking/PairingActions.ets): handed to the
  // page, which only acts if that request is still the one waiting. Only
  // onNewWant: a notification can only be answered by a running app, since
  // the request it is about lives in the process that posted it.
  private acceptPairingAnswer(want: Want): void {
    const answer: PairingAnswer | null = readPairingAnswer(want);
    if (answer === null) return;
    this.context.eventHub.emit(PAIRING_ACTION_EVENT, answer.action, answer.deviceId);
  }

  // "Share to ClipLink" (see share/ShareIntake.ets): copies the shared files
  // now, while the grant holds, then queues everything for Index.ets.
  private acceptShare(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (!isShareWant(want, launchParam)) return;
    intakeShare(this.context, want).then((items: SharedIn[]) => {
      enqueueShares(items);
      this.context.eventHub.emit(SHARED_IN_EVENT);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to take a share. Cause: %{public}s', JSON.stringify(err));
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    AppStorage.setOrCreate<number>('colorMode', newConfig.colorMode);
    if (newConfig.language !== undefined) {
      AppStorage.setOrCreate<string>('language', newConfig.language);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // Immersive/edge-to-edge layout: content draws behind the status bar
    // and navigation bar instead of the system reserving solid space for
    // them (which otherwise shows as an unstyled black gap, since we never
    // set a matching window background for that reserved area). Index.ets
    // queries the actual avoid-area insets and pads its own content
    // accordingly, rather than relying on the system's default insetting.
    const mainWindow = windowStage.getMainWindowSync();
    mainWindow.setWindowLayoutFullScreen(true).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to set full-screen layout. Cause: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}