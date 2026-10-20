# 架构

```text
ArkTS UI（EntryAbility）
  │  status.json / vpn.json / control
  ▼
TailnetVpnAbility（VpnExtensionAbility）
  │  创建 VpnConnection，传入 tun FD
  ▼
Go 引擎（libtailscale_go.so，c-shared）
  ├─ tsnet.Server（Tailscale v1.86.5 + OHOS 补丁）
  ├─ 基于 VPN FD 的 tun.Device，MTU 1280
  ├─ 路由：仅 100.64.0.0/10（不做全局代理）
  └─ 本地 HTTP CONNECT 代理 127.0.0.1:7899
        ├─ 直连上游
        ├─ 外部 HTTP(S) 代理（proxy.json）
        └─ 轻量 SS AEAD 上游（ss-node.json + YAML 候选）
```

## 数据流

1. UI 通过 `startVpnExtensionAbility` 启动 VPN 扩展。
2. 扩展创建 `VpnConnection`，把 TUN FD 交给 Go 引擎。
3. 引擎在 `127.0.0.1:7899` 建立本地前置代理，并把 `HTTPS_PROXY`/`HTTP_PROXY` 指向它。URL 固定，模式切换不会让 `tshttpproxy` 的进程内缓存失效。
4. 本地代理选择上游：
   - SS：使用 `ss-node.json` 的主节点，连接/握手失败后切换剩余 YAML 候选；
   - 外部：HTTP CONNECT 链到配置的代理；
   - 直连：直接拨号。
5. tsnet 仅对控制面/DERP 使用本地代理；Tailnet 数据走 TUN 和显式的 `100.64.0.0/10` 路由。
6. 引擎持续写 `status.json` 心跳；UI 结合 `vpn.json`（VPN 已建立）判断连接状态。

## 有意的限制

- 不做全局代理，不接管整机 VPN 出口。
- SS 仅支持经典 AEAD（aes-128/256-gcm），不支持插件、SS2022。
- SS 配置只存在应用沙箱；密码不写日志。
- 故障转移覆盖连接/握手失败；节点能连上但控制面不可达的情况不会自动识别。
