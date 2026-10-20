# 工具链溯源：OpenHarmony Go（ohos_golang_go）

> 归档日期：2026-10-16。本文件记录工具链的来源、校验值与构建方式，保证可追溯、可重建。

## 官方来源

- 仓库：https://gitcode.com/openharmony-sig/ohos_golang_go （OpenHarmony SIG 官方）
- 使用分支/发布：`release-branch.go1.24` 的正式发布 **go1.24.5.ohosv1r1**
  - 发布 tag commit：`2d8b23f6923100d8c90d8add9299da2c9d032a20`
  - VERSION：`go1.24.5`（打包日期 2025-07-02）

## 下载物（存放于 third_party\）

| 文件 | 大小 | SHA256 |
|---|---|---|
| `go1.24.5.ohosv1r1.zip`（官方发布附件：源码 + Linux 主机预编译） | 81.4 MB | `50F31C2E3E519ECDB34795DC6AFAD14504F5D9C36AF6055EC1F5466E7C2C73D2` |
| `ohos_golang_go-go1.24.5.ohosv1r1-source.zip`（源码分支归档） | 36.7 MB | 未单独计算（内容与上方源码部分一致） |

## 关键事实（已核对）

- 官方发布附件的 `bin/go`、`bin/gofmt` **无 `.exe` 后缀**，且包内无任何 `.exe` → 该预编译为 **Linux 主机版**，Windows 上不可直接使用。
- 包内含完整源码与 `src/make.bat`、`src/make.bash`，官方支持从源码自建。
- Windows 自建方式依据 **Go 官方文档**（https://go.dev/doc/install/source）：
  - 在 `src/` 下运行 `make.bat`；
  - bootstrap 要求：**"Go 1.24 and 1.25 require Go 1.22"**（本机 bootstrap 使用系统 Go 1.25.5，满足）；
  - 无 C 编译器时可 `CGO_ENABLED=0` 构建（官方文档明确支持；本项目主机侧不需要 cgo，交叉编译 cgo 由目标端 CC 完成）；
  - `GOROOT_BOOTSTRAP` 指向现有 Go 安装（`C:\Program Files\Go`）。

## 构建记录（Windows 主机自建）

- 目标产物：`third_party\ohos-go\bin\go.exe`（windows/amd64 主机工具链，含 openharmony GOOS 支持）
- 构建命令：`GOROOT_BOOTSTRAP=C:\Program Files\Go; CGO_ENABLED=0; cd third_party\ohos-go\src; .\make.bat`
- 构建缓存与 GOPATH 全部指向项目内 `.cache\`（遵守资源存放规矩）
- 结果：见 `docs\decisions\002-Go工具链构建验证.md`（构建完成后填写）

## 备查：升级候选

- 仓库另有 `release-branch.go1.26`（2026-08 有提交）。当前不采用；如未来升级 Tailscale 核心导致 Go 版本要求变化，再走版本核查流程（规矩第 3 条）。
