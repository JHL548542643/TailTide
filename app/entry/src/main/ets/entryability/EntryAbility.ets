import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';
const STATUS_BAR_COLOR = '#00000000';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', JSON.stringify(err));
    }
    this.applySystemBars();
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindow = undefined;
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.applySystemBars();
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate colorMode=%{public}d', newConfig.colorMode);
  }

  private isDarkMode(): boolean {
    return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private applySystemBars(): void {
    if (this.mainWindow === undefined) {
      return;
    }
    let dark = this.isDarkMode();
    try {
      this.mainWindow.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(err) ?? '');
      });
      this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: STATUS_BAR_COLOR,
        isStatusBarLightIcon: dark,
        statusBarContentColor: dark ? '#FFFFFF' : '#221436',
        navigationBarColor: '#00000000',
        isNavigationBarLightIcon: dark,
        navigationBarContentColor: dark ? '#FFFFFF' : '#221436'
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err) ?? '');
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'applySystemBars error: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
