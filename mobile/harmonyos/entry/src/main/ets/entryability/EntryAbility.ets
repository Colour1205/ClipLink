import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { enqueueShares, intakeShare, isShareWant, SHARED_IN_EVENT, SharedIn, sweepShareCopies } from '../share/ShareIntake';

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
  }

  // ClipLink is a singleton UIAbility, so a share while it's running
  // arrives here rather than in onCreate (onForeground never sees the Want).
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.acceptShare(want, launchParam);
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