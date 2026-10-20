# Build

This repository does **not** vendor `third_party/`. The engine needs the OpenHarmony Go toolchain plus a patched Tailscale source tree.

## Prerequisites

- DevEco Studio with HarmonyOS SDK (API 24 compatible; tested on API 26 device).
- Windows PowerShell.
- OpenHarmony Go toolchain (Go 1.24.x cross build) at `third_party/ohos-go`.
- Tailscale v1.86.5 source at `third_party/tailscale`, with `patches/tailscale-v1.86.5-ohos.patch` applied.
- The Tailscale dependencies (wireguard-go, gVisor, go-yaml) available through the Go module cache.

## Engine

```powershell
.\tools\build-engine.ps1
```

This cross-compiles `engine/` to `app/entry/libs/arm64-v8a/libtailscale_go.so` and copies the generated header.

## HAP

```powershell
.\tools\build-hap.ps1
# optional: install to a connected device
.\tools\build-hap.ps1 -Install -Device <device-serial>
```

The public package id is `com.tailtide.app`. Configure your own signing profile in DevEco Studio; signing material is not included.

## Signing (required for a signed HAP)

`app/build-profile.json5` is gitignored to keep signing material out of git. A fresh checkout only has `app/build-profile.example.json5`.

```powershell
Copy-Item app/build-profile.example.json5 app/build-profile.json5
```

Then in DevEco Studio: **File > Project Structure > Signing Configs**, create/select a profile for `com.tailtide.app`, and **Build > Build Hap(s)**. Without a matching signing profile the build stops at `SignHap`; an unsigned HAP may still be produced but cannot be installed.

## Runtime notes

- Android/ANCO Clash running in a container is isolated from the HarmonyOS host; the app uses its own SS client instead.
- The app stores node configuration in its private sandbox. Do not commit `.cache/`.
- `.cache/`, `third_party/`, `engine/dist/` and prebuilt `.so` files are gitignored.