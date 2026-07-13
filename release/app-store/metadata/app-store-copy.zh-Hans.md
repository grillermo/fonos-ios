# Fonos App Store Copy (zh-Hans)

## App 信息

- App 名称：Fonos
- 副标题：语音输入与文字处理
- 主类别建议：效率
- 次类别建议：工具
- 价格建议：免费首发，后续如加入云端额度或高级模型配置再评估订阅/内购

## 促销文本

用语音快速输入、整理、翻译和润色文字；支持系统语音识别，也可配置兼容 OpenAI 的转写与 LLM 服务。

## 描述

Fonos 是一款为 iPhone 设计的语音输入工具。打开 App 直接开始听写，把口述内容转成文字，并按需要保留原文、润色、正式化或翻译。你也可以通过键盘扩展在其他 App 中调用 Fonos，让常用输入场景更顺手。

主要功能：

- 一键听写，把语音转成可复制、分享或发送的文字
- Raw、Polish、Formal、Translate 等处理模式
- 历史记录，方便回看和复用过往听写内容
- Notes 笔记工作流，把语音整理到笔记本
- 键盘扩展，可在其他 App 中使用 Fonos 输入
- 支持 Apple Speech，并可配置兼容 OpenAI 的 STT / LLM 服务
- API key 存在 Keychain 中，不写入普通设置存储

Fonos 适合需要快速记录想法、回复消息、整理会议片段、翻译短句或把口语变成更清晰文字的人。

## 关键词草案

听写,语音输入,转写,翻译,润色,效率,键盘,快捷指令,笔记,Whisper

## 版本说明草案

Fonos 1.0 首个 iOS 版本：支持主 App 听写、历史记录、笔记、设置模型服务，以及键盘扩展输入。

## 审核备注草案

Fonos 不需要账号登录。主 App 可以使用 Apple Speech 进行听写；也可在 Settings 中手动添加网络 STT 或 LLM 服务。发送音频或文本前，Fonos 会明确显示服务商、目标地址和数据类型并要求用户同意；权限可在 Settings 中撤回，API key 始终保存在 Apple Keychain。

键盘扩展需要开启 Full Access。由于 iOS 自定义键盘不能直接访问麦克风，它通过 App Group 与主 App 通信。审核时请先打开 Fonos → Settings → General，明确启动 15 分钟 Keyboard Ready，再到其他 App 切换至 Fonos 键盘。限时会话期间 iOS 会持续显示麦克风指示；Fonos 会丢弃空闲音频 buffer，点击键盘麦克风后只在内存中保留这一段有限语音，并在所选 recipe 完成、失败或取消后释放。

## 仍需人工确认

- Support URL：`https://github.com/ethannortharc/fonos/issues`
- Marketing URL（可选）
- Privacy Policy URL：提交 App Review 前仍需提供一个公开 HTTPS URL
- Copyright
- App Store Connect 年龄分级问卷
- 隐私标签：需要确认音频、转写文本、笔记或诊断信息是否离开设备，以及实时请求结束后开发者或服务商是否仍可访问或保留
- 加密出口合规：确认 processed build 没有显示 Missing Compliance；工程已声明不使用非豁免加密，仅在 App Store Connect 仍提示时回答
