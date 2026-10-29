# Retry Failed Transcriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Dictate or Notes recording's transcription run fails before any text is saved, keep the audio on the device and let the user retry or discard it from popup menus on the Dictate error card, the History list and the notebook detail screen.

**Spec:** `docs/superpowers/specs/2026-10-29-retry-failed-transcriptions-design.md`

**Architecture:** A file store (`PendingRecordingStore`) keeps `<id>.wav` + `<id>.json` under `AppGroup/PendingRecordings/`. `DictationViewModel` and `NoteViewModel` save to it from their failure paths and expose retry/discard methods. The spec's `PendingRecordingRetrier` responsibilities (compile from current settings, quiet vs full mode, in-flight tracking, success → discard, failure → record attempt) live in those two view models, because they already own workflow compilation and the test provider overrides; a separate class would have to duplicate both. A shared `PendingRecordingRow` view renders pending items with a ⋯ popup `Menu` plus a long-press `contextMenu`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, Foundation file APIs. No third-party dependencies.

---

## Conventions for every task

- Project file: `FonosApp.xcodeproj` registers files by hand (no synchronized folders). Every new `.swift` file must be registered with the helper from Task 1, Step 1.
- Test command (the simulator in `CLAUDE.md`, "iPhone 16", is not installed; use "iPhone 16e"):

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:FonosAppTests/<SuiteName> 2>&1 | tail -40
```

- `docs/` is gitignored; the plan and spec are committed with `git add -f`. Source files are committed normally.
- Commit messages end with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

## File structure

| File | Status | Responsibility |
|---|---|---|
| `FonosApp/Models/PendingRecording.swift` | Create | `PendingRecording` metadata, `PendingRecordingError` |
| `FonosApp/Services/PendingRecordingStore.swift` | Create | WAV + JSON persistence, orphan cleanup, change notification, `shouldKeep` rule |
| `FonosApp/Services/DictationRecordingFlow.swift` | Modify | Save on failure, full retry, quiet retry, discard |
| `FonosApp/Services/DictationViewModel.swift` | Modify | New stored properties (`pendingStore`, `lastPendingRecordingID`, `retryingPendingIDs`, `copyText`, `activeRunPersistedText`) |
| `FonosApp/Services/DictationWorkflowPreparation.swift` | Modify | `prepareMainWorkflow(workflowID:)` |
| `FonosApp/Services/NoteViewModel.swift` | Modify | Save on failure, quiet retry, discard |
| `FonosApp/Views/Components/PendingRecordingRow.swift` | Create | Shared pending row with popup menu |
| `FonosApp/Views/DictationView.swift` | Modify | Retry ▾ menu on the error card |
| `FonosApp/Views/HistoryView.swift` | Modify | Pending section |
| `FonosApp/Views/NotebookDetailView.swift` | Modify | Pending rows |
| `FonosApp/Views/RecordNoteSheet.swift` | Modify | "Saved to this notebook for retry." |
| `FonosApp/Views/ContentView.swift` | Modify | Pass view model / tab switch closure |
| `FonosAppTests/PendingRecordingStoreTests.swift` | Create | Store tests |
| `FonosAppTests/PendingRecordingDictationTests.swift` | Create | Dictate save/retry tests |
| `FonosAppTests/PendingRecordingNoteTests.swift` | Create | Notes save/retry tests |

---

### Task 1: PendingRecording model and store

**Files:**
- Create: `FonosApp/Models/PendingRecording.swift`
- Create: `FonosApp/Services/PendingRecordingStore.swift`
- Test: `FonosAppTests/PendingRecordingStoreTests.swift`

- [ ] **Step 1: Create the project-file helper**

Write this script to `${TMPDIR}xcodeproj_add.py` (outside the repo; it is a tool, not product code):

```python
#!/usr/bin/env python3
"""Register a new Swift file in FonosApp.xcodeproj beside an existing sibling.

Usage (from the repo root): python3 "${TMPDIR}xcodeproj_add.py" <new file name> <sibling file name>
The new file joins the sibling's group and the sibling's target Sources phase.
"""
import re
import secrets
import sys

pbx = "FonosApp.xcodeproj/project.pbxproj"
new, sibling = sys.argv[1], sys.argv[2]
s = open(pbx).read()
if f"/* {new} */" in s:
    sys.exit(f"{new} is already registered")


def gid():
    return secrets.token_hex(12).upper()


ref_m = re.search(r"^\t\t(\w+) /\* " + re.escape(sibling) + r" \*/ = \{isa = PBXFileReference;.*$", s, re.M)
build_m = re.search(r"^\t\t(\w+) /\* " + re.escape(sibling) + r" in Sources \*/ = \{isa = PBXBuildFile;.*$", s, re.M)
if not ref_m or not build_m:
    sys.exit(f"sibling {sibling} not found")
ref, build = gid(), gid()
s = s.replace(ref_m.group(0), ref_m.group(0) + f'\n\t\t{ref} /* {new} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {new}; sourceTree = "<group>"; }};', 1)
s = s.replace(build_m.group(0), build_m.group(0) + f"\n\t\t{build} /* {new} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {new} */; }};", 1)
child = f"\t\t\t\t{ref_m.group(1)} /* {sibling} */,\n"
assert s.count(child) == 1, "sibling group entry is not unique"
s = s.replace(child, child + f"\t\t\t\t{ref} /* {new} */,\n")
phase = f"\t\t\t\t{build_m.group(1)} /* {sibling} in Sources */,\n"
assert s.count(phase) == 1, "sibling Sources entry is not unique"
s = s.replace(phase, phase + f"\t\t\t\t{build} /* {new} in Sources */,\n")
open(pbx, "w").write(s)
print(f"registered {new} beside {sibling}")
```

Sibling anchors used in this plan (each is in exactly one group and one Sources phase): `DictationSession.swift` (Models), `NoteViewModel.swift` (Services), `ActivityCard.swift` (Views/Components), `NoteINV06RecordFlowTests.swift` (tests).

- [ ] **Step 2: Write the failing store tests**

Create `FonosAppTests/PendingRecordingStoreTests.swift`:

```swift
// Pending recordings: failed transcription audio is kept as <id>.wav +
// <id>.json until a retry succeeds or the user discards it.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingStoreTests

import Testing
import Foundation
@testable import FonosApp

private func makeTempStore() -> PendingRecordingStore {
    PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    )
}

/// 44-byte WAV header with a byte rate of 32 000, followed by one second of silence.
private func oneSecondWAV() -> Data {
    var data = Data(count: 44 + 32_000)
    var byteRate = UInt32(32_000).littleEndian
    withUnsafeBytes(of: &byteRate) { data.replaceSubrange(28..<32, with: $0) }
    return data
}

struct PendingRecordingStoreTests {

    @Test("save, list, read audio and discard round-trip")
    func roundTrip() throws {
        let store = makeTempStore()
        let wav = oneSecondWAV()
        let saved = try store.save(
            wav: wav, surface: .dictate, workflowID: "wf.dictation",
            error: "Network unavailable. Check your connection."
        )

        #expect(store.all() == [saved])
        #expect(try store.audio(id: saved.id) == wav)
        #expect(saved.durationSeconds == 1)
        #expect(saved.attempts == 0)

        store.discard(id: saved.id)
        #expect(store.all().isEmpty)
        #expect(store.recording(id: saved.id) == nil)
    }

