import { socket, vpnExtension, connection } from '@kit.NetworkKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { common, Want, bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { VpnNotification } from '../vpnability/VpnNotification';
import { ProxyConfig } from '../common/ProxyConfig';
import bridge from 'libtailnet_bridge.so';

const TAG: string = 'IndexPage';
const APP_NAME: string = 'TailTide';
const APP_SUBTITLE: string = 'Tailnet 随身连接';
const APP_VERSION_FALLBACK: string = '1.1.2';
const STATUS_POLL_INTERVAL_MS: number = 2000;
const WATCHDOG_INTERVAL_MS: number = 10000;
const PROBE_MIN_INTERVAL_MS: number = 30000;
const PROXY_PROBE_TIMEOUT_MS: number = 3000;
const STATUS_STALE_SECONDS: number = 30;
const BACKOFF_STEPS_MS: number[] = [15000, 30000, 60000, 120000, 300000];

const vpnWant: Want = {
  deviceId: '',
  bundleName: 'com.tailtide.app',
  abilityName: 'TailnetVpnAbility',
};

interface EngineStatus {
  ok: boolean;
  backendState?: string;
  authUrl?: string;
  tailscaleIps?: string[];
  ts?: number;
}

interface VpnStateFile {
  active: boolean;
  ts?: number;
}

interface SsNodeInfo {
  name: string;
  port: number;
  cipher: string;
}

interface SsListResult {
  ok: boolean;
  nodes?: SsNodeInfo[];
  error?: string;
}

interface OpResult {
  ok: boolean;
  error?: string;
}

interface SsNodeFile {
  name?: string;
  server?: string;
  port?: number;
  cipher?: string;
}

@Entry
@Component
struct Index {
  @State status: string = '未连接';
  @State busy: boolean = false;
  @State connected: boolean = false;
  @State engineState: string = '-';
  @State authUrl: string = '';
  @State tsIps: string = '-';
  @State proxyUrl: string = '';
  @State ssNodes: string[] = [];
  @State ssSelected: string = '';
  @State ssStatus: string = '';
  @State ssBusy: boolean = false;
  @State showAdvanced: boolean = false;
  @State engineVersion: string = '';
  @State appVersion: string = APP_VERSION_FALLBACK;
  @State statusBarHeight: number = 0;
  @State navBarHeight: number = 0;
  private pollTimer: number = -1;
  private watchdogTimer: number = -1;
  private userDisconnected: boolean = false;
  private backoffIdx: number = 0;
  private nextRetryAt: number = 0;
  private lastProbeAt: number = 0;
  private proxyOk: boolean | undefined = undefined;

