# Release Checklist

## 已确认

- Bundle ID：`com.fonos.ios`
- Marketing version：`1.0`
- Build number：`2`
- Deployment target：iOS `17.0`
- Device family：iPhone
- Team ID：`SBU743JJ9S`
- App display name：`Fonos`
- 本地化：`en`、`zh-Hans`
- iPhone 17 Pro 截图：已生成到 `release/app-store/screenshots/iphone-17-pro/`
- 截图尺寸：`1206 x 2622` portrait PNG
- 截图数据：通过 `FONOS_SCREENSHOT_MODE=1` 注入 in-memory demo data
- Release archive：已生成到 `build/FonosApp.xcarchive`
- App Store IPA：已导出到 `build/AppStore/FonosApp.ipa`
- Distribution signing：`Cloud Managed Apple Distribution`，过期日 `2027-07-05`
- App Store Connect upload：`1.0 (2)` 已上传成功，等待 Apple 处理 build
- App icon：已替换为最终黑金声纹图标，已补齐 iPhone required sizes 和 1024px marketing icon
- App icon source：`release/app-store/icon/fonos-icon-final-1024.png`

## 已跑验证

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'platform=iOS Simulator,id=480335BF-BE94-43D4-8335-35330B6F157B' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

FONOS_SCREENSHOT_DIR="$PWD/release/app-store/screenshots/iphone-17-pro" \
xcodebuild test -project FonosApp.xcodeproj -scheme FonosAppUITests \
  -destination 'platform=iOS Simulator,id=480335BF-BE94-43D4-8335-35330B6F157B' \
  -only-testing:FonosAppUITests/FonosAppUITests/testCaptureAppStoreScreenshots \
  CODE_SIGNING_ALLOWED=NO

xcodebuild archive -project FonosApp.xcodeproj -scheme FonosApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/FonosApp.xcarchive

xcodebuild -exportArchive \
  -archivePath build/FonosApp.xcarchive \
  -exportPath build/AppStoreUpload \
  -exportOptionsPlist release/app-store/ExportOptions.app-store-upload.plist \
  -allowProvisioningUpdates
```

## 当前状态

App Store Connect 上传已成功。Apple 侧可能还需要几分钟处理 build；处理完成后，可在 App Store Connect 的 Fonos 版本页或 TestFlight 里选择 `1.0 (2)`。

本机 Keychain 里没有本地 `Apple Distribution` 证书；当前导出使用 Xcode 自动签名和 Apple cloud managed distribution signing。导出摘要里的 profiles：

- `iOS Team Store Provisioning Profile: com.fonos.ios`
- `iOS Team Store Provisioning Profile: com.fonos.ios.keyboard`

## 还没做

- App Store Connect 版本页选择上传后的 build
- 隐私标签填写
- 年龄分级填写
- 出口合规填写
- 选择价格和可用地区
- App Review 联系方式和审核备注确认

## 平台支持

当前 `1.0 (2)` 是 iPhone-only 首发包：

- Xcode `TARGETED_DEVICE_FAMILY = 1`
- Archive `UIDeviceFamily = [1]`
- App Store Connect 只需当前 iPhone 截图集

iPad 原生支持建议作为后续版本处理：需要改为 universal target、适配宽屏 UI、测试 iPad 键盘扩展，并准备 iPad 截图。

Apple Watch 原生支持需要新增 watchOS app/extension target，设计 Watch 上的核心流程，并准备 watchOS metadata、截图和图标；当前项目没有 Watch target。

## Export / Upload 命令

导出 IPA：

```bash
xcodebuild -exportArchive \
  -archivePath build/FonosApp.xcarchive \
  -exportPath build/AppStore \
  -exportOptionsPlist release/app-store/ExportOptions.app-store-connect.plist \
  -allowProvisioningUpdates
```

上传 App Store Connect：

```bash
xcodebuild -exportArchive \
  -archivePath build/FonosApp.xcarchive \
  -exportPath build/AppStoreUpload \
  -exportOptionsPlist release/app-store/ExportOptions.app-store-upload.plist \
  -allowProvisioningUpdates
```

本次命令行上传使用当前 Xcode 登录账号和 cloud managed distribution signing 成功完成。
