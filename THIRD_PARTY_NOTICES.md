# 第三方组件声明

TailTide 包含或依赖以下第三方软件/规范。本文件仅供参考，授权以各上游项目为准。

| 组件 | 版本/来源 | 许可证 | 链接 |
|---|---|---|---|
| Tailscale（tsnet、控制面、DERP） | v1.86.5，含 `patches/` 补丁 | BSD-3-Clause | https://github.com/tailscale/tailscale |
| wireguard-go | 随 Tailscale v1.86.5 锁定 | MIT | https://github.com/tailscale/wireguard-go |
| gVisor netstack | 随 Tailscale v1.86.5 锁定 | Apache-2.0 | https://github.com/google/gvisor |
| go-yaml | v2.4.0 | Apache-2.0 | https://github.com/go-yaml/yaml |
| OpenHarmony Go 工具链 | 构建依赖，不随仓库分发 | BSD-3-Clause | https://gitee.com/openharmony/third_party_go |
| Shadowsocks AEAD / SIP002 规范 | `docs/references/shadowsocks/` 存档 | MIT（站点页脚） | https://shadowsocks.org/ |
| RFC 1928（SOCKS5） | 存档于 `docs/references/shadowsocks/rfc1928.txt` | IETF Trust | https://www.rfc-editor.org/rfc/rfc1928 |
| RFC 9110 §9.3.6（HTTP CONNECT） | 摘要见 `docs/references/http-connect.md` | IETF Trust | https://www.rfc-editor.org/rfc/rfc9110 |

## 不再分发

- HarmonyOS SDK 声明文件与 OpenHarmony 文档**不**包含在本公开仓库中；请参考华为/OpenHarmony 官方文档及本机安装的 SDK。
- `third_party/` 不随仓库提供；见 `docs/BUILD.md`。

## 商标

"Tailscale" 是 Tailscale Inc. 的商标。本项目与 Tailscale Inc. 无关联，也未获其背书。"TailTide" 是本个人项目的名称。紫色灵感自应援色，不代表与任何艺人存在关联。
