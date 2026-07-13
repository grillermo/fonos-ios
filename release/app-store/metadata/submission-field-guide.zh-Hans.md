# Fonos App Store Connect 填写建议

## 截图

当前已有截图：

- `release/app-store/screenshots/iphone-17-pro-max/01-dictate.png`
- `release/app-store/screenshots/iphone-17-pro-max/02-history.png`
- `release/app-store/screenshots/iphone-17-pro-max/03-notes.png`
- `release/app-store/screenshots/iphone-17-pro-max/04-settings.png`

上传位置：

App Store Connect -> Apps -> Fonos -> App Store -> iOS App 1.0 -> App Preview and Screenshots

建议顺序：

1. Dictate
2. History
3. Notes
4. Settings

当前目录中的 iPhone 17 Pro Max 截图为 `1320 x 2868`，用于 6.9 英寸截图槽。

## 三个 URL

### Support URL

必填。给用户遇到问题时获取支持的页面。

暂定值：`https://github.com/ethannortharc/fonos/issues`。正式提交前应改成包含私人联系邮箱、隐私政策链接和常见问题的公开支持页面；仅有公开 Issues 页面存在审核风险。

建议内容：

- 产品名 Fonos
- 联系邮箱
- 常见问题：麦克风权限、Speech Recognition 权限、键盘 Full Access、主 App 需要运行
- 简单 troubleshooting

### Privacy Policy URL

必填。必须是公开网页，不建议只放本地文件。

**提交 App Review 前仍需提供：托管下述隐私政策的公开 HTTPS URL，以及可私下联系开发者的支持邮箱。**
工程的 `FONOS_PRIVACY_POLICY_URL` 当前故意留空，拿到正式 URL 后同时填入 Release build setting 与 App Store Connect。

建议内容：

- Fonos 会请求麦克风和语音识别权限
- 听写历史和笔记默认保存在设备本地
- API key 保存在 Keychain
- 如果用户配置第三方 STT/LLM endpoint，音频或文本会发送给用户选择的服务商处理
- Fonos 当前没有第三方 analytics / ads SDK
- 用户可以删除本地历史和配置

### Marketing URL

可选。没有官网时可以先不填。

## 隐私标签建议

基于当前代码，建议保守填写：

- 不用于第三方广告
- 不用于跨 App / 网站追踪
- 没有第三方 analytics / ads SDK
- `Audio Data`：用户主动录制、并可能发送给所选网络 STT 的语音
- `Other User Content`：转写文本、prompt 和笔记内容
- API key 仅保存在设备 Keychain 时不因这一点申报 Identifiers；若远端服务使用该 key 识别账户，则按该服务的实际收集和保留行为评估
- Diagnostics：如果当前没有上传 crash/log/diagnostic 数据，可以不勾选

关键解释：

Fonos 默认会在本地保存历史和笔记；用户配置网络 STT/LLM 服务时，App 会先显示服务商、目标 origin 和将发送的数据类型，并在用户明确允许后才发送音频/文本。用户可在 Settings → General → Privacy & Data Sharing 撤回全部权限。API key 仅存 Keychain。隐私页和审核备注都应与该行为一致。

## 年龄分级建议

按当前功能，建议问卷大部分选择 None：

- Cartoon or Fantasy Violence: None
- Realistic Violence: None
- Sexual Content or Nudity: None
- Profanity or Crude Humor: None
- Alcohol, Tobacco, Drug Use or References: None
- Medical/Treatment Information: None
- Gambling: None
- Contests: None
- Unrestricted Web Access: No
- User-Generated Content: No, 如果只把用户自己的听写/笔记视为个人内容；Yes 只有在有公开发布、社区、分享平台时才更合适

预期年龄分级大概率是 4+。

注意：如果未来加入网页浏览、公开分享、社区内容、AI 生成成人内容或医疗建议，需要重新评估。

## 出口合规建议

当前 app 使用 HTTPS / URLSession / Apple 系统框架，并可连接用户配置的 API endpoint。通常可以按标准加密路径填写。

建议表述：

- App uses encryption: Yes, because it uses HTTPS / secure network communication.
- Encryption is limited to standard Apple-provided / operating-system cryptography and secure network communication.
- App does not implement custom cryptographic algorithms.
- App is not primarily a cryptography or security product.

工程已设置 `ITSAppUsesNonExemptEncryption = NO`，表示不使用非豁免加密。上传并处理完成后先确认 build 没有显示 Missing Compliance；只有 App Store Connect 仍提示时才按当前问卷回答。

如果表单问是否 qualifies for exemption，通常选择使用标准加密/HTTPS 的豁免路径；最终以 Apple 表单当前问题为准。

## App Review Notes 建议

Fonos does not require account sign-in.

The main app can use Apple Speech for dictation. Users may also manually configure network STT or LLM services in Settings by adding an endpoint and API key. Before any audio or text is sent, Fonos identifies the provider and destination, discloses the data types, and requires explicit permission. Users can withdraw all remote-AI permissions in Settings at any time. API keys remain in Apple Keychain.

The keyboard extension requires Full Access and communicates with the main app through an App Group. To test no-jump keyboard dictation, open Fonos → Settings → General, explicitly start the 15-minute Keyboard Ready session, then switch to the Fonos keyboard in another app and tap its microphone. iOS shows its orange microphone indicator while Keyboard Ready is active. Idle input buffers are discarded; bounded in-memory utterance capture begins only after the keyboard microphone is tapped. Keyboard Ready can be stopped from the persistent in-app banner and expires automatically.