    @Test("history scope lists dictate items; notebook scope lists that notebook's notes")
    func scopes() throws {
        let store = makeTempStore()
        let notebookA = UUID()
        let dictate = try store.save(wav: oneSecondWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        let noteA = try store.save(wav: oneSecondWAV(), surface: .note, notebookID: notebookA, error: "e")
        _ = try store.save(wav: oneSecondWAV(), surface: .note, notebookID: UUID(), error: "e")

        #expect(store.pending(for: .history) == [dictate])
        #expect(store.pending(for: .notebook(notebookA)) == [noteA])
    }

    @Test("all() is newest first")
    func ordering() throws {
        let store = makeTempStore()
        let old = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e", now: Date(timeIntervalSince1970: 1))
        let new = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e", now: Date(timeIntervalSince1970: 2))
        #expect(store.all().map(\.id) == [new.id, old.id])
    }

    @Test("recordAttempt increments attempts and replaces the error")
    func recordAttempt() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "first")
        store.recordAttempt(id: saved.id, error: "second")
        let updated = try #require(store.recording(id: saved.id))
        #expect(updated.attempts == 1)
        #expect(updated.lastError == "second")
    }

    @Test("a JSON whose WAV is missing is dropped")
    func orphanJSON() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e")
        try FileManager.default.removeItem(at: store.audioURL(saved.id))
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.metadataURL(saved.id).path))
    }

    @Test("a WAV without JSON is deleted only after an hour")
    func orphanWAV() throws {
        let store = makeTempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let id = UUID()
        try oneSecondWAV().write(to: store.audioURL(id))

        _ = store.all()
        #expect(FileManager.default.fileExists(atPath: store.audioURL(id).path))

        _ = store.all(now: Date().addingTimeInterval(2 * 3_600))
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(id).path))
    }

    @Test("shouldKeep rejects cancellation, empty audio and no-speech results")
    func shouldKeep() {
        let audio = Data(count: 44)
        #expect(PendingRecordingStore.shouldKeep(error: STTError.networkUnavailable, audio: audio))
        #expect(PendingRecordingStore.shouldKeep(error: STTError.authenticationFailed, audio: audio))
        #expect(!PendingRecordingStore.shouldKeep(error: CancellationError(), audio: audio))
        #expect(!PendingRecordingStore.shouldKeep(error: STTError.networkUnavailable, audio: Data()))
        #expect(!PendingRecordingStore.shouldKeep(error: STTError.noTranscript, audio: audio))
        #expect(!PendingRecordingStore.shouldKeep(
            error: VoiceWorkflowRuntimeError.emptyTranscript(widgetID: "stt"), audio: audio
        ))
    }

    /// Runs on the main actor so the store posts synchronously.
    @Test("changes post pendingRecordingsChanged")
    @MainActor
    func postsChange() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let store = makeTempStore()
        let posts = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .pendingRecordingsChanged, object: store, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e")
        store.recordAttempt(id: saved.id, error: "e2")
        store.discard(id: saved.id)
        #expect(posts.value == 3)
    }
}
```

- [ ] **Step 3: Register the test file and run it to verify it fails**

```bash
python3 "${TMPDIR}xcodeproj_add.py" PendingRecordingStoreTests.swift NoteINV06RecordFlowTests.swift
```

Run the test command with `<SuiteName>` = `PendingRecordingStoreTests`.
Expected: build FAILS with `cannot find 'PendingRecordingStore' in scope`.

- [ ] **Step 4: Create the model**

Create `FonosApp/Models/PendingRecording.swift`:

```swift
import Foundation

/// A recording whose transcription run failed before any text was saved.
/// The audio sits beside this metadata in `PendingRecordingStore` until a
/// retry succeeds or the user discards it.
struct PendingRecording: Codable, Identifiable, Equatable, Sendable {
    enum Surface: String, Codable, Sendable {
        case dictate
        case note
    }

    /// Which list shows an item: History shows Dictate recordings, a
    /// notebook shows the notes recorded into it.
    enum Scope: Equatable, Sendable {
        case history
        case notebook(UUID)
    }

    let id: UUID
    let surface: Surface
    let workflowID: String?
    let notebookID: UUID?
    let createdAt: Date
    var lastError: String
    var attempts: Int
    let durationSeconds: TimeInterval
}

enum PendingRecordingError: LocalizedError, Equatable {
    case notFound
    case alreadyRetrying
    case dictationBusy
    case recipeUnavailable
    case notebookUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound:
            "This recording is no longer saved."
        case .alreadyRetrying:
            "This recording is already being retried."
        case .dictationBusy:
            "Finish the current dictation first."
        case .recipeUnavailable:
            "The recipe this recording used no longer exists. Discard it or record again."
        case .notebookUnavailable:
            "The notebook this recording belonged to no longer exists. Discard it or record again."
        }
    }
}
```

- [ ] **Step 5: Create the store**

Create `FonosApp/Services/PendingRecordingStore.swift`:

```swift
import Foundation
import os.log

private let pendingLog = Logger(subsystem: "com.fonos.ios", category: "PendingRecordingStore")

extension Notification.Name {
    static let pendingRecordingsChanged = Notification.Name("com.fonos.ios.pendingRecordingsChanged")
}

/// Keeps failed recordings as `<id>.wav` + `<id>.json` in the App Group so
/// they can be retried later. The WAV is written before its JSON, so a JSON
/// never points at missing audio; `all()` cleans up whatever a crash left.
final class PendingRecordingStore: @unchecked Sendable {
    static let shared = PendingRecordingStore(directory: defaultDirectory())

    /// A WAV this old with no JSON was abandoned mid-save.
    private static let orphanAudioAge: TimeInterval = 3_600

