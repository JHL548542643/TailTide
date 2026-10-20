# ss-probe（Shadowsocks 出站可行性探针）

用途：验证“最小 SS AEAD 客户端 + 本地 HTTP CONNECT”能否在 PC 上连到 Tailscale 控制面。
这是探针，不修改 App。

## 前提

- 官方 AEAD 规范已归档：docs/references/shadowsocks/
- 支持经典 SS AEAD：aes-128-gcm / aes-256-gcm；不支持 SS2022、plugin、UDP
- 节点配置来自本地 Clash YAML，密码只写入 .cache（gitignored）

## 用法

~~~powershell
# 1. 列出候选（type=ss, cipher=aes-256-gcm, 无 plugin）
python tools/ss-probe/extract_node.py --list

# 2. 选一个节点，写出 .cache/ss-node.json（含密码，不要入库）
python tools/ss-probe/extract_node.py --name <node-name>

# 3. 构建并在 PC 上测试控制面
go build -C tools/ss-probe -o ..\..\.cache\ss-probe.exe .
.\.cache\ss-probe.exe -test
~~~

也可以不带 -test 常驻本地代理，然后用其他工具测试：

~~~powershell
.\.cache\ss-probe.exe -listen 127.0.0.1:7899
curl.exe -x http://127.0.0.1:7899 -I https://controlplane.tailscale.com/
~~~

## 输出

- 只打印节点名、端口、cipher、目标、状态；不打印密码
- 成功示例：test OK target=https://controlplane.tailscale.com/ status=...