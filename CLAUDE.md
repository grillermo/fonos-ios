# Fonos iOS

Voice dictation app for iPhone. iOS companion to [fonos](https://github.com/ethannortharc/fonos)
(desktop + fonos-core); split out of that monorepo 2026-07 with full history.

## Working agreements

- **Roadmap and priorities live in `docs/ROADMAP.md`** (local-only, gitignored).
  Read it before starting feature work — it records what to fix first (P0
  broken flows), what to port from desktop (P1), and standing decisions.
- **Zero third-party dependencies.** Apple frameworks only. iOS 17+, Swift 6.
- **Data formats mirror fonos-core** (desktop repo): notebook export JSON,
  vocab books, scenario files. Reuse is contract-level (shared JSON shapes),
  not source-level — no UniFFI/Rust binding for now.
- `docs/` and `.ratchet/` are internal planning/spec material — gitignored,
  never published. Tests named `INV*`/`QD*`/`NoteINV*` trace to
  `.ratchet/*/spec.yaml`.
- API keys go in Keychain (`KeychainStore`), never in `AppConfig`/UserDefaults.

## Layout

| Target | What |
|---|---|
| `FonosApp/` | Main SwiftUI app — Dictate / History / Notes / Settings tabs |
| `FonosKeyboard/` | Dictation keyboard. Cannot record audio itself — talks to the main app over App Group IPC (`group.com.fonos.ios`, Darwin notifications + files); main app must be running (`BackgroundRecordingService`) |
| `FonosWidget/` | Quick-record widget (Live Activity is a deliberate stub) |
| `FonosIntents/` | Siri App Intents (`DictateIntent`, `RecordNoteIntent`) |
| `FonosAppTests/` | Unit tests incl. Ratchet invariant suites |

Key flow: `DictationViewModel` → `AudioCaptureService` →
`VoiceWorkflowPlanFactory` → `VoiceWorkflowEngine` → surface output adapters.
STT (`AppleSTT` / `WhisperSTT` / `FonosSTT` via `ModelProfile`) and optional
OpenAI-compatible LLM steps are frozen into the plan; LLM failure can fall back
to the step input. Notes compile `NotebookPipeline` settings into the same
engine, then adapt the result into SwiftData.

## Build & test

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