    let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardIPC.appGroupID
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingRecordings", isDirectory: true)
    }

    /// Cancellation, empty audio and "no speech" leave nothing worth retrying.
    static func shouldKeep(error: Error, audio: Data) -> Bool {
        guard !audio.isEmpty, !(error is CancellationError) else { return false }
        if let sttError = error as? STTError, sttError == .noTranscript { return false }
        if let runtimeError = error as? VoiceWorkflowRuntimeError,
           case .emptyTranscript = runtimeError { return false }
        return true
    }

    /// Seconds of audio in a PCM WAV, read from the header's byte rate.
    static func duration(ofWAV data: Data) -> TimeInterval {
        guard data.count > 44 else { return 0 }
        let byteRate = data.subdata(in: 28..<32).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        guard byteRate > 0 else { return 0 }
        return Double(data.count - 44) / Double(byteRate)
    }

    func audioURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    func metadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    @discardableResult
    func save(
        wav: Data,
        surface: PendingRecording.Surface,
        workflowID: String? = nil,
        notebookID: UUID? = nil,
        error: String,
        now: Date = Date()
    ) throws -> PendingRecording {
        let recording = PendingRecording(
            id: UUID(),
            surface: surface,
            workflowID: workflowID,
            notebookID: notebookID,
            createdAt: now,
            lastError: error,
            attempts: 0,
            durationSeconds: Self.duration(ofWAV: wav)
        )
        try lock.withLock {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try wav.write(to: audioURL(recording.id), options: .atomic)
            try writeMetadata(recording)
        }
        pendingLog.info("Kept failed recording \(recording.id.uuidString.prefix(8), privacy: .public) for retry")
        postChange()
        return recording
    }

    /// Every pending recording, newest first. Drops JSONs whose WAV is gone
    /// and WAVs left without JSON for over an hour.
    func all(now: Date = Date()) -> [PendingRecording] {
        lock.withLock {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                return []
            }
            var recordings: [PendingRecording] = []
            for name in names where name.hasSuffix(".json") {
                let url = directory.appendingPathComponent(name)
                guard let recording = readMetadata(at: url),
                      fileManager.fileExists(atPath: audioURL(recording.id).path) else {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                recordings.append(recording)
            }
            let known = Set(recordings.map { "\($0.id.uuidString).wav" })
            for name in names where name.hasSuffix(".wav") && !known.contains(name) {
                let url = directory.appendingPathComponent(name)
                let created = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
                if now.timeIntervalSince(created ?? now) > Self.orphanAudioAge {
                    try? fileManager.removeItem(at: url)
                }
            }
            return recordings.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func pending(for scope: PendingRecording.Scope) -> [PendingRecording] {
        all().filter { recording in
            switch scope {
            case .history:
                recording.surface == .dictate
            case .notebook(let id):
                recording.surface == .note && recording.notebookID == id
            }
        }
    }

    func recording(id: UUID) -> PendingRecording? {
        lock.withLock {
            guard fileManager.fileExists(atPath: audioURL(id).path) else { return nil }
            return readMetadata(at: metadataURL(id))
        }
    }

    func audio(id: UUID) throws -> Data {
        guard let data = try? Data(contentsOf: audioURL(id)) else {
            throw PendingRecordingError.notFound
        }
        return data
    }

    func discard(id: UUID) {
        lock.withLock {
            try? fileManager.removeItem(at: metadataURL(id))
            try? fileManager.removeItem(at: audioURL(id))
        }
        postChange()
    }

    func recordAttempt(id: UUID, error: String) {
        let updated: Bool = lock.withLock {
            guard var recording = readMetadata(at: metadataURL(id)) else { return false }
            recording.attempts += 1
            recording.lastError = error
            do {
                try writeMetadata(recording)
                return true
            } catch {
                pendingLog.error("Could not record retry attempt: \(error.localizedDescription)")
                return false
            }
        }
        if updated { postChange() }
    }

    // MARK: - Private (call with the lock held)

    private func readMetadata(at url: URL) -> PendingRecording? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingRecording.self, from: data)
    }

    private func writeMetadata(_ recording: PendingRecording) throws {
        let data = try JSONEncoder().encode(recording)
        try data.write(to: metadataURL(recording.id), options: .atomic)
    }

    private func postChange() {
        let post = { NotificationCenter.default.post(name: .pendingRecordingsChanged, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
```

Register both files:

```bash
python3 "${TMPDIR}xcodeproj_add.py" PendingRecording.swift DictationSession.swift
python3 "${TMPDIR}xcodeproj_add.py" PendingRecordingStore.swift NoteViewModel.swift
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the test command with `PendingRecordingStoreTests`.
Expected: all 8 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add FonosApp/Models/PendingRecording.swift FonosApp/Services/PendingRecordingStore.swift FonosAppTests/PendingRecordingStoreTests.swift FonosApp.xcodeproj/project.pbxproj
git commit -m "feat(retry): store failed recordings for retry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Dictate keeps failed audio

**Files:**
- Modify: `FonosApp/Services/DictationViewModel.swift` (Services section, after `var activeProcessingID: UUID?`)
- Modify: `FonosApp/Services/DictationRecordingFlow.swift` (`finishRecordingWhenIdle`, `resetFlowUI`, `persistSession`)
- Test: `FonosAppTests/PendingRecordingDictationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FonosAppTests/PendingRecordingDictationTests.swift`:

```swift
// Dictate keeps the audio of a failed run and retries it from the error card
// (full recipe) or from History (quiet: save + copy, no outputs).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingDictationTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

private final class SwitchableSTT: STTProvider, @unchecked Sendable {
    var error: STTError?
    var transcript = "hello again"

    init(error: STTError? = .networkUnavailable) { self.error = error }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        if let error { throw error }
        return transcript
    }
}

private func makeTempStore() -> PendingRecordingStore {
    PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    )
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema([DictationSession.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

private func dummyWAV() -> Data { Data(count: 44) }

@MainActor
private func waitUntil(
    _ vm: DictationViewModel,
    timeout: TimeInterval = 5,
    _ done: (DictationViewModel.RecordingState) -> Bool
) async throws {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if done(vm.recordingState) { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("Timed out; state is \(vm.recordingState)")
}

private func isError(_ state: DictationViewModel.RecordingState) -> Bool {
    if case .error = state { return true }
    return false
}

private func isResult(_ state: DictationViewModel.RecordingState) -> Bool {
    if case .result = state { return true }
    return false
}

@MainActor
private func makeViewModel(_ stt: SwitchableSTT) -> (DictationViewModel, PendingRecordingStore) {
    let vm = DictationViewModel(sttProvider: stt)
    let store = makeTempStore()
    vm.pendingStore = store
    vm.copyText = { _ in }
    return (vm, store)
}

@Suite(.serialized)
struct PendingRecordingDictationTests {

    @Test("an STT failure keeps the audio and points the error card at it")
    @MainActor
    func failureKeepsAudio() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)

        let pending = try #require(store.all().first)
        #expect(pending.surface == .dictate)
        #expect(pending.workflowID == "wf.dictation")
        #expect(vm.lastPendingRecordingID == pending.id)
    }

    @Test("no speech keeps nothing")
    @MainActor
    func noSpeechKeepsNothing() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: .noTranscript))
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
    }

    @Test("a failure after text reached History keeps nothing")
    @MainActor
    func failureAfterPersistKeepsNothing() {
        let (vm, store) = makeViewModel(SwitchableSTT())
        vm.activeRunPersistedText = true
        vm.handleMainRunFailure(
            DestinationError.destinationUnavailable("Shortcut"),
            wavData: dummyWAV(),
            workflowID: "wf.dictation",
            retryingPendingID: nil
        )
        #expect(store.all().isEmpty)
    }

    @Test("a successful run keeps nothing")
    @MainActor
    func successKeepsNothing() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isResult)
        #expect(store.all().isEmpty)
    }
}
```

- [ ] **Step 2: Register and run to verify it fails**

```bash
python3 "${TMPDIR}xcodeproj_add.py" PendingRecordingDictationTests.swift NoteINV06RecordFlowTests.swift
```

Run the test command with `PendingRecordingDictationTests`.
Expected: build FAILS with `value of type 'DictationViewModel' has no member 'pendingStore'`.

- [ ] **Step 3: Add the stored properties**

In `FonosApp/Services/DictationViewModel.swift`, directly after `var activeProcessingID: UUID?` add:

```swift

    /// Failed recordings kept for retry. Tests swap in a temporary store.
    var pendingStore = PendingRecordingStore.shared

    /// The recording the current error card can retry, if the failure kept one.
    @Published var lastPendingRecordingID: UUID?

    /// Pending recordings being retried from History, for row spinners.
    @Published var retryingPendingIDs: Set<UUID> = []

    /// Quiet retries copy their text. Tests replace this to keep the
    /// simulator's pasteboard out of assertions.
    var copyText: @MainActor (String) -> Void = { UIPasteboard.general.string = $0 }

    /// Set once the running workflow's recorder hook has saved text to
    /// History; a failure after that point has nothing to retry.
    var activeRunPersistedText = false
```

- [ ] **Step 4: Save on failure in the run path**

In `FonosApp/Services/DictationRecordingFlow.swift`, replace the whole `finishRecordingWhenIdle(wavData:)` function (from `@MainActor\n    func finishRecordingWhenIdle` through its closing brace, just before `@MainActor\n    func resetFlowUI()`) with:

```swift
    @MainActor
    func finishRecordingWhenIdle(wavData: Data) {
        let prepared: PreparedMainWorkflow
        do {
            prepared = try preparedMainWorkflow ?? prepareNextMainWorkflow()
        } catch {
            dictationLog.error("❌ Recipe preflight failed: \(error.localizedDescription)")
            recordingState = .error(message: error.localizedDescription)
            return
        }
        preparedMainWorkflow = nil
        runMainWorkflow(prepared, wavData: wavData, retryingPendingID: nil)
    }

    /// Runs a prepared plan on captured or saved audio. A failure before any
    /// text reached History keeps the audio for retry; a retry that fails
    /// again only records the attempt.
    @MainActor
    func runMainWorkflow(
        _ prepared: PreparedMainWorkflow,
        wavData: Data,
        retryingPendingID: UUID?
    ) {
        let processingID = prepared.runID
        activeProcessingID = processingID
        activeRunPersistedText = false
        if workflowPresentation.runID != processingID {
            workflowPresentation = WorkflowRunPresentation(
                runID: processingID,
                definition: prepared.surface.definition,
                catalog: prepared.surface.catalog
            )
        }
        sttLatency = 0
        llmLatency = 0
        recordingState = .processing

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if activeProcessingID == processingID {
                    activeProcessingID = nil
                    processingTask = nil
                }
            }

            do {
                dictationLog.info("🔄 Running voice recipe \(prepared.persistedDefinition.id, privacy: .public)...")
                let workflowResult = try await VoiceWorkflowEngine().run(
                    VoiceWorkflowRunInput(
                        runID: processingID,
                        audioData: wavData,
                        source: prepared.compiled.plan.validation.sourceKind,
                        sourceAcquisitionDuration: Date().timeIntervalSince(
                            prepared.sourceStartedAt
                        ),
                        dryRun: false
                    ),
                    using: prepared.compiled.plan,
                    onEvent: { [weak self] event in
                        await self?.receiveWorkflowEvent(event)
                    },
                    recorder: { [weak self] processed in
                        await self?.persistSession(
                            processed: processed,
                            definition: prepared.persistedDefinition,
                            destination: prepared.surface.destinationSummary
                        )
                    }
                )
                guard activeProcessingID == processingID, !Task.isCancelled else { return }
                updateLatencies(from: workflowResult)
                dictationLog.info("✅ Processing complete: \(workflowResult.finalText.prefix(50))...")
                workflowPresentation.complete(with: workflowResult)
                if let retryingPendingID {
                    pendingStore.discard(id: retryingPendingID)
                }
                recordingState = .result(
                    transcript: workflowResult.rawText,
                    processed: workflowResult.finalText == workflowResult.rawText
                        ? nil
                        : workflowResult.finalText
                )

            } catch is CancellationError {
                dictationLog.info("⏹ Processing cancelled")
            } catch {
                guard activeProcessingID == processingID else { return }
                dictationLog.error("❌ Processing failed: \(error.localizedDescription)")
                handleMainRunFailure(
                    error,
                    wavData: wavData,
                    workflowID: prepared.persistedDefinition.id,
                    retryingPendingID: retryingPendingID
                )
                recordingState = .error(message: error.localizedDescription)
            }
        }
    }

    /// Decides what a failed run leaves behind. Text already in History means
    /// there is nothing to retry: a retried item is then discarded.
    @MainActor
    func handleMainRunFailure(
        _ error: Error,
        wavData: Data,
        workflowID: String,
        retryingPendingID: UUID?
    ) {
        if let retryingPendingID {
            if activeRunPersistedText {
                pendingStore.discard(id: retryingPendingID)
            } else {
                pendingStore.recordAttempt(id: retryingPendingID, error: error.localizedDescription)
                lastPendingRecordingID = retryingPendingID
            }
            return
        }
        guard !activeRunPersistedText,
              PendingRecordingStore.shouldKeep(error: error, audio: wavData) else { return }
        do {
            lastPendingRecordingID = try pendingStore.save(
                wav: wavData,
                surface: .dictate,
                workflowID: workflowID,
                error: error.localizedDescription
            ).id
        } catch {
            dictationLog.error("❌ Could not keep the recording for retry: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 5: Clear the card's pending id on reset, and flag persisted text**

In the same file, replace `resetFlowUI()`:

```swift
    @MainActor
    func resetFlowUI() {
        workflowPresentation = .idle
        frozenSTTProviderName = nil
        frozenLLMProviderName = nil
        sttLatency = 0
        llmLatency = 0
        lastPendingRecordingID = nil
    }
```

Replace `persistSession(processed:definition:destination:)` (keep its doc comment) with the version below, which splits the insert into `insertSession` for reuse by quiet retries in Task 3:

```swift
    /// Engine recorder hook: persists after processors but before outputs, so
    /// a failed delivery still leaves recoverable text in History.
    @MainActor
    func persistSession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition,
        destination: String
    ) {
        activeRunPersistedText = true
        lastSession = insertSession(
            processed: processed,
            definition: definition,
            destination: destination
        )
    }

    @MainActor
    func insertSession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition,
        destination: String
    ) -> DictationSession? {
        guard let context = modelContext else { return nil }
        let legacyModeID = WorkflowMigration.legacyModeID(
            forWorkflowID: definition.id
        )
        let session = DictationSession(
            date: Date(),
            workflowID: definition.id,
            workflowName: definition.name,
            mode: legacyModeID ?? definition.id,
            inputText: processed.rawText,
            outputText: processed.finalText,
            destination: destination,
            latencyMs: processed.timings.total * 1_000
        )
        context.insert(session)
        do {
            try context.save()
        } catch {
            // History is non-essential: match desktop DbRecorder by absorbing
            // local persistence failures instead of failing dictation.
            dictationLog.error("❌ Failed to persist workflow record: \(error.localizedDescription)")
        }
        return session
    }
```

- [ ] **Step 6: Run the new tests and the existing Dictate suites**

Run the test command with `PendingRecordingDictationTests`, then with `DictationPersistenceTests`.
Expected: all PASS. If `DestinationError.destinationUnavailable` is not visible from tests, grep its definition (`grep -rn "enum DestinationError" FonosApp`) and use any of its cases.

- [ ] **Step 7: Commit**

```bash
git add FonosApp/Services/DictationViewModel.swift FonosApp/Services/DictationRecordingFlow.swift FonosAppTests/PendingRecordingDictationTests.swift FonosApp.xcodeproj/project.pbxproj
git commit -m "feat(retry): keep failed Dictate audio for retry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Dictate retry (full and quiet) and discard

**Files:**
- Modify: `FonosApp/Services/DictationWorkflowPreparation.swift` (`prepareMainWorkflow`)
- Modify: `FonosApp/Services/DictationRecordingFlow.swift` (append before `sendToDestination`)
- Test: `FonosAppTests/PendingRecordingDictationTests.swift`

- [ ] **Step 1: Add the failing tests**

Append inside `struct PendingRecordingDictationTests` (before its closing brace):

```swift

    @Test("Retry now runs the recipe on the saved audio and discards it on success")
    @MainActor
    func fullRetrySucceeds() async throws {
        let stt = SwitchableSTT()
        let (vm, store) = makeViewModel(stt)
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let id = try #require(vm.lastPendingRecordingID)

        stt.error = nil
        vm.retryPendingRecording(id)
        try await waitUntil(vm, isResult)

        #expect(vm.recordingState == .result(transcript: "hello again", processed: nil))
        #expect(store.all().isEmpty)
    }

    @Test("a retry that fails again keeps the item and counts the attempt")
    @MainActor
    func fullRetryFailsAgain() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let id = try #require(vm.lastPendingRecordingID)

        vm.retryPendingRecording(id)
        try await waitUntil(vm, isError)

        #expect(store.recording(id: id)?.attempts == 1)
        #expect(store.all().count == 1)
        #expect(vm.lastPendingRecordingID == id)
    }

    @Test("a retry whose recipe is gone reports it and keeps the item")
    @MainActor
    func retryMissingRecipe() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.deleted", error: "e")

        vm.retryPendingRecording(saved.id)

        #expect(vm.recordingState == .error(message: PendingRecordingError.recipeUnavailable.errorDescription!))
        #expect(store.recording(id: saved.id)?.attempts == 1)
        #expect(vm.lastPendingRecordingID == saved.id)
    }

    @Test("quiet retry saves to History, copies, discards, and leaves the Dictate state alone")
    @MainActor
    func quietRetry() async throws {
        let container = try makeContainer()
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        vm.modelContext = container.mainContext
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        let text = try await vm.retryPendingRecordingQuietly(saved.id)

        #expect(text == "hello again")
        #expect(copied == ["hello again"])
        #expect(store.all().isEmpty)
        #expect(vm.recordingState == .idle)
        #expect(vm.lastSession == nil)
        let sessions = try container.mainContext.fetch(FetchDescriptor<DictationSession>())
        #expect(sessions.map(\.outputText) == ["hello again"])
        #expect(sessions.first?.workflowID == "wf.dictation")
    }

    @Test("a quiet retry that fails counts the attempt and rethrows")
    @MainActor
    func quietRetryFails() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        await #expect(throws: STTError.networkUnavailable) {
            try await vm.retryPendingRecordingQuietly(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 1)
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("discard from the error card removes the item and returns to idle")
    @MainActor
    func discardFromCard() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let id = try #require(vm.lastPendingRecordingID)

        vm.discardPendingRecording(id)

        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
        #expect(vm.recordingState == .idle)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run the test command with `PendingRecordingDictationTests`.
Expected: build FAILS with `value of type 'DictationViewModel' has no member 'retryPendingRecording'`.

- [ ] **Step 3: Let preparation target a given recipe**

In `FonosApp/Services/DictationWorkflowPreparation.swift`, change the start of `prepareMainWorkflow` from:

```swift
    func prepareMainWorkflow(
        oneShotDestination: DictationOneShotDestination? = nil
    ) throws -> PreparedMainWorkflow {
        WorkflowMigration.migrate(&config)
        let catalog = config.workflowCatalog
        guard let definition = catalog.workflow(id: config.activeVoiceWorkflowID) else {
            throw VoiceWorkflowCompileError.unknownWidget(
                workflowID: config.activeVoiceWorkflowID,
                widgetID: config.activeVoiceWorkflowID
            )
        }
```

to:

```swift
    func prepareMainWorkflow(
        oneShotDestination: DictationOneShotDestination? = nil,
        workflowID: String? = nil
    ) throws -> PreparedMainWorkflow {
        WorkflowMigration.migrate(&config)
        let catalog = config.workflowCatalog
        let requestedID = workflowID ?? config.activeVoiceWorkflowID
        guard let definition = catalog.workflow(id: requestedID) else {
            throw VoiceWorkflowCompileError.unknownWidget(
                workflowID: requestedID,
                widgetID: requestedID
            )
        }
```

- [ ] **Step 4: Add retry and discard**

In `FonosApp/Services/DictationRecordingFlow.swift`, insert before `@MainActor\n    func sendToDestination`:

```swift
    // MARK: - Pending recordings

    /// Retry from the Dictate error card: the saved recipe, compiled from
    /// current settings, with its outputs, shown like a fresh recording.
    @MainActor
    func retryPendingRecording(_ id: UUID) {
        guard !isRunBusy else { return }
        resetFlowUI()
        do {
            let pending = try retryableRecording(id)
            let wavData = try pendingStore.audio(id: id)
            let prepared = try prepareMainWorkflow(workflowID: pending.workflowID)
            workflowPresentation = WorkflowRunPresentation(
                runID: prepared.runID,
                definition: prepared.surface.definition,
                catalog: prepared.surface.catalog
            )
            runMainWorkflow(prepared, wavData: wavData, retryingPendingID: id)
        } catch {
            dictationLog.error("❌ Retry could not start: \(error.localizedDescription)")
            pendingStore.recordAttempt(id: id, error: error.localizedDescription)
            if pendingStore.recording(id: id) != nil {
                lastPendingRecordingID = id
            }
            recordingState = .error(message: error.localizedDescription)
        }
    }

    /// Retry from History: saves the text and copies it, without running the
    /// recipe's outputs or touching the Dictate screen.
    @MainActor
    @discardableResult
    func retryPendingRecordingQuietly(_ id: UUID) async throws -> String {
        guard !isRunBusy else { throw PendingRecordingError.dictationBusy }
        guard !retryingPendingIDs.contains(id) else { throw PendingRecordingError.alreadyRetrying }
        retryingPendingIDs.insert(id)
        defer { retryingPendingIDs.remove(id) }

        do {
            let pending = try retryableRecording(id)
            let wavData = try pendingStore.audio(id: id)
            let (definition, compiled) = try compileQuietRetry(workflowID: pending.workflowID)
            let result = try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(
                    audioData: wavData,
                    source: compiled.plan.validation.sourceKind
                ),
                using: compiled.plan,
                recorder: { [weak self] processed in
                    await self?.persistRetrySession(processed: processed, definition: definition)
                }
            )
            pendingStore.discard(id: id)
            copyText(result.finalText)
            return result.finalText
        } catch {
            pendingStore.recordAttempt(id: id, error: error.localizedDescription)
            throw error
        }
    }

    @MainActor
    func discardPendingRecording(_ id: UUID) {
        pendingStore.discard(id: id)
        guard lastPendingRecordingID == id else { return }
        lastPendingRecordingID = nil
        if case .error = recordingState {
            recordingState = .idle
            resetFlowUI()
        }
    }

    @MainActor
    private func retryableRecording(_ id: UUID) throws -> PendingRecording {
        guard let pending = pendingStore.recording(id: id) else {
            throw PendingRecordingError.notFound
        }
        guard let workflowID = pending.workflowID,
              config.workflowCatalog.workflow(id: workflowID) != nil else {
            throw PendingRecordingError.recipeUnavailable
        }
        return pending
    }

    /// The recipe with its outputs swapped for return-to-caller, so a quiet
    /// retry yields text and nothing else.
    @MainActor
    private func compileQuietRetry(
        workflowID: String?
    ) throws -> (WorkflowDefinition, VoiceWorkflowPlanFactory.Compilation) {
        WorkflowMigration.migrate(&config)
        let catalog = config.workflowCatalog
        guard let workflowID, let definition = catalog.workflow(id: workflowID) else {
            throw PendingRecordingError.recipeUnavailable
        }
        let widgetID = "out.ios-retry"
        var quietCatalog = catalog
        quietCatalog.widgets.removeAll { $0.id == widgetID }
        quietCatalog.widgets.append(WorkflowWidget(
            id: widgetID,
            role: .output,
            typeTag: "return_to_caller",
            name: String(localized: "Retry"),
            icon: "arrow.clockwise"
        ))
        var quietDefinition = definition
        quietDefinition.outputs = [widgetID]
        let compiled = try compileMainWorkflow(
            definition: quietDefinition,
            catalog: quietCatalog,
            legacyScopeID: legacyScopeID(for: definition),
            outputsByWidgetID: [:]
        )
        return (definition, compiled)
    }

    @MainActor
    private func persistRetrySession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition
    ) {
        _ = insertSession(processed: processed, definition: definition, destination: "result")
    }
```

- [ ] **Step 5: Run the tests**

Run the test command with `PendingRecordingDictationTests`, then `DictationPersistenceTests`.
Expected: all PASS. If `quietDefinition.outputs` is a `let`, check `WorkflowDefinition` (`FonosApp/Models/WorkflowDefinition.swift`); `mainSurfaceWorkflow` already mutates `effectiveDefinition.outputs`, so it is a `var`.

- [ ] **Step 6: Commit**

```bash
git add FonosApp/Services/DictationWorkflowPreparation.swift FonosApp/Services/DictationRecordingFlow.swift FonosAppTests/PendingRecordingDictationTests.swift
git commit -m "feat(retry): retry and discard saved Dictate recordings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Notes keep failed audio and retry quietly

**Files:**
- Modify: `FonosApp/Services/NoteViewModel.swift` (properties after `var vocabStore = VocabStore()`; `recordAndStore`; `persist`)
- Test: `FonosAppTests/PendingRecordingNoteTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `FonosAppTests/PendingRecordingNoteTests.swift`:

```swift
// Notes keep the audio of a failed notebook run; the notebook's pending row
// retries it quietly (new note + copy).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingNoteTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

private final class SwitchableNoteSTT: STTProvider, @unchecked Sendable {
    var error: STTError?
    var transcript = "note text"

    init(error: STTError? = .networkUnavailable) { self.error = error }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        if let error { throw error }
        return transcript
    }
}

