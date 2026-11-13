# Vendored: Dictus for iOS

- Upstream: https://github.com/getdictus/dictus-ios
- Tag v2.0.0, commit 8804c3629741b9aebe9475e0b2103769eb969dc5 (2026-11-08)
- License: MIT (LICENSE in this folder)

## What is here

- `Sources/DictusCore/`: upstream `DictusCore/Sources/DictusCore/`, whole.
- `Sources/DictusModels/Vendored/`: upstream `DictusApp/Models/*.swift` and
  `DictusApp/Audio/{SpeechModelProtocol,ParakeetEngine,NemotronEngine,WhisperComputeOptions,DictationFailureMessage}.swift`.

## Local changes (keep this list complete; re-apply when updating)

1. `DictusCore/AppGroup.swift`: `identifier` is `group.me.chiq.fonos`.
2. `Vendored/BackgroundModelDownloadService.swift`: `sessionIdentifier` is `me.chiq.fonos.model-download`.
3. `Shims/TranscriptionError.swift`: copied verbatim from `DictusApp/Audio/TranscriptionService.swift`.
4. `Shims/NotificationNames.swift`: two names copied from `DictusApp/DictusApp.swift`.
5. `Shims/DictationCoordinator.swift`: Fonos-written stand-in with only the members ModelManager calls.
6. `Facade/OnDeviceModels.swift`: Fonos-written public API.

## Updating

Repeat Task 3 of the plan against the new tag, re-apply changes 1–2, rebuild, and
fix any new app-only symbol by copying it into `Shims/` (and listing it above).
