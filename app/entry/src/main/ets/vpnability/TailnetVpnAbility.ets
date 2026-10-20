import { socket, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { VpnNotification } from './VpnNotification';
import { ProxyConfig } from '../common/ProxyConfig';
import bridge from 'libtailnet_bridge.so';

const TAG: string = 'TailnetVpnAbility';
const STATE_DIR_SUFFIX: string = '/tailnet';
const HOSTNAME: string = 'harmony-tailnet';
const STATUS_POLL_INTERVAL_MS: number = 10000;
const IP_WAIT_INTERVAL_MS: number = 3000;
const IP_WAIT_MAX_TRIES: number = 10;
const PROXY_PROBE_TIMEOUT_MS: number = 3000;
const NO_STATE_KICK_AFTER_MS: number = 60000;
const PROBE_MIN_INTERVAL_MS: number = 30000;
const KICK_MIN_INTERVAL_MS: number = 300000;
const CREATE_RETRY_DELAYS_MS: number[] = [15000, 30000, 60000, 120000, 300000];
const INIT_RETRY_DELAY_MS: number = 3000;

interface EngineStatusLite {
  ok: boolean;
  backendState?: string;
  authUrl?: string;
  tailscaleIps?: string[];
  tunReadPkts?: number;
  tunWritePkts?: number;
}

interface OpResult {
  ok: boolean;
  error?: string;
}

interface VpnStateFile {
  active: boolean;
  ts: number;
}

interface LastIpFile {
  ip: string;
}

export default class TailnetVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  private statusTimer: number = -1;
  private ipWaitTimer: number = -1;
  private ipWaitTries: number = 0;
  private initRetryTimer: number = -1;
  private configureRetryTimer: number = -1;
  private configureAttempt: number = 0;
  // 显式阶段：idle -> noTun -> configuring -> running / error
  private phase: string = 'idle';
  private vpnConfigured: boolean = false;
  private noStateSince: number = 0;
  private lastProbeAt: number = 0;
  private lastKickAt: number = 0;
  private kickInFlight: boolean = false;
  private proxyUrl: string = ProxyConfig.defaultUrl();
  private configuredIp: string = '';
  private lastReconfigAt: number = 0;
  private destroying: boolean = false;
  private lastLoggedBackend: string = '';
  private logReadOffset: number = -1;

  onCreate(want: Want): void {
    hilog.info(0x0000, TAG, 'onCreate, want: %{public}s', want.abilityName);
    this.proxyUrl = ProxyConfig.read(this.context.filesDir);
    hilog.info(0x0000, TAG, 'external proxy config: %{public}s', this.proxyUrl);
    try {
      if (typeof bridge.engineVersion === 'function') {
        hilog.info(0x0000, TAG, 'engine version: %{public}s', bridge.engineVersion());
      } else {
        hilog.warn(0x0000, TAG, 'engineVersion API missing (engine/HAP build mismatch)');
      }
      if (typeof bridge.stopEngineQuiet !== 'function' || typeof bridge.kickRestart !== 'function') {
        hilog.warn(0x0000, TAG, 'sync bridge capability missing (engine/HAP mismatch)');
      }
      if (typeof bridge.stopEngineQuietAsync !== 'function' || typeof bridge.kickRestartAsync !== 'function') {
        hilog.warn(0x0000, TAG, 'async bridge capability missing; will fall back to sync calls');
      }
    } catch (err) {
      hilog.error(0x0000, TAG, 'bridge capability check failed: %{public}s', JSON.stringify(err) ?? '');
    }
    this.initVpnConnection();
  }

  private initVpnConnection(): void {
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      hilog.info(0x0000, TAG, 'createVpnConnection success');
      this.protectProcessAndStartEngine();
    } catch (err) {
      hilog.error(0x0000, TAG, 'createVpnConnection failed: %{public}s', JSON.stringify(err) ?? '');
      if (this.initRetryTimer !== -1) {
        return;
      }
      this.initRetryTimer = setTimeout(() => {
        this.initRetryTimer = -1;
        this.initVpnConnection();
      }, INIT_RETRY_DELAY_MS);
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
    this.destroying = true;
    this.clearTimer(this.statusTimer);
    this.statusTimer = -1;
    this.clearTimer(this.ipWaitTimer);
    this.ipWaitTimer = -1;
    this.clearTimer(this.configureRetryTimer);
    this.configureRetryTimer = -1;
    this.clearTimer(this.initRetryTimer);
    this.initRetryTimer = -1;
    VpnNotification.cancelConnected();
    this.vpnConfigured = false;
    this.phase = 'idle';
    this.writeVpnActive(false);
    // 先停引擎（fdTun.Close 关闭 tun fd），再 destroy（网络清理）。
    // 这里使用普通 stopEngine（写 Stopped），让 UI 看门狗感知扩展死亡并自动拉起。
    let stopResult = bridge.stopEngine();
    hilog.info(0x0000, TAG, 'stopEngine result: %{public}s', stopResult);
    this.vpnConnection?.destroy().then(() => {
      hilog.info(0x0000, TAG, 'vpn destroy success');
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'vpn destroy failed: %{public}s', JSON.stringify(err) ?? '');
    });
  }

  private clearTimer(timer: number): void {
    if (timer !== -1) {
      clearTimeout(timer);
    }
  }

  // 官方时序（js-apis-net-vpnExtension.md protectProcessNet 示例）：先保护进程
  //（引擎后续创建的 socket 直走物理网络，不进入 VPN 路由）。
  private protectProcessAndStartEngine(): void {
    this.vpnConnection?.protectProcessNet().then(() => {
      hilog.info(0x0000, TAG, 'protectProcessNet success');
      this.startEngineOrFastPath();
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'protectProcessNet failed: %{public}s', JSON.stringify(err) ?? '');
      this.startEngineOrFastPath();
    });
  }

  // 冷启动快速路径：若缓存过 tailnet IP，直接建 VPN 并带 tun 启动引擎，
  // 跳过"无 tun 取 IP"阶段（省一次 stop/start）；IP 失效时由状态轮询自愈。
  private startEngineOrFastPath(): void {
    if (this.destroying) {
      return;
    }
    let cached = this.readCachedIp();
    if (cached !== '') {
      hilog.info(0x0000, TAG, 'fast start with cached tailnet IP: %{public}s', cached);
      this.configureVpnAndRestartEngine(cached);
      return;
    }
    this.startEngineWithoutTun();
  }

  // 第一阶段：不带 tun 启动引擎，用于从持久化状态取得本机 tailnet IP
  private startEngineWithoutTun(): void {
    let stateDir = this.context.filesDir + STATE_DIR_SUFFIX;
    let result = bridge.startEngine(stateDir, HOSTNAME, this.proxyUrl, -1);
    let ok = this.isOkResult(result) || result.indexOf('already started') >= 0;
    hilog.info(0x0000, TAG, 'startEngine(no tun) ok=%{public}s result: %{public}s', ok ? 'true' : 'false', result);
    if (!ok) {
      // 引擎未启动：按退避重试（避免永久停留 NoState）
      this.scheduleConfigureRetry();
      this.startStatusPolling();
      return;
    }
    this.phase = 'noTun';
    this.waitForTailscaleIps();
  }

  // 等待 tailnet IP（已登录设备来自持久化状态，通常 1~3 秒）
  private waitForTailscaleIps(): void {
    if (this.ipWaitTimer !== -1) {
      clearInterval(this.ipWaitTimer);
    }
    this.ipWaitTries = 0;
    this.ipWaitTimer = setInterval(() => {
      this.ipWaitTries++;
      let raw = bridge.getStatus();
      let ip = this.extractV4(raw);
      if (ip !== '') {
        clearInterval(this.ipWaitTimer);
        this.ipWaitTimer = -1;
        this.configureVpnAndRestartEngine(ip);
        return;
      }
      if (this.ipWaitTries >= IP_WAIT_MAX_TRIES) {
        clearInterval(this.ipWaitTimer);
        this.ipWaitTimer = -1;
        hilog.warn(0x0000, TAG, 'no Tailscale IP yet (login pending); keep engine running without tun');
        this.startStatusPolling();
      }
    }, IP_WAIT_INTERVAL_MS);
  }

  private extractV4(raw: string): string {
    try {
      let st = JSON.parse(raw) as EngineStatusLite;
      if (st.ok && st.tailscaleIps !== undefined && st.tailscaleIps !== null) {
        for (let i = 0; i < st.tailscaleIps.length; i++) {
          if (st.tailscaleIps[i].indexOf(':') < 0) {
            return st.tailscaleIps[i];
          }
        }
      }
    } catch (err) {
      // ignore
    }
    return '';
  }

  private isOkResult(raw: string): boolean {
    try {
      let r = JSON.parse(raw) as OpResult;
      return r.ok === true;
    } catch (err) {
      return false;
    }
  }

  private readCachedIp(): string {
    try {
      let path = this.context.filesDir + STATE_DIR_SUFFIX + '/last_ip.json';
      let content = fs.readTextSync(path);
      let data = JSON.parse(content) as LastIpFile;
      if (data !== undefined && data !== null && this.isValidIpv4(data.ip)) {
        return data.ip;
      }
    } catch (err) {
      // 缓存不存在或损坏：走完整两阶段流程
    }
    return '';
  }

  private writeCachedIp(ip: string): void {
    try {
      let dir = this.context.filesDir + STATE_DIR_SUFFIX;
      let file = fs.openSync(dir + '/last_ip.json', fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let data: LastIpFile = { ip: ip };
      fs.writeSync(file.fd, JSON.stringify(data));
      fs.closeSync(file);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'write last_ip.json failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  private isValidIpv4(value: string): boolean {
    if (value === undefined || value === null || value.length === 0) {
      return false;
    }
    let parts = value.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      let part = parts[i];
      if (part.length === 0 || part.length > 3) {
        return false;
      }
      for (let j = 0; j < part.length; j++) {
        let code = part.charCodeAt(j);
        if (code < 48 || code > 57) {
          return false;
        }
      }
      let n = parseInt(part);
      if (n < 0 || n > 255) {
        return false;
      }
    }
    return true;
  }

  // 第二阶段：以真实 tailnet IP 作为 vpn-tun 地址建立 VPN（源码依据：tstun selectSrcIP，
  // 源地址必须等于本节点 tailnet IP，否则出向包会被对端按防伪造丢弃），再带 tun 重启引擎。
  private configureVpnAndRestartEngine(ip: string): void {
    if (this.vpnConfigured || this.phase === 'configuring') {
      return;
    }
    this.phase = 'configuring';
    if (this.configureRetryTimer !== -1) {
      clearTimeout(this.configureRetryTimer);
      this.configureRetryTimer = -1;
    }
    // 阶段切换使用静默停止（异步）：不写 Stopped，避免 UI 看门狗误判，且不阻塞 JS 线程
    let config: vpnExtension.VpnConfig = {
      addresses: [
        {
          address: {
            address: ip,
            family: 1
          },
          prefixLength: 32
        }
      ],
      routes: [
        {
          interface: 'vpn-tun',
          destination: {
            address: {
              address: '100.64.0.0',
              family: 1
            },
            prefixLength: 10
          },
          gateway: {
            address: '',
            family: 1
          },
          hasGateway: false,
          isDefaultRoute: false
        }
      ],
      // 与引擎侧 tunMTU 一致，依据 tstun/mtu.go safeTUNMTU=1280
      mtu: 1280,
      isBlocking: true
    };
    this.stopEngineQuietPromise().then((stopResult: string) => {
      hilog.info(0x0000, TAG, 'stopEngineQuiet result: %{public}s', stopResult);
      if (this.destroying || this.phase !== 'configuring') {
        return;
      }
      this.createVpnThenStartEngine(config, ip, false);
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'stopEngineQuiet failed: %{public}s', JSON.stringify(err) ?? '');
      this.rollbackToNoTun('stopEngineQuiet failed');
    });
  }

  private createVpnThenStartEngine(config: vpnExtension.VpnConfig, ip: string, isRetry: boolean): void {
    this.vpnConnection?.create(config).then((tunFd: number) => {
      hilog.info(0x0000, TAG, 'vpn create success, tunFd: %{public}d', tunFd);
      this.writeVpnActive(true);
      VpnNotification.publishConnected();
      let stateDir = this.context.filesDir + STATE_DIR_SUFFIX;
      let result = bridge.startEngine(stateDir, HOSTNAME, this.proxyUrl, tunFd);
      let ok = this.isOkResult(result);
      hilog.info(0x0000, TAG, 'startEngine(tun) ok=%{public}s result: %{public}s', ok ? 'true' : 'false', result);
      if (!ok) {
        // VPN 已接管 100.64/10 但引擎未运行 = 流量黑洞：立即拆掉并回滚
        this.rollbackToNoTun('startEngine(tun) failed');
        return;
      }
      this.configureAttempt = 0;
      this.vpnConfigured = true;
      this.phase = 'running';
      this.configuredIp = ip;
      this.writeCachedIp(ip);
      this.logEngineSummary(true);
      this.startStatusPolling();
    }).catch((err: Error) => {
      let detail = JSON.stringify(err) ?? '';
      hilog.error(0x0000, TAG, 'vpn create failed: %{public}s', detail);
      // 2203002 = VPN exist already：常见于上一实例被系统/重装强杀后遗留的孤儿 VPN。
      // 官方文档要求先 destroy 再 create，这里自动清理并重试一次。
      if (!isRetry && detail.indexOf('2203002') >= 0) {
        this.recoverStaleVpnAndRetry(config, ip);
        return;
      }
      this.rollbackToNoTun('vpn create failed');
    });
  }

  private recoverStaleVpnAndRetry(config: vpnExtension.VpnConfig, ip: string): void {
    hilog.warn(0x0000, TAG, 'stale vpn detected, destroy then retry create');
    let old = this.vpnConnection;
    let rebuild = () => {
      try {
        this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      } catch (err) {
        hilog.error(0x0000, TAG, 'recreate connection failed: %{public}s', JSON.stringify(err) ?? '');
        this.rollbackToNoTun('recreate connection failed');
        return;
      }
      this.vpnConnection.protectProcessNet().then(() => {
        hilog.info(0x0000, TAG, 'protectProcessNet success (retry)');
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, 'protectProcessNet failed (retry): %{public}s', JSON.stringify(err) ?? '');
      });
      setTimeout(() => {
        if (this.vpnConfigured || this.phase !== 'configuring') {
          return;
        }
        this.createVpnThenStartEngine(config, ip, true);
      }, 800);
    };
    if (old !== undefined) {
      old.destroy().then(() => {
        hilog.info(0x0000, TAG, 'stale vpn destroy success');
        rebuild();
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, 'stale vpn destroy failed: %{public}s', JSON.stringify(err) ?? '');
        rebuild();
      });
    } else {
      rebuild();
    }
  }

  // 阶段二失败回滚：拆掉 VPN（避免黑洞）→ 恢复无 tun 引擎 → 退避重试
  private rollbackToNoTun(reason: string): void {
    if (this.destroying) {
      return;
    }
    hilog.warn(0x0000, TAG, 'rollback to no-tun engine: %{public}s', reason);
    this.vpnConfigured = false;
    this.phase = 'error';
    this.writeVpnActive(false);
    VpnNotification.cancelConnected();
    let old = this.vpnConnection;
    let done = () => {
      try {
        this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      } catch (err) {
        hilog.error(0x0000, TAG, 'recreate connection after rollback failed: %{public}s', JSON.stringify(err) ?? '');
      }
      this.vpnConnection?.protectProcessNet().then(() => {
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, 'protectProcessNet failed (rollback): %{public}s', JSON.stringify(err) ?? '');
      });
      let stateDir = this.context.filesDir + STATE_DIR_SUFFIX;
      let result = bridge.startEngine(stateDir, HOSTNAME, this.proxyUrl, -1);
      let ok = this.isOkResult(result) || result.indexOf('already started') >= 0;
      hilog.info(0x0000, TAG, 'rollback startEngine(no tun) ok=%{public}s result: %{public}s', ok ? 'true' : 'false',
        result);
      if (ok) {
        this.phase = 'noTun';
      }
      this.scheduleConfigureRetry();
      this.startStatusPolling();
    };
    if (old !== undefined) {
      old.destroy().then(() => {
        done();
      }).catch((err: Error) => {
        hilog.error(0x0000, TAG, 'rollback vpn destroy failed: %{public}s', JSON.stringify(err) ?? '');
        done();
      });
    } else {
      done();
    }
  }

  private scheduleConfigureRetry(): void {
    if (this.configureRetryTimer !== -1) {
      return;
    }
    let idx = this.configureAttempt < CREATE_RETRY_DELAYS_MS.length ?
      this.configureAttempt : CREATE_RETRY_DELAYS_MS.length - 1;
    let delay = CREATE_RETRY_DELAYS_MS[idx];
    this.configureAttempt++;
    hilog.info(0x0000, TAG, 'schedule retry #%{public}d in %{public}dms', this.configureAttempt, delay);
    this.configureRetryTimer = setTimeout(() => {
      this.configureRetryTimer = -1;
      if (this.destroying) {
        return;
      }
      let raw = bridge.getStatus();
      let st = this.parseStatus(raw);
      if (st === undefined || st.ok !== true) {
        // 引擎不在运行：先恢复无 tun 引擎
        this.startEngineWithoutTun();
        return;
      }
      let ip = this.extractV4(raw);
      if (ip !== '') {
        this.configureVpnAndRestartEngine(ip);
      } else {
        this.scheduleConfigureRetry();
      }
    }, delay);
  }

  private startStatusPolling(): void {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
    }
    this.statusTimer = setInterval(() => {
      this.statusPollTick();
    }, STATUS_POLL_INTERVAL_MS);
  }

  private statusPollTick(): void {
    let raw = bridge.getStatus();
    let st = this.parseStatus(raw);
    this.logEngineSummaryFrom(st, raw, false);
    this.pumpEngineLog();
    if (st === undefined || st.ok !== true) {
      return;
    }
    if (st.backendState === 'NoState') {
      if (this.noStateSince === 0) {
        this.noStateSince = Date.now();
      }
      this.maybeKickControlPlane();
    } else {
      this.noStateSince = 0;
    }
    // 缓存 IP 与实际 netmap 不一致（节点重分配）：重建 VPN，避免源地址错误丢包
    if (this.vpnConfigured && this.phase === 'running') {
      let actualIp = this.extractV4(raw);
      if (actualIp !== '' && actualIp !== this.configuredIp && Date.now() - this.lastReconfigAt > 60000) {
        this.lastReconfigAt = Date.now();
        this.reconfigureWithIp(actualIp);
        return;
      }
    }
    // 登录完成后补做 VPN 配置（首次使用/离线恢复场景）；重试计时器存在时由其负责
    if (!this.vpnConfigured && this.phase === 'noTun' && this.configureRetryTimer === -1) {
      let ip = this.extractV4(raw);
      if (ip !== '') {
        this.configureVpnAndRestartEngine(ip);
      }
    }
  }

  private parseStatus(raw: string): EngineStatusLite | undefined {
    try {
      return JSON.parse(raw) as EngineStatusLite;
    } catch (err) {
      return undefined;
    }
  }

  private stopEngineQuietPromise(): Promise<string> {
    if (typeof bridge.stopEngineQuietAsync === 'function') {
      return bridge.stopEngineQuietAsync();
    }
    if (typeof bridge.stopEngineQuiet === 'function') {
      return Promise.resolve(bridge.stopEngineQuiet());
    }
    return Promise.resolve(bridge.stopEngine());
  }

  private kickRestartPromise(): Promise<string> {
    let stateDir = this.context.filesDir + STATE_DIR_SUFFIX;
    if (typeof bridge.kickRestartAsync === 'function') {
      return bridge.kickRestartAsync(stateDir, HOSTNAME, this.proxyUrl);
    }
    if (typeof bridge.kickRestart === 'function') {
      return Promise.resolve(bridge.kickRestart(stateDir, HOSTNAME, this.proxyUrl));
    }
    return Promise.resolve('{"ok":false,"error":"kickRestart missing"}');
  }

  // 缓存的 IP 已失效（节点重分配/IP 变更）：停引擎 → 拆 VPN → 用新 IP 重建
  private reconfigureWithIp(newIp: string): void {
    hilog.warn(0x0000, TAG, 'tailnet IP changed: configured=%{public}s actual=%{public}s; reconfiguring',
      this.configuredIp, newIp);
    this.vpnConfigured = false;
    this.phase = 'configuring';
    VpnNotification.cancelConnected();
    this.writeVpnActive(false);
    this.stopEngineQuietPromise().then(() => {
      if (this.destroying) {
        return;
      }
      let old = this.vpnConnection;
      let done = () => {
        if (this.destroying) {
          return;
        }
        try {
          this.vpnConnection = vpnExtension.createVpnConnection(this.context);
        } catch (err) {
          hilog.error(0x0000, TAG, 'recreate connection failed: %{public}s', JSON.stringify(err) ?? '');
          this.rollbackToNoTun('recreate connection failed');
          return;
        }
        this.vpnConnection.protectProcessNet().then(() => {
        }).catch((err: Error) => {
          hilog.error(0x0000, TAG, 'protectProcessNet failed (reconfigure): %{public}s', JSON.stringify(err) ?? '');
        });
        this.phase = 'noTun';
        this.configureVpnAndRestartEngine(newIp);
      };
      if (old !== undefined) {
        old.destroy().then(() => {
          done();
        }).catch((err: Error) => {
          hilog.error(0x0000, TAG, 'reconfigure destroy failed: %{public}s', JSON.stringify(err) ?? '');
          done();
        });
      } else {
        done();
      }
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'reconfigure stop failed: %{public}s', JSON.stringify(err) ?? '');
      this.rollbackToNoTun('reconfigure stop failed');
    });
  }

  private logEngineSummary(force: boolean): void {
    let raw = bridge.getStatus();
    this.logEngineSummaryFrom(this.parseStatus(raw), raw, force);
  }

  // 摘要日志（不含 AuthURL），仅在 backendState 变化或强制时输出
  private logEngineSummaryFrom(st: EngineStatusLite | undefined, raw: string, force: boolean): void {
    if (st === undefined) {
      hilog.warn(0x0000, TAG, 'engine status unavailable');
      return;
    }
    let backend = (st.backendState !== undefined && st.backendState !== null) ? st.backendState : '-';
    if (!force && backend === this.lastLoggedBackend) {
      return;
    }
    this.lastLoggedBackend = backend;
    let ip = this.extractV4(raw);
    let r = (st.tunReadPkts !== undefined && st.tunReadPkts !== null) ? st.tunReadPkts : 0;
    let w = (st.tunWritePkts !== undefined && st.tunWritePkts !== null) ? st.tunWritePkts : 0;
    hilog.info(0x0000, TAG, 'engine: backend=%{public}s ip=%{public}s read=%{public}d write=%{public}d', backend,
      ip !== '' ? ip : '-', r, w);
  }

  // 控制面长等（NoState）：先探测代理是否可达，可达则重启引擎重置退避；
  // 不可达则保持等待（代理是开发期 hdc rport，手机侧无法自建）。
  private maybeKickControlPlane(): void {
    let now = Date.now();
    if (now - this.noStateSince < NO_STATE_KICK_AFTER_MS) {
      return;
    }
    if (this.kickInFlight || now - this.lastProbeAt < PROBE_MIN_INTERVAL_MS) {
      return;
    }
    this.lastProbeAt = now;
    this.kickInFlight = true;
    this.probeProxy().then((ok: boolean) => {
      if (!ok) {
        this.kickInFlight = false;
        hilog.warn(0x0000, TAG, 'control plane waiting: proxy unreachable, keep waiting');
        return;
      }
      if (this.vpnConfigured || this.phase === 'configuring' || this.destroying) {
        this.kickInFlight = false;
        return;
      }
      if (Date.now() - this.lastKickAt < KICK_MIN_INTERVAL_MS) {
        this.kickInFlight = false;
        return;
      }
      this.lastKickAt = Date.now();
      this.noStateSince = Date.now();
      hilog.warn(0x0000, TAG, 'control plane stuck in NoState but proxy reachable; restart engine to reset backoff');
      // 引擎内原子重启（抑制 "Stopped" 落盘）；异步执行避免阻塞扩展 JS 线程
      this.kickRestartPromise().then((result: string) => {
        this.kickInFlight = false;
        hilog.info(0x0000, TAG, 'kick: kickRestart result: %{public}s', result);
      }).catch((err: Error) => {
        this.kickInFlight = false;
        hilog.error(0x0000, TAG, 'kick failed: %{public}s', JSON.stringify(err) ?? '');
      });
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
          hilog.warn(0x0000, TAG, 'proxy probe send failed: %{public}s', JSON.stringify(err) ?? '');
          finish(false);
        });
      }).catch((err: Error) => {
        hilog.warn(0x0000, TAG, 'proxy probe connect failed: %{public}s', JSON.stringify(err) ?? '');
        finish(false);
      });
      setTimeout(() => {
        finish(false);
      }, PROXY_PROBE_TIMEOUT_MS + 500);
    });
  }

  // 供 UI 判定"已连接"的旁路标记（VPN 是否真的已建立）
  private writeVpnActive(active: boolean): void {
    try {
      let dir = this.context.filesDir + STATE_DIR_SUFFIX;
      let file = fs.openSync(dir + '/vpn.json', fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      let state: VpnStateFile = { active: active, ts: Math.floor(Date.now() / 1000) };
      fs.writeSync(file.fd, JSON.stringify(state));
      fs.closeSync(file);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'write vpn.json failed: %{public}s', JSON.stringify(err) ?? '');
    }
  }

  // 诊断：增量把 engine.log 新内容泵到 hilog（不依赖 UI 进程存活），
  // 过滤 netcheck 与 AuthURL/login URL，单次最多 40 行。
  private pumpEngineLog(): void {
    let file: fs.File | undefined = undefined;
    try {
      let path = this.context.filesDir + STATE_DIR_SUFFIX + '/engine.log';
      let stat = fs.statSync(path);
      if (stat.size <= 0) {
        return;
      }
      if (this.logReadOffset < 0) {
        this.logReadOffset = stat.size > 8192 ? stat.size - 8192 : 0;
      }
      if (this.logReadOffset >= stat.size) {
        return;
      }
      let remain = stat.size - this.logReadOffset;
      let readLen = remain > 65536 ? 65536 : remain;
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(readLen);
      let n = fs.readSync(file.fd, buf, { offset: this.logReadOffset, length: readLen });
      if (n <= 0) {
        return;
      }
      this.logReadOffset += n;
      let decoder = util.TextDecoder.create('utf-8');
      let text = decoder.decodeToString(new Uint8Array(buf, 0, n));
      let lines = text.split('\n');
      let emitted = 0;
      for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        if (line.length === 0 || line.indexOf('netcheck:') >= 0 ||
          line.indexOf('login.tailscale.com') >= 0 || line.indexOf('AuthURL') >= 0) {
          continue;
        }
        if (line.length > 400) {
          line = line.substring(0, 400);
        }
        hilog.info(0x0000, 'EngineLogExt', '%{public}s', line);
        emitted++;
        if (emitted >= 40) {
          break;
        }
      }
    } catch (err) {
      // 静默：日志泵失败不影响主流程
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (err) {
          // ignore
        }
      }
    }
  }
}