private func makeTempStore() -> PendingRecordingStore {
    PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    )
}

@MainActor
private func makeNotes(_ stt: SwitchableNoteSTT) throws
    -> (NoteViewModel, NoteService, NoteContainer, PendingRecordingStore) {
    let container = try ModelContainer(
        for: Schema([NoteContainer.self, NoteEntry.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let service = NoteService(modelContainer: container)
    let notebook = try service.createNotebook(title: "Retry Notebook")
    let vm = NoteViewModel(noteService: service, sttProvider: stt, llmProvider: nil)
    let store = makeTempStore()
    vm.pendingStore = store
    vm.copyText = { _ in }
    return (vm, service, notebook, store)
}

@MainActor
struct PendingRecordingNoteTests {

    @Test("an STT failure keeps the audio for that notebook")
    func failureKeepsAudio() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))

        let pending = try #require(store.all().first)
        #expect(pending.surface == .note)
        #expect(pending.notebookID == notebook.id)
        #expect(vm.lastFailureSavedForRetry)
        if case .error = vm.recordingState {} else { Issue.record("expected error state") }
    }

    @Test("no speech and success keep nothing")
    func nothingKept() async throws {
        let stt = SwitchableNoteSTT(error: .noTranscript)
        let (vm, _, notebook, store) = try makeNotes(stt)
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        #expect(store.all().isEmpty)
        #expect(!vm.lastFailureSavedForRetry)

        stt.error = nil
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        #expect(store.all().isEmpty)
    }

    @Test("quiet retry adds the note, copies it and discards the item")
    func quietRetry() async throws {
        let stt = SwitchableNoteSTT()
        let (vm, service, notebook, store) = try makeNotes(stt)
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let id = try #require(store.all().first?.id)

        stt.error = nil
        let text = try await vm.retryPendingRecording(id)

        #expect(text == "note text")
        #expect(copied == ["note text"])
        #expect(store.all().isEmpty)
        #expect(service.entriesForNotebook(notebook.id).map(\.rawText) == ["note text"])
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("a retry that fails again counts the attempt")
    func retryFailsAgain() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let id = try #require(store.all().first?.id)

        await #expect(throws: STTError.networkUnavailable) {
            try await vm.retryPendingRecording(id)
        }
        #expect(store.recording(id: id)?.attempts == 1)
    }

    @Test("a retry whose notebook is gone reports it and keeps the item")
    func missingNotebook() async throws {
        let (vm, _, _, store) = try makeNotes(SwitchableNoteSTT(error: nil))
        let saved = try store.save(wav: Data(count: 44), surface: .note, notebookID: UUID(), error: "e")

        await #expect(throws: PendingRecordingError.notebookUnavailable) {
            try await vm.retryPendingRecording(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 1)
    }
}
```

- [ ] **Step 2: Register and run to verify it fails**

```bash
python3 "${TMPDIR}xcodeproj_add.py" PendingRecordingNoteTests.swift NoteINV06RecordFlowTests.swift
```

Run the test command with `PendingRecordingNoteTests`.
Expected: build FAILS with `value of type 'NoteViewModel' has no member 'pendingStore'`.

- [ ] **Step 3: Add properties**

In `FonosApp/Services/NoteViewModel.swift`, after `var vocabStore = VocabStore()` add:

```swift

    // MARK: - Pending recordings

    /// Failed recordings kept for retry. Tests swap in a temporary store.
    var pendingStore = PendingRecordingStore.shared

    /// True when the last failure kept its audio, so the sheet can say so.
    @Published var lastFailureSavedForRetry = false

    /// Pending recordings being retried, for row spinners.
    @Published var retryingPendingIDs: Set<UUID> = []

    /// Retries copy their text. Tests replace this.
    var copyText: (String) -> Void = { UIPasteboard.general.string = $0 }
