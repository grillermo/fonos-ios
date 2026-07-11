# Fonos App Store Connect 填写建议

## 截图

当前已有截图：

- `release/app-store/screenshots/iphone-17-pro/01-dictate.png`
- `release/app-store/screenshots/iphone-17-pro/02-history.png`
- `release/app-store/screenshots/iphone-17-pro/03-notes.png`
- `release/app-store/screenshots/iphone-17-pro/04-settings.png`

上传位置：

App Store Connect -> Apps -> Fonos -> App Store -> iOS App 1.0 -> App Preview and Screenshots

建议顺序：

1. Dictate
2. History
3. Notes
4. Settings

如果 App Store Connect 要求 6.9 英寸截图，而当前 iPhone 17 Pro 截图不能复用，需要再生成一套 6.9 英寸截图。

## 三个 URL

### Support URL

必填。给用户遇到问题时获取支持的页面。

建议内容：

- 产品名 Fonos
- 联系邮箱
- 常见问题：麦克风权限、Speech Recognition 权限、键盘 Full Access、主 App 需要运行
- 简单 troubleshooting

### Privacy Policy URL

必填。必须是公开网页，不建议只放本地文件。

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
- User Content：可能处理音频、转写文本、笔记内容
- Identifiers：如果把用户自己填的 API key 算入 app 内配置，应披露为敏感凭据/用户提供的信息；但它保存在 Keychain，不用于追踪
- Diagnostics：如果当前没有上传 crash/log/diagnostic 数据，可以不勾选

关键解释：

Fonos 默认会在本地保存历史和笔记；用户配置 OpenAI-compatible 服务时，音频/文本会发给对应第三方 endpoint。因此隐私页和审核备注都应说明这是用户主动配置的处理方式。

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

如果表单问是否 qualifies for exemption，通常选择使用标准加密/HTTPS 的豁免路径；最终以 Apple 表单当前问题为准。

## App Review Notes 建议

Fonos does not require account sign-in.

The main app can use Apple Speech for dictation. Users may also manually configure OpenAI-compatible STT or LLM services in Settings by adding an endpoint and API key.

The keyboard extension requires Full Access and communicates with the main app through an App Group. To test the keyboard extension, please open the Fonos app first, then switch to the Fonos keyboard from another app.
