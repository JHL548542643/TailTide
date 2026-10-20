# HarmonyOS 品牌与 UI 参考

- 存档日期：2026-10-20
- 对应：ADR-011（TailTide 品牌/图标/UI 改版）

## 官方文档

- 应用配置（app.json5/module.json5、icon/label/startWindowIcon）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-component-configuration-stage
- 分层图标（layered-image）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/layered-image
- 启动页/启动图标：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/start-window-icon
- 通知：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-notificationmanager
- 状态栏/导航栏：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-window
- promptAction（Toast）：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-promptaction
- AlertDialog：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-methods-alert-dialog-box
- pasteboard：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-pasteboard
- bundleManager：
  https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-bundlemanager
- HarmonyOS Design：
  https://developer.huawei.com/consumer/cn/design/

## 本地 SDK 依据（API 24）

- `sdk/default/openharmony/ets/api/@ohos.window.d.ts`
  - `WindowStage.getMainWindowSync()`；`Window.setWindowSystemBarProperties(SystemBarProperties)`
  - `SystemBarProperties.statusBarColor / isStatusBarLightIcon / statusBarContentColor / navigationBarColor / isNavigationBarLightIcon / navigationBarContentColor`
- `sdk/default/openharmony/ets/api/@ohos.promptAction.d.ts`
  - `showToast(options: ShowToastOptions)`；`ShowToastOptions.message: string | Resource`，`duration?: number`
- `sdk/default/openharmony/ets/component/alert_dialog.d.ts`
  - `AlertDialog.show(value: AlertDialogParamWithConfirm | AlertDialogParamWithButtons | AlertDialogParamWithOptions)`
  - `AlertDialogParamWithButtons.primaryButton / secondaryButton: AlertDialogButtonBaseOptions`
- `sdk/default/openharmony/ets/api/@ohos.pasteboard.d.ts`
  - `createData(mimeType, value)`；`getSystemPasteboard().setData(data): Promise<void>`；`MIMETYPE_TEXT_PLAIN`
- `sdk/default/openharmony/ets/api/@ohos.bundle.bundleManager.d.ts`
  - `getBundleInfoForSelfSync(bundleFlags: number): BundleInfo`；`BundleInfo.versionName`
- 组件：`Image / Circle / Select / TextInput / Button / LoadingProgress / Column / Row / Scroll / Stack`，API 24 全量可用。

## 关键结论

- 无新增系统权限；图标/启动页为资源替换；状态栏/Toast/对话框/剪贴板/版本读取均为 API 24 已有能力；
- 分层图标沿用现有 `layered_image.json` 与 `startWindowIcon` 机制，不改变模块配置结构；
- 深浅色通过 `resources/base` 与 `resources/dark` 的 color.json 实现，组件使用 `$r('app.color.*')`。