```

- [ ] **Step 4: Save on failure, extract the run, add retry**

Replace `recordAndStore(to:audioData:)` and `persist(_:recipe:to:)` (from the `/// Compile the notebook's settings…` doc comment through the end of `persist`, just before `// MARK: - Audio Level Polling`) with:

```swift
    /// Compile the notebook's settings into a frozen voice workflow, execute it,
    /// then adapt the result into a NoteEntry. Dictate, keyboard and Notes now
    /// share provider resolution, vocabulary, correction, fallback and tracing.
    /// A failure keeps the audio so the notebook can retry it.
    func recordAndStore(to containerId: UUID, audioData: Data) async {
        lastFailureSavedForRetry = false
        guard noteService.notebook(id: containerId) != nil else {
            recordingState = .error(message: "Notebook not found.")
            return
        }

        do {
            _ = try await transcribeAndStore(to: containerId, audioData: audioData)
            recordingState = .done
        } catch {
            noteVMLog.error("Notebook workflow failed: \(error.localizedDescription)")
            if PendingRecordingStore.shouldKeep(error: error, audio: audioData) {
                do {
                    try pendingStore.save(
                        wav: audioData,
                        surface: .note,
                        notebookID: containerId,
                        error: error.localizedDescription
                    )
                    lastFailureSavedForRetry = true
                } catch {
                    noteVMLog.error("Could not keep the recording for retry: \(error.localizedDescription)")
                }
            }
            recordingState = .error(message: error.localizedDescription)
        }
    }

    /// Retry from the notebook: a new note from the saved audio, compiled
    /// from the notebook's current settings, then copied.
    @discardableResult
    func retryPendingRecording(_ id: UUID) async throws -> String {
        guard !retryingPendingIDs.contains(id) else { throw PendingRecordingError.alreadyRetrying }
        guard let pending = pendingStore.recording(id: id) else { throw PendingRecordingError.notFound }
        retryingPendingIDs.insert(id)
        defer { retryingPendingIDs.remove(id) }

        do {
            guard let notebookID = pending.notebookID,
                  noteService.notebook(id: notebookID) != nil else {
                throw PendingRecordingError.notebookUnavailable
            }
            let audioData = try pendingStore.audio(id: id)
            let text = try await transcribeAndStore(to: notebookID, audioData: audioData)
            pendingStore.discard(id: id)
            copyText(text)
            return text
        } catch {
            pendingStore.recordAttempt(id: id, error: error.localizedDescription)
            throw error
        }
    }

    func discardPendingRecording(_ id: UUID) {
        pendingStore.discard(id: id)
    }

    /// Runs the notebook recipe and stores the note. Returns the note's text.
    private func transcribeAndStore(to containerId: UUID, audioData: Data) async throws -> String {
        guard let notebook = noteService.notebook(id: containerId) else {
            throw PendingRecordingError.notebookUnavailable
        }
        let recipe = NotebookPipeline.workflowRecipe(for: notebook)
        let factory = VoiceWorkflowPlanFactory(
            config: config,
            vocabStore: vocabStore,
            sttProviderOverride: _testSTT,
            llmProviderOverride: _testLLM,
            effectiveVocabularyBooks: vocabStore.effectiveBooks(notebookID: containerId)
        )
        let compilation = try factory.compile(
            definition: recipe.definition,
            catalog: recipe.catalog,
            legacyScopeID: nil,
            supportedOutputTypes: ["return_to_caller"],
            resolveOutput: { _ in ReturnToCallerVoiceWorkflowOutput() }
        )
        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(audioData: audioData),
            using: compilation.plan
        )
        let entry = try persist(result, recipe: recipe, to: containerId)
        return entry.processedText ?? entry.rawText
    }

    private func persist(
        _ result: VoiceWorkflowResult,
        recipe: NotebookPipeline.WorkflowRecipe,
        to containerId: UUID
    ) throws -> NoteEntry {
        let processedText = recipe.hasLLM && result.degradations.isEmpty
            ? result.finalText
            : nil
        return try noteService.addEntry(
            to: containerId,
            rawText: result.rawText,
            processedText: processedText,
            mode: recipe.hasLLM ? "llm" : "raw",
            language: recipe.language
        )
    }
```