  aboutToAppear(): void {
    // 每次重新打开 App：清除本会话的"手动断开"标记，恢复自动连接
    this.userDisconnected = false;
    this.backoffIdx = 0;
    this.nextRetryAt = 0;
    {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.proxyUrl = ProxyConfig.read(context.filesDir);
      // 清掉开发期/联调期遗留的测试值，避免无声回退到已关闭的代理
      if (this.proxyUrl === 'http://127.0.0.1:7890') {
        this.proxyUrl = '';
      }
    }
    try {
      this.engineVersion = bridge.engineVersion();
    } catch (err) {
      this.engineVersion = '';
    }
    try {
      let info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName !== undefined && info.versionName !== null && info.versionName !== '') {
        this.appVersion = info.versionName;
      }
    } catch (err) {
      this.appVersion = APP_VERSION_FALLBACK;
    }
    this.loadSafeArea();
    this.loadSsState();
    this.pollTimer = setInterval(() => {
      this.refreshEngineStatus();
    }, STATUS_POLL_INTERVAL_MS);
    this.watchdogTimer = setInterval(() => {
      this.watchdogTick();
    }, WATCHDOG_INTERVAL_MS);
    this.requestNotificationPermission();
    setTimeout(() => {
      this.watchdogTick();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.watchdogTimer !== -1) {
      clearInterval(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  @Builder HeroCard() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Image($r('app.media.logo'))
          .width(40)
          .height(40)
          .objectFit(ImageFit.Contain)
        Column({ space: 2 }) {
          Text(APP_NAME)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.hero_text'))
          Text(APP_SUBTITLE)
            .fontSize(12)
            .fontColor($r('app.color.hero_text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Row({ space: 6 }) {
          Circle({ width: 8, height: 8 })
            .fill(this.connected ? $r('app.color.accent') : '#94A3B8')
          Text(this.connected ? '在线' : '离线')
            .fontSize(12)
            .fontColor($r('app.color.hero_text_secondary'))
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.hero_chip_bg'))
        .borderRadius(16)
      }
      .width('100%')

      Column({ space: 4 }) {
        Text(this.connected ? '已连接' : this.busy ? '正在连接…' : this.status.indexOf('无网络') >= 0 ? '无网络' : '未连接')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.hero_text'))
        Text(this.connected ? '你的 Tailnet 已就绪' : this.status)
          .fontSize(14)
          .fontColor($r('app.color.hero_text_secondary'))
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row() {
        Column({ space: 2 }) {
          Text('TAILSCALE IP')
            .fontSize(10)
            .letterSpacing(1)
            .fontColor($r('app.color.hero_text_secondary'))
          Text(this.tsIps === '-' ? '未分配' : this.tsIps)
            .fontSize(17)
            .fontColor($r('app.color.hero_text'))
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Button('复制')
          .fontSize(12)
          .fontColor($r('app.color.hero_text'))
          .backgroundColor($r('app.color.hero_chip_bg'))
          .height(32)
          .borderRadius(16)
          .enabled(this.tsIps !== '-')
          .onClick(() => {
            this.copyIp();
          })
      }
      .width('100%')

      if (this.busy) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.hero_text'))
          Text('正在处理…')
            .fontSize(13)
            .fontColor($r('app.color.hero_text_secondary'))
        }
        .width('100%')
      }

      Button(this.connected ? '断开连接' : '连接 Tailnet')
        .width('100%')
        .height(50)
        .borderRadius(25)
        .backgroundColor(this.connected ? $r('app.color.hero_chip_bg') : $r('app.color.hero_text'))
        .fontColor(this.connected ? $r('app.color.hero_text') : $r('app.color.hero_start'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .enabled(!this.busy)
        .onClick(() => {
          if (this.connected) {
            this.disconnectVpn();
          } else {
            this.connectVpn(false);
          }
        })
    }
    .width('100%')
    .padding(22)
    .borderRadius(28)
    .linearGradient({ angle: 140, colors: [[$r('app.color.hero_start'), 0], [$r('app.color.hero_end'), 1]] })
    .shadow({ radius: 24, color: $r('app.color.hero_shadow'), offsetY: 10 })
  }

  @Builder AuthCard() {
    Column({ space: 10 }) {
      Row() {
        Text('需要登录 Tailscale')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('授权')
          .fontSize(12)
          .fontColor($r('app.color.primary'))
      }
      .width('100%')
      Text('完成登录后，TailTide 会自动继续连接。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Button('打开登录页面')
        .width('100%')
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.on_primary'))
        .onClick(() => {
          this.openLoginPage();
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.card'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.card_border') })
  }

  @Builder EgressCard() {
    Column({ space: 12 }) {
      Row() {
        Text('出口节点')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.ssSelected !== '' ? '内置 SS' : (this.proxyUrl.trim() !== '' ? '外部代理' : '直连'))
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.primary_bg'))
          .borderRadius(12)
      }
      .width('100%')

      if (this.ssSelected !== '') {
        Column({ space: 6 }) {
          Text(this.ssSelected)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Row({ space: 8 }) {
            Text('自动故障转移')
              .fontSize(11)
              .fontColor($r('app.color.success'))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor($r('app.color.success_bg'))
              .borderRadius(10)
            Text('主节点 + ' + this.ssNodes.length + ' 个候选')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      } else if (this.ssNodes.length > 0) {
        Text('已导入配置，请选择一个主节点')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      } else {
        Text('导入 Clash 配置，启用内置 SS 出口')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }

      if (this.ssNodes.length > 0) {
        Select(this.ssNodes.map((name: string): SelectOption => {
          let option: SelectOption = { value: name };
          return option;
        }))
          .selected(this.ssNodes.indexOf(this.ssSelected))
          .value(this.ssSelected)
          .width('100%')
          .height(46)
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(14)
          .fontColor($r('app.color.text_primary'))
          .onSelect((index: number, value: string) => {
            this.applySsNode(value);
          })
      }

      Row({ space: 10 }) {
        Button(this.ssBusy ? '正在导入…' : (this.ssNodes.length > 0 ? '更换配置' : '导入配置'))
          .layoutWeight(1)
          .height(44)
          .borderRadius(22)
          .backgroundColor($r('app.color.primary_bg'))
          .fontColor($r('app.color.primary'))
          .enabled(!this.ssBusy)
          .onClick(() => {
            this.importClashConfig();
          })
        if (this.ssSelected !== '') {
          Button('清除')
            .height(44)
            .borderRadius(22)
            .fontSize(14)
            .backgroundColor($r('app.color.danger_bg'))
            .fontColor($r('app.color.danger'))
            .enabled(!this.busy)
            .onClick(() => {
              this.confirmClearSs();
            })
        }
      }
      .width('100%')

      if (this.ssStatus !== '') {
        Text(this.ssStatus)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.card'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.card_border') })
    .shadow({ radius: 20, color: $r('app.color.card_shadow'), offsetY: 6 })
  }

  @Builder AdvancedCard() {
    Column({ space: 12 }) {
      Row() {
        Text('高级设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.showAdvanced ? '收起' : '展开')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .onClick(() => {
        this.showAdvanced = !this.showAdvanced;
      })

      if (this.showAdvanced) {
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(1)
        Text('外部代理')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        TextInput({ text: this.proxyUrl, placeholder: '留空=直连；例如 http://192.168.1.2:7890' })
          .width('100%')
          .height(46)
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .onChange((value: string) => {
            this.proxyUrl = value;
          })
        Text('仅在未选择 SS 节点时生效；SS 节点优先。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Button('保存外部代理并重连')
          .width('100%')
          .height(44)
          .borderRadius(22)
          .backgroundColor($r('app.color.primary_bg'))
          .fontColor($r('app.color.primary'))
          .enabled(!this.busy)
          .onClick(() => {
            this.saveProxy();
          })
        Row() {
          Text('引擎：' + this.engineState)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Blank()
          Text('出口探测：' + (this.proxyOk === undefined ? '—' : this.proxyOk ? '可用' : '不可达'))
            .fontSize(11)
            .fontColor(this.proxyOk === false ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.card'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.card_border') })
  }

  @Builder AboutCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Image($r('app.media.logo'))
          .width(30)
          .height(30)
          .objectFit(ImageFit.Contain)
          .backgroundColor($r('app.color.primary'))
          .borderRadius(10)
          .padding(5)
        Column({ space: 2 }) {
          Text(APP_NAME)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(APP_SUBTITLE)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text('v' + this.appVersion)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      Text('SS 出口仅用于 Tailscale 控制面/DERP；不接管手机全局流量。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
      Text('引擎 ' + this.engineVersion)
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.card'))
    .borderRadius(24)
    .border({ width: 1, color: $r('app.color.card_border') })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_bg'))
      Scroll() {
        Column({ space: 16 }) {
          this.HeroCard()
          if (this.authUrl !== '') {
            this.AuthCard()
          }
          this.EgressCard()
          this.AdvancedCard()
          this.AboutCard()
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 18 + this.statusBarHeight, bottom: 28 + this.navBarHeight })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private loadSafeArea(): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        let avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        let ui = this.getUIContext();
        this.statusBarHeight = ui.px2vp(avoid.topRect.height);
        this.navBarHeight = ui.px2vp(avoid.bottomRect.height);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, TAG, 'getLastWindow failed: %{public}s', JSON.stringify(err) ?? '');
      });
    } catch (err) {
      hilog.warn(0x0000, TAG, 'loadSafeArea failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  private copyIp(): void {
    if (this.tsIps === '-') {
      return;
    }
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.tsIps);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.showToast('已复制 Tailscale IP');
      }).catch((err: BusinessError) => {
        this.showToast('复制失败');
      });
    } catch (err) {
      this.showToast('复制失败');
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      hilog.warn(0x0000, TAG, 'showToast failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  private confirmClearSs(): void {
    this.getUIContext().showAlertDialog({
      title: '清除内置出口？',
      message: '清除后将回退到外部代理或直连，Tailnet 可能需要重新连接。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.clearSsNode();
        }
      },
      cancel: () => {
      }
    });
  }

  private loadSsState(): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let ssPath = context.filesDir + '/tailnet/ss-node.json';
      let content = fs.readTextSync(ssPath);
      let data = JSON.parse(content) as SsNodeFile;
      if (data !== undefined && data !== null && data.name !== undefined && data.name !== null) {
        this.ssSelected = data.name;
        this.ssStatus = '当前主节点：' + data.name;
      }
    } catch (err) {
    }
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let yaml = context.filesDir + '/tailnet/clash-config.yaml';
      fs.accessSync(yaml);
      this.refreshSsNodes();
    } catch (err) {
    }
  }

