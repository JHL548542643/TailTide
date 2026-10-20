# TailTide

面向 HarmonyOS 的私有 Tailscale 客户端，可选内置 Shadowsocks 出口（仅用于 Tailscale 控制面 / DERP）。

> **与 Tailscale Inc. 无关联**。"Tailscale" 仅用于说明互操作性。
>
> **与林俊杰无关联**。紫色仅灵感自应援色“紫海”，不代表任何官方背书。

![TailTide 图标](docs/assets/icon.png)

## 功能

- HarmonyOS 5/6/7（API 24+），ArkTS UI + VpnExtensionAbility + Go/tsnet 引擎。
- 仅声明 Tailscale TUN 路由 `100.64.0.0/10`，不做全局代理，手机其他流量不受影响。
- 内置轻量经典 Shadowsocks AEAD 客户端（aes-128/256-gcm，无插件）。
- 支持导入 Clash YAML，选择主节点，连接/握手失败时自动切换候选节点。
- 固定本地前置代理 `127.0.0.1:7899`；上游支持直连、外部 HTTP(S) 代理、SS。
- 连接状态来自引擎心跳，安装/重启后不会误报“已连接”。
- 浅色/深色主题、状态卡片、出口卡片、高级设置、复制 IP、Toast/对话框反馈。
- 无遥测。

## 架构

见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 构建

见 [docs/BUILD.md](docs/BUILD.md)。`third_party/` **不随仓库提供**，需按构建文档准备 Go 工具链、Tailscale 源码与补丁。

## 隐私

无遥测、无统计。SS 节点配置保存在应用沙箱。见 [PRIVACY.md](PRIVACY.md)。

## 安全

见 [SECURITY.md](SECURITY.md)。切勿提交 `.cache/`、`clash-config.yaml`、`ss-node.json`。

## 许可证

MIT，见 [LICENSE](LICENSE)。

## 第三方

见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目为个人项目，按“现状”提供，不提供任何担保。使用者需自行遵守 Tailscale 服务条款及 Shadowsocks 服务商条款。内置 SS 客户端仅用于 Tailscale 控制面/DERP，不作为全局代理。
