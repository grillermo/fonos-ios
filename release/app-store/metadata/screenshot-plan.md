# Screenshot Plan

截图目录：

`release/app-store/screenshots/iphone-17-pro-max/`

当前 App Store 上传集由 iPhone 17 Pro Max 生成，portrait PNG 尺寸均为 `1320 x 2868`，符合 6.9 英寸截图槽。`iphone-17-pro/` 下的 `1206 x 2622` 图片仅保留作开发视觉回归参考，不作为 App Store 上传素材。两组截图都通过 `FONOS_SCREENSHOT_MODE=1` 启动 App，并注入临时 in-memory demo 数据生成，不会写入真实用户数据：

- `01-dictate.png`：主听写页，展示 Polish 模式、录音入口、Demo STT / LLM 已配置状态
- `02-history.png`：History 页，展示三条 demo 听写记录，覆盖 Polish、Formal、Translate
- `03-notes.png`：Notes 页，展示 Launch Notes、Meeting Recaps、Ideas 三个 demo notebook
- `04-settings.png`：Settings → General，展示限时 Keyboard Ready 和隐私控制入口

## 推荐上传顺序

1. `01-dictate.png`
   - 建议标题：一键开始语音输入
   - 说明：突出 Fonos 的核心听写入口、处理模式和已配置模型状态。

2. `02-history.png`
   - 建议标题：自动保留听写历史
   - 说明：突出听写结果可检索、可复用，并能按模式过滤。

3. `03-notes.png`
   - 建议标题：把语音整理成笔记
   - 说明：突出笔记本工作流和不同场景分类。

4. `04-settings.png`
   - 建议标题：在键盘里直接语音输入
   - 说明：突出用户主动开启的限时 Keyboard Ready；之后可在其他 App 的 Fonos 键盘中点击麦克风直接听写，无需跳转。

## 质量备注

- `iphone-17-pro-max/` 是无外框、无营销文案的真实 UI 截图，可用于 App Store Connect 的 6.9 英寸截图槽。
- History、Notes、Settings 使用 demo 数据，避免空状态截图削弱首发页表达。
- Demo profile 名称使用 `Demo ...`，避免暗示 App 内置真实 API key 或托管模型额度。
- 第一张截图会出现在搜索结果里，建议优先保留 Dictate 页。
