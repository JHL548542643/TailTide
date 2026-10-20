# 安全策略

## 不要提交密钥

本仓库不得包含：

- `.cache/clash-config.yaml`、`.cache/ss-node.json` 或任何真实 SS 节点密码；
- Tailscale auth key、SSH 私钥、token、签名材料；
- 个人 IP、设备序列号、家目录路径。

`.cache/` 与 `third_party/` 已在 `.gitignore` 中忽略。如发现仓库或其历史中存在密钥，请私下报告，不要开公开 issue。

## 报告漏洞

请通过托管平台的私有安全通告，或仓库资料中的联系方式联系维护者。请说明：

- 受影响版本/提交；
- 复现步骤；
- 影响（隐私、凭据泄露、VPN 绕过等）；
- 问题位于 App、Go 引擎还是第三方依赖。

## 范围

- App 将 SS 节点配置保存在私有沙箱；日志不得包含密码。
- SS 客户端仅用于 Tailscale 控制面/DERP，不是通用代理。
- 第三方依赖见 `THIRD_PARTY_NOTICES.md`；上游问题请报告给上游。