- [ ] **Step 5: Run the new and existing Notes tests**

Run the test command with `PendingRecordingNoteTests`, then `NoteINV06RecordFlowTests`, then `NoteINV11NoAudioTests`.
Expected: all PASS. (`NoteEntry` stays text-only; audio exists only in the pending store and only after a failure.)

- [ ] **Step 6: Commit**

```bash
git add FonosApp/Services/NoteViewModel.swift FonosAppTests/PendingRecordingNoteTests.swift FonosApp.xcodeproj/project.pbxproj
git commit -m "feat(retry): keep failed note audio and retry it from the notebook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Shared pending row with popup menu

**Files:**
- Create: `FonosApp/Views/Components/PendingRecordingRow.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// A failed recording waiting for retry. The ⋯ button and a long press open
/// the same popup menu.
struct PendingRecordingRow: View {
    let recording: PendingRecording
    let title: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDiscard: () -> Void

    private static let accent = Color(hex: "#fb923c")

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 18))
                .foregroundColor(Self.accent)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "#fafaf9"))
                    Text(Self.durationText(recording.durationSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.5))
                }
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.5))
                Text(recording.lastError)
                    .font(.system(size: 12))
                    .foregroundColor(Self.accent.opacity(0.9))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isRetrying {
                ProgressView()
                    .tint(Self.accent)
            } else {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.7))
                }
                .accessibilityLabel(Text("Pending recording actions"))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Self.accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Self.accent.opacity(0.3), lineWidth: 1)
                )
        )
        .contextMenu {
            if !isRetrying { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRetry) {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        Button {
            UIPasteboard.general.string = recording.lastError
        } label: {
            Label("Copy error", systemImage: "doc.on.doc")
        }
        Button(role: .destructive, action: onDiscard) {
            Label("Discard", systemImage: "trash")
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 2: Register and build**

```bash
python3 "${TMPDIR}xcodeproj_add.py" PendingRecordingRow.swift ActivityCard.swift
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add FonosApp/Views/Components/PendingRecordingRow.swift FonosApp.xcodeproj/project.pbxproj
git commit -m "feat(retry): pending recording row with retry menu

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Retry ▾ on the Dictate error card

**Files:**
- Modify: `FonosApp/Views/DictationView.swift` (properties/init at the top; `errorCard`)
- Modify: `FonosApp/Views/ContentView.swift` (`DictationView(viewModel:)` call)

- [ ] **Step 1: Add the History hand-off**

In `DictationView`, replace:

```swift
    /// Convenience initialiser for previews and unit tests.
    /// Uses a default no-op DictationViewModel (no STT provider).
    init(viewModel: DictationViewModel = DictationViewModel()) {
        self.viewModel = viewModel
    }
```

with:

```swift
    /// Switches to the History tab, where saved recordings are listed.
    var onOpenHistory: () -> Void

    /// Convenience initialiser for previews and unit tests.
    /// Uses a default no-op DictationViewModel (no STT provider).
    init(
        viewModel: DictationViewModel = DictationViewModel(),
        onOpenHistory: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onOpenHistory = onOpenHistory
    }
```

In `ContentView.swift`, replace `DictationView(viewModel: dictationViewModel)` with:

```swift
            DictationView(
                viewModel: dictationViewModel,
                onOpenHistory: { selectedTab = .history }
            )
```

- [ ] **Step 2: Add the menu to the error card**

Replace the whole `errorCard(message:)` function with:

```swift
    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color(hex: "#ef4444"))
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.8))
                    .lineLimit(3)
            }
            if let pendingID = viewModel.lastPendingRecordingID {
                HStack {
                    Text("Recording saved")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.6))
                    Spacer()
                    Menu {
                        Button {
                            viewModel.retryPendingRecording(pendingID)
                        } label: {
                            Label("Retry now", systemImage: "arrow.clockwise")
                        }
                        Button {
                            onOpenHistory()
                        } label: {
                            Label("Open in History", systemImage: "clock")
                        }
                        Button(role: .destructive) {
                            viewModel.discardPendingRecording(pendingID)
                        } label: {
                            Label("Discard recording", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Retry")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#fbbf24"))
                    }
                    .disabled(viewModel.isRunBusy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "#ef4444").opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color(hex: "#ef4444").opacity(0.2), lineWidth: 1)
                )
        )
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add FonosApp/Views/DictationView.swift FonosApp/Views/ContentView.swift
git commit -m "feat(retry): Retry menu on the Dictate error card

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Pending section in History

