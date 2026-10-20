# 隐私

## 无遥测

TailTide 不收集分析、遥测、广告标识或崩溃报告，App 内没有账号系统。

## 本地数据

- SS 节点配置（含节点密码）保存在应用私有沙箱：`filesDir/tailnet/clash-config.yaml`、`filesDir/tailnet/ss-node.json`。
- 日志仅本地，不记录密码。
- 卸载 App 会删除沙箱数据。

## 网络流量

- Tailnet 流量由 Tailscale 引擎（WireGuard/DERP）处理，使用使用者自己的 Tailscale 账号。
- 启用内置 SS 出口时，Tailscale 控制面/DERP 的连接会经使用者选择的 Shadowsocks 服务器中转。该服务器及其运营者可能看到连接元数据，请选择可信服务商。
- App **不会**把手机全局流量交给 SS 服务器；只有 Tailscale 引擎使用本地前置代理。

## 第三方

Tailscale、Shadowsocks 服务商、HarmonyOS 平台各有自己的隐私政策。本项目与它们无关联。
