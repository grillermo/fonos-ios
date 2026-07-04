# Fonos iOS

**Voice dictation for iPhone.** Tap to record, speak naturally, and get transcribed — optionally polished, translated, or rewritten by an LLM — then route the result to the clipboard, Messages, any URL scheme, or type it directly into any app with the Fonos keyboard.

The iOS companion to [Fonos](https://github.com/ethannortharc/fonos), the voice terminal for macOS and Linux. Both share the same concepts and data formats (modes, notebooks, model profiles), each built natively for its platform.

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

## Features

- **Dictation modes** — Raw, Polish, Formal, Translate, or custom prompts. Each mode is a transcription pass plus an optional LLM pass with its own model overrides.
- **Bring your own providers** — on-device Apple Speech, any OpenAI-compatible STT/LLM endpoint, or a local Fonos server. API keys live in the Keychain, never in config files.
- **Voice notebooks** — route captures into notebooks, each with its own system prompt, language, and model overrides. Quick Note catches everything else.
- **Dictation keyboard** — a custom keyboard extension that types transcription results into any app's text field.
- **Widget & Siri** — Home/Lock Screen quick-record widget, plus "Dictate with Fonos" and "Record a Note" App Intents.

## Targets

| Target | What it is |
|---|---|
| `FonosApp` | Main SwiftUI app — Dictate / History / Notes / Settings |
| `FonosKeyboard` | Custom keyboard extension (dictation via the main app over App Group IPC) |
| `FonosWidget` | WidgetKit quick-record widget |
| `FonosIntents` | App Intents / Siri Shortcuts |

## Building

Xcode 16+, iOS 17+, Swift 6. No third-party dependencies — Apple frameworks only.

```
open FonosApp.xcodeproj
```

## License

[MIT](LICENSE)