**Files:**
- Modify: `FonosApp/Views/HistoryView.swift`
- Modify: `FonosApp/Views/ContentView.swift` (`HistoryView()` call)

- [ ] **Step 1: Inject the view model and state**

In `HistoryView`, after `@Environment(\.modelContext) private var modelContext` add:

```swift
    @ObservedObject var dictationViewModel: DictationViewModel
    @State private var pendingRecordings: [PendingRecording] = []
    @State private var retryError: String?
```

In `ContentView.swift` replace `HistoryView()` with `HistoryView(dictationViewModel: dictationViewModel)`. In the `#Preview` at the bottom of `HistoryView.swift`, replace `HistoryView()` with `HistoryView(dictationViewModel: DictationViewModel())`.

- [ ] **Step 2: Show the list when only pending items exist, and keep it fresh**

In `body`, replace:

```swift
                    if sessions.isEmpty {
                        emptyState
                    } else if filteredSessions.isEmpty {
                        noResultsState
                    } else {
                        sessionList
                    }
```

with:

```swift
                    if sessions.isEmpty && pendingRecordings.isEmpty {
                        emptyState
                    } else if filteredSessions.isEmpty && pendingRecordings.isEmpty {
                        noResultsState
                    } else {
                        sessionList
                    }
```

Then replace:

