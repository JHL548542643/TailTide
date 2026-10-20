import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ProxyConfig';

interface ProxyConfigData {
  url: string;
}

// 控制面代理配置：持久化在 filesDir/tailnet/proxy.json（{ "url": "http://host:port" }）。
// 默认沿用开发期 hdc rport 通道；UI 可改为局域网/路由代理，留空表示直连。
export class ProxyConfig {
  static defaultUrl(): string {
    return 'http://127.0.0.1:7890';
  }

  static read(filesDir: string): string {
    try {
      let path = filesDir + '/tailnet/proxy.json';
      let content = fs.readTextSync(path);
      let data = JSON.parse(content) as ProxyConfigData;
      if (data !== undefined && data !== null && data.url !== undefined && data.url !== null) {
        return data.url;
      }
    } catch (err) {
      // 文件不存在/解析失败：使用默认值
    }
    return ProxyConfig.defaultUrl();
  }

  static write(filesDir: string, url: string): boolean {
    try {
      let dir = filesDir + '/tailnet';
      try {
        fs.mkdirSync(dir, true);
      } catch (err) {
        // 目录已存在
      }
      let data: ProxyConfigData = { url: url };
      let file = fs.openSync(dir + '/proxy.json',
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(data));
      fs.closeSync(file);
      hilog.info(0x0000, TAG, 'proxy config saved: %{public}s', url);
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, 'write proxy config failed: %{public}s', JSON.stringify(err) ?? '');
      return false;
    }
  }
}
