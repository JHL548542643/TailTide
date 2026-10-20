# 构建

本仓库**不**内置 `third_party/`。引擎需要 OpenHarmony Go 工具链和打好补丁的 Tailscale 源码。

## 前置条件

- 安装 DevEco Studio 与 HarmonyOS SDK（兼容 API 24；在 API 26 设备上测试）。
- Windows PowerShell。
- OpenHarmony Go 工具链（Go 1.24.x 交叉构建）位于 `third_party/ohos-go`。
- Tailscale v1.86.5 源码位于 `third_party/tailscale`，并应用 `patches/tailscale-v1.86.5-ohos.patch`。
- Tailscale 依赖（wireguard-go、gVisor、go-yaml）可通过 Go module cache 获取。

## 引擎

```powershell
.\tools\build-engine.ps1
```

交叉编译 `engine/` 到 `app/entry/libs/arm64-v8a/libtailscale_go.so`，并复制生成的头文件。

## HAP

```powershell
.\tools\build-hap.ps1
# 可选：安装到已连接设备
.\tools\build-hap.ps1 -Install -Device <device-serial>
```

公开包名为 `com.tailtide.app`。请在 DevEco Studio 配置自己的签名；仓库不包含签名材料。

## 签名（生成可安装 HAP 必需）

`app/build-profile.json5` 已被 gitignore，以避免签名材料入库。全新 checkout 只有 `app/build-profile.example.json5`。

```powershell
Copy-Item app/build-profile.example.json5 app/build-profile.json5
```

然后在 DevEco Studio 中打开 **File > Project Structure > Signing Configs**，为 `com.tailtide.app` 创建/选择签名 Profile，再 **Build > Build Hap(s)**。没有匹配的签名时构建会停在 `SignHap`；可能仍产出未签名 HAP，但不能安装。

## 运行时说明

- Android/ANCO Clash 运行在容器中，与 HarmonyOS 宿主隔离；App 使用自己的 SS 客户端，不依赖容器。
- App 将节点配置保存在私有沙箱，请勿提交 `.cache/`。
- `.cache/`、`third_party/`、`engine/dist/` 及预编译 `.so` 均已 gitignore。