```swift
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
        }
```

with:

```swift
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .onAppear(perform: reloadPending)
            .onReceive(NotificationCenter.default.publisher(for: .pendingRecordingsChanged)) { _ in
                reloadPending()
            }
            .alert(
                "Retry Failed",
                isPresented: Binding(
                    get: { retryError != nil },
                    set: { if !$0 { retryError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { retryError = nil }
            } message: {
                Text(retryError ?? "")
            }
        }
```

- [ ] **Step 3: Add the pending rows**

In `sessionList`, directly after `List {` insert:

```swift
            if !pendingRecordings.isEmpty {
                Section {
                    ForEach(pendingRecordings) { recording in
                        PendingRecordingRow(
                            recording: recording,
                            title: pendingTitle(recording),
                            isRetrying: dictationViewModel.retryingPendingIDs.contains(recording.id),
                            onRetry: { retry(recording.id) },
                            onDiscard: { dictationViewModel.discardPendingRecording(recording.id) }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    Text("Pending")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#fb923c"))
                }
            }
```

Before `// MARK: - Delete`, add:

```swift
    // MARK: - Pending recordings

    private func reloadPending() {
        pendingRecordings = dictationViewModel.pendingStore.pending(for: .history)
    }

    private func pendingTitle(_ recording: PendingRecording) -> String {
        recording.workflowID
            .flatMap { dictationViewModel.config.workflowCatalog.workflow(id: $0)?.name }
            ?? String(localized: "Dictation")
    }

    private func retry(_ id: UUID) {
        Task {
            do {
                try await dictationViewModel.retryPendingRecordingQuietly(id)
            } catch {
                retryError = error.localizedDescription
            }
        }
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add FonosApp/Views/HistoryView.swift FonosApp/Views/ContentView.swift
git commit -m "feat(retry): pending recordings in History

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Pending rows in the notebook and the record sheet message

**Files:**
- Modify: `FonosApp/Views/NotebookDetailView.swift`
- Modify: `FonosApp/Views/RecordNoteSheet.swift` (`.error` case)

- [ ] **Step 1: Notebook state**

In `NotebookDetailView`, after `@State private var persistenceError: String?` add:

```swift
    @State private var pendingRecordings: [PendingRecording] = []
    @State private var retryError: String?
```

- [ ] **Step 2: Show the list when only pending items exist**

Replace:

```swift
                if entries.isEmpty {
                    emptyState
                } else {
                    entriesList
                }
```

with:

```swift
                if entries.isEmpty && pendingRecordings.isEmpty {
                    emptyState
                } else {
                    entriesList
                }
```

- [ ] **Step 3: Rows, refresh and alert**

In `entriesList`, directly after `List {` insert:

```swift
            ForEach(pendingRecordings) { recording in
                PendingRecordingRow(
                    recording: recording,
                    title: String(localized: "Voice note"),
                    isRetrying: noteViewModel.retryingPendingIDs.contains(recording.id),
                    onRetry: { retry(recording.id) },
                    onDiscard: { noteViewModel.discardPendingRecording(recording.id) }
                )
                .listRowBackground(Color(hex: "#1a1917"))
                .listRowSeparator(.hidden)
            }
```

Replace `.onAppear { reloadEntries() }` with:

```swift
        .onAppear { reloadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .pendingRecordingsChanged)) { _ in
            reloadEntries()
        }
        .alert(
            "Retry Failed",
            isPresented: Binding(
                get: { retryError != nil },
                set: { if !$0 { retryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { retryError = nil }
        } message: {
            Text(retryError ?? "")
        }
```

Replace `reloadEntries()`:

```swift
    private func reloadEntries() {
        entries = noteService.entriesForNotebook(notebook.id)
        pendingRecordings = noteViewModel.pendingStore.pending(for: .notebook(notebook.id))
    }

    private func retry(_ id: UUID) {
        Task {
            do {
                try await noteViewModel.retryPendingRecording(id)
            } catch {
                retryError = error.localizedDescription
            }
        }
    }
```

(A successful retry discards the item, which posts `pendingRecordingsChanged`, which reloads both the new entry and the pending list.)

- [ ] **Step 4: Record sheet message**

In `RecordNoteSheet.swift`, in `case .error(let message):`, after the `Text(message)` block (its `.padding(.horizontal, 32)` line) and before `Button("Dismiss")`, insert:

```swift
                        if noteViewModel.lastFailureSavedForRetry {
                            Text("Saved to this notebook for retry.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(hex: "#fb923c"))
                        }
```

- [ ] **Step 5: Build**

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add FonosApp/Views/NotebookDetailView.swift FonosApp/Views/RecordNoteSheet.swift
git commit -m "feat(retry): pending recordings in the notebook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Full verification

- [ ] **Step 1: Run the whole test suite**

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp -destination 'platform=iOS Simulator,name=iPhone 16e' 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`. Any failure in an existing suite is a regression from Tasks 2–4; fix it before continuing.

- [ ] **Step 2: Check it in the running app**

Use the `run` skill to launch the app in the simulator, then:

1. In Settings → Models, point STT at a cloud profile with an unreachable URL (or turn on the simulator's Network Link Conditioner "100% Loss").
2. Dictate a few words. Expect the error card with "Recording saved" and **Retry ▾**; the menu shows Retry now / Open in History / Discard recording.
3. Open in History: a "Pending" section with the row; ⋯ and long-press show Retry / Copy error / Discard.
4. Restore the network and Retry from History. Expect the row to become a normal History entry and the text on the clipboard.
5. Repeat in a notebook: the record sheet says "Saved to this notebook for retry."; the notebook shows the pending row; Retry adds a note.

- [ ] **Step 3: Commit any fixes**

```bash
git status --short
```

If anything changed, commit it with a `fix(retry): …` message ending with the co-author line.