  private refreshSsNodes(): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let yaml = context.filesDir + '/tailnet/clash-config.yaml';
      let raw = bridge.listSsNodes(yaml);
      let res = JSON.parse(raw) as SsListResult;
      if (res.ok === true && res.nodes !== undefined && res.nodes !== null) {
        this.ssNodes = res.nodes.map((n: SsNodeInfo): string => n.name);
      } else {
        this.ssStatus = `读取节点失败：${res.error ?? ''}`;
      }
    } catch (err) {
      this.ssStatus = `读取节点失败：${JSON.stringify(err) ?? ''}`;
    }
  }

  private async importClashConfig(): Promise<void> {
    if (this.ssBusy) {
      return;
    }
    this.ssBusy = true;
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let documentPicker = new picker.DocumentViewPicker(context);
      let options: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        fileSuffixFilters: ['YAML|.yaml']
      };
      let uris: string[] = await documentPicker.select(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return;
      }
      let dir = context.filesDir + '/tailnet';
      try {
        fs.mkdirSync(dir, true);
      } catch (mkdirErr) {
      }
      let dest = dir + '/clash-config.yaml';
      try {
        let src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
        fs.copyFileSync(src.fd, dest);
        fs.closeSync(src);
      } catch (copyErr) {
        let text = fs.readTextSync(uris[0]);
        let out = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(out.fd, text);
        fs.closeSync(out);
      }
      this.refreshSsNodes();
      this.ssStatus = '已导入：' + this.ssNodes.length + ' 个可用 SS 节点';
      this.showToast('已导入 ' + this.ssNodes.length + ' 个节点');
    } catch (err) {
      this.ssStatus = '导入失败：' + (JSON.stringify(err) ?? '');
      this.showToast('导入失败');
    } finally {
      this.ssBusy = false;
    }
  }

  private applySsNode(name: string): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let yaml = context.filesDir + '/tailnet/clash-config.yaml';
      let raw = bridge.selectSsNode(yaml, name);
      let res = JSON.parse(raw) as OpResult;
      if (res.ok === true) {
        this.ssSelected = name;
        this.ssStatus = '已选择：' + name + '；正在重启 VPN…';
        this.showToast('已切换出口：' + name);
        this.restartVpnWithNewProxy();
      } else {
        this.ssStatus = '选择失败：' + (res.error ?? '');
        this.showToast('切换出口失败');
      }
    } catch (err) {
      this.ssStatus = '选择失败：' + (JSON.stringify(err) ?? '');
      this.showToast('切换出口失败');
    }
  }

  private clearSsNode(): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      fs.unlinkSync(context.filesDir + '/tailnet/ss-node.json');
    } catch (err) {
    }
    this.ssSelected = '';
    this.ssStatus = '已清除内置出口，将使用外部代理/直连';
    this.showToast('已清除内置出口');
    this.restartVpnWithNewProxy();
  }

  private readStatusFile(): EngineStatus | undefined {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let path = context.filesDir + '/tailnet/status.json';
      let content = fs.readTextSync(path);
      return JSON.parse(content) as EngineStatus;
    } catch (err) {
      return undefined;
    }
  }

  // VPN 是否真正建立（扩展在 create 成功/回滚时写 vpn.json）。
  // UI 判定"已连接"必须是引擎 Running + VPN active，避免系统侧 VPN 被拆而 UI 说谎。
  private isVpnActive(): boolean {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let path = context.filesDir + '/tailnet/vpn.json';
      let content = fs.readTextSync(path);
      let vpn = JSON.parse(content) as VpnStateFile;
      if (vpn === undefined || vpn === null || vpn.active !== true) {
        return false;
      }
      // vpn.json 只在 create 时写一次；用引擎 status.json 的心跳判断新鲜度，
      // 避免 30s 后把正常连接误判为未连接。
      let st = this.readStatusFile();
      if (st === undefined || st.ok !== true) {
        return false;
      }
      let now = Math.floor(Date.now() / 1000);
      if (st.ts === undefined || st.ts === null || st.ts <= 0 || now - st.ts > STATUS_STALE_SECONDS) {
        return false;
      }
      return st.backendState === 'Running' || st.backendState === 'Starting';
    } catch (err) {
      return false;
    }
  }

  private hasNetwork(): boolean {
    try {
      return connection.hasDefaultNetSync();
    } catch (err) {
      // 查询失败时按有网处理，避免误报
      return true;
    }
  }

  // 引擎存活判定：心跳新鲜（≤30s）且处于有效状态（Running/Starting/NeedsLogin/NoState）
  private isEngineAlive(): boolean {
    let st = this.readStatusFile();
    if (st === undefined || st.ok !== true) {
      return false;
    }
    let now = Math.floor(Date.now() / 1000);
    if (st.ts === undefined || st.ts === null || st.ts <= 0 || now - st.ts > STATUS_STALE_SECONDS) {
      return false;
    }
    if (st.backendState === 'Running' && !this.isVpnActive()) {
      return false;
    }
    return st.backendState === 'Running' || st.backendState === 'Starting' ||
      st.backendState === 'NeedsLogin' || st.backendState === 'NoState';
  }

  private refreshEngineStatus(): void {
    let st = this.readStatusFile();
    if (st === undefined) {
      return;
    }
    this.engineState = (st.backendState !== undefined && st.backendState !== null) ? st.backendState : '-';
    this.authUrl = (st.authUrl !== undefined && st.authUrl !== null) ? st.authUrl : '';
    // IPv6 尚未启用（VpnConfig.isIPv6Accepted 默认 false），只展示 IPv4，避免误导
    this.tsIps = '-';
    let ips = st.tailscaleIps;
    if (ips !== undefined && ips !== null) {
      for (let i = 0; i < ips.length; i++) {
        if (ips[i].indexOf(':') < 0) {
          this.tsIps = ips[i];
          break;
        }
      }
    }
    if (st.backendState === 'Running' && this.isVpnActive() && this.hasNetwork()) {
      this.status = '已连接';
      this.connected = true;
    } else {
      this.connected = false;
    }
  }

  // 看门狗：引擎不存活则按退避策略自动重启 VPN 扩展（后台保活的唯一合规工程手段）
  private watchdogTick(): void {
    if (this.userDisconnected) {
      return;
    }
    if (this.isEngineAlive()) {
      this.backoffIdx = 0;
      this.nextRetryAt = 0;
      this.updateAliveStatus();
      return;
    }
    let now = Date.now();
    if (now < this.nextRetryAt) {
      return;
    }
    if (this.busy) {
      return;
    }
    hilog.info(0x0000, TAG, 'watchdog: engine not alive, restarting VPN extension (attempt %{public}d)',
      this.backoffIdx + 1);
    this.status = '连接异常，正在自动恢复…';
    this.connectVpn(true);
  }

  private scheduleBackoff(): void {
    let idx = this.backoffIdx < BACKOFF_STEPS_MS.length ? this.backoffIdx : BACKOFF_STEPS_MS.length - 1;
    this.nextRetryAt = Date.now() + BACKOFF_STEPS_MS[idx];
    this.backoffIdx++;
  }

  // 存活状态细分：Running / NoState（等待控制面，探测代理可达性）/ 其他（连接中）
  private updateAliveStatus(): void {
    let st = this.readStatusFile();
    let backend = (st !== undefined && st.backendState !== undefined && st.backendState !== null) ?
      st.backendState : '';
    if (backend === 'Running') {
      if (!this.hasNetwork()) {
        this.status = '无网络（VPN 待机中）';
        this.connected = false;
      } else if (this.isVpnActive()) {
        this.status = '已连接';
        this.connected = true;
        this.proxyOk = true;
      } else {
        this.status = 'VPN 未就绪（引擎运行中）';
        this.connected = false;
      }
      return;
    }
    if (backend === 'NoState') {
      this.connected = false;
      if (!this.hasNetwork()) {
        this.status = '无网络（等待恢复）';
        return;
      }
      this.maybeProbeProxy();
      this.status = this.proxyOk === false ?
        '等待控制面（代理不可达：请检查外部代理或 SS 节点）' : '等待控制面…';
      return;
    }
    this.connected = false;
    this.status = '正在连接…';
  }

  private maybeProbeProxy(): void {
    let now = Date.now();
    if (now - this.lastProbeAt < PROBE_MIN_INTERVAL_MS) {
      return;
    }
    this.lastProbeAt = now;
    this.probeProxy().then((ok: boolean) => {
      this.proxyOk = ok;
      hilog.info(0x0000, TAG, 'UI proxy probe: %{public}s', ok ? 'reachable' : 'unreachable');
    });
  }

  private probeProxy(): Promise<boolean> {
    let port = 7899;
    return new Promise<boolean>((resolve) => {
      let tcp = socket.constructTCPSocketInstance();
      let settled = false;
      let finish = (ok: boolean) => {
        if (settled) {
          return;
        }
        settled = true;
        tcp.close().catch(() => {
        });
        resolve(ok);
      };
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        try {
          let bytes = new Uint8Array(value.message);
          let n = Math.min(bytes.length, 12);
          let text = '';
          for (let i = 0; i < n; i++) {
            text += String.fromCharCode(bytes[i]);
          }
          if (text.startsWith('HTTP/1.1 200')) {
            finish(true);
          }
        } catch (err) {
          finish(false);
        }
      });
      tcp.connect({
        address: {
          address: '127.0.0.1',
          port: port,
          family: 1
        },
        timeout: PROXY_PROBE_TIMEOUT_MS
      }).then(() => {
        let req = 'CONNECT controlplane.tailscale.com:443 HTTP/1.1\r\nHost: controlplane.tailscale.com:443\r\n\r\n';
        tcp.send({ data: req }).catch((err: Error) => {
          hilog.warn(0x0000, TAG, 'UI proxy probe send failed: %{public}s', JSON.stringify(err) ?? '');
          finish(false);
        });
      }).catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'UI proxy probe connect failed: %{public}s', JSON.stringify(err) ?? '');
        finish(false);
      });
      setTimeout(() => {
        finish(false);
      }, PROXY_PROBE_TIMEOUT_MS + 500);
    });
  }

  private connectVpn(auto: boolean): void {
    if (this.busy) {
      return;
    }
    if (!auto) {
      this.userDisconnected = false;
      this.backoffIdx = 0;
      this.nextRetryAt = 0;
    }
    this.connected = false;
    this.busy = true;
    this.requestNotificationPermission();
    if (auto) {
      // 清理可能残留的旧通知（扩展被强杀场景）
      VpnNotification.cancelConnected();
    }
    vpnExtension.startVpnExtensionAbility(vpnWant).then(() => {
      hilog.info(0x0000, TAG, 'startVpnExtensionAbility resolved (auto=%{public}s)', auto ? 'true' : 'false');
      this.status = '已发起连接，等待引擎…';
      this.scheduleBackoff();
      this.busy = false;
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'startVpnExtensionAbility failed, code=%{public}d, msg=%{public}s', err.code,
        err.message);
      this.status = `启动失败：${err.code}`;
      this.scheduleBackoff();
      this.busy = false;
    });
  }

  private saveProxy(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let url = this.proxyUrl.trim();
    if (!ProxyConfig.write(context.filesDir, url)) {
      this.status = '代理保存失败';
      this.showToast('代理保存失败');
      return;
    }
    this.status = '代理已保存，正在重连…';
    this.showToast('外部代理已保存');
    this.restartVpnWithNewProxy();
  }

  private restartVpnWithNewProxy(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    vpnExtension.stopVpnExtensionAbility(vpnWant).then(() => {
      hilog.info(0x0000, TAG, 'stop for proxy change resolved');
      this.busy = false;
      this.backoffIdx = 0;
      this.nextRetryAt = 0;
      setTimeout(() => {
        if (!this.userDisconnected) {
          this.connectVpn(true);
        }
      }, 1500);
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'stop for proxy change failed, code=%{public}d, msg=%{public}s', err.code, err.message);
      this.busy = false;
    });
  }

  private disconnectVpn(): void {
    this.userDisconnected = true;
    this.busy = true;
    vpnExtension.stopVpnExtensionAbility(vpnWant).then(() => {
      hilog.info(0x0000, TAG, 'stopVpnExtensionAbility resolved');
      VpnNotification.cancelConnected();
      this.status = '未连接（本次会话不再自动重连）';
      this.connected = false;
      this.engineState = '-';
      this.authUrl = '';
      this.tsIps = '-';
      this.busy = false;
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'stopVpnExtensionAbility failed, code=%{public}d, msg=%{public}s', err.code,
        err.message);
      this.status = `断开失败：${err.code} ${err.message}`;
      this.busy = false;
    });
  }

  private openLoginPage(): void {
    let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(this.authUrl).then(() => {
      hilog.info(0x0000, TAG, 'openLink success');
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, 'openLink failed, code=%{public}d, msg=%{public}s', err.code, err.message);
    });
  }

  private requestNotificationPermission(): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      notificationManager.requestEnableNotification(context).then(() => {
        hilog.info(0x0000, TAG, 'requestEnableNotification success');
      }).catch((err: BusinessError) => {
        hilog.info(0x0000, TAG, 'requestEnableNotification: %{public}s', JSON.stringify(err) ?? '');
      });
    } catch (err) {
      hilog.error(0x0000, TAG, 'requestNotificationPermission error: %{public}s', JSON.stringify(err) ?? '');
    }
  }
}
