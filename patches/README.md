# 补丁目录（patches）

上游第三方代码的本地修改一律以 patch 文件形式存放于此，与上游 commit 绑定，可审计、可重放。

| 补丁 | 目标 | 基线 commit | 说明 |
|---|---|---|---|
| `tailscale-v1.86.5-ohos.patch` | `third_party/tailscale` | `db392aed39630023f969e1961fcbced785d09358`（tag v1.86.5） | 共 2 处：① 给 `tsnet.Server` 增加可选字段 `Tun tun.Device`，并在 `wgengine.Config` 中传入（数据面接入点）；② 真实 tun 模式下强制 `ns.ProcessLocalIPs/ProcessSubnets = false`（避免 netstack 拦截 100.64.0.0/10 回程包）。**Tun 为 nil 时行为与官方完全一致**。详见 ADR-005。 |

## 应用 / 撤销 / 校验

- 应用：`git -C third_party/tailscale apply ..\patches\tailscale-v1.86.5-ohos.patch`
- 撤销：`git -C third_party/tailscale checkout -- .`
- 校验：`git -C third_party/tailscale diff --stat`（应恰好 1 个文件变更，16 insertions）
