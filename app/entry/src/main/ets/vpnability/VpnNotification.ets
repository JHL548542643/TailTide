import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { WantAgent } from '@ohos.app.ability.wantAgent';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VpnNotification';
const NOTIFICATION_ID: number = 1001;
const BUNDLE_NAME: string = 'com.tailtide.app';
const ENTRY_ABILITY: string = 'EntryAbility';

export class VpnNotification {
  static async publishConnected(): Promise<void> {
    try {
      let connectedAgent: WantAgent = await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: BUNDLE_NAME,
            abilityName: ENTRY_ABILITY
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      });
      let request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        tapDismissed: false,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'TailTide',
            text: 'Tailnet 已连接',
            additionalText: '点击返回 TailTide'
          }
        },
        wantAgent: connectedAgent
      };
      await notificationManager.publish(request);
      hilog.info(0x0000, TAG, 'publish connected notification success');
    } catch (err) {
      hilog.error(0x0000, TAG, 'publish connected notification failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  static async cancelConnected(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFICATION_ID);
      hilog.info(0x0000, TAG, 'cancel connected notification success');
    } catch (err) {
      hilog.error(0x0000, TAG, 'cancel connected notification failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }
}
